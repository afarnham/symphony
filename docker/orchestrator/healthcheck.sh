#!/bin/sh
set -eu

port=${SYMPHONY_PORT:-4000}
exec curl --fail --silent --show-error --max-time 4 "http://127.0.0.1:${port}/api/v1/state" >/dev/null
