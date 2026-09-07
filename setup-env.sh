#!/usr/bin/env bash
# Load Veritas RPC credentials copied from Settings → RPC Credentials.
# Settings Copy produces `user:password`.
#
#   source ./setup-env.sh '<user>:<password>'
#   source ./setup-env.sh "$(pbpaste)"
#   eval "$(./setup-env.sh '<user>:<password>')"

_setup_env_fail() {
  echo "usage: source ./setup-env.sh '<user>:<password>'" >&2
  echo "  Copy from Settings → RPC Credentials, then:" >&2
  echo "  source ./setup-env.sh '<user>:<password>'" >&2
  echo "  source ./setup-env.sh \"\$(pbpaste)\"" >&2
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    unset -f _setup_env_fail
    return 1
  fi
  exit 1
}

creds="${1:-}"
if [[ -z "$creds" || "$creds" != *:* ]]; then
  _setup_env_fail
  return 1
fi

user="${creds%%:*}"
password="${creds#*:}"
if [[ -z "$user" || -z "$password" ]]; then
  _setup_env_fail
  return 1
fi

export SPACED_RPC_USER="$user"
export SPACED_RPC_PASSWORD="$password"
export SPACED_RPC_URL="${SPACED_RPC_URL:-http://127.0.0.1:12888}"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
env_file="${root}/examples/rpc.env"
cat > "$env_file" <<EOF
SPACED_RPC_URL=${SPACED_RPC_URL}
SPACED_RPC_USER=${SPACED_RPC_USER}
SPACED_RPC_PASSWORD=${SPACED_RPC_PASSWORD}
EOF

echo "RPC credentials loaded (user ${SPACED_RPC_USER})." >&2
echo "Wrote ${env_file}" >&2

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf "export SPACED_RPC_USER=%q\n" "$SPACED_RPC_USER"
  printf "export SPACED_RPC_PASSWORD=%q\n" "$SPACED_RPC_PASSWORD"
  printf "export SPACED_RPC_URL=%q\n" "$SPACED_RPC_URL"
fi

unset -f _setup_env_fail
unset creds user password root env_file
