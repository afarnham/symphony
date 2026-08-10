#!/bin/sh
set -eu

authorized_key=/run/secrets/worker_ssh_authorized_key
github_token=/run/secrets/github_worker_token
openai_api_key=/run/secrets/openai_api_key
host_private_key=/run/secrets/worker_ssh_host_private_key

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

[ -r "$authorized_key" ] || fail "worker SSH authorized key is missing or unreadable"
[ -s "$authorized_key" ] || fail "worker SSH authorized key is empty"
[ -r "$github_token" ] || fail "GitHub worker token is missing or unreadable"
[ -s "$github_token" ] || fail "GitHub worker token is empty"
[ -r "$host_private_key" ] || fail "worker SSH host private key is missing or unreadable"
[ -s "$host_private_key" ] || fail "worker SSH host private key is empty"

umask 077
mkdir -p "$GH_CONFIG_DIR"

token=$(tr -d '\r\n' <"$github_token")
[ -n "$token" ] || fail "GitHub worker token contains no usable value"
cat >"$GH_CONFIG_DIR/hosts.yml" <<EOF
github.com:
    git_protocol: https
    users:
        x-access-token:
    user: x-access-token
    oauth_token: $token
EOF
chmod 0600 "$GH_CONFIG_DIR/hosts.yml"
unset token

if [ -s "$openai_api_key" ]; then
  if ! /usr/local/libexec/codex-real login --with-api-key <"$openai_api_key" >/dev/null 2>&1; then
    fail "Codex API-key authentication failed"
  fi
fi

case "${1:-serve}" in
  serve)
    shift || true
    exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
    ;;
  *)
    exec "$@"
    ;;
esac
