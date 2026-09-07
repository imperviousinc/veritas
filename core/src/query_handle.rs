//! Query a fabric handle via certrelay and return decoded SIP-7 records as JSON.
//!
//! Same `GET /query?q=@space,label@space` the search UI uses. Relays in
//! `EXCLUDE_CERTRELAY_URL` are skipped even if they are bootstrap seeds or
//! appear in `/peers`.

use fabric::libveritas::cert::KeyHash;
use fabric::libveritas::sip7;
use fabric::Message;
use serde::{Deserialize, Serialize};
use spaces_nums::num_id::NumId;
use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Duration;

pub const DEFAULT_EXCLUDE: &str = "http://70.251.209.207:47778";

/// `None` = not set by the app (env var or default). `Some("")` = exclude nothing.
static EXCLUDE_OVERRIDE: Mutex<Option<String>> = Mutex::new(None);

/// Set the comma-separated exclude list. An empty string excludes no relays.
pub fn set_exclude_relays(raw: String) {
    *EXCLUDE_OVERRIDE.lock().unwrap_or_else(|e| e.into_inner()) = Some(raw);
}

pub fn current_exclude_relays() -> String {
    exclude_raw()
}

const PEER_TIMEOUT: Duration = Duration::from_secs(10);
const QUERY_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Serialize)]
pub struct QueryHandleResult {
    pub handle: String,
    pub found: bool,
    pub relay: String,
    pub anchor: u32,
    pub proof_bytes: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub num_id: Option<String>,
    pub spaces: Vec<SpaceJson>,
}

#[derive(Debug, Serialize)]
pub struct SpaceJson {
    pub space: String,
    pub receipt: bool,
    pub records: Vec<RecordJson>,
    pub handles: Vec<HandleJson>,
}

#[derive(Debug, Serialize)]
pub struct HandleJson {
    pub handle: String,
    pub temporary: bool,
    pub records: Vec<RecordJson>,
    pub fallback_records: Vec<RecordJson>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum RecordJson {
    Seq { version: u64 },
    Txt { key: String, value: Vec<String> },
    Addr { key: String, value: Vec<String> },
    Blob { key: String, value: String },
    Sig { canonical: String, handle: String },
    Malformed { rtype: u8 },
    Unknown { rtype: u8 },
}

/// True for a space (`@space` or `space`), false for a handle (`subspace@space`).
pub fn is_space_name(name: &str) -> bool {
    let name = name.trim();
    !name.is_empty() && (name.starts_with('@') || !name.contains('@'))
}

pub fn normalize_space(name: &str) -> String {
    let name = name.trim();
    if name.starts_with('@') {
        name.to_string()
    } else {
        format!("@{name}")
    }
}

pub async fn query(handle: &str) -> Result<QueryHandleResult, String> {
    let handle = handle.trim();
    if !handle.contains('@') || handle.starts_with('@') {
        return Err("expected a handle like subspace@space".into());
    }

    let blocked = excluded_keys();
    let seeds: Vec<String> = fabric::seeds::SEED_SEMI_TRUSTED
        .iter()
        .map(|(url, _)| (*url).to_string())
        .collect();
    let mut relays = discover_relays(&seeds, &blocked).await;
    if relays.is_empty() {
        return Err("no certrelay URLs left after exclude list".into());
    }
    shuffle(&mut relays);
    tracing::info!(
        "queryhandle using {} non-excluded relays, first={}",
        relays.len(),
        relays[0]
    );

    let space = format!("@{}", handle.rsplit('@').next().unwrap());
    let q = format!("{space},{handle}");
    let client = http_client();
    let mut last_err = "no relays".to_string();

    for relay in relays {
        let url = format!("{relay}/query");
        let resp = match client
            .get(&url)
            .query(&[("q", q.as_str())])
            .timeout(QUERY_TIMEOUT)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                last_err = format!("{relay}: {e}");
                continue;
            }
        };
        if !resp.status().is_success() {
            last_err = format!("{relay}: HTTP {}", resp.status().as_u16());
            continue;
        }
        let bytes = match resp.bytes().await {
            Ok(b) if !b.is_empty() => b,
            Ok(_) => {
                last_err = format!("{relay}: empty proof");
                continue;
            }
            Err(e) => {
                last_err = format!("{relay}: {e}");
                continue;
            }
        };

        let msg = Message::from_slice(&bytes).map_err(|e| format!("decode proof: {e}"))?;
        let result = decode_message(handle, &relay, &bytes, &msg);
        if result.found {
            return Ok(result);
        }
        last_err = format!("{handle}: not in proof from {relay}");
    }

    Err(last_err)
}

/// Parse spaced `getfallback` result JSON into SIP-7 records.
pub fn fallback_records_from_rpc(value: &serde_json::Value) -> Option<Vec<RecordJson>> {
    if let Some(data) = value.get("data").and_then(|v| v.as_str()) {
        use base64::Engine;
        if let Ok(raw) = base64::engine::general_purpose::STANDARD.decode(data) {
            if let Some(recs) = fallback_records_from_set(&sip7::RecordSet::new(raw)) {
                return Some(recs);
            }
        }
    }
    if let Some(recs) = value.get("records") {
        if recs.is_array() {
            if let Ok(parsed) = serde_json::from_value::<Vec<RecordJson>>(recs.clone()) {
                return Some(parsed);
            }
        }
    }
    None
}

pub fn fallback_records_from_set(set: &sip7::RecordSet) -> Option<Vec<RecordJson>> {
    let recs = records_json(set);
    if recs.is_empty() { None } else { Some(recs) }
}

impl QueryHandleResult {
    /// Attach on-chain num fallback next to the queried handle's `records`.
    pub fn set_handle_fallback(&mut self, records: Vec<RecordJson>) {
        let target = self.handle.as_str();
        for space in &mut self.spaces {
            for h in &mut space.handles {
                if h.handle == target {
                    h.fallback_records = records;
                    return;
                }
            }
        }
    }
}

fn shuffle<T>(items: &mut [T]) {
    if items.len() < 2 {
        return;
    }
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(1);
    let marker: u8 = 0;
    seed ^= std::ptr::addr_of!(marker) as u64;
    for i in (1..items.len()).rev() {
        seed = seed.wrapping_mul(0x9E37_79B9_7F4A_7C15).wrapping_add(1);
        let j = (seed as usize) % (i + 1);
        items.swap(i, j);
    }
}

fn http_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .user_agent("veritas")
            .build()
            .expect("reqwest client")
    })
}

fn relay_key(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let rest = trimmed
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(trimmed);
    rest.split('/').next().unwrap_or(rest).to_ascii_lowercase()
}

fn exclude_raw() -> String {
    if let Some(overridden) = EXCLUDE_OVERRIDE
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
    {
        return overridden;
    }
    std::env::var("EXCLUDE_CERTRELAY_URL").unwrap_or_else(|_| DEFAULT_EXCLUDE.to_string())
}

fn excluded_keys() -> HashSet<String> {
    exclude_raw()
        .split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(relay_key)
        .collect()
}

fn is_excluded(url: &str, blocked: &HashSet<String>) -> bool {
    let key = relay_key(url);
    !key.is_empty() && blocked.contains(&key)
}

async fn discover_relays(seeds: &[String], blocked: &HashSet<String>) -> Vec<String> {
    let mut ordered = Vec::new();
    let mut seen = HashSet::new();

    fn add(url: &str, ordered: &mut Vec<String>, seen: &mut HashSet<String>, blocked: &HashSet<String>) {
        let url = url.trim().trim_end_matches('/');
        let key = relay_key(url);
        if key.is_empty() || seen.contains(&key) {
            return;
        }
        if is_excluded(url, blocked) {
            seen.insert(key);
            tracing::info!("skip excluded certrelay {url}");
            return;
        }
        seen.insert(key);
        ordered.push(url.to_string());
    }

    for seed in seeds {
        add(seed, &mut ordered, &mut seen, blocked);
    }

    let client = http_client();
    let bootstrap = ordered.clone();
    for seed in bootstrap {
        let resp = match client
            .get(format!("{seed}/peers"))
            .timeout(PEER_TIMEOUT)
            .send()
            .await
        {
            Ok(r) if r.status().is_success() => r,
            _ => continue,
        };
        let value: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(_) => continue,
        };
        let peers = if value.is_array() {
            value.as_array().cloned().unwrap_or_default()
        } else {
            value
                .get("peers")
                .or_else(|| value.get("relays"))
                .and_then(|v| v.as_array())
                .cloned()
                .unwrap_or_default()
        };
        for peer in peers {
            let url = peer
                .as_str()
                .map(str::to_string)
                .or_else(|| peer.get("url").and_then(|u| u.as_str()).map(str::to_string));
            if let Some(url) = url {
                add(&url, &mut ordered, &mut seen, blocked);
            }
        }
    }

    ordered
}

fn decode_message(handle: &str, relay: &str, bytes: &[u8], msg: &Message) -> QueryHandleResult {
    let mut found = false;
    let mut num_id = None;
    let mut spaces = Vec::new();
    for bundle in &msg.spaces {
        let mut handles = Vec::new();
        for epoch in &bundle.epochs {
            for h in &epoch.handles {
                let name = format!("{}{}", h.name, bundle.subject);
                if name == handle {
                    found = true;
                    num_id = Some(NumId::from_spk::<KeyHash>(h.genesis_spk.clone()).to_string());
                }
                handles.push(HandleJson {
                    handle: name,
                    temporary: h.signature.is_some(),
                    records: h.records.as_ref().map(records_json).unwrap_or_default(),
                    fallback_records: Vec::new(),
                });
            }
        }
        spaces.push(SpaceJson {
            space: bundle.subject.to_string(),
            receipt: bundle.receipt.is_some(),
            records: bundle.records.as_ref().map(records_json).unwrap_or_default(),
            handles,
        });
    }
    QueryHandleResult {
        handle: handle.to_string(),
        found,
        relay: relay.to_string(),
        anchor: msg.chain.anchor.height,
        proof_bytes: bytes.len(),
        num_id,
        spaces,
    }
}

fn records_json(set: &sip7::RecordSet) -> Vec<RecordJson> {
    match set.unpack() {
        Ok(records) => records
            .into_iter()
            .map(|rec| match rec {
                sip7::ParsedRecord::Seq(version) => RecordJson::Seq { version },
                sip7::ParsedRecord::Txt { key, value } => RecordJson::Txt {
                    key: key.to_string(),
                    value: value.to_vec().into_iter().map(str::to_string).collect(),
                },
                sip7::ParsedRecord::Addr { key, value } => RecordJson::Addr {
                    key: key.to_string(),
                    value: value.to_vec().into_iter().map(str::to_string).collect(),
                },
                sip7::ParsedRecord::Blob { key, value } => RecordJson::Blob {
                    key: key.to_string(),
                    value: hex::encode(value),
                },
                sip7::ParsedRecord::Sig(sig) => RecordJson::Sig {
                    canonical: sig.canonical.to_string(),
                    handle: sig.handle.to_string(),
                },
                sip7::ParsedRecord::Malformed { rtype, .. } => RecordJson::Malformed { rtype },
                sip7::ParsedRecord::Unknown { rtype, .. } => RecordJson::Unknown { rtype },
            })
            .collect(),
        Err(_) => Vec::new(),
    }
}
