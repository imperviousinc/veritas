//! Query a fabric handle (default: `subspace@space`) from certrelay and print
//! the handles + SIP-7 records in the proof.
//!
//! This is `GET /query?q=@space,subspace@space` — the same request the Veritas
//! search UI sends. It is not spaced `getspace`.
//!
//! Relays in `EXCLUDE_CERTRELAY_URL` (comma-separated) are skipped even if
//! they appear as bootstrap seeds or in `/peers`.
//!
//! ```bash
//! cargo run --example resolve_handle -- subspace@space
//! ```

use fabric::libveritas::sip7;
use fabric::Message;
use std::collections::HashSet;
use std::process::Command;

const DEFAULT_RELAYS: &[&str] = &[
    "https://relay-cosmos.spacesprotocol.org",
    "https://relay-atlas.spacesprotocol.org",
    "https://relay-orion.spacesprotocol.org",
    "https://relay-pulsar.spacesprotocol.org",
];
const DEFAULT_EXCLUDE: &str = "http://70.251.209.207:47778";

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let handle = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "subspace@space".to_string());

    if !handle.contains('@') || handle.starts_with('@') {
        eprintln!("usage: resolve_handle <label@space>     e.g. subspace@space");
        std::process::exit(1);
    }

    let exclude = std::env::var("EXCLUDE_CERTRELAY_URL").unwrap_or_else(|_| DEFAULT_EXCLUDE.into());
    let blocked = excluded_keys(&exclude);
    let seeds = match std::env::var("CERTRELAY_URL") {
        Ok(url) if !url.is_empty() => vec![url],
        _ => DEFAULT_RELAYS.iter().map(|s| s.to_string()).collect(),
    };
    let mut relays = discover_relays(&seeds, &blocked)?;
    if relays.is_empty() {
        eprintln!("No relays left after EXCLUDE_CERTRELAY_URL={exclude}");
        std::process::exit(1);
    }
    shuffle(&mut relays);
    eprintln!(
        "trying {} non-excluded relays, first={}",
        relays.len(),
        relays[0]
    );

    let space = format!("@{}", handle.rsplit('@').next().unwrap());
    let q = format!("{space},{handle}");

    for relay in &relays {
        let url = format!("{relay}/query");
        eprintln!("GET {url}?q={q}");
        let output = Command::new("curl")
            .args([
                "-sS",
                "-A",
                "veritas-examples",
                "--max-time",
                "30",
                "-G",
                &url,
                "--data-urlencode",
                &format!("q={q}"),
            ])
            .output()?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            eprintln!("curl failed: {stderr}");
            continue;
        }
        if output.stdout.is_empty() {
            eprintln!("empty proof from {relay}");
            continue;
        }

        let msg = Message::from_slice(&output.stdout)?;
        println!(
            "proof {} bytes  anchor={}  spaces={}",
            output.stdout.len(),
            msg.chain.anchor.height,
            msg.spaces.len()
        );

        let mut found = false;
        for bundle in &msg.spaces {
            println!(
                "space {}  receipt={}",
                bundle.subject,
                bundle.receipt.is_some()
            );
            if let Some(records) = &bundle.records {
                print_records("  space records", records);
            }
            for epoch in &bundle.epochs {
                for h in &epoch.handles {
                    let name = format!("{}{}", h.name, bundle.subject);
                    println!("  handle {name}  temporary={}", h.signature.is_some());
                    if let Some(records) = &h.records {
                        print_records("    records", records);
                    }
                    if name == handle {
                        found = true;
                    }
                }
            }
        }

        if found {
            return Ok(());
        }
        eprintln!("{handle}: not in proof from {relay}");
    }

    eprintln!("{handle}: not found");
    std::process::exit(1);
}

fn relay_key(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    let rest = trimmed
        .split_once("://")
        .map(|(_, rest)| rest)
        .unwrap_or(trimmed);
    rest.split('/').next().unwrap_or(rest).to_ascii_lowercase()
}

fn excluded_keys(raw: &str) -> HashSet<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(relay_key)
        .collect()
}

fn is_excluded(url: &str, blocked: &HashSet<String>) -> bool {
    let key = relay_key(url);
    !key.is_empty() && blocked.contains(&key)
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

fn add_relay(url: &str, ordered: &mut Vec<String>, seen: &mut HashSet<String>, blocked: &HashSet<String>) {
    let url = url.trim().trim_end_matches('/');
    let key = relay_key(url);
    if key.is_empty() || seen.contains(&key) {
        return;
    }
    if is_excluded(url, blocked) {
        if seen.insert(key.clone()) {
            eprintln!("skip excluded relay {url}");
        }
        return;
    }
    seen.insert(key);
    ordered.push(url.to_string());
}

fn discover_relays(
    seeds: &[String],
    blocked: &HashSet<String>,
) -> Result<Vec<String>, Box<dyn std::error::Error>> {
    let mut ordered = Vec::new();
    let mut seen = HashSet::new();

    for seed in seeds {
        add_relay(seed, &mut ordered, &mut seen, blocked);
    }

    let bootstrap = ordered.clone();
    for seed in bootstrap {
        let output = Command::new("curl")
            .args([
                "-sS",
                "-A",
                "veritas-examples",
                "--max-time",
                "10",
                &format!("{seed}/peers"),
            ])
            .output()?;
        if !output.status.success() || output.stdout.is_empty() {
            continue;
        }
        let value: serde_json::Value = match serde_json::from_slice(&output.stdout) {
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
                add_relay(&url, &mut ordered, &mut seen, blocked);
            }
        }
    }

    Ok(ordered)
}

fn print_records(label: &str, set: &sip7::RecordSet) {
    match set.unpack() {
        Ok(records) if records.is_empty() => {}
        Ok(records) => {
            println!("{label}:");
            for rec in records {
                match rec {
                    sip7::ParsedRecord::Txt { key, value } => {
                        println!("    txt  {key} = {}", value.to_vec().join(", "));
                    }
                    sip7::ParsedRecord::Addr { key, value } => {
                        println!("    addr {key} = {}", value.to_vec().join(", "));
                    }
                    sip7::ParsedRecord::Blob { key, value } => {
                        println!("    blob {key} ({} bytes)", value.len());
                    }
                    sip7::ParsedRecord::Seq(version) => {
                        println!("    seq  {version}");
                    }
                    sip7::ParsedRecord::Sig(sig) => {
                        println!("    sig  {} {}", sig.canonical, sig.handle);
                    }
                    sip7::ParsedRecord::Malformed { rtype, .. } => {
                        println!("    malformed rtype={rtype}");
                    }
                    sip7::ParsedRecord::Unknown { rtype, .. } => {
                        println!("    unknown rtype={rtype}");
                    }
                }
            }
        }
        Err(e) => println!("{label}: (unpack error: {e})"),
    }
}
