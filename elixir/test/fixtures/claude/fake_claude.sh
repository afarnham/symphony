#!/usr/bin/env bash

set -eu

if [ "${1-}" = "auth" ] && [ "${2-}" = "status" ]; then
  case "${FAKE_CLAUDE_AUTH_STATUS-logged-in}" in
    logged-in)
      printf '%s\n' '{"loggedIn":true,"authMethod":"oauth_token","apiProvider":"firstParty"}'
      exit 0
      ;;
    logged-out)
      printf '%s\n' '{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty"}'
      exit 1
      ;;
    malformed)
      printf '%s\n' 'auth status is unavailable'
      exit 1
      ;;
    timeout)
      sleep 30
      exit 1
      ;;
  esac
fi

count_file="$PWD/.fake-claude-count"
count=0

if [ -f "$count_file" ]; then
  count=$(cat "$count_file")
fi

count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s\n' "$@" > "$PWD/claude-args-$count.txt"
cat > "$PWD/claude-prompt-$count.txt"
printf '%s' "${SYMPHONY_TRACKER_MCP_URL-unset}" > "$PWD/claude-mcp-url-$count.txt"
printf '%s' "${SYMPHONY_TRACKER_MCP_TOKEN-unset}" > "$PWD/claude-mcp-token-$count.txt"
printf '%s' "${LINEAR_API_KEY-unset}" > "$PWD/claude-tracker-secret-$count.txt"

allowed_tools=""
has_mcp_config=false
previous=""

for argument in "$@"; do
  if [ "$previous" = "--allowedTools" ]; then
    allowed_tools="$argument"
  fi

  if [ "$previous" = "--mcp-config" ]; then
    has_mcp_config=true
  fi

  previous="$argument"
done

tools_json=""

if [ -n "$allowed_tools" ]; then
  old_ifs=$IFS
  IFS=','
  for tool in $allowed_tools; do
    if [ -n "$tools_json" ]; then
      tools_json="$tools_json,"
    fi
    tools_json="$tools_json\"$tool\""
  done
  IFS=$old_ifs
fi

mcp_servers_json=""
if [ "$has_mcp_config" = true ]; then
  mcp_servers_json='{"name":"symphony_tracker","status":"connected"}'
fi

mode=$(cat "$PWD/claude-prompt-$count.txt")
session_id="session-123"

if [ "$mode" = "session-mismatch" ]; then
  session_id="session-other"
fi

case "$mode" in
  *-mcp-disconnected)
    tools_json=""
    mcp_servers_json=""
    ;;
esac

printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$session_id\",\"cwd\":\"$PWD\",\"model\":\"fake-claude\",\"permissionMode\":\"default\",\"tools\":[$tools_json],\"mcp_servers\":[$mcp_servers_json]}"

case "$mode" in
  blocked|blocked-mcp-disconnected)
    printf '%s\n' '{"type":"assistant","session_id":"session-123","message":{"id":"message-blocked","content":[{"type":"text","text":"<!-- symphony:needs-input -->\nWhich environment should I use?"}]}}'
    printf '%s\n' '{"type":"result","subtype":"success","session_id":"session-123","is_error":false,"result":"<!-- symphony:needs-input -->\nWhich environment should I use?"}'
    ;;

  ignore-term)
    printf '%s\n' "$$" > "$PWD/claude-process.pid"
    bash -c 'trap "" TERM HUP INT; while :; do sleep 1; done' &
    child=$!
    printf '%s\n' "$child" > "$PWD/claude-child.pid"
    trap '' TERM HUP INT
    wait "$child"
    ;;

  read-timeout)
    printf '%s\n' "$$" > "$PWD/claude-process.pid"
    sleep 30 &
    child=$!
    printf '%s\n' "$child" > "$PWD/claude-child.pid"
    trap 'printf terminated > "$PWD/claude-terminated"; exit 143' TERM INT
    wait "$child"
    ;;

  hard-timeout)
    printf '%s\n' "$$" > "$PWD/claude-process.pid"
    sleep 30 &
    child=$!
    printf '%s\n' "$child" > "$PWD/claude-child.pid"
    trap 'printf terminated > "$PWD/claude-terminated"; exit 143' TERM INT

    while :; do
      printf '%s\n' '{"type":"system","subtype":"task_progress","session_id":"session-123","task_id":"task-1","description":"still working"}'
      sleep 0.03
    done
    ;;

  fail|fail-mcp-disconnected)
    printf '%s\n' '{"type":"result","subtype":"error_during_execution","session_id":"session-123","is_error":true,"result":"The turn failed."}'
    exit 1
    ;;

  *)
    printf '%s\n' "{\"type\":\"assistant\",\"session_id\":\"$session_id\",\"message\":{\"id\":\"message-$count\",\"content\":[{\"type\":\"text\",\"text\":\"completed turn $count\"}],\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}}"
    printf '%s\n' "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"$session_id\",\"is_error\":false,\"result\":\"completed turn $count\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2}}"
    ;;
esac
