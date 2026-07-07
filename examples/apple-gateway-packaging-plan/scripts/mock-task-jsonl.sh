#!/usr/bin/env sh

set -eu

target="${1:-build:homebrew-cask}"

rejected_names=""
for env_name in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  eval "env_value=\${$env_name-}"
  if [ -n "$env_value" ]; then
    if [ -n "$rejected_names" ]; then
      rejected_names="$rejected_names,$env_name"
    else
      rejected_names="$env_name"
    fi
  fi
done

if [ -n "$rejected_names" ]; then
  TARGET="$target" REJECTED_NAMES="$rejected_names" python3 - <<'PY'
import json
import os

print(json.dumps({
    "target": os.environ["TARGET"],
    "dryRun": True,
    "exitCode": 64,
    "credentialBoundaryViolation": True,
    "rejectedAppleEnvNames": os.environ["REJECTED_NAMES"].split(","),
    "rejectedAppleEnvValues": "redacted",
    "message": "Refusing to run packaging-plan mock with Apple signing credentials in the command environment."
}, separators=(",", ":")))
PY
  exit 64
fi

TARGET="$target" python3 - <<'PY'
import json
import os

print(json.dumps({
    "target": os.environ["TARGET"],
    "dryRun": True,
    "exitCode": 0,
    "sideEffects": {
        "publishes": False,
        "signs": False,
        "notarizes": False,
        "uploads": False
    },
    "requiredAppleEnvNames": [
        "APPLE_SIGNING_IDENTITY",
        "APPLE_ID",
        "APPLE_PASSWORD",
        "APPLE_TEAM_ID"
    ],
    "requiredAppleEnvValuesPresent": False,
    "planText": "\n".join([
        "Swift Homebrew Cask DMG plan",
        "mode: dry-run",
        "targets: darwin-arm64, darwin-x64",
        "artifact: Riela.dmg",
        "sign: false",
        "notarize: false",
        "publish side effects: false",
        "required Apple env: APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID names only"
    ])
}, separators=(",", ":")))
PY
