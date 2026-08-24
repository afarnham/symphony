#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
project="symphony-container-smoke-$$"
dive_claude_model="smoke-claude-model"
dive_codex_model="smoke-codex-model"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/symphony-container-smoke.XXXXXX")
secrets_dir="$test_root/secrets"
mkdir -p "$secrets_dir"

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    printf '%s\n' "the container smoke test needs root or sudo to apply production secret ownership" >&2
    exit 1
  fi
}

cleanup() {
  SYMPHONY_SECRETS_DIR="$secrets_dir" \
  SYMPHONY_WORKFLOW_FILE="$repo_root/docker/tests/WORKFLOW.md" \
    docker compose --project-directory "$repo_root" -p "$project" down --volumes --remove-orphans \
      >/dev/null 2>&1 || true

  case "$test_root" in
    "${TMPDIR:-/tmp}"/symphony-container-smoke.*) rm -rf -- "$test_root" ;;
  esac
}
trap cleanup EXIT INT TERM

command -v docker >/dev/null 2>&1 || {
  printf '%s\n' "docker is required" >&2
  exit 1
}
docker compose version >/dev/null

ssh-keygen -q -t ed25519 -N '' -f "$secrets_dir/worker_ssh_private_key"
cp "$secrets_dir/worker_ssh_private_key.pub" "$secrets_dir/worker_ssh_authorized_key"
ssh-keygen -q -t ed25519 -N '' -f "$secrets_dir/worker_ssh_host_private_key"
cp "$secrets_dir/worker_ssh_host_private_key.pub" "$secrets_dir/worker_ssh_host_public_key"

github_project_token=$(openssl rand -hex 24)
github_worker_token=$(openssl rand -hex 24)
printf '%s\n' "$github_project_token" >"$secrets_dir/github_project_token"
printf '%s\n' "$github_worker_token" >"$secrets_dir/github_worker_token"
for profile in afarnham karbas; do
  : >"$secrets_dir/${profile}_claude_oauth_token"
  : >"$secrets_dir/${profile}_openai_api_key"
done
# Match production's bind-mounted Compose secret contract. This also exercises
# OpenSSH StrictModes for the directly mounted authorized-keys file.
as_root chown 10001:10001 "$secrets_dir"/*
as_root chmod 0400 "$secrets_dir"/*

compose() {
  SYMPHONY_DIVE_CLAUDE_MODEL="$dive_claude_model" \
  SYMPHONY_DIVE_CODEX_MODEL="$dive_codex_model" \
  SYMPHONY_SECRETS_DIR="$secrets_dir" \
  SYMPHONY_WORKFLOW_FILE="$repo_root/docker/tests/WORKFLOW.md" \
    docker compose \
      --project-directory "$repo_root" \
      -f "$repo_root/compose.yaml" \
      -f "$repo_root/compose.build.yaml" \
      -p "$project" \
      "$@"
}

SYMPHONY_DIVE_CODEX_MODEL= \
SYMPHONY_SECRETS_DIR="$secrets_dir" \
SYMPHONY_WORKFLOW_FILE="$repo_root/docker/tests/WORKFLOW.md" \
  docker compose \
    --project-directory "$repo_root" \
    -f "$repo_root/compose.yaml" \
    -f "$repo_root/compose.build.yaml" \
    -p "${project}-defaults" \
    config | grep -F 'SYMPHONY_DIVE_CODEX_MODEL: gpt-5.6-terra' >/dev/null

compose config >"$test_root/rendered-compose.yaml"
if grep -F "$github_project_token" "$test_root/rendered-compose.yaml" >/dev/null || \
   grep -F "$github_worker_token" "$test_root/rendered-compose.yaml" >/dev/null; then
  printf '%s\n' "rendered Compose configuration contains a secret value" >&2
  exit 1
fi

compose up --detach --build --wait

curl --fail --silent --show-error --max-time 5 \
  "http://127.0.0.1:${SYMPHONY_PORT:-4000}/api/v1/state" >/dev/null

[ "$(compose exec -T symphony id -u)" = "10001" ]
[ "$(compose exec -T agent-worker-afarnham id -u)" = "10001" ]
[ "$(compose exec -T agent-worker-karbas id -u)" = "10001" ]

compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham \
  'test "$PWD" = /workspaces && test "$GH_CONFIG_DIR" = /tmp/symphony-gh && test "$XDG_CACHE_HOME" = /home/worker/.cache && test "$NPM_CONFIG_CACHE" = /home/worker/.cache/npm && test "$SYMPHONY_DIVE_CLAUDE_MODEL" = smoke-claude-model && test "$SYMPHONY_DIVE_CODEX_MODEL" = smoke-codex-model'
compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham 'gh auth token >/dev/null'
compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham \
  'printf "protocol=https\nhost=github.com\n\n" | git credential fill >/dev/null'
compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham \
  'test -d /run/sshd && npm cache verify >/dev/null && pnpm store path >/dev/null'
compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham \
  'test "$(git config --get user.name)" = "Symphony Agent" && test "$(git config --get user.email)" = "symphony-agent@users.noreply.github.com"'
compose exec -T symphony ssh -F /tmp/symphony-ssh/config agent-worker-afarnham \
  'repo=$(mktemp -d /workspaces/smoke-commit.XXXXXX) && git -C "$repo" init -q && printf smoke >"$repo/check" && git -C "$repo" add check && git -C "$repo" commit -qm "test: smoke worker commit" && rm -rf -- "$repo"'

compose exec -T agent-worker-afarnham touch /home/worker/.codex/afarnham-only
compose exec -T agent-worker-afarnham touch /home/worker/.claude/afarnham-only
compose exec -T agent-worker-afarnham touch /workspaces/afarnham-only
compose exec -T agent-worker-karbas test ! -e /home/worker/.codex/afarnham-only
compose exec -T agent-worker-karbas test ! -e /home/worker/.claude/afarnham-only
compose exec -T agent-worker-karbas test ! -e /workspaces/afarnham-only

compose exec -T --detach symphony \
  ssh -F /tmp/symphony-ssh/config -N -R 127.0.0.1:49123:127.0.0.1:4000 agent-worker-afarnham
sleep 2
compose exec -T agent-worker-afarnham \
  curl --fail --silent --show-error --max-time 5 http://127.0.0.1:49123/api/v1/state >/dev/null

if compose logs | grep -F "$github_project_token" >/dev/null || \
   compose logs | grep -F "$github_worker_token" >/dev/null; then
  printf '%s\n' "container logs contain a secret value" >&2
  exit 1
fi

printf '%s\n' "Symphony container smoke test passed"
