#!/bin/sh
# Test-only VM loopback fixture; never included in the production runtime image.
set -eu
if [ -n "${RIELA_FIXTURE_PROXY_HOST:-}" ]; then
  : "${RIELA_FIXTURE_PROXY_PORT:?fixture port is required}"
  receipt=$(mktemp "${TMPDIR:?private temporary directory is required}/sdk-proxy.XXXXXX")
  LD_LIBRARY_PATH=/opt/riela/proxy-libs /opt/riela/socat -d -d \
    "TCP-LISTEN:$RIELA_FIXTURE_PROXY_PORT,bind=127.0.0.1,reuseaddr,fork" \
    "TCP:$RIELA_FIXTURE_PROXY_HOST:$RIELA_FIXTURE_PROXY_PORT" 2>"$receipt" &
  proxy_pid=$!
  attempts=0
  until grep -q 'listening on' "$receipt"; do
    kill -0 "$proxy_pid" 2>/dev/null || { cat "$receipt" >&2; exit 1; }
    attempts=$((attempts + 1))
    [ "$attempts" -lt 200 ] || { cat "$receipt" >&2; exit 1; }
    sleep 0.05
  done
fi
exec /opt/riela/riela-worker "$@"
