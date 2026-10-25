#!/usr/bin/env bash
# Real bounded HTTPS read with synthetic credentials only; no mailbox data.
set -euo pipefail
cli=${1:?Usage: check-linux-gmail-transport.sh /path/to/riela}
repo_root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$repo_root/tmp"
probe_root=$(mktemp -d "$repo_root/tmp/linux-gmail-transport.XXXXXX")
trap 'rm -rf "$probe_root"' EXIT
python3 - "$probe_root/config.toml" "$probe_root" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[2]);quoted=lambda name:json.dumps(str(root/name))
Path(sys.argv[1]).write_text('[storage]\ncache_dir = '+quoted('cache')+'\nattachment_dir = '+quoted('attachments')+'''
allowed_send_attachment_roots = []
[[credentials]]
id = "fixture"
provider = "gmail"
access_mode = "read"
token_store_path = '''+quoted('token.json')+'''
[[accounts]]
id = "personal"
provider = "gmail"
email_address = "fixture@example.invalid"
credential_id = "fixture"
default_label_ids = ["INBOX"]
''')
PY
status=0
env -i PATH="$PATH" HOME="$probe_root" LANG=C.UTF-8 \
  GMAIL_GATEWAY_CONFIG="$probe_root/config.toml" \
  GMAIL_GATEWAY_CREDENTIAL_FIXTURE_ACCESS_TOKEN=synthetic \
  "$cli" gateway gmail graphql query --query \
  'query { messageBodyBytes(accountId:"personal",messageId:"synthetic",maxBytes:1024) { complete byteCount } }' \
  >"$probe_root/out" 2>"$probe_root/err" || status=$?
if ((status == 0 || status >= 128)); then
  echo "Synthetic Gmail bounded read did not return a controlled error (status $status)" >&2
  exit 1
fi
if grep -Eq 'non-zero retain count|Segmentation fault|Signal 11' "$probe_root/err"; then
  echo "Linux Gmail bounded transport lifetime regression" >&2
  exit 1
fi
python3 - "$probe_root/out" <<'PY'
import json,sys
value=json.load(open(sys.argv[1]))
errors=value.get('errors',[])
assert any(error.get('code')=='PROVIDER_API_ERROR' and error.get('message')=='Gmail bounded read failed'
    and 400<=error.get('extensions',{}).get('httpStatus',0)<=599 for error in errors), 'bounded HTTPS response not exercised'
PY
echo "Linux Gmail bounded HTTPS probe returned a controlled error (status $status)"
