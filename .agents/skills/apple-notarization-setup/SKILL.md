---
name: apple-notarization-setup
description: Use when setting up or verifying Apple Developer ID signing credentials, Apple app-specific passwords, kinko secret storage, or local macOS notarization readiness for riela without recording credential values.
---

# Apple Notarization Setup

Use this for riela macOS signing/notarization setup before local Homebrew Cask
DMG release builds. Keep all credential values out of logs, skill files,
commits, and final responses.

## Credential Safety

- Never print, paste, commit, or summarize actual Apple passwords,
  app-specific passwords, certificate passwords, private keys, `.p12` contents,
  or kinko secret values.
- It is acceptable to mention secret key names such as `APPLE_ID`,
  `APPLE_PASSWORD`, `APPLE_TEAM_ID`, and `APPLE_SIGNING_IDENTITY`.
- When a private login, passkey, or 2FA step is needed, ask the user to enter
  it directly in the browser or system dialog.
- Use `kinko exec --env ...` for commands that need secrets. Do not use
  commands that echo exported secret values.

## Required Local Inputs

The local Cask DMG path expects:

- A valid Developer ID Application certificate imported into the macOS login
  keychain.
- `APPLE_SIGNING_IDENTITY` stored in kinko.
- `APPLE_ID` stored in kinko.
- `APPLE_TEAM_ID` stored in kinko.
- `APPLE_PASSWORD` stored in kinko as an Apple app-specific password.

Check presence only:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
for key in APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
  if [ -n "${!key:-}" ]; then echo "$key=present"; else echo "$key=missing"; fi
done
'
```

Check local certificates:

```bash
security find-identity -v -p codesigning
```

Expect a valid `Developer ID Application` identity matching the stored identity
name.

## Local Build And Notarization

Build signed, notarized, and stapled Cask DMGs:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

For a tagged release:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v<version>
```

This builds:

- `dist/homebrew-cask/riela-<version>-darwin-arm64.dmg`
- `dist/homebrew-cask/riela-<version>-darwin-x64.dmg`

The release wrapper uploads the `.dmg` assets to the GitHub release and renders
`../homebrew-tap/Casks/riela.rb`. Commit and push the tap change from the tap
repository after review.

## Notarization Status

When `notarytool` submits notarization, record only submission ids and status.
To check status:

```bash
kinko exec --env APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- bash -lc '
/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool info <submission-id> \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID"
'
```

Look for `status: Accepted`. If a submission stays `In Progress`, do not claim
deployment is complete.

## Validation After Acceptance

After notarization is accepted and DMGs exist:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate dist/homebrew-cask/riela-<version>-darwin-x64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 dist/homebrew-cask/riela-<version>-darwin-x64.dmg
```

## Completion Criteria

Local Apple setup is complete when:

- kinko has all required Apple secret keys present.
- `security find-identity` reports the matching Developer ID Application
  identity.
- `task build:homebrew-cask -- darwin-arm64 darwin-x64` signs and notarizes
  both DMGs.
- Stapler and Gatekeeper validation pass for both DMGs.
