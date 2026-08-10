#!/bin/sh
set -eu

token_file=/run/secrets/claude_oauth_token

if [ -s "$token_file" ]; then
  CLAUDE_CODE_OAUTH_TOKEN=$(tr -d '\r\n' <"$token_file")
  [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || {
    printf '%s\n' "Claude OAuth token contains no usable value" >&2
    exit 1
  }
  export CLAUDE_CODE_OAUTH_TOKEN
fi

exec /usr/local/libexec/claude-real "$@"
