# RPC and handle examples

Veritas embeds a [spaced](https://github.com/spacesprotocol/spaces) JSON-RPC server on **mainnet** at:

```
http://127.0.0.1:12888
```

Auth is HTTP Basic. These examples use the credentials from Settings → RPC Credentials:

```
user:     436813c5b4dc2c63
password: 19a87f2055b28a5054635ac6baaa40fc
```

They are generated when Veritas starts. If a call returns `401 Unauthorized`, copy the current pair from Settings.

Veritas must be running (menu bar icon present, sync Ready or at least spaced listening).

## curl

```bash
./examples/rpc.sh getserverinfo
./examples/rpc.sh getspace @lunde
./examples/rpc.sh getrootanchors
```

`getspace` is the on-chain **space** (`@lunde`), not a fabric handle (`andrew@lunde`). Handles are resolved in the Veritas search UI via certrelay, not this RPC.

Or raw:

```bash
curl -sS -u '436813c5b4dc2c63:19a87f2055b28a5054635ac6baaa40fc' \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"getserverinfo","params":[]}' \
  http://127.0.0.1:12888
```

## Python

```bash
python3 examples/rpc.py getserverinfo
python3 examples/rpc.py getspace @lunde
python3 examples/rpc.py getcommitment @lunde
```

## Handle: `andrew@lunde`

A handle is not a spaced `getspace` argument. Query it through certrelay
(`GET /query?q=@lunde,andrew@lunde`) — the same request the Veritas search UI sends.

```bash
# Raw proof from a public relay (binary Message)
./examples/query_handle.sh andrew@lunde
python3 examples/query_handle.py andrew@lunde

# Decode the proof and print the handle
cargo run --example resolve_handle -- andrew@lunde
```

The certrelay query is `GET /query?q=@lunde,andrew@lunde`.

`EXCLUDE_CERTRELAY_URL` defaults to `http://70.251.209.207:47778`. Relays on that comma-separated list are skipped even if they are bootstrap seeds or appear in `/peers`:

```bash
# default exclude
python3 examples/query_handle.py andrew@lunde

# extra excludes
EXCLUDE_CERTRELAY_URL='http://70.251.209.207:47778,http://127.0.0.1:7779' \
  python3 examples/query_handle.py andrew@lunde
```
