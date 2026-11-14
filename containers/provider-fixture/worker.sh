#!/bin/sh
set -eu
/opt/riela/provider-fixture &
provider_pid=$!
trap 'kill "$provider_pid" 2>/dev/null || true' EXIT HUP INT TERM
attempt=0
while [ ! -f /tmp/provider-fixture-ready ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 100 ]; then exit 1; fi
  sleep 0.1
done
/opt/riela/riela-addon-worker-real "$@"
