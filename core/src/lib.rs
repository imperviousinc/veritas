pub mod logging;
pub mod runner;
mod checkpoint;
mod types;
#[cfg(feature = "nostr")]
mod nostr;

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use fabric::anchor::AnchorSets;
use fabric::client::Fabric;
use spaces_client::config::ExtendedNetwork;
use spaces_client::jsonrpsee::http_client::HttpClient;
use spaces_client::jsonrpsee::tokio;
use spaces_client::rpc::RpcClient;
use spaces_protocol::bitcoin::hashes::Hash as _;
use tracing_subscriber::prelude::*;

use crate::logging::{CaptureLayer, LogEntry, SharedLogBuffer};
use crate::runner::ServiceRunner;

uniffi::setup_scaffolding!();

/// Generate 32 random bytes using timestamp + stack address as entropy.
fn rand_bytes() -> [u8; 32] {
    use spaces_protocol::bitcoin::hashes::{sha256, Hash, HashEngine};
    use std::time::{SystemTime, UNIX_EPOCH};
    let mut engine = sha256::Hash::engine();
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    engine.input(&nanos.to_le_bytes());
    // Stack address as additional entropy
    let stack_var: u8 = 0;
    let addr = std::ptr::addr_of!(stack_var) as u64;
    engine.input(&addr.to_le_bytes());
    sha256::Hash::from_engine(engine).to_byte_array()
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum VeritasError {
    #[error("{msg}")]
    Rpc { msg: String },
    #[error("no anchor set available")]
    NoAnchorSet,
    #[error("{msg}")]
    InvalidInput { msg: String },
    #[error("{msg}")]
    Nostr { msg: String },
}

impl From<anyhow::Error> for VeritasError {
    fn from(e: anyhow::Error) -> Self {
        VeritasError::Rpc { msg: e.to_string() }
    }
}

impl From<spaces_client::jsonrpsee::core::ClientError> for VeritasError {
    fn from(e: spaces_client::jsonrpsee::core::ClientError) -> Self {
        VeritasError::Rpc { msg: e.to_string() }
    }
}

impl From<std::io::Error> for VeritasError {
    fn from(e: std::io::Error) -> Self {
        VeritasError::Rpc { msg: e.to_string() }
    }
}

impl From<fabric::client::Error> for VeritasError {
    fn from(e: fabric::client::Error) -> Self {
        VeritasError::Rpc { msg: e.to_string() }
    }
}

// -- Sync status --

#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum SyncPhase {
    DownloadingCheckpoint,
    VerifyingCheckpoint,
    ExtractingCheckpoint,
    StartingServices,
    SyncingHeaders,
    SyncingBlocks,
    Ready,
}

#[derive(Clone, uniffi::Record)]
pub struct SyncStatus {
    pub phase: SyncPhase,
    /// 0.0–1.0 progress within the current phase
    pub progress: f32,
    /// Human-readable description
    pub message: String,
}

#[derive(Clone, uniffi::Record)]
pub struct CheckpointOption {
    pub height: u32,
    pub block_hash: String,
    pub digest: String,
}

#[derive(Clone, uniffi::Record)]
pub struct CheckpointInfo {
    /// Whether a checkpoint download is needed (no existing data)
    pub needs_checkpoint: bool,
    /// Hardcoded checkpoint height (0 = none configured)
    pub hardcoded_height: u32,
    /// Latest available checkpoint from the server, if newer
    pub latest: Option<CheckpointOption>,
}

pub(crate) type SharedSyncStatus = Arc<Mutex<SyncStatus>>;

// -- UniFFI record wrappers (flattened) --

#[derive(uniffi::Record)]
pub struct ServerInfo {
    pub network: String,
    pub tip_hash: String,
    pub tip_height: u32,
    pub chain_blocks: u32,
    pub chain_headers: u32,
    pub ready: bool,
    pub progress: f32,
}

impl From<spaces_client::rpc::ServerInfo> for ServerInfo {
    fn from(info: spaces_client::rpc::ServerInfo) -> Self {
        Self {
            network: info.network.to_string(),
            tip_hash: info.tip.hash.to_string(),
            tip_height: info.tip.height,
            chain_blocks: info.chain.blocks,
            chain_headers: info.chain.headers,
            ready: info.ready,
            progress: info.progress,
        }
    }
}

#[derive(uniffi::Record)]
pub struct SpaceInfo {
    pub txid: String,
    pub name: String,
    pub value: u64,
    pub script_pubkey: String,
    /// "bid" or "transfer" or "reserved"
    pub covenant_type: String,
    /// For bids: total burned in sats
    pub total_burned: Option<u64>,
    /// For bids: block height at which registration is safe
    pub claim_height: Option<u32>,
    /// For transfers: expiration height
    pub expire_height: Option<u32>,
    /// For transfers: optional covenant data as hex
    pub data: Option<String>,
}

impl From<spaces_protocol::FullSpaceOut> for SpaceInfo {
    fn from(fso: spaces_protocol::FullSpaceOut) -> Self {
        let space = fso.spaceout.space.as_ref();
        let (covenant_type, total_burned, claim_height, expire_height, data) =
            match space.map(|s| &s.covenant) {
                Some(spaces_protocol::Covenant::Bid {
                    total_burned,
                    claim_height,
                    ..
                }) => (
                    "bid".into(),
                    Some(total_burned.to_sat()),
                    *claim_height,
                    None,
                    None,
                ),
                Some(spaces_protocol::Covenant::Transfer {
                    expire_height,
                    data,
                }) => (
                    "transfer".into(),
                    None,
                    None,
                    Some(*expire_height),
                    data.as_ref().map(|d| hex::encode(d.as_slice())),
                ),
                Some(spaces_protocol::Covenant::Reserved) => {
                    ("reserved".into(), None, None, None, None)
                }
                None => ("none".into(), None, None, None, None),
            };

        Self {
            txid: fso.txid.to_string(),
            name: space
                .map(|s| s.name.to_string())
                .unwrap_or_default(),
            value: fso.spaceout.value.to_sat(),
            script_pubkey: fso.spaceout.script_pubkey.to_string(),
            covenant_type,
            total_burned,
            claim_height,
            expire_height,
            data,
        }
    }
}

#[derive(uniffi::Record)]
pub struct NumInfo {
    pub txid: String,
    pub id: String,
    pub name: String,
    pub value: u64,
    pub script_pubkey: String,
    pub data: Option<String>,
    pub last_update: u32,
}

impl From<spaces_nums::FullNumOut> for NumInfo {
    fn from(fno: spaces_nums::FullNumOut) -> Self {
        Self {
            txid: fno.txid.to_string(),
            id: fno.numout.num.id.to_string(),
            name: fno.numout.num.name.to_string(),
            value: fno.numout.value.to_sat(),
            script_pubkey: fno.numout.script_pubkey.to_string(),
            data: fno.numout.num.data.as_ref().map(|d| hex::encode(d.as_slice())),
            last_update: fno.numout.num.last_update,
        }
    }
}

#[derive(uniffi::Record)]
pub struct CommitmentInfo {
    pub state_root: String,
    pub prev_root: Option<String>,
    pub rolling_hash: String,
    pub block_height: u32,
}

impl From<spaces_nums::Commitment> for CommitmentInfo {
    fn from(c: spaces_nums::Commitment) -> Self {
        Self {
            state_root: hex::encode(c.state_root),
            prev_root: c.prev_root.map(hex::encode),
            rolling_hash: hex::encode(c.rolling_hash),
            block_height: c.block_height,
        }
    }
}

#[derive(uniffi::Record)]
pub struct TrustAnchor {
    pub trust_id: String,
    pub height: u32,
}

#[derive(uniffi::Record)]
pub struct RootAnchorInfo {
    pub spaces_root: String,
    pub nums_root: Option<String>,
    pub block_hash: String,
    pub block_height: u32,
}

impl From<spaces_nums::RootAnchor> for RootAnchorInfo {
    fn from(ra: spaces_nums::RootAnchor) -> Self {
        Self {
            spaces_root: hex::encode(ra.spaces_root),
            nums_root: ra.nums_root.map(hex::encode),
            block_hash: ra.block.hash.to_string(),
            block_height: ra.block.height,
        }
    }
}

#[derive(uniffi::Record)]
pub struct FallbackInfo {
    /// Raw fallback data as base64
    pub data: String,
    /// Parsed SIP-7 records as JSON string, if valid
    pub records_json: Option<String>,
}

impl From<spaces_client::rpc::FallbackResponse> for FallbackInfo {
    fn from(fb: spaces_client::rpc::FallbackResponse) -> Self {
        let records_json = fb.records.as_ref().and_then(|rs| {
            serde_json::to_string(rs).ok()
        });
        Self {
            data: fb.data,
            records_json,
        }
    }
}

#[derive(uniffi::Record)]
pub struct RpcCredentials {
    pub user: String,
    pub password: String,
}

// -- Veritas object --

/// Optional external spaced connection. When set, start() just connects
/// instead of launching embedded services.
#[derive(Clone, uniffi::Record)]
pub struct ExternalSpaced {
    pub url: String,
    pub user: String,
    pub password: String,
}

/// Checkpoint configuration set before start().
enum CheckpointConfig {
    /// Use the hardcoded default (initial state).
    Default,
    /// Use a specific checkpoint.
    Use(spaces_checkpoint::Checkpoint),
    /// Skip checkpoint download entirely.
    Skip,
}

#[derive(uniffi::Object)]
pub struct Veritas {
    data_dir: PathBuf,
    network: ExtendedNetwork,
    external: Option<ExternalSpaced>,
    shutdown: Arc<Mutex<Option<tokio::sync::broadcast::Sender<()>>>>,
    log_buffer: SharedLogBuffer,
    client: Mutex<Option<HttpClient>>,
    sync_status: SharedSyncStatus,
    /// Block height when this session started syncing (set on first server info response)
    start_block: Mutex<Option<u32>>,
    /// Last seen peer status message (sticky - survives log buffer rotation)
    last_peer_status: Mutex<Option<String>>,
    checkpoint_config: Mutex<CheckpointConfig>,
    rpc_user: String,
    rpc_password: String,
    fabric: Fabric,
}

#[uniffi::export(async_runtime = "tokio")]
impl Veritas {
    /// Create a new Veritas instance.
    /// Pass `external` to connect to a running spaced instance instead of
    /// launching embedded services. Useful for development or advanced users.
    /// `data_dir` - path to the app's data directory. On sandboxed macOS/iOS,
    /// pass the container's Application Support path from Swift. If empty,
    /// falls back to `~/Library/Application Support/Veritas`.
    /// `seeds` - optional list of fabric relay seed URLs. If empty, uses built-in defaults.
    #[uniffi::constructor]
    pub fn new(data_dir: Option<String>, external: Option<ExternalSpaced>, seeds: Option<Vec<String>>) -> Arc<Self> {
        let data_dir = match data_dir {
            Some(path) if !path.is_empty() => PathBuf::from(path),
            _ => dirs::data_dir()
                .expect("failed to resolve Application Support directory")
                .join("Veritas"),
        };

        let log_buffer = logging::new_shared_buffer();

        let _ = tracing_subscriber::registry()
            .with(
                CaptureLayer::new(log_buffer.clone())
                    .with_filter(
                        tracing_subscriber::filter::Targets::new()
                            .with_default(tracing::Level::INFO)
                            .with_target("yuki", tracing::Level::WARN),
                    ),
            )
            .try_init();

        let fabric = match &seeds {
            Some(s) if !s.is_empty() => {
                let refs: Vec<&str> = s.iter().map(|s| s.as_str()).collect();
                Fabric::with_seeds(&refs)
            }
            _ => Fabric::new(),
        };

        Arc::new(Self {
            data_dir,
            network: ExtendedNetwork::Mainnet,
            external,
            shutdown: Arc::new(Mutex::new(None)),
            log_buffer,
            client: Mutex::new(None),
            sync_status: Arc::new(Mutex::new(SyncStatus {
                phase: SyncPhase::StartingServices,
                progress: 0.0,
                message: "Initializing...".into(),
            })),
            start_block: Mutex::new(None),
            last_peer_status: Mutex::new(None),
            checkpoint_config: Mutex::new(CheckpointConfig::Default),
            rpc_user: hex::encode(&rand_bytes()[..8]),
            rpc_password: hex::encode(&rand_bytes()[..16]),
            fabric,
        })
    }

    /// Fetch root anchors from spaced, compute the latest trust set,
    /// and pin it in fabric for verification.
    pub async fn update_trust_id(&self) -> Result<TrustAnchor, VeritasError> {
        let client = self.rpc_client()?;
        let anchors = client.get_root_anchors().await?;
        let sets = AnchorSets::from_anchors(anchors);
        let latest = sets.latest().ok_or(VeritasError::NoAnchorSet)?;
        let height = latest.entries.iter()
            .max_by_key(|r| r.block.height).map(|r| r.block.height)
            .unwrap_or(0);
        let trust_id = self.fabric.trust_from_set(latest)?;
        Ok(TrustAnchor {
            trust_id: trust_id.to_string(),
            height,
        })
    }

    /// Resolve a handle (e.g. "alice@bitcoin") via fabric relays.
    pub async fn resolve(&self, handle: String) -> Result<Option<types::Zone>, VeritasError> {
        let Some(resolved) = self.fabric.resolve(&handle).await? else {
            return Ok(None)
        };
        let badge = match self.fabric.badge(&resolved) {
            fabric::client::Badge::Orange => "orange",
            fabric::client::Badge::Unverified => "unverified",
            fabric::client::Badge::None => "none",
        };
        Ok(Some(types::zone_from_inner(&resolved, badge.into())))
    }

    /// Export a `.spacecert` certificate chain for a handle.
    pub async fn export_certificate(&self, handle: String) -> Result<Vec<u8>, VeritasError> {
        Ok(self.fabric.export(&handle).await?)
    }

    /// Check checkpoint status. Call before start() to show the user
    /// whether a checkpoint is needed and if a newer one is available.
    pub async fn check_checkpoint(&self) -> CheckpointInfo {
        let spaced_dir = self.data_dir
            .join("spaced")
            .join(self.network.to_string());

        let needs = spaces_checkpoint::needs_checkpoint(&spaced_dir);
        let hardcoded_height = spaces_checkpoint::integrity::checkpoint().height;

        let latest = tokio::task::spawn_blocking(|| {
            spaces_checkpoint::fetch_latest(spaces_checkpoint::CHECKPOINT_BASE_URL).ok().flatten()
        })
            .await
            .ok()
            .flatten()
            .filter(|cp| cp.height > hardcoded_height)
            .map(|cp| CheckpointOption {
                height: cp.height,
                block_hash: cp.block_hash,
                digest: cp.digest,
            });

        CheckpointInfo {
            needs_checkpoint: needs,
            hardcoded_height,
            latest,
        }
    }

    /// Configure a specific checkpoint to use on first sync.
    /// Call after `checkCheckpoint()`, before `start()`.
    pub fn use_checkpoint(&self, checkpoint: CheckpointOption) {
        *self.checkpoint_config.lock().unwrap() = CheckpointConfig::Use(
            spaces_checkpoint::Checkpoint {
                height: checkpoint.height,
                block_hash: checkpoint.block_hash,
                digest: checkpoint.digest,
            },
        );
    }

    /// Skip checkpoint download entirely, sync from scratch.
    /// Call before `start()`.
    pub fn skip_checkpoint(&self) {
        *self.checkpoint_config.lock().unwrap() = CheckpointConfig::Skip;
    }

    /// Start services. In embedded mode, launches yuki + spaced and blocks.
    /// In external mode, connects to the remote spaced and returns immediately.
    pub fn start(&self) -> Result<(), VeritasError> {
        if let Some(ext) = &self.external {
            return self.connect_external(ext);
        }

        let config = std::mem::replace(
            &mut *self.checkpoint_config.lock().unwrap(),
            CheckpointConfig::Default,
        );
        match config {
            CheckpointConfig::Skip => {}
            CheckpointConfig::Default => {
                checkpoint::download_checkpoint(
                    &self.data_dir,
                    self.network,
                    &self.sync_status,
                    None,
                ).map_err(VeritasError::from)?;
            }
            CheckpointConfig::Use(cp) => {
                checkpoint::download_checkpoint(
                    &self.data_dir,
                    self.network,
                    &self.sync_status,
                    Some(cp),
                ).map_err(VeritasError::from)?;
            }
        }

        {
            let mut s = self.sync_status.lock().unwrap();
            *s = SyncStatus {
                phase: SyncPhase::StartingServices,
                progress: 0.0,
                message: "Starting services...".into(),
            };
        }

        let (tx, _) = tokio::sync::broadcast::channel(1);
        {
            let mut guard = self.shutdown.lock().unwrap();
            *guard = Some(tx.clone());
        }

        let runner = ServiceRunner::new(
            self.data_dir.clone(),
            self.network,
            tx,
            self.rpc_user.clone(),
            self.rpc_password.clone(),
        );
        runner.run().map_err(VeritasError::from)
    }

    /// Signal all services to shut down. No-op in external mode.
    pub fn stop(&self) {
        let guard = self.shutdown.lock().unwrap();
        if let Some(tx) = guard.as_ref() {
            let _ = tx.send(());
        }
    }

    /// Drain all log entries captured since the last call.
    pub fn get_logs(&self) -> Vec<LogEntry> {
        logging::drain(&self.log_buffer)
    }

    /// Get the current sync status. During checkpoint download this returns
    /// download progress. Once services are running, it queries spaced's
    /// server info to determine sync progress. Swift should poll every 1-2s.
    pub async fn get_sync_status(&self) -> SyncStatus {
        // During checkpoint phases, return the stored status directly
        {
            let s = self.sync_status.lock().unwrap();
            match s.phase {
                SyncPhase::DownloadingCheckpoint
                | SyncPhase::VerifyingCheckpoint
                | SyncPhase::ExtractingCheckpoint => return s.clone(),
                _ => {}
            }
        }

        // Once services are up, try to get live status from spaced
        let info = match self.rpc_client().ok() {
            Some(client) => client.get_server_info().await.ok(),
            None => None,
        };

        let Some(info) = info else {
            // No RPC yet - check logs for peer connection status
            if let Some(peer_msg) = self.peek_peer_status() {
                let status = SyncStatus {
                    phase: SyncPhase::StartingServices,
                    progress: 0.0,
                    message: peer_msg,
                };
                *self.sync_status.lock().unwrap() = status.clone();
                return status;
            }
            return self.sync_status.lock().unwrap().clone();
        };

        let tip = info.tip.height;
        let blocks = info.chain.blocks;
        let headers = info.chain.headers;

        // Record start block on first successful response
        let start_block = {
            let mut sb = self.start_block.lock().unwrap();
            if sb.is_none() {
                *sb = Some(blocks);
            }
            sb.unwrap()
        };

        // Progress relative to where this session started
        let total_to_sync = tip.saturating_sub(start_block);
        let synced = blocks.saturating_sub(start_block);
        let remaining = tip.saturating_sub(blocks);

        // We're truly ready only when spaced has usable root anchors.
        // Without anchors, resolve/trust operations will fail even if spaced says "ready"
        // (e.g. fresh checkpoint load before yuki finds peers to build the anchor set).
        let has_anchors = match self.rpc_client().ok() {
            Some(c) => c.get_root_anchors().await.map(|a| !a.is_empty()).unwrap_or(false),
            None => false,
        };
        let status = if info.ready && has_anchors {
            SyncStatus {
                phase: SyncPhase::Ready,
                progress: 1.0,
                message: "Synced".into(),
            }
        } else if headers < tip && synced == 0 {
            let headers_to_sync = tip.saturating_sub(start_block);
            let headers_done = headers.saturating_sub(start_block);
            let progress = if headers_to_sync > 0 {
                headers_done as f32 / headers_to_sync as f32
            } else {
                0.0
            };
            SyncStatus {
                phase: SyncPhase::SyncingHeaders,
                progress,
                message: format!("Syncing headers ({}/{})", headers_done, headers_to_sync),
            }
        } else if total_to_sync == 0 {
            SyncStatus {
                phase: SyncPhase::StartingServices,
                progress: 0.0,
                message: "Starting...".into(),
            }
        } else {
            let progress = synced as f32 / total_to_sync as f32;
            SyncStatus {
                phase: SyncPhase::SyncingBlocks,
                progress,
                message: format!("Verifying ({}/{}, {} remaining)", synced, total_to_sync, remaining),
            }
        };

        // If nothing changed since last poll and yuki is finding peers, show that instead
        let status = if !info.ready {
            let prev = self.sync_status.lock().unwrap();
            let stalled = prev.progress == status.progress;
            drop(prev);
            if stalled {
                if let Some(peer_msg) = self.peek_peer_status() {
                    SyncStatus { message: peer_msg, ..status }
                } else {
                    status
                }
            } else {
                status
            }
        } else {
            status
        };

        *self.sync_status.lock().unwrap() = status.clone();
        status
    }

    pub async fn get_server_info(&self) -> Result<ServerInfo, VeritasError> {
        let client = self.rpc_client()?;
        let info = client.get_server_info().await?;
        Ok(info.into())
    }

    pub async fn get_space(&self, space_or_hash: String) -> Result<Option<SpaceInfo>, VeritasError> {
        let client = self.rpc_client()?;
        let result = client.get_space(&space_or_hash).await?;
        Ok(result.map(Into::into))
    }

    pub async fn get_num(&self, subject: String) -> Result<Option<NumInfo>, VeritasError> {
        let client = self.rpc_client()?;
        let subject: spaces_client::rpc::Subject = subject.parse()
            .map_err(|e: String| VeritasError::Rpc { msg: e })?;
        let result = client.get_num(subject).await?;
        Ok(result.map(Into::into))
    }

    pub async fn get_commitment(&self, subject: String, root: Option<String>) -> Result<Option<CommitmentInfo>, VeritasError> {
        let client = self.rpc_client()?;
        let subject: spaces_client::rpc::Subject = subject.parse()
            .map_err(|e: String| VeritasError::Rpc { msg: e })?;
        let root_hash = match root {
            Some(hex) => {
                let bytes = hex::decode(&hex)
                    .map_err(|e| VeritasError::Rpc { msg: e.to_string() })?;
                let hash = spaces_protocol::bitcoin::hashes::sha256::Hash::from_slice(&bytes)
                    .map_err(|e: spaces_protocol::bitcoin::hashes::FromSliceError| VeritasError::Rpc { msg: e.to_string() })?;
                Some(hash)
            }
            None => None,
        };
        let result = client.get_commitment(subject, root_hash).await?;
        Ok(result.map(Into::into))
    }

    pub async fn get_root_anchors(&self) -> Result<Vec<RootAnchorInfo>, VeritasError> {
        let client = self.rpc_client()?;
        let anchors = client.get_root_anchors().await?;
        Ok(anchors.into_iter().map(Into::into).collect())
    }

    pub async fn get_fallback(&self, subject: String) -> Result<Option<FallbackInfo>, VeritasError> {
        let client = self.rpc_client()?;
        let subject: spaces_client::rpc::Subject = subject.parse()
            .map_err(|e: String| VeritasError::Rpc { msg: e })?;
        let result = client.get_fallback(subject).await?;
        Ok(result.map(Into::into))
    }

    pub async fn verify_schnorr(&self, subject: String, message: String, signature: String) -> Result<bool, VeritasError> {
        let client = self.rpc_client()?;
        let subject: spaces_client::rpc::Subject = subject.parse()
            .map_err(|e: String| VeritasError::Rpc { msg: e })?;
        let msg_bytes = hex::decode(&message)
            .map_err(|e| VeritasError::Rpc { msg: e.to_string() })?;
        let sig_bytes = hex::decode(&signature)
            .map_err(|e| VeritasError::Rpc { msg: e.to_string() })?;
        let result = client.verify_schnorr(
            subject,
            spaces_protocol::Bytes::new(msg_bytes),
            spaces_protocol::Bytes::new(sig_bytes),
        ).await?;
        Ok(result)
    }

    pub fn data_dir(&self) -> String {
        self.data_dir.to_string_lossy().into_owned()
    }

    pub fn yuki_url(&self) -> String {
        ServiceRunner::default_yuki_url(self.network)
    }

    pub fn spaced_url(&self) -> String {
        ServiceRunner::default_spaced_url(self.network)
    }

    /// RPC credentials for the embedded spaced instance.
    /// Generated randomly at startup. Useful for debugging with curl.
    pub fn rpc_credentials(&self) -> RpcCredentials {
        RpcCredentials {
            user: self.rpc_user.clone(),
            password: self.rpc_password.clone(),
        }
    }
}

#[cfg(feature = "nostr")]
#[uniffi::export(async_runtime = "tokio")]
impl Veritas {
    /// Fetch all #veritas messages by a specific npub from the given relays.
    /// Optionally filter by fuzzy text search.
    pub async fn find_nostr(&self, npub: String, relays: Vec<String>, text: Option<String>) -> Result<Vec<nostr::NostrMessage>, VeritasError> {
        nostr::find_message(&npub, &relays, text.as_deref()).await
    }
}

impl Veritas {

    /// Peek at recent log entries for yuki peer connection status.
    /// Returns a message like "Finding peers (2/8)...".
    /// Sticky: once seen, keeps returning the last known status even if
    /// the log entry has scrolled out of the buffer.
    fn peek_peer_status(&self) -> Option<String> {
        let buf = self.log_buffer.lock().ok()?;
        for entry in buf.entries.iter().rev().take(20) {
            if entry.target.starts_with("yuki") && entry.message.contains("connections to peers") {
                let connected = entry.message.split("Connected: ")
                    .nth(1)
                    .and_then(|s| s.split(',').next())
                    .and_then(|s| s.trim().parse::<u32>().ok());
                let required = entry.message.split("Required: ")
                    .nth(1)
                    .and_then(|s| s.trim().parse::<u32>().ok());
                if let (Some(c), Some(r)) = (connected, required) {
                    let msg = format!("Finding peers ({}/{})", c, r);
                    *self.last_peer_status.lock().unwrap() = Some(msg.clone());
                    return Some(msg);
                }
            }
        }
        // Fall back to last known peer status
        self.last_peer_status.lock().unwrap().clone()
    }

    fn connect_external(&self, ext: &ExternalSpaced) -> Result<(), VeritasError> {
        let token = spaces_client::auth::auth_token_from_creds(&ext.user, &ext.password);
        let client = spaces_client::auth::http_client_with_auth(&ext.url, &token)
            .map_err(|e| VeritasError::Rpc { msg: e.to_string() })?;

        *self.client.lock().unwrap() = Some(client);
        *self.sync_status.lock().unwrap() = SyncStatus {
            phase: SyncPhase::Ready,
            progress: 1.0,
            message: "Connected to external spaced".into(),
        };
        Ok(())
    }

    fn rpc_client(&self) -> Result<HttpClient, VeritasError> {
        let mut guard = self.client.lock().unwrap();
        if let Some(client) = guard.as_ref() {
            return Ok(client.clone());
        }

        let token = spaces_client::auth::auth_token_from_creds(&self.rpc_user, &self.rpc_password);
        let url = self.spaced_url();
        let client = spaces_client::auth::http_client_with_auth(&url, &token)
            .map_err(|e| VeritasError::Rpc { msg: e.to_string() })?;
        *guard = Some(client.clone());
        Ok(client)
    }
}