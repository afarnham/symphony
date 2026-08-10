#!/bin/sh
set -eu

# SSH sessions otherwise start in /home/worker, whose root stays read-only.
# Land in the persistent workspace volume while preserving HOME for CLI auth.
cd /workspaces
exec /bin/bash "$@"
