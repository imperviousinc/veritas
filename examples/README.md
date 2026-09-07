# RPC and handle examples

Veritas embeds a JSON-RPC server on **mainnet** at:

```
http://127.0.0.1:12888
```

Auth is HTTP Basic. Credentials are generated when Veritas starts and change on every restart. Copy the current pair from Settings → RPC Credentials.

Copy the current pair from Settings → RPC Credentials (`user:password`), then:

```bash
source ./setup-env.sh "$(pbpaste)"
# or
source ./setup-env.sh '<user>:<password>'
```

That exports `SPACED_RPC_USER` / `SPACED_RPC_PASSWORD` and writes `examples/rpc.env` (gitignored). After a Veritas restart, run it again with the new copied pair.

`eval "$(./setup-env.sh '<user>:<password>')"` also works if you prefer not to `source`.

Veritas must be running (menu bar icon present, sync Ready or at least spaced listening).

## curl

```bash
./examples/rpc.sh getserverinfo
./examples/rpc.sh getspace @space
./examples/rpc.sh getrootanchors
./examples/rpc.sh queryhandle subspace@space
```

`getspace` is the on-chain **space** (`@space`). `queryhandle` takes a fabric handle (`subspace@space`) or a space (`@space`); a space is served as `getspace`.

Or raw:

```bash
curl -sS -u "$SPACED_RPC_USER:$SPACED_RPC_PASSWORD" \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"queryhandle","params":["subspace@space"]}' \
  http://127.0.0.1:12888
```

## Python

```bash
python3 examples/rpc.py getserverinfo
python3 examples/rpc.py getspace @space
python3 examples/rpc.py getcommitment @space
python3 examples/rpc.py queryhandle subspace@space
```

## Handle: `subspace@space`

`queryhandle` runs inside Veritas: a space (`@space`) is answered with spaced `getspace`. A handle (`subspace@space`) queries certrelay (`GET /query?q=@space,subspace@space`), skips relays in `EXCLUDE_CERTRELAY_URL` (default `http://70.251.209.207:47778`), picks a random non-excluded relay first (then failovers), and returns the decoded proof as JSON. If the handle has an on-chain num, that num's `getfallback` records are included as `fallback_records`.

```bash
./examples/rpc.sh queryhandle subspace@space
python3 examples/rpc.py queryhandle subspace@space
```

Standalone certrelay scripts (no Veritas required) are still in this directory:

```bash
./examples/query_handle.sh subspace@space
python3 examples/query_handle.py subspace@space
cargo run --example resolve_handle -- subspace@space
```
