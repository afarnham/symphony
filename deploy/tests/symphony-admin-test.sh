#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ADMIN=$(cd -- "$SCRIPT_DIR/.." && pwd)/symphony-admin
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/symphony-admin-test.XXXXXX")
SECRETS_ROOT="$TEST_ROOT/secrets"
PASS_COUNT=0

cleanup() {
  rm -f -- \
    "$TEST_ROOT/fake-bin/docker" \
    "$TEST_ROOT/docker.log" \
    "$TEST_ROOT/deployment.env" \
    "$TEST_ROOT/authorized-key.backup" \
    "$TEST_ROOT/injected"
  if [[ -d "$SECRETS_ROOT" ]]; then
    find "$SECRETS_ROOT" -type f -exec rm -f -- {} +
    find "$SECRETS_ROOT" -depth -type d -exec rmdir -- {} + 2>/dev/null || true
  fi
  rmdir -- "$TEST_ROOT/fake-bin" "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf 'ok %d - %s\n' "$PASS_COUNT" "$1"
}

mode_of() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

admin() {
  SYMPHONY_SECRETS_DIR="$SECRETS_ROOT" \
    SYMPHONY_SECRET_UID="$(id -u)" \
    SYMPHONY_SECRET_GID="$(id -g)" \
    "$ADMIN" "$@"
}

set_secret() {
  local name=$1
  local value=$2
  printf '%s\n' "$value" | admin secrets set "$name" --stdin
}

assert_file_line() {
  local path=$1
  local expected=$2
  local actual
  IFS= read -r actual <"$path" || fail "could not read $path"
  [[ "$actual" == "$expected" ]] || fail "$path did not contain the expected value"
}

printf '1..14\n'

admin secrets init >/dev/null
[[ "$(mode_of "$SECRETS_ROOT")" == "700" ]] || fail "secrets directory mode"
for name in \
  github_project_token github_worker_token claude_oauth_token openai_api_key \
  worker_ssh_private_key worker_ssh_authorized_key \
  worker_ssh_host_private_key worker_ssh_host_public_key; do
  [[ "$(mode_of "$SECRETS_ROOT/$name")" == "400" ]] || fail "$name mode"
done
ssh-keygen -l -f "$SECRETS_ROOT/worker_ssh_authorized_key" >/dev/null || fail "generated SSH key"
ssh-keygen -l -f "$SECRETS_ROOT/worker_ssh_host_public_key" >/dev/null || fail "generated host SSH key"
pass "init creates private files and a valid ed25519 worker key"

private_fingerprint=$(ssh-keygen -lf "$SECRETS_ROOT/worker_ssh_private_key")
admin secrets init >/dev/null
[[ "$(ssh-keygen -lf "$SECRETS_ROOT/worker_ssh_private_key")" == "$private_fingerprint" ]] ||
  fail "init replaced existing worker key"
pass "init is idempotent and preserves generated key material"

cp "$SECRETS_ROOT/worker_ssh_authorized_key" "$TEST_ROOT/authorized-key.backup"
rm -f "$SECRETS_ROOT/worker_ssh_authorized_key"
admin secrets init >/dev/null
[[ "$(ssh-keygen -lf "$SECRETS_ROOT/worker_ssh_authorized_key")" == \
  "$(ssh-keygen -lf "$TEST_ROOT/authorized-key.backup")" ]] ||
  fail "init did not recover the authorized key from its private key"
pass "init safely recovers interrupted SSH public-key installation"

project_token='github-secret-value-1'
set_output=$(set_secret github_project_token "$project_token" 2>&1)
[[ "$set_output" != *"$project_token"* ]] || fail "set disclosed project token"
assert_file_line "$SECRETS_ROOT/github_project_token" "$project_token"
[[ "$(mode_of "$SECRETS_ROOT/github_project_token")" == "400" ]] || fail "rotated mode"
pass "set accepts stdin without disclosing the value"

set_secret github_project_token 'github-secret-value-2' >/dev/null
assert_file_line "$SECRETS_ROOT/github_project_token" 'github-secret-value-2'
[[ "$(find "$SECRETS_ROOT" -name '.github_project_token.*' -print -quit)" == "" ]] ||
  fail "rotation left a temporary file"
pass "rotation atomically replaces a secret"

if printf 'truncated-without-newline' | admin secrets set github_project_token --stdin >/dev/null 2>&1; then
  fail "truncated input unexpectedly succeeded"
fi
assert_file_line "$SECRETS_ROOT/github_project_token" 'github-secret-value-2'
pass "truncated input preserves the previous secret"

if printf '\n' | admin secrets set github_project_token --stdin >/dev/null 2>&1; then
  fail "empty input unexpectedly succeeded"
fi
assert_file_line "$SECRETS_ROOT/github_project_token" 'github-secret-value-2'
pass "failed empty input preserves the previous secret"

injection_target="$TEST_ROOT/injected"
if printf 'bad\n' | admin secrets set "github_project_token;touch $injection_target" --stdin >/dev/null 2>&1; then
  fail "invalid secret name unexpectedly succeeded"
fi
[[ ! -e "$injection_target" ]] || fail "secret name executed shell syntax"
pass "invalid and injected secret names are rejected"

list_output=$(admin secrets list)
[[ "$list_output" != *'github-secret-value-2'* ]] || fail "list disclosed token"
[[ "$list_output" == *'claude_oauth_token'*'unset'* ]] || fail "list did not report optional unset secret"
pass "list reports state without revealing values"

set_secret github_worker_token 'worker-secret-value' >/dev/null
admin secrets verify >/dev/null || fail "verify rejected valid required secrets"
pass "verify accepts required GitHub tokens with optional model credentials unset"

chmod 644 "$SECRETS_ROOT/github_worker_token"
if admin secrets verify >/dev/null 2>&1; then
  fail "verify accepted an insecure mode"
fi
chmod 400 "$SECRETS_ROOT/github_worker_token"
pass "verify rejects insecure permissions"

mkdir -p "$TEST_ROOT/fake-bin"
apply_fake_docker() {
  cat >"$TEST_ROOT/fake-bin/docker" <<'EOF'
#!/usr/bin/env bash
{
  printf '%s\n' '<call>'
  printf '%s\n' "$@"
} >>"$FAKE_DOCKER_LOG"
EOF
  chmod 755 "$TEST_ROOT/fake-bin/docker"
}
apply_fake_docker
FAKE_DOCKER_LOG="$TEST_ROOT/docker.log" \
  PATH="$TEST_ROOT/fake-bin:$PATH" \
  SYMPHONY_SECRETS_DIR="$SECRETS_ROOT" \
  "$ADMIN" auth codex >/dev/null
expected_args=$'<call>\ncompose\n--project-name\nsymphony\n--file\n/opt/symphony/compose.yaml\nrun\n--rm\n--no-deps\nvolume-init\n<call>\ncompose\n--project-name\nsymphony\n--file\n/opt/symphony/compose.yaml\nrun\n--rm\n--no-deps\nagent-worker\ncodex\nlogin\n--device-auth'
actual_args=$(<"$TEST_ROOT/docker.log")
[[ "$actual_args" == "$expected_args" ]] || fail "Codex auth compose arguments were incorrect"
pass "Codex auth uses a disposable worker container"

deployment_env="$TEST_ROOT/deployment.env"
: >"$deployment_env"
: >"$TEST_ROOT/docker.log"
FAKE_DOCKER_LOG="$TEST_ROOT/docker.log" \
  PATH="$TEST_ROOT/fake-bin:$PATH" \
  SYMPHONY_SECRETS_DIR="$SECRETS_ROOT" \
  SYMPHONY_ENV_FILE="$deployment_env" \
  "$ADMIN" auth claude >/dev/null
expected_args=$'<call>\ncompose\n--env-file\n'"$deployment_env"$'\n--project-name\nsymphony\n--file\n/opt/symphony/compose.yaml\nrun\n--rm\n--no-deps\nvolume-init\n<call>\ncompose\n--env-file\n'"$deployment_env"$'\n--project-name\nsymphony\n--file\n/opt/symphony/compose.yaml\nrun\n--rm\n--no-deps\nagent-worker\nclaude\nauth\nlogin'
actual_args=$(<"$TEST_ROOT/docker.log")
[[ "$actual_args" == "$expected_args" ]] || fail "deployment env file was not forwarded"
pass "auth loads the protected deployment environment file"

if FAKE_DOCKER_LOG="$TEST_ROOT/docker.log" \
  PATH="$TEST_ROOT/fake-bin:$PATH" \
  SYMPHONY_SECRETS_DIR="$SECRETS_ROOT" \
  SYMPHONY_WORKER_SERVICE='agent-worker;touch-injected' \
  "$ADMIN" auth claude >/dev/null 2>&1; then
  fail "injected service name unexpectedly succeeded"
fi
pass "compose service input is validated instead of evaluated"

printf '# %d tests passed\n' "$PASS_COUNT"
