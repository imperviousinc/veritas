use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::Arc;
use spaces_client::config::ExtendedNetwork;
use spaces_client::jsonrpsee::tokio;

pub const DEFAULT_RPC_PORT: u16 = 12888;

/// Runs yuki (Bitcoin light client) and spaced in dedicated threads,
/// each with its own tokio runtime for full isolation.
pub struct ServiceRunner {
    data_dir: PathBuf,
    network: ExtendedNetwork,
    shutdown: tokio::sync::broadcast::Sender<()>,
    rpc_user: String,
    rpc_password: String,
    rpc_port: Arc<AtomicU16>,
    rpc_rebind: Arc<tokio::sync::Notify>,
    stopping: Arc<AtomicBool>,
}

impl ServiceRunner {
    pub fn new(
        data_dir: PathBuf,
        network: ExtendedNetwork,
        shutdown: tokio::sync::broadcast::Sender<()>,
        rpc_user: String,
        rpc_password: String,
        rpc_port: Arc<AtomicU16>,
        rpc_rebind: Arc<tokio::sync::Notify>,
        stopping: Arc<AtomicBool>,
    ) -> Self {
        Self {
            data_dir,
            network,
            shutdown,
            rpc_user,
            rpc_password,
            rpc_port,
            rpc_rebind,
            stopping,
        }
    }

    /// Start yuki and spaced in dedicated threads with their own tokio runtimes.
    /// Blocks the calling thread until either service exits.
    pub fn run(self) -> anyhow::Result<()> {
        let yuki_args = self.yuki_args();
        let spaced_args = self.spaced_args();

        let (done_tx, done_rx) = std::sync::mpsc::channel::<(&str, anyhow::Result<()>)>();

        let done_yuki = done_tx.clone();
        let shutdown_yuki = self.shutdown.clone();
        std::thread::Builder::new()
            .name("yuki".into())
            .spawn(move || {
                let result = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .map_err(anyhow::Error::from)
                    .and_then(|rt| rt.block_on(Self::yuki_runner(yuki_args, shutdown_yuki)));
                let _ = done_yuki.send(("yuki", result));
            })?;

        // No wait needed - spaced retries connecting to yuki's RPC on its own

        let done_spaced = done_tx.clone();
        let shutdown_spaced = self.shutdown.clone();
        std::thread::Builder::new()
            .name("spaced".into())
            .spawn(move || {
                let result = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .map_err(anyhow::Error::from)
                    .and_then(|rt| rt.block_on(Self::spaced_runner(spaced_args, shutdown_spaced)));
                let _ = done_spaced.send(("spaced", result));
            })?;

        let done_proxy = done_tx;
        let shutdown_proxy = self.shutdown.clone();
        let backend = Self::default_spaced_backend_url(self.network);
        let rpc_user = self.rpc_user.clone();
        let rpc_password = self.rpc_password.clone();
        let rpc_port = self.rpc_port.clone();
        let rpc_rebind = self.rpc_rebind.clone();
        let stopping = self.stopping.clone();
        std::thread::Builder::new()
            .name("rpc-proxy".into())
            .spawn(move || {
                let result = tokio::runtime::Builder::new_multi_thread()
                    .enable_all()
                    .build()
                    .map_err(anyhow::Error::from)
                    .and_then(|rt| {
                        rt.block_on(Self::rpc_proxy_loop(
                            rpc_port,
                            rpc_rebind,
                            stopping,
                            backend,
                            rpc_user,
                            rpc_password,
                            shutdown_proxy,
                        ))
                    });
                let _ = done_proxy.send(("rpc-proxy", result));
            })?;

        // Wait for the first service to exit
        let (name, result) = done_rx.recv()
            .map_err(|_| anyhow::anyhow!("service threads exited without reporting"))?;

        // Signal the remaining service to shut down
        let _ = self.shutdown.send(());

        match result {
            Ok(()) => {
                tracing::info!("{} exited", name);
                Ok(())
            }
            Err(e) => {
                tracing::error!("{} failed: {}", name, e);
                Err(e)
            }
        }
    }

    /// Start yuki only. Blocks until it exits.
    pub fn run_yuki_only(self) -> anyhow::Result<()> {
        let yuki_args = self.yuki_args();
        let shutdown = self.shutdown.clone();

        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()?;

        rt.block_on(Self::yuki_runner(yuki_args, shutdown))
    }

    /// The public RPC URL (proxy: spaced methods + `queryhandle`).
    pub fn spaced_url(&self) -> String {
        Self::default_spaced_url(self.network)
    }

    /// Default public RPC URL for a given network.
    pub fn default_spaced_url(network: ExtendedNetwork) -> String {
        format!("http://127.0.0.1:{}", Self::public_rpc_port(network))
    }

    pub fn public_url(port: u16) -> String {
        format!("http://127.0.0.1:{port}")
    }

    /// Embedded spaced listens here; the public proxy forwards to it.
    pub fn default_spaced_backend_url(network: ExtendedNetwork) -> String {
        format!("http://127.0.0.1:{}", Self::spaced_backend_port(network))
    }

    /// Path to the cookie file spaced will write for RPC auth.
    pub fn spaced_cookie(&self) -> PathBuf {
        self.spaced_data_dir()
            .join(self.network.to_string())
            .join(".cookie")
    }

    pub fn yuki_url(&self) -> String {
        format!("http://127.0.0.1:{}", Self::yuki_port(self.network))
    }

    pub fn default_yuki_url(network: ExtendedNetwork) -> String {
        format!("http://127.0.0.1:{}", Self::yuki_port(network))
    }

    fn spaced_data_dir(&self) -> PathBuf {
        self.data_dir.join("spaced")
    }

    fn yuki_port(network: ExtendedNetwork) -> u16 {
        match network {
            ExtendedNetwork::Mainnet => 12881,
            ExtendedNetwork::Testnet4 => 12771,
            _ => 12117,
        }
    }

    fn public_rpc_port(network: ExtendedNetwork) -> u16 {
        match network {
            ExtendedNetwork::Mainnet => DEFAULT_RPC_PORT,
            ExtendedNetwork::Testnet4 => 12777,
            _ => 12111,
        }
    }

    async fn rpc_proxy_loop(
        rpc_port: Arc<AtomicU16>,
        rebind: Arc<tokio::sync::Notify>,
        stopping: Arc<AtomicBool>,
        backend: String,
        rpc_user: String,
        rpc_password: String,
        shutdown: tokio::sync::broadcast::Sender<()>,
    ) -> anyhow::Result<()> {
        let mut bound_once = false;
        loop {
            if stopping.load(Ordering::SeqCst) {
                return Ok(());
            }
            let port = rpc_port.load(Ordering::SeqCst);
            let bind = SocketAddr::from(([127, 0, 0, 1], port));
            let wait_rebind = rebind.notified();
            tokio::pin!(wait_rebind);
            let mut shutdown_rx = shutdown.subscribe();

            tokio::select! {
                result = crate::rpc_proxy::run(
                    bind,
                    backend.clone(),
                    rpc_user.clone(),
                    rpc_password.clone(),
                    shutdown.subscribe(),
                ) => {
                    if stopping.load(Ordering::SeqCst) {
                        return result;
                    }
                    match result {
                        Ok(()) => return Ok(()),
                        Err(e) => {
                            tracing::error!("RPC proxy failed on {bind}: {e}");
                            if !bound_once {
                                return Err(e);
                            }
                            let mut shutdown_wait = shutdown.subscribe();
                            tokio::select! {
                                _ = shutdown_wait.recv() => return Ok(()),
                                _ = rebind.notified() => continue,
                            }
                        }
                    }
                }
                _ = &mut wait_rebind => {
                    bound_once = true;
                    tracing::info!("RPC port changed, rebinding public RPC");
                    continue;
                }
                _ = shutdown_rx.recv() => return Ok(()),
            }
        }
    }

    fn spaced_backend_port(network: ExtendedNetwork) -> u16 {
        match network {
            ExtendedNetwork::Mainnet => 12887,
            ExtendedNetwork::Testnet4 => 12776,
            _ => 12110,
        }
    }



    fn yuki_args(&self) -> Vec<String> {
        let mut args = vec![
            "yuki".into(),
            "--chain".into(), self.network.to_string(),
            "--rpc-port".into(), Self::yuki_port(self.network).to_string(),
            "--data-dir".into(), self.data_dir.join("yuki").to_str().unwrap().to_string(),
        ];
        let block_id = crate::checkpoint::yuki_checkpoint(&self.data_dir, self.network);
        if !block_id.is_empty() {
            args.push("--checkpoint".into());
            args.push(block_id);
        }
        args
    }

    fn spaced_args(&self) -> Vec<String> {
        vec![
            "spaced".into(),
            "--chain".into(), self.network.to_string(),
            "--rpc-port".into(), Self::spaced_backend_port(self.network).to_string(),
            "--data-dir".into(), self.spaced_data_dir().to_str().unwrap().to_string(),
            "--bitcoin-rpc-url".into(), self.yuki_url(),
            "--bitcoin-rpc-light".into(),
            "--enable-pruning".into(),
            "--rpc-user".into(), self.rpc_user.clone(),
            "--rpc-password".into(), self.rpc_password.clone(),
        ]
    }

    async fn yuki_runner(
        args: Vec<String>,
        shutdown: tokio::sync::broadcast::Sender<()>,
    ) -> anyhow::Result<()> {
        yuki::app::run(args, shutdown).await?;
        Ok(())
    }

    async fn spaced_runner(
        args: Vec<String>,
        shutdown: tokio::sync::broadcast::Sender<()>,
    ) -> anyhow::Result<()> {
        let mut app = spaces_client::app::App::new(shutdown);
        app.run(args).await
    }
}