# veritas-app-core

Rust backend for the Veritas iOS/macOS app. Embeds [yuki](https://github.com/imperviousinc/yuki) (Bitcoin light client) and [spaced](https://github.com/spacesprotocol/spaces) (Spaces protocol daemon) as libraries, exposing a Swift-friendly API via [UniFFI](https://mozilla.github.io/uniffi-rs/).

## Building

```bash
cargo build
```

### CLI

Run the backend standalone (without Swift/Xcode):

```bash
cargo run --bin veritas
```

Options:

| Flag | Description |
|---|---|
| `-d, --data-dir <PATH>` | Custom data directory |
| `--no-checkpoint` | Skip checkpoint, sync from scratch |
| `--latest-checkpoint` | Use latest checkpoint without prompting |
| `-v, --verbose` | Show full log output |
| `--seed <URL>` | Custom fabric relay seed URLs |

## Architecture

- **`src/lib.rs`** - `Veritas` UniFFI object: manages service lifecycle, exposes async RPC methods to Swift
- **`src/runner.rs`** - `ServiceRunner`: launches yuki and spaced in isolated threads with dedicated tokio runtimes
- **`src/checkpoint.rs`** - Checkpoint download/verification on first launch
- **`src/nostr.rs`** - Nostr relay communication: fetch and verify `#veritas` tagged events
- **`src/logging.rs`** - Tracing capture layer that buffers log entries for the Swift log viewer

### Data directory

All data is stored under `~/Library/Application Support/Veritas/`:

```
Veritas/
  yuki/           # yuki chain data
  spaced/
    mainnet/
      root.sdb        # spaces state db
      nums.sdb        # nums state db
      index.sqlite     # block index
      .cookie          # RPC auth cookie
```

## Checkpoints

New users would need to sync the entire chain from scratch, which takes a long time. Checkpoints let them bootstrap from a recent snapshot.

### How it works

1. On first launch, if no `root.sdb` exists, the app downloads a `checkpoint.tar.gz` from the latest GitHub release
2. The archive's SHA-256 is verified against a hash compiled into the binary
3. The archive is extracted into the spaced data directory
4. yuki starts syncing from the checkpoint height instead of genesis

### How the app uses checkpoints

On first launch, the app calls `checkCheckpoint()` to see if a newer checkpoint is available from the server. If one exists, it can be selected with `useCheckpoint()` before calling `start()`. The CLI prompts interactively; the `--latest-checkpoint` flag auto-selects it.

The hardcoded checkpoint in the binary serves as a fallback when the server is unreachable.