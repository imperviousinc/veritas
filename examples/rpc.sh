#!/usr/bin/env bash
# Call the embedded spaced JSON-RPC (Veritas mainnet).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/rpc.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/rpc.env"
  set +a
fi

RPC_URL="${SPACED_RPC_URL:-http://127.0.0.1:12888}"
if [[ -z "${SPACED_RPC_USER:-}" || -z "${SPACED_RPC_PASSWORD:-}" ]]; then
  echo "Set SPACED_RPC_USER and SPACED_RPC_PASSWORD (they change each Veritas start)." >&2
  echo "Copy them from Settings → RPC Credentials, then either:" >&2
  echo "  export SPACED_RPC_USER=... SPACED_RPC_PASSWORD=..." >&2
  echo "  or write them to ${SCRIPT_DIR}/rpc.env (see rpc.env.example)" >&2
  exit 1
fi
RPC_USER="${SPACED_RPC_USER}"
RPC_PASSWORD="${SPACED_RPC_PASSWORD}"

rpc() {
  local method="$1"
  shift
  local params="${1:-[]}"
  local body tmp code
  tmp="$(mktemp -t veritas-rpc.XXXXXX)"
  code=$(curl -sS -o "$tmp" -w "%{http_code}" \
    -u "${RPC_USER}:${RPC_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
    "${RPC_URL}" || true)
  body="$(cat "$tmp")"
  rm -f "$tmp"

  if [[ "$code" != "200" ]]; then
    echo "HTTP ${code} from ${RPC_URL}" >&2
    if [[ -n "$body" ]]; then
      echo "$body" >&2
    fi
    if [[ "$code" == "401" ]]; then
      echo "RPC credentials are stale. Copy the current pair from Settings → RPC Credentials," >&2
      echo "then update SPACED_RPC_USER / SPACED_RPC_PASSWORD or examples/rpc.env." >&2
    elif [[ "$code" == "000" ]]; then
      echo "Could not reach ${RPC_URL}. Is Veritas running?" >&2
    fi
    return 1
  fi
  printf '%s' "$body"
}

pretty() {
  local body
  body="$(cat)"
  [[ -z "$body" ]] && return 0
  if command -v jq >/dev/null 2>&1 && jq -e . >/dev/null 2>&1 <<<"$body"; then
    jq . <<<"$body"
  else
    printf '%s\n' "$body"
  fi
}

# getspace wants "@space", not a handle like "subspace@space".
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
  getspace <name>              e.g. @space
  getspaceowner <name>
  getnum <subject>             e.g. #1-2-3
  getcommitment <subject>      e.g. @space
  getdelegation <subject>
  getrootanchors
  getfallback <subject>
  queryhandle <handle|space>   e.g. subspace@space or @space
  discover                     list RPC methods
  raw <method> <json-params>   e.g. raw getspace '["@space"]'

Credentials: SPACED_RPC_USER SPACED_RPC_PASSWORD (required; rotate on each Veritas start)
Optional:    SPACED_RPC_URL  or  examples/rpc.env
EOF
}

cmd="${1:-}"
shift || true

case "$cmd" in
  ""|-h|--help) usage ;;
  getserverinfo) rpc getserverinfo | pretty ;;
  getspace)
    name="$(as_space "${1:?space name required, e.g. @space}")"
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
  queryhandle)
    handle="${1:?handle or space required, e.g. subspace@space or @space}"
    rpc queryhandle "$(printf '[%s]' "$(json_str "$handle")")" | pretty
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
