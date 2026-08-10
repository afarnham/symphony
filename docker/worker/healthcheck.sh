#!/bin/bash
set -euo pipefail

exec 3<>/dev/tcp/127.0.0.1/2222
IFS= read -r -t 3 banner <&3
exec 3>&-

[[ "$banner" == SSH-* ]]
