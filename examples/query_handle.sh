#!/usr/bin/env bash
# Query a fabric handle (e.g. subspace@space) from certrelay.
# This is the same GET /query the Veritas search UI uses — not spaced getspace.
set -euo pipefail

HANDLE="${1:-subspace@space}"
EXCLUDE_CERTRELAY_URL="${EXCLUDE_CERTRELAY_URL:-http://70.251.209.207:47778}"

if [[ "$HANDLE" != *@* || "$HANDLE" == @* ]]; then
  echo "usage: $0 <label@space>     e.g. $0 subspace@space" >&2
  exit 1
fi

space="@${HANDLE##*@}"
q="${space},${HANDLE}"

# host:port, lowercased, no trailing slash — so http/https and /peers URLs match.
relay_key() {
  local u="$1"
  u="${u#"${u%%[![:space:]]*}"}"
  u="${u%"${u##*[![:space:]]}"}"
  u="${u%/}"
  u="${u#*://}"
  u="${u%%/*}"
  echo "$u" | tr '[:upper:]' '[:lower:]'
}

is_excluded() {
  local key
  key="$(relay_key "$1")"
  local IFS=','
  local ex
  for ex in $EXCLUDE_CERTRELAY_URL; do
    [[ -z "$ex" ]] && continue
    if [[ "$key" == "$(relay_key "$ex")" ]]; then
      return 0
    fi
  done
  return 1
}

seen_keys=""
already_seen() {
  case ",${seen_keys}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

if [[ -n "${CERTRELAY_URL:-}" ]]; then
  seeds=("${CERTRELAY_URL}")
else
  seeds=(
    "https://relay-cosmos.spacesprotocol.org"
    "https://relay-atlas.spacesprotocol.org"
    "https://relay-orion.spacesprotocol.org"
    "https://relay-pulsar.spacesprotocol.org"
  )
fi

relays=()

add_relay() {
  local url="${1%/}"
  local key
  key="$(relay_key "$url")"
  [[ -z "$key" ]] && return
  if is_excluded "$url"; then
    if ! already_seen "$key"; then
      echo "skip excluded relay ${url}"
      seen_keys="${seen_keys:+${seen_keys},}${key}"
    fi
    return
  fi
  if already_seen "$key"; then
    return
  fi
  seen_keys="${seen_keys:+${seen_keys},}${key}"
  relays+=("$url")
}

for seed in "${seeds[@]}"; do
  add_relay "$seed"
done

# Discover peers from bootstrap seeds, then exclude again.
bootstrap_relays=("${relays[@]}")
for seed in "${bootstrap_relays[@]}"; do
  peers_json="$(curl -sS -A "veritas-examples" --max-time 10 "${seed}/peers" || true)"
  [[ -z "$peers_json" ]] && continue
  while IFS= read -r peer; do
    [[ -z "$peer" ]] && continue
    add_relay "$peer"
  done < <(python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
peers = data if isinstance(data, list) else data.get("peers") or data.get("relays") or []
for p in peers:
    url = p.get("url") if isinstance(p, dict) else p
    if url:
        print(url)
' <<<"$peers_json" 2>/dev/null || true)
done

if [[ ${#relays[@]} -eq 0 ]]; then
  echo "No relays left after EXCLUDE_CERTRELAY_URL=${EXCLUDE_CERTRELAY_URL}" >&2
  exit 1
fi

# Pick a random order among non-excluded relays.
for ((i=${#relays[@]}-1; i>0; i--)); do
  j=$((RANDOM % (i + 1)))
  tmp="${relays[i]}"
  relays[i]="${relays[j]}"
  relays[j]="$tmp"
done

out="$(mktemp -t certrelay-query.XXXXXX)"
trap 'rm -f "$out"' EXIT

for relay in "${relays[@]}"; do
  echo "GET ${relay}/query?q=${q}"
  http_code=$(curl -sS -o "$out" -w "%{http_code}" \
    -A "veritas-examples" \
    --max-time 30 \
    -G "${relay}/query" \
    --data-urlencode "q=${q}" || true)
  bytes=$(wc -c < "$out" | tr -d ' ')
  echo "HTTP ${http_code}  ${bytes} bytes"
  if [[ "$http_code" == "200" && "$bytes" -gt 0 ]]; then
    dest="/tmp/certrelay-query.bin"
    cp "$out" "$dest"
    echo "Saved proof to ${dest}"
    echo "To decode this proof and print the handle:"
    echo "  cargo run --example resolve_handle -- ${HANDLE}"
    exit 0
  fi
done

echo "No relay returned a proof for ${HANDLE}." >&2
exit 1
