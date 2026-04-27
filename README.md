# Veritas

A menu bar trust anchor for the [Spaces protocol](https://spacesprotocol.org). Embeds a Bitcoin light node and a spaces client to verify handles directly - no trusted servers.

## Structure

```
core/     Rust backend (UniFFI library + CLI)
app/      macOS/iOS app (Xcode)
```

## Building

### Rust core

```bash
cd core
cargo build
```

Run the CLI standalone:

```bash
cargo run --bin veritas
```

See [core/README.md](core/README.md) for CLI options and architecture details.

### Swift bindings + app

Build the Rust library for all Apple targets and copy bindings into the Xcode project:

```bash
cd core
./build-local.sh
```

Then open `app/veritas.xcodeproj` in Xcode and build normally.

## License

Licensed under the [Apache License, Version 2.0](LICENSE).