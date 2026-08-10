#!/bin/sh
set -eu

workflow_path=${SYMPHONY_WORKFLOW_PATH:-/etc/symphony/WORKFLOW.md}
logs_root=${SYMPHONY_LOGS_ROOT:-/var/log/symphony}
port=${SYMPHONY_PORT:-4000}
private_key=/run/secrets/worker_ssh_private_key
host_public_key=/run/secrets/worker_ssh_host_public_key
ssh_dir=/tmp/symphony-ssh

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -f "$workflow_path" ] || fail "Symphony workflow is missing at $workflow_path"
[ -r "$private_key" ] || fail "worker SSH private key is missing or unreadable"
[ -s "$private_key" ] || fail "worker SSH private key is empty"
[ -r "$host_public_key" ] || fail "worker SSH host public key is missing or unreadable"
[ -s "$host_public_key" ] || fail "worker SSH host public key is empty"

case "$port" in
  ''|*[!0-9]*) fail "SYMPHONY_PORT must be a numeric TCP port" ;;
esac

if [ "$port" -gt 65535 ]; then
  fail "SYMPHONY_PORT must be between 0 and 65535"
fi

umask 077
mkdir -p "$ssh_dir" "$logs_root"
cp "$private_key" "$ssh_dir/worker_key"
chmod 0600 "$ssh_dir/worker_key"

host_key=$(tr -d '\r\n' <"$host_public_key")
case "$host_key" in
  ssh-ed25519\ *) ;;
  *) fail "worker SSH host public key must be an ssh-ed25519 public key" ;;
esac

known_hosts="$ssh_dir/known_hosts"
printf '[agent-worker]:2222 %s\n' "$host_key" >"$known_hosts"
unset host_key
chmod 0600 "$known_hosts"

cat >"$ssh_dir/config" <<EOF
Host agent-worker
  HostName agent-worker
  User worker
  Port 2222
  IdentityFile $ssh_dir/worker_key
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $known_hosts
  LogLevel ERROR
EOF
chmod 0600 "$ssh_dir/config"

set -- \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root" \
  --port "$port" \
  "$workflow_path"

exec /app/bin/symphony eval 'SymphonyElixir.CLI.main(System.argv())' "$@"
