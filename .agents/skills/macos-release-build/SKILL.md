---
name: macos-release-build
description: Use when building, signing, notarizing, validating, publishing, or tap-rendering riela macOS Homebrew Cask `.dmg` artifacts.
---

# macOS Release Build Skill

This skill covers the repository-specific workflow for producing macOS
Homebrew Cask `.dmg` artifacts that contain `RielaApp.app` and the `riela`
CLI, validating them locally, and preparing them for Apple
signing/notarization and GitHub release publication.

## When To Apply

Apply this skill when:

- building a macOS `.dmg` for the riela Cask
- validating local macOS Cask archive output
- preparing or debugging Apple signing/notarization inputs
- publishing or verifying Cask release artifacts
- rendering `Casks/riela.rb` in `tacogips/homebrew-tap`

Use the formula packaging flow for CLI-only `brew install riela` tarball
releases on macOS. Linux CLI tarballs may be published to GitHub releases, but
they are not rendered into the Homebrew tap.
The macOS Cask is the `RielaApp.app` + `riela` CLI install path.

## Repository Facts

- `scripts/build-homebrew-release.sh` builds CLI-only `riela` tarballs under
  `dist/homebrew/`. The Homebrew Formula uses the macOS archives only.
- `scripts/build-homebrew-cask-release.sh` builds signed and notarized Cask
  DMGs under `dist/homebrew-cask/`; each DMG contains `RielaApp.app` and the
  `riela` CLI.
- `scripts/render-homebrew-cask.sh` renders `Casks/riela.rb` from archive
  checksums.
- `scripts/release-homebrew-cask-local.sh` builds, notarizes, uploads, and
  renders the sibling tap cask for a pushed `v<version>` tag.
- `Taskfile.yml` exposes `build:homebrew-cask`, `homebrew:cask`,
  `homebrew:tap-cask`, and `release:homebrew-cask-local`.

## Apple Signing And Notarization Inputs

The local release path consumes these secret names:

- `APPLE_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_PASSWORD`
- `APPLE_TEAM_ID`

Meaning:

- `APPLE_SIGNING_IDENTITY` is the Developer ID Application identity used to
  sign `RielaApp.app` and the `riela` executable.
- `APPLE_ID`, `APPLE_PASSWORD`, and `APPLE_TEAM_ID` support notarization.

Keep certificate material and password values in the local keychain and
password manager. Do not commit Apple credentials.

## Local Build Workflow

### 1. Check version alignment

Before tagging or publishing, verify the release version is consistent across
the package metadata and built CLI:

```bash
version="$(tr -d '[:space:]' < VERSION)"
cli_version="$(nix develop -c bash -lc 'swift run riela --version' | tail -n 1 | tr -d '[:space:]')"
test "$cli_version" = "$version"
```

The CLI output must exactly match `VERSION`. In this repository the CLI version
is exposed through `rielaSwiftMigrationVersion`, so update that constant when
preparing a new release.

### 2. Check release plan

```bash
task build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

The dry-run plan must show both a staged signed app and a staged signed binary:

```text
staged signed app: .../RielaApp.app
staged signed binary: .../riela
```

### 3. Build signed, notarized, and stapled DMGs

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task build:homebrew-cask -- darwin-arm64 darwin-x64
```

### 4. Verify DMG outputs

```bash
ls -lh dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
ls -lh dist/homebrew-cask/riela-<version>-darwin-x64.dmg
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
/Applications/Xcode.app/Contents/Developer/usr/bin/stapler validate dist/homebrew-cask/riela-<version>-darwin-x64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 dist/homebrew-cask/riela-<version>-darwin-arm64.dmg
spctl --assess --type open --context context:primary-signature --verbose=4 dist/homebrew-cask/riela-<version>-darwin-x64.dmg
```

## Release Publication

For a tagged release:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  task release:homebrew-cask-local -- v<version>
```

The wrapper checks the local and remote tag, verifies `VERSION`, uploads the
`.dmg` assets to `tacogips/riela`, and renders
`../homebrew-tap/Casks/riela.rb`.

After reviewing the rendered tap cask:

```bash
cd ../homebrew-tap
git add Casks/riela.rb README.md
git commit -m "chore: add riela cask"
git push origin main
```

Users can then install with:

```bash
brew tap tacogips/tap
brew install --cask riela
```

That Cask installs `RielaApp.app` and links `riela`. Users who want only the
command line tool on macOS should install the formula instead:

```bash
brew tap tacogips/tap
brew install riela
```

Linux users install CLI-only GitHub release tarballs directly; do not require
Linux Formula assets for the macOS tap update.

## Validation Notes

- A successful Swift build does not prove notarization.
- Gatekeeper trust requires the executable signature, notarization acceptance,
  stapling, and `spctl --type open` acceptance for the DMG.
- The Cask DMG must contain both `RielaApp.app` and `riela`; do not regress it
  to a CLI-only Cask.
- The formula remains macOS CLI-only; do not add `RielaApp.app` or Linux
  archive branches to formula archives.
- The Cask builder does not upload releases, mutate the tap, or push commits.
