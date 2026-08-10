#!/bin/sh
set -eu

token_file=/run/secrets/github_worker_token

case "${1:-}" in
  get)
    protocol=
    host=

    while IFS='=' read -r key value; do
      case "$key" in
        protocol) protocol=$value ;;
        host) host=$value ;;
      esac
    done

    if [ "$protocol" = "https" ] && [ "$host" = "github.com" ] && [ -s "$token_file" ]; then
      printf 'username=x-access-token\npassword='
      tr -d '\r\n' <"$token_file"
      printf '\n\n'
    fi
    ;;
  store|erase)
    ;;
esac
