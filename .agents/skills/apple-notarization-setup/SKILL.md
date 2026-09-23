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
- A validated `notarytool` Keychain profile named `riela-release` (or the name
  set by `RIELA_NOTARY_KEYCHAIN_PROFILE`). The app-specific password is entered
  into the secure interactive prompt once, not supplied on a command line.

Check presence only:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY -- bash -lc '
for key in APPLE_SIGNING_IDENTITY; do
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

## Store Notarization Credentials

After rotating any previously exposed app-specific password, create the
Keychain profile interactively. Never use `--password` to create it; the
notarytool prompt accepts the new password without exposing it in process
arguments. Enter the Apple ID, Team ID, and new password at its prompts:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool store-credentials riela-release
```

Set `RIELA_NOTARY_KEYCHAIN_PROFILE` if a different profile name is required.

## Local Build And Notarization

Build signed, notarized, and stapled Cask DMGs:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY -- \
  task build:homebrew-cask -- darwin-arm64
```

For a tagged release:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY -- \
  task release:homebrew-cask-local -- v<version>
```

This builds:

- `dist/homebrew-cask/riela-<version>-darwin-arm64.dmg`

The release wrapper uploads the `.dmg` assets to the GitHub release and renders
`../homebrew-tap/Casks/riela.rb`. Commit and push the tap change from the tap
repository after review.

## Notarization Status

When `notarytool` submits notarization, record only submission ids and status.
To check status:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/notarytool info <submission-id> \
  --keychain-profile riela-release
```

Look for `status: Accepted`. If a submission stays `In Progress`, do not claim
deployment is complete.

## Validation After Acceptance

After notarization is accepted and DMGs exist:

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
```

## Completion Criteria

Local Apple setup is complete when:

- kinko has `APPLE_SIGNING_IDENTITY` present and a validated `notarytool`
  Keychain profile is available.
- `security find-identity` reports the matching Developer ID Application
  identity.
- `task build:homebrew-cask -- darwin-arm64` signs and notarizes the ARM64 DMG.
- Stapler and Gatekeeper validation pass for the ARM64 DMG.
