#!/usr/bin/env bash

set -eu

trace=${FAKE_SSH_TRACE:?}
state_dir=${FAKE_SSH_STATE_DIR:?}
mkdir -p "$state_dir"

printf 'CALL' >> "$trace"
for argument in "$@"; do
  printf '\t%s' "$argument" >> "$trace"
done
printf '\n' >> "$trace"

arguments=" $* "

case "$arguments" in
  *" -O check "*)
    if [ -f "$state_dir/loss" ]; then
      exit 42
    fi

    find "$state_dir" -name 'tunnel-*.ready' -type f | grep -q .
    ;;

  *" -O exit "*)
    touch "$state_dir/stop"
    exit 0
    ;;

  *" -N -R "*)
    if [ "${FAKE_SSH_REMOTE_MODE-}" = "reject-forwarding" ]; then
      printf 'remote port forwarding rejected\n'
      exit 23
    fi

    forwarding=""
    previous=""

    for argument in "$@"; do
      if [ "$previous" = "-R" ]; then
        forwarding=$argument
        break
      fi
      previous=$argument
    done

    remote_port=$(printf '%s' "$forwarding" | cut -d: -f2)

    if [ "${FAKE_SSH_FAIL_REMOTE_PORT-}" = "$remote_port" ]; then
      printf 'remote port forwarding failed\n'
      exit 23
    fi

    ready_file="$state_dir/tunnel-$remote_port.ready"
    rm -f "$state_dir/stop"
    touch "$ready_file"
    trap 'rm -f "$ready_file"; exit 0' TERM INT

    while [ ! -f "$state_dir/stop" ]; do
      if [ -f "$state_dir/loss" ]; then
        rm -f "$ready_file"
        exit 42
      fi
      sleep 0.01
    done

    rm -f "$ready_file"
    exit 0
    ;;

  *)
    remote_command="${!#}"

    if [[ "$remote_command" == *"SYMPHONY_SSH_FORWARD_PROBE"* ]]; then
      if [ "${FAKE_SSH_REMOTE_MODE-}" = "forward-probe-timeout" ]; then
        while :; do sleep 1; done
      fi

      printf 'symphony-ssh-forward-probe-ok'
      exit 0
    fi

    if [[ "$remote_command" == *"SYMPHONY_MCP_HEALTH"* ]]; then
      if [ "${FAKE_SSH_REMOTE_MODE-}" = "mcp-health-failure" ]; then
        exit 44
      fi
      exit 0
    fi

    if [[ "$remote_command" == *"rm -rf -- "*"symphony-claude."* ]] &&
       [ "${FAKE_SSH_REMOTE_MODE-}" = "cleanup-failure" ]; then
      exit 41
    fi

    case "${FAKE_SSH_REMOTE_MODE-}" in
      missing-bash) exit 41 ;;
      missing-claude) exit 42 ;;
      missing-curl) exit 43 ;;
    esac

    exec bash -c "$remote_command"
    ;;
esac
