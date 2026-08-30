#!/usr/bin/env bash
# Call the embedded spaced JSON-RPC (Veritas mainnet).
set -euo pipefail

RPC_URL="${SPACED_RPC_URL:-http://127.0.0.1:12888}"
RPC_USER="${SPACED_RPC_USER:-436813c5b4dc2c63}"
RPC_PASSWORD="${SPACED_RPC_PASSWORD:-19a87f2055b28a5054635ac6baaa40fc}"

rpc() {
  local method="$1"
  shift
  local params="${1:-[]}"
  curl -sS \
    -u "${RPC_USER}:${RPC_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "${RPC_URL}"
}

pretty() {
  if command -v jq >/dev/null 2>&1; then
    jq .
  else
    cat
  fi
}

# getspace wants "@lunde", not a handle like "andrew@lunde".
as_space() {
  local name="$1"
  if [[ "$name" == *@* && "$name" != @* ]]; then
    local space="@${name##*@}"
    echo "note: getspace takes a space, not a handle; using ${space} (from ${name})" >&2
    echo "$space"
  else
    echo "$name"
  fi
}

json_str() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

usage() {
  cat <<'EOF'
Usage: ./examples/rpc.sh <command> [args...]

Commands:
  getserverinfo
  getspace <name>              e.g. @lunde
  getspaceowner <name>
  getnum <subject>             e.g. #1-2-3
  getcommitment <subject>      e.g. @lunde
  getdelegation <subject>
  getrootanchors
  getfallback <subject>
  discover                     list RPC methods
  raw <method> <json-params>   e.g. raw getspace '["@lunde"]'

Env overrides: SPACED_RPC_URL SPACED_RPC_USER SPACED_RPC_PASSWORD
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  ""|-h|--help) usage ;;
  getserverinfo) rpc getserverinfo | pretty ;;
  getspace)
    name="$(as_space "${1:?space name required, e.g. @lunde}")"
    rpc getspace "$(printf '[%s]' "$(json_str "$name")")" | pretty
    ;;
  getspaceowner)
    name="$(as_space "${1:?space name required}")"
    rpc getspaceowner "$(printf '[%s]' "$(json_str "$name")")" | pretty
    ;;
  getnum)
    subject="${1:?subject required}"
    rpc getnum "$(printf '[%s]' "$(json_str "$subject")")" | pretty
    ;;
  getcommitment)
    subject="${1:?subject required}"
    rpc getcommitment "$(printf '[%s,null]' "$(json_str "$subject")")" | pretty
    ;;
  getdelegation)
    subject="${1:?subject required}"
    rpc getdelegation "$(printf '[%s]' "$(json_str "$subject")")" | pretty
    ;;
  getrootanchors) rpc getrootanchors | pretty ;;
  getfallback)
    subject="${1:?subject required}"
    rpc getfallback "$(printf '[%s]' "$(json_str "$subject")")" | pretty
    ;;
  discover) rpc rpc.discover | pretty ;;
  raw)
    method="${1:?method required}"
    params="${2:-[]}"
    rpc "$method" "$params" | pretty
    ;;
  *)
    echo "unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
