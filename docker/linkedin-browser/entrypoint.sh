#!/bin/sh
# Run Chromium on a virtual display, the LinkedIn bridge, and, only when
# SYMPHONY_LINKEDIN_LOGIN=1, a noVNC view of that display for the one-time
# LinkedIn sign-in. Exit when any process stops so the container restarts.
set -eu

profile=/data/profile
export DISPLAY=:99

Xvfb "$DISPLAY" -screen 0 1280x900x24 -nolisten tcp &
pids=$!
i=0
until [ -S /tmp/.X11-unix/X99 ]; do
  i=$((i + 1))
  [ "$i" -le 50 ] || { echo "Xvfb did not start" >&2; exit 1; }
  sleep 0.2
done

# Only this container uses the profile volume. A lock or DevTools port left by
# an earlier container (different hostname) would stop Chromium or mislead the
# bridge, so clear them before starting.
rm -f "$profile/SingletonLock" "$profile/SingletonSocket" "$profile/SingletonCookie" \
  "$profile/DevToolsActivePort"

# The container itself is the sandbox; Chromium's own sandbox needs privileges
# Docker does not grant. DevTools binds to the container's loopback only.
chromium \
  --no-sandbox \
  --user-data-dir="$profile" \
  --password-store=basic \
  --no-first-run \
  --no-default-browser-check \
  --disable-sync \
  --disable-dev-shm-usage \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=0 \
  about:blank &
pids="$pids $!"

SYMPHONY_LINKEDIN_BRIDGE_SOCKET=/run/symphony-linkedin/bridge.sock \
SYMPHONY_LINKEDIN_BRIDGE_TOKEN_FILE=/run/secrets/linkedin_bridge_token \
SYMPHONY_LINKEDIN_CHROME_USER_DATA_DIR="$profile" \
  node /opt/linkedin-bridge/src/index.mjs &
pids="$pids $!"

if [ "${SYMPHONY_LINKEDIN_LOGIN:-0}" = 1 ]; then
  x11vnc -display "$DISPLAY" -localhost -forever -shared -nopw -quiet &
  pids="$pids $!"
  websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
  pids="$pids $!"
fi

trap 'kill $pids 2>/dev/null' INT TERM
# Wait for the first process to exit, then stop the rest.
while :; do
  for pid in $pids; do
    if ! kill -0 "$pid" 2>/dev/null; then
      kill $pids 2>/dev/null || true
      exit 1
    fi
  done
  sleep 5
done
