use std::io::Write;
use std::sync::Arc;
use std::time::Duration;
use clap::Parser;
use vertias_app_core::{CheckpointOption, Veritas};

#[derive(Parser)]
#[command(name = "veritas", about = "Veritas node")]
struct Cli {
    /// Data directory (default: ~/Library/Application Support/Veritas)
    #[arg(short, long)]
    data_dir: Option<String>,

    /// Fabric relay seed URLs
    #[arg(long)]
    seed: Vec<String>,

    /// Skip checkpoint download, sync from scratch
    #[arg(long)]
    no_checkpoint: bool,

    /// Use the latest available checkpoint without prompting
    #[arg(long)]
    latest_checkpoint: bool,

    /// Show full log output
    #[arg(short, long)]
    verbose: bool,
}

fn main() -> anyhow::Result<()> {
    let cli = Cli::parse();

    let seeds = if cli.seed.is_empty() { None } else { Some(cli.seed) };
    let app = Veritas::new(cli.data_dir, None, seeds);

    if cli.no_checkpoint {
        app.skip_checkpoint();
    } else if let Some(cp) = resolve_checkpoint(&app, cli.latest_checkpoint)? {
        app.use_checkpoint(cp);
    }

    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(run(app, cli.verbose))
}

/// Check if a newer checkpoint is available and prompt the user.
fn resolve_checkpoint(
    app: &Arc<Veritas>,
    use_latest: bool,
) -> anyhow::Result<Option<CheckpointOption>> {
    let info = app.check_checkpoint();

    if !info.needs_checkpoint {
        return Ok(None);
    }

    let Some(latest) = info.latest else {
        return Ok(None);
    };

    if use_latest {
        eprintln!("  Using latest checkpoint (height: {})", latest.height);
        eprintln!();
        return Ok(Some(latest));
    }

    eprintln!("  A newer checkpoint is available:");
    eprintln!();
    eprintln!("    Hardcoded:  height {}", info.hardcoded_height);
    eprintln!("    Latest:     height {}", latest.height);
    eprintln!("                block  {}", latest.block_hash);
    eprintln!("                sha256 {}", latest.digest);
    eprintln!();
    eprint!("  Use latest checkpoint? [Y/n] ");
    std::io::stderr().flush()?;

    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;
    let answer = input.trim().to_lowercase();

    eprintln!();
    if answer.is_empty() || answer == "y" || answer == "yes" {
        Ok(Some(latest))
    } else {
        Ok(None)
    }
}

async fn run(
    app: Arc<Veritas>,
    verbose: bool,
) -> anyhow::Result<()> {
    eprintln!("  Data:  {}", app.data_dir());
    eprintln!();

    let bg_app = app.clone();
    let start_task = tokio::task::spawn_blocking(move || {
        bg_app.start()
    });
    tokio::pin!(start_task);

    // Phase 1: Wait for sync
    eprint!("  Syncing with Bitcoin...");
    let mut last_msg = String::new();
    loop {
        tokio::select! {
            result = &mut start_task => {
                eprint!("\r\x1b[2K");
                let inner = result.map_err(|e| anyhow::anyhow!("service thread panicked: {e}"))?;
                inner.map_err(|e| anyhow::anyhow!("{e}"))?;
                return Ok(());
            }
            _ = tokio::time::sleep(Duration::from_secs(1)) => {}
        }

        let status = app.get_sync_status().await;
        if status.phase == vertias_app_core::SyncPhase::Ready {
            eprint!("\r\x1b[2K");
            eprintln!("  \x1b[32m✓\x1b[0m Synced with Bitcoin");
            break;
        }

        if status.message != last_msg {
            eprint!("\r\x1b[2K  ⟳ {}...", status.message);
            last_msg = status.message;
        }

        if verbose {
            for entry in app.get_logs() {
                eprint!("\r\x1b[2K");
                eprintln!("    \x1b[2m[{}] {}\x1b[0m", entry.level, entry.message);
                eprint!("  ⟳ {}...", last_msg);
            }
        } else {
            app.get_logs(); // drain
        }
    }

    // Phase 2: Trust anchor
    eprint!("  Updating trust anchor...");
    match app.update_trust_id().await {
        Ok(anchor) => {
            eprint!("\r\x1b[2K");
            eprintln!("  \x1b[32m✓\x1b[0m Trust anchor ready (height: {})", anchor.height);
        }
        Err(e) => {
            eprint!("\r\x1b[2K");
            eprintln!("  \x1b[31m✗\x1b[0m Trust anchor failed: {e}");
        }
    }

    eprintln!();
    eprintln!("  Ready. Spaced RPC at {}", app.spaced_url());
    eprintln!();

    // Keep running, drain logs and detect service exit
    loop {
        tokio::select! {
            result = &mut start_task => {
                eprintln!();
                let inner = result.map_err(|e| anyhow::anyhow!("service thread panicked: {e}"))?;
                inner.map_err(|e| anyhow::anyhow!("{e}"))?;
                return Ok(());
            }
            _ = tokio::time::sleep(Duration::from_secs(2)) => {}
        }

        if verbose {
            for entry in app.get_logs() {
                eprintln!("    \x1b[2m[{}] {}\x1b[0m", entry.level, entry.message);
            }
        } else {
            app.get_logs();
        }
    }
}