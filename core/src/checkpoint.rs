use std::path::{Path, PathBuf};
use spaces_checkpoint::{
    needs_checkpoint, ensure_checkpoint as apply_checkpoint,
    integrity, CHECKPOINT_BASE_URL, Checkpoint,
};
use spaces_client::config::ExtendedNetwork;

use crate::{SharedSyncStatus, SyncPhase, SyncStatus};

const APPLIED_CHECKPOINT_FILE: &str = "checkpoint.json";

/// Returns the "blockhash:height" for yuki's --checkpoint arg.
/// Priority: applied checkpoint on disk > hardcoded > protocol genesis anchor.
pub(crate) fn yuki_checkpoint(data_dir: &Path, network: ExtendedNetwork) -> String {
    // Check if we stored a checkpoint from a previous download
    if let Some(cp) = read_applied_checkpoint(data_dir) {
        return cp.block_id();
    }

    let cp = integrity::checkpoint();
    if cp.height > 0 {
        return cp.block_id();
    }

    // Fallback: protocol genesis anchor
    let anchor = match network {
        ExtendedNetwork::Mainnet => spaces_protocol::constants::ChainAnchor::MAINNET(),
        ExtendedNetwork::Testnet4 => spaces_protocol::constants::ChainAnchor::TESTNET4(),
        _ => return String::new(),
    };
    format!("{}:{}", anchor.hash, anchor.height)
}

/// Downloads and extracts a checkpoint if no existing data is found.
/// Pass a `Checkpoint` to use a specific one, or `None` for the hardcoded default.
pub(crate) fn download_checkpoint(
    data_dir: &PathBuf,
    network: ExtendedNetwork,
    status: &SharedSyncStatus,
    checkpoint: Option<Checkpoint>,
) -> anyhow::Result<()> {
    if network != ExtendedNetwork::Mainnet {
        return Ok(());
    }

    let spaced_dir = data_dir
        .join("spaced")
        .join(network.to_string());

    if !needs_checkpoint(&spaced_dir) {
        tracing::info!("existing spaced data found, skipping checkpoint");
        return Ok(());
    }

    let cp = match checkpoint {
        Some(cp) => cp,
        None => {
            let cp = integrity::checkpoint();
            if cp.height == 0 || cp.digest.is_empty() {
                tracing::debug!("no checkpoint configured, skipping");
                return Ok(());
            }
            cp
        }
    };

    let url = cp.url(CHECKPOINT_BASE_URL);
    let digest = cp.digest_bytes()
        .map_err(|e| anyhow::anyhow!("{}", e))?;

    {
        let mut s = status.lock().unwrap();
        *s = SyncStatus {
            phase: SyncPhase::DownloadingCheckpoint,
            progress: 0.0,
            message: "Starting checkpoint download...".into(),
        };
    }

    let status_clone = status.clone();
    let progress_cb = checkpoint_progress_cb(status_clone);

    let applied = apply_checkpoint(&spaced_dir, &url, &digest, Some(&progress_cb))
        .map_err(|e| anyhow::anyhow!("{}", e))?;

    if applied {
        write_applied_checkpoint(data_dir, &cp);

        let mut s = status.lock().unwrap();
        *s = SyncStatus {
            phase: SyncPhase::ExtractingCheckpoint,
            progress: 1.0,
            message: "Checkpoint ready".into(),
        };
    } else {
        tracing::warn!("checkpoint download failed, will sync from scratch");
    }

    Ok(())
}

/// Build the progress callback that drives checkpoint status transitions.
/// Tracks download progress and transitions to VerifyingCheckpoint when
/// the download completes (downloaded >= total).
fn checkpoint_progress_cb(status: SharedSyncStatus) -> impl Fn(u64, u64) + Send + Sync {
    use std::sync::atomic::{AtomicBool, Ordering};
    let download_done = AtomicBool::new(false);

    move |downloaded: u64, total: u64| {
        // Once download is complete, switch to verifying (once)
        if downloaded >= total && total > 0 {
            if !download_done.swap(true, Ordering::Relaxed) {
                let mut s = status.lock().unwrap();
                *s = SyncStatus {
                    phase: SyncPhase::VerifyingCheckpoint,
                    progress: 0.0,
                    message: "Verifying checkpoint...".into(),
                };
            }
            return;
        }

        if download_done.load(Ordering::Relaxed) {
            return;
        }

        let progress = if total > 0 {
            (downloaded as f32 / total as f32).min(1.0)
        } else {
            0.0
        };
        let mut s = status.lock().unwrap();
        *s = SyncStatus {
            phase: SyncPhase::DownloadingCheckpoint,
            progress,
            message: if total > 0 {
                format!(
                    "Downloading checkpoint ({:.1}/{:.1} MB)",
                    downloaded as f64 / 1_000_000.0,
                    total as f64 / 1_000_000.0,
                )
            } else {
                format!("Downloading checkpoint ({:.1} MB)", downloaded as f64 / 1_000_000.0)
            },
        };
    }
}

fn applied_checkpoint_path(data_dir: &Path) -> PathBuf {
    data_dir.join(APPLIED_CHECKPOINT_FILE)
}

fn write_applied_checkpoint(data_dir: &Path, cp: &Checkpoint) {
    if let Ok(json) = serde_json::to_string(cp) {
        let _ = std::fs::write(applied_checkpoint_path(data_dir), json);
    }
}

fn read_applied_checkpoint(data_dir: &Path) -> Option<Checkpoint> {
    let data = std::fs::read_to_string(applied_checkpoint_path(data_dir)).ok()?;
    serde_json::from_str(&data).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn make_status() -> SharedSyncStatus {
        Arc::new(Mutex::new(SyncStatus {
            phase: SyncPhase::DownloadingCheckpoint,
            progress: 0.0,
            message: "Starting...".into(),
        }))
    }

    #[test]
    fn test_progress_transitions() {
        let status = make_status();
        let cb = checkpoint_progress_cb(status.clone());

        let total: u64 = 10_000_000;

        // Simulate partial download
        cb(1_000_000, total);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::DownloadingCheckpoint);
            assert!((s.progress - 0.1).abs() < 0.01);
            assert!(s.message.contains("1.0"));
        }

        // More progress
        cb(5_000_000, total);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::DownloadingCheckpoint);
            assert!((s.progress - 0.5).abs() < 0.01);
        }

        // Download complete - should transition to verifying
        cb(total, total);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::VerifyingCheckpoint);
            assert_eq!(s.progress, 0.0);
            assert!(s.message.contains("Verifying"));
        }

        // Further callbacks after download done should be ignored
        cb(total, total);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::VerifyingCheckpoint);
        }
    }

    #[test]
    fn test_progress_no_content_length() {
        let status = make_status();
        let cb = checkpoint_progress_cb(status.clone());

        // total = 0 means no Content-Length
        cb(500_000, 0);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::DownloadingCheckpoint);
            assert_eq!(s.progress, 0.0);
            assert!(s.message.contains("0.5 MB"));
        }

        cb(2_000_000, 0);
        {
            let s = status.lock().unwrap();
            assert_eq!(s.phase, SyncPhase::DownloadingCheckpoint);
            assert_eq!(s.progress, 0.0);
            assert!(s.message.contains("2.0 MB"));
        }
    }
}