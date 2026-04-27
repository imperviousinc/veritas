use std::collections::HashSet;
use std::time::Duration;
use futures_util::{SinkExt, StreamExt};
use simsearch::SimSearch;
use spaces_protocol::bitcoin::hashes::{sha256, Hash, HashEngine};
use spaces_protocol::bitcoin::secp256k1::{self, Secp256k1, XOnlyPublicKey};
use spaces_protocol::bitcoin::bech32;
use tokio_tungstenite::tungstenite::Message as WsMessage;

use crate::VeritasError;

const RELAY_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(uniffi::Record)]
pub struct NostrMessage {
    pub note_id: String,
    pub content: String,
    pub pubkey: String,
    pub created_at: u64,
}

/// Fetch all #veritas notes by a specific npub from the given relays,
/// optionally filtering by a fuzzy text query.
pub(crate) async fn find_message(
    npub: &str,
    relays: &[String],
    text: Option<&str>,
) -> Result<Vec<NostrMessage>, VeritasError> {
    let pubkey = decode_npub(npub)?;

    let mut all_events: Vec<NostrEvent> = Vec::new();
    let mut seen_ids: HashSet<[u8; 32]> = HashSet::new();

    for relay_url in relays {
        match fetch_tagged(relay_url, &pubkey).await {
            Ok(events) => {
                for event in events {
                    if seen_ids.insert(event.id) {
                        all_events.push(event);
                    }
                }
                if !all_events.is_empty() {
                    break;
                }
            }
            Err(e) => {
                tracing::warn!("relay {} failed: {}", relay_url, e);
            }
        }
    }

    let filtered = if let Some(query) = text {
        let mut engine: SimSearch<usize> = SimSearch::new();
        for (i, event) in all_events.iter().enumerate() {
            engine.insert(i, &event.content);
        }
        let indices = engine.search(query);
        let keep: HashSet<usize> = indices.into_iter().collect();
        all_events
            .into_iter()
            .enumerate()
            .filter(|(i, _)| keep.contains(i))
            .map(|(_, e)| e)
            .collect::<Vec<_>>()
    } else {
        all_events
    };

    let mut results: Vec<NostrMessage> = filtered
        .into_iter()
        .map(|e| NostrMessage {
            note_id: hex::encode(e.id),
            content: e.content,
            pubkey: hex::encode(e.pubkey),
            created_at: e.created_at,
        })
        .collect();

    results.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(results)
}

/// Decode a nostr npub (bech32) to a 32-byte pubkey.
fn decode_npub(npub_str: &str) -> Result<[u8; 32], VeritasError> {
    let (hrp, data) = bech32::decode(npub_str)
        .map_err(|e| VeritasError::Nostr { msg: format!("invalid npub: {e}") })?;
    if hrp != bech32::Hrp::parse_unchecked("npub") {
        return Err(VeritasError::Nostr { msg: "expected npub hrp".into() });
    }
    let bytes: [u8; 32] = data.try_into()
        .map_err(|_| VeritasError::Nostr { msg: "npub must be 32 bytes".into() })?;
    Ok(bytes)
}

// -- Nostr event parsing and verification --

struct NostrEvent {
    id: [u8; 32],
    pubkey: [u8; 32],
    created_at: u64,
    kind: u64,
    tags: serde_json::Value,
    content: String,
    sig: [u8; 64],
}

fn parse_event(value: &serde_json::Value) -> Option<NostrEvent> {
    let obj = value.as_object()?;
    let id = hex::decode(obj.get("id")?.as_str()?).ok()?;
    let pubkey = hex::decode(obj.get("pubkey")?.as_str()?).ok()?;
    let created_at = obj.get("created_at")?.as_u64()?;
    let kind = obj.get("kind")?.as_u64()?;
    let tags = obj.get("tags")?.clone();
    let content = obj.get("content")?.as_str()?.to_string();
    let sig = hex::decode(obj.get("sig")?.as_str()?).ok()?;

    Some(NostrEvent {
        id: id.try_into().ok()?,
        pubkey: pubkey.try_into().ok()?,
        created_at,
        kind,
        tags,
        content,
        sig: sig.try_into().ok()?,
    })
}

fn verify_event(event: &NostrEvent) -> bool {
    verify_event_id(event) && verify_event_sig(event)
}

fn verify_event_id(event: &NostrEvent) -> bool {
    let serialized = serde_json::to_string(&serde_json::json!([
        0,
        hex::encode(event.pubkey),
        event.created_at,
        event.kind,
        event.tags,
        event.content,
    ]));

    let Ok(serialized) = serialized else {
        return false;
    };

    let mut engine = sha256::Hash::engine();
    engine.input(serialized.as_bytes());
    let hash = sha256::Hash::from_engine(engine);
    hash.to_byte_array() == event.id
}

fn verify_event_sig(event: &NostrEvent) -> bool {
    let ctx = Secp256k1::verification_only();
    let Ok(pubkey) = XOnlyPublicKey::from_slice(&event.pubkey) else {
        return false;
    };
    let Ok(sig) = secp256k1::schnorr::Signature::from_slice(&event.sig) else {
        return false;
    };
    let msg = secp256k1::Message::from_digest(event.id);
    ctx.verify_schnorr(&sig, &msg, &pubkey).is_ok()
}

// -- Nostr relay communication --

/// Fetch all #veritas kind:1 events from a relay for a specific author.
async fn fetch_tagged(
    url: &str,
    pubkey: &[u8; 32],
) -> Result<Vec<NostrEvent>, VeritasError> {
    let (mut ws, _) = tokio::time::timeout(
        RELAY_TIMEOUT,
        tokio_tungstenite::connect_async(url),
    )
    .await
    .map_err(|_| VeritasError::Nostr { msg: format!("timeout connecting to {url}") })?
    .map_err(|e| VeritasError::Nostr { msg: format!("websocket error: {e}") })?;

    let sub_id = "veritas";
    let req = serde_json::json!([
        "REQ",
        sub_id,
        {
            "authors": [hex::encode(pubkey)],
            "#t": ["veritas"],
            "kinds": [1],
            "limit": 50
        }
    ]);

    ws.send(WsMessage::Text(req.to_string().into()))
        .await
        .map_err(|e| VeritasError::Nostr { msg: format!("send error: {e}") })?;

    let mut events = Vec::new();

    let result = tokio::time::timeout(RELAY_TIMEOUT, async {
        while let Some(msg) = ws.next().await {
            let text = match msg {
                Ok(WsMessage::Text(t)) => t.to_string(),
                Ok(WsMessage::Close(_)) => break,
                Err(e) => {
                    tracing::warn!("relay read error: {e}");
                    break;
                }
                _ => continue,
            };

            let parsed: serde_json::Value = match serde_json::from_str(&text) {
                Ok(v) => v,
                Err(_) => continue,
            };

            let arr = match parsed.as_array() {
                Some(a) => a,
                None => continue,
            };

            match arr.first().and_then(|v| v.as_str()) {
                Some("EVENT") if arr.len() >= 3 => {
                    if let Some(event) = parse_event(&arr[2]) {
                        if verify_event(&event) {
                            events.push(event);
                        }
                    }
                }
                Some("EOSE") => break,
                Some("NOTICE") => {
                    if let Some(msg) = arr.get(1).and_then(|v| v.as_str()) {
                        tracing::warn!("relay notice: {msg}");
                    }
                }
                _ => {}
            }
        }
    })
    .await;

    if result.is_err() {
        tracing::warn!("relay {url} timed out");
    }

    let close = serde_json::json!(["CLOSE", sub_id]);
    let _ = ws.send(WsMessage::Text(close.to_string().into())).await;
    let _ = ws.close(None).await;

    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT_RELAYS: &[&str] = &[
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.nostr.band",
    ];

    fn default_relays() -> Vec<String> {
        DEFAULT_RELAYS.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn test_decode_npub() {
        let pubkey = decode_npub(
            "npub1al9wl7han3nnh4zv78qm2r8lhu3frmysps948ctxdzzkfztu06hswjuds8"
        ).expect("valid npub");
        assert_eq!(pubkey.len(), 32);
    }

    #[test]
    fn test_event_id_verification() {
        let pubkey = [0x3bu8; 32];
        let event = NostrEvent {
            id: [0u8; 32],
            pubkey,
            created_at: 1673347337,
            kind: 1,
            tags: serde_json::json!([]),
            content: "hello world".into(),
            sig: [0u8; 64],
        };

        let serialized = serde_json::to_string(&serde_json::json!([
            0,
            hex::encode(event.pubkey),
            event.created_at,
            event.kind,
            event.tags,
            event.content,
        ])).unwrap();

        let mut engine = sha256::Hash::engine();
        engine.input(serialized.as_bytes());
        let expected_id = sha256::Hash::from_engine(engine).to_byte_array();

        let event_with_id = NostrEvent { id: expected_id, ..event };
        assert!(verify_event_id(&event_with_id));

        let bad_event = NostrEvent { id: [0xffu8; 32], ..event_with_id };
        assert!(!verify_event_id(&bad_event));
    }

    #[tokio::test]
    #[ignore] // requires network
    async fn test_fetch_tagged() {
        let pubkey = decode_npub(
            "npub1kh4mfzvrgu64rv65hwefspa26un29vpecv96vgcwnwe7fy93h75scw9u73"
        ).expect("valid npub");

        println!("Pubkey hex: {}", hex::encode(pubkey));

        let events = fetch_tagged("wss://relay.damus.io", &pubkey).await
            .expect("relay query should succeed");

        println!("Found {} #veritas events", events.len());
        for event in &events {
            println!("---");
            println!("Content: {}", &event.content[..event.content.len().min(200)]);
            println!("Created: {}", event.created_at);
        }
    }

    #[tokio::test]
    #[ignore] // requires network
    async fn test_find_nostr_with_text() {
        let relays = default_relays();
        let msgs = find_message(
            "npub1kh4mfzvrgu64rv65hwefspa26un29vpecv96vgcwnwe7fy93h75scw9u73",
            &relays,
            Some("pancakes"),
        ).await.expect("search should work");
        println!("Found {} messages matching 'pancakes'", msgs.len());
        for msg in &msgs {
            println!("{}", msg.content);
        }
    }

    #[tokio::test]
    #[ignore] // requires network
    async fn test_fuzzy_search_primal() {
        let relays = vec!["wss://relay.primal.net".to_string()];
        let msgs = find_message(
            "npub1kh4mfzvrgu64rv65hwefspa26un29vpecv96vgcwnwe7fy93h75scw9u73",
            &relays,
            Some("i lik paknackes"),
        ).await.expect("search should work");
        println!("Found {} messages matching 'i lik paknackes'", msgs.len());
        for msg in &msgs {
            println!("  [{}] {}", msg.note_id, msg.content);
        }
    }
}