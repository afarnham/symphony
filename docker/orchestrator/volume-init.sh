#!/bin/sh
set -eu

target_uid=10001
target_gid=10001

for volume_root in \
  /volumes/afarnham/workspaces \
  /volumes/afarnham/claude-auth \
  /volumes/afarnham/codex-auth \
  /volumes/afarnham/worker-cache \
  /volumes/afarnham/worker-local \
  /volumes/karbas/workspaces \
  /volumes/karbas/claude-auth \
  /volumes/karbas/codex-auth \
  /volumes/karbas/worker-cache \
  /volumes/karbas/worker-local \
  /volumes/logs
do
  if [ ! -d "$volume_root" ] || [ -L "$volume_root" ]; then
    printf 'invalid managed volume mount: %s\n' "$volume_root" >&2
    exit 1
  fi

  if [ "$(stat -c '%u:%g:%a' "$volume_root")" = "$target_uid:$target_gid:700" ]; then
    continue
  fi

  # Regain ownership before chmod so the service needs only CAP_CHOWN, even on
  # repeat runs where the volume root already belongs to the runtime user.
  chown 0:0 "$volume_root"
  chmod 0700 "$volume_root"
  chown "$target_uid:$target_gid" "$volume_root"
done
