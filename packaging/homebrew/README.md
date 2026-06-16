# Homebrew Packaging

`riela` Homebrew releases install a standalone Swift executable built with
Xcode SwiftPM. The published macOS archive contains `bin/riela`. Homebrew
does not need a runtime dependency on Bun or a separate add-on package.

Build release archives:

```bash
scripts/build-homebrew-release.sh darwin-arm64 darwin-x64
```

The command writes archives and checksum files under `dist/homebrew/`:

```text
riela-<version>-darwin-arm64.tar.gz
riela-<version>-darwin-x64.tar.gz
```

Each archive contains:

```text
bin/riela
README.md
```

Create or update the GitHub release named `v<version>` with those archives:

```bash
gh release create "v<version>" \
  dist/homebrew/riela-<version>-darwin-arm64.tar.gz \
  dist/homebrew/riela-<version>-darwin-x64.tar.gz \
  --repo tacogips/riela \
  --title "riela v<version>" \
  --notes ""
```

If the release already exists, upload or replace the assets with:

```bash
gh release upload "v<version>" \
  dist/homebrew/riela-<version>-darwin-arm64.tar.gz \
  dist/homebrew/riela-<version>-darwin-x64.tar.gz \
  --repo tacogips/riela \
  --clobber
```

Then render the formula into the existing `tacogips/homebrew-tap` checkout:

```bash
scripts/render-homebrew-formula.sh <version> ../homebrew-tap/Formula/riela.rb
```

The Taskfile wrapper for that tap path is:

```bash
task homebrew:tap-formula -- <version>
```

For any other tap repository, run the render command from this repository and
write the generated formula into the tap's `Formula/riela.rb`.
Override `RIELA_RELEASE_BASE_URL` when the archives are hosted somewhere
other than `https://github.com/tacogips/riela/releases/download/v<version>`.

Commit and push the tap change:

```bash
cd ../homebrew-tap
git add Formula/riela.rb README.md
git commit -m "chore: add riela formula"
git push origin main
```

After the tap commit is pushed, users can install with:

```bash
brew tap tacogips/tap
brew install riela
```

Smoke-test a local formula before upload by rendering into a temporary tap that
uses the local archive directory as its URL base:

```bash
brew tap-new local/riela-test
tap_root="$(brew --repository local/riela-test)"
RIELA_RELEASE_BASE_URL="file://$PWD/dist/homebrew" \
  scripts/render-homebrew-formula.sh <version> "$tap_root/Formula/riela.rb"
brew install local/riela-test/riela
brew test local/riela-test/riela
riela workflow usage matrix-chat-reply --workflow-definition-dir ./examples --output json
brew uninstall riela
brew untap local/riela-test
```

Linux Homebrew archives are fail-closed for this cutover. The formula renderer
does not read Linux checksum files and generated formulas do not reference
stale TypeScript/Bun Linux archive URLs. Add Linux only after a reviewed Swift
Linux build contract defines targets, archive contents, checksum evidence, and
formula behavior.

## Swift Readiness And Production Cutover Archives

TASK-008 prepared local Swift readiness artifacts and blocked cutover gates.
TASK-009 recorded deterministic gate evidence for the current branch, and its
adversarial implementation review was accepted with no high or mid findings in
workflow session
`riel-codex-design-and-implement-review-loop-1781261544-53db3135`. The release
cutover now uses Swift archives under `dist/homebrew`; release upload and tap
mutation remain separate operator actions.

The Swift executable product is still named `riela`. Resolve the release
binary path with Xcode SwiftPM:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk \
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift \
    build -c release --product riela --show-bin-path
```

Historical Swift readiness archives remain staged separately from production
archives:

```text
dist/swift-homebrew/work/riela-<version>-darwin-arm64/bin/riela
dist/swift-homebrew/work/riela-<version>-darwin-x64/bin/riela
dist/swift-homebrew/riela-swift-<version>-darwin-arm64.tar.gz
dist/swift-homebrew/riela-swift-<version>-darwin-x64.tar.gz
```

Each archive contains `bin/riela` and `README.md`, and each archive must have
a sibling `.sha256` file. Preview formula testing, when needed, must use only a
local URL base such as `file://$PWD/dist/swift-homebrew` or unpublished CI
artifacts.

Build or inspect the local readiness archive plan:

```bash
RIELA_VERSION=0.0.0-task009 scripts/build-swift-homebrew-readiness.sh --dry-run darwin-arm64
RIELA_VERSION=0.0.0-task009 scripts/build-swift-homebrew-readiness.sh darwin-arm64
tar -tzf dist/swift-homebrew/riela-swift-0.0.0-task009-darwin-arm64.tar.gz
(cd dist/swift-homebrew && shasum -a 256 -c riela-swift-0.0.0-task009-darwin-arm64.tar.gz.sha256)
```

Cutover gates are recorded in `packaging/homebrew/swift-cutover-gates.json`.
For TASK-009, non-review gates were marked passed only when that manifest
recorded the exact local command, fixture or archive path, and result. The
dedicated release cutover marked `productionRuntime` as `swift-native`,
`homebrewFormulaSource` as `swift-executable-archive`, and
`allowsProductionCutover` as `true` after both macOS targets had archive,
checksum, formula, Homebrew smoke, deterministic workflow, and leakage
evidence.

Production Swift Homebrew packaging is separate from TypeScript/Bun source
deletion readiness. The deletion gate is tracked in
`packaging/swift-deletion-readiness.json` and referenced from
`packaging/homebrew/swift-cutover-gates.json` as
`typeScriptDeletionReadiness.ready=true` after reviewed-tree deletion evidence
accepted the remaining TypeScript-family source removal. The deletion evidence
is bound to the base commit and stable reviewed-file tree digest recorded in
`packaging/swift-deletion-readiness-evidence.json`. Release tooling, fallback
validation, package metadata,
CLI/server/GraphQL/event surfaces, workflow package behavior, persistence code,
documentation, tests, and `codex-agent`, `claude-code-agent`, and
`cursor-cli-agent` parity references remain governed by the deletion gate.
