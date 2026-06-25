# Riela Swift Native Migration Design: Verification Gates and Open Decisions

## Verification Gates

Each migrated package needs:

- Swift unit tests for the migrated public contracts.
- Fixture compatibility tests against existing workflow JSON and node JSON examples.
- CLI smoke tests for `workflow validate`, `workflow inspect`, and deterministic `workflow run` without real agent calls.
- Agent adapter tests that use injected process runners and injected readiness probes, not live LLM credentials or local CLI availability.
- Packaging verification for the Swift macOS executable artifact at the SwiftPM
  release bin path, staged under `dist/swift-homebrew/work/.../bin/riela`,
  archived as `riela-swift-<version>-darwin-arm64.tar.gz` and
  `riela-swift-<version>-darwin-x64.tar.gz`, and smoke-tested before any
  TypeScript removal or Homebrew switch.
- TASK-008 deterministic readiness checks for
  `packaging/homebrew/swift-cutover-gates.json`,
  `scripts/build-swift-homebrew-readiness.sh`, archive naming, `.sha256`
  sidecars, and the absence of production publishing side effects.
- Dedicated release cutover checks for production Swift archives under
  `dist/homebrew`, generated formula URLs and checksums, local formula install
  or explicit Homebrew-tool blocker, and
  `packaging/homebrew/swift-cutover-gates.json` transitioning
  `productionRuntime`, `homebrewFormulaSource`, and `allowsProductionCutover`
  only after evidence is recorded.

The current branch has been verified with Xcode Swift 6.3.2 by setting `DEVELOPER_DIR` and `SDKROOT` to `/Applications/Xcode.app`; `swift test` passed 197 tests for the current Swift scaffold, model validation, adapter, runtime publication, deterministic CLI, package/event/GraphQL/server contracts, and packaging-readiness coverage. Default `swift` lookup can still point at a Nix Apple SDK path, so use the Xcode toolchain command recorded in the implementation plan until local toolchain selection is fixed.

Additional required verification:

- `git status --short --branch`
- `bun run typecheck:server`
- `bun run lint:biome`
- `bun run packages/riela/src/bin.ts workflow validate codex-design-and-implement-review-loop --scope project`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift --version`
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`

## Open Decisions

Open user decisions are tracked in `design-docs/user-qa/qa-swift-native-migration.md`.

Known unresolved decisions:

- whether the replacement milestone is CLI/runtime parity only, or also includes a native macOS UI
- whether to vendor local source from the three repository-owned agent packages or continue mapping behavior from package pins and TypeScript adapters until dedicated Swift references exist
