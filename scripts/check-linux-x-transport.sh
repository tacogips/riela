#!/usr/bin/env bash
# Regression for FoundationNetworking _MultiHandle teardown in embedded X reads.
# Synthetic credentials only: no account data, user credentials or billable posts.
set -euo pipefail
cli=${1:?Usage: check-linux-x-transport.sh /path/to/riela}
repo_root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$repo_root/tmp"
probe_root=$(mktemp -d "$repo_root/tmp/linux-x-transport.XXXXXX")
trap 'rm -rf "$probe_root"' EXIT
status=0
env -i PATH="$PATH" HOME="$probe_root" LANG=C.UTF-8 \
  X_GW_CONSUMER_KEY=synthetic X_GW_CONSUMER_SECRET=synthetic \
  X_GW_ACCESS_TOKEN=synthetic X_GW_ACCESS_TOKEN_SECRET=synthetic \
  "$cli" gateway x graphql query 'query { accountMe { id username } }' \
  --json --retry 0 --timeout-ms 10000 >"$probe_root/out" 2>"$probe_root/err" || status=$?
if ((status == 0 || status >= 128)); then
  echo "Synthetic X HTTPS probe did not return a controlled authentication/transport error (status $status)" >&2
  exit 1
fi
if grep -Eq 'non-zero retain count|Segmentation fault|Signal 11' "$probe_root/err"; then
  echo "Linux X transport lifetime regression" >&2
  exit 1
fi
python3 - "$probe_root/out" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
assert isinstance(value,dict) and ('errors' in value or 'error' in value), 'missing SDK error envelope'
PY
echo "Linux X HTTPS probe returned a controlled error (status $status)"
