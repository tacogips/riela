# builtin-addon-116-03-verification progress

Mode: `issue-resolution`. Issue: https://github.com/tacogips/riela/issues/116. Codex-agent references: none. Plan: `impl-plans/active/builtin-addon-116-03-verification.md`. Accepted predecessors: `builtin-addon-116-01-catalog`, `builtin-addon-116-02-deferred` from runtime `acceptedPlanIds`. Source HEAD during checks: `24224202f69c019639e1aaddfce4a1d99ef7ea6d` on `fix/example-contract-migration`.

Status: assigned Step 6 implementation and behavioral verification complete. Independent review, final exact-file commit and non-force push remain downstream.

## Reconciliation

- The three plan 01 owned Swift files match its `attempt-1/final-owned-source.json` SHA-256 values. The deferred test file SHA-256 is `21235367473f884097c0c3a7cb5dba428d6bd25f9ba20aceea78e81eac0903c5`, matching the accepted plan 02 outcome. No overwrite repair was needed.
- The design remains aligned with the 12 exact version-1 descriptors, including two visibly deferred no-op gateway names. The combined tests preserve unsupported-version and unknown-name fail-closed behavior and the deferred response envelope with zero gateway calls.
- This plan changed only the issue 116 section of `design-docs/specs/node-addon-catalog-and-chat-reply-worker/authoring-and-resolution.md`, this progress log and `impl-plans/active/builtin-addon-116-verification-findings.md`. Edit preimages and intent records are in `tmp/builtin-addon-116-20260927-comm000006/builtin-addon-116-03-verification/attempt-1/edit-*-intent.json`.

## Combined verification

Evidence root: `tmp/builtin-addon-116-20260927-comm000006/builtin-addon-116-03-verification/attempt-1/`. Each named command has a complete `.log` and terminal `.exit` file there; `checks.json` records argv and status. Xcode Swift 6.3.3, `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift`; `toolchain.log` records path/version.

| Command | Exit | Result |
| --- | ---: | --- |
| `swift test --skip-update --filter RielaBuiltinAddonCatalog` | 0 | 2 tests, zero failures; `catalog-test.log` |
| `swift test --skip-update --filter WorkflowHostCapabilityTests` | 0 | 22 tests, zero failures; `host-test.log` |
| `swift test --skip-update --filter DeferredContainerAddonTests` | 0 | 2 tests, zero failures; `deferred-test.log` |
| `/usr/bin/xcrun swiftlint --quiet --no-cache` | 0 | repository-wide lint; `repo-swiftlint.log` |
| `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < changed-swift-paths.nul` | 0 | four changed Swift paths; `selected-swiftlint.log`, `selected-swiftlint.exit` |
| `swift build --skip-update` | 0 | source build; `build.log` |
| `swift build --skip-update --show-bin-path` | 0 | `.build/arm64-apple-macosx/debug`; `bin-path.log` |
| `git diff --check` | 0 | `diff-check.log` |

Source executable: `.build/arm64-apple-macosx/debug/riela`, SHA-256 `08f2c32c45000f90a8ee8b2af54a06dadb26b137c100245890c308fc7dcdbb65`; `source-cli-identity.json`. Its `workflow validate --help` exits 2 because this parser requires a positional workflow name. The plan's absolute-directory command form produces `invalid scoped workflow or package name` usage errors: all 75 attempt-1 commands exited 2, as retained in `attempt-1/example-summary.json` and individual logs. Source parser and bundled usage establish `<name> --workflow-definition-dir <examples-root>` as the supported form. The corrected 75-command attempt exited 0 as a collector and is recorded in `attempt-2/validate-all-examples.log`, `.exit`, `example-summary.json`, and each example's stdout, stderr and exit file.

Corrected result: 75 accounted for, 74 valid, one invalid, zero missing JSON. Baseline: 59 valid, 16 invalid with `unresolvedAddonExecutable`. All 16 catalog-caused diagnostics are removed; 15 newly validate. The sole remaining `x-follower-ai-business-digest` failure is a separate output-schema reference error, precisely recorded in `impl-plans/active/builtin-addon-116-verification-findings.md`. No live model, provider or gateway calls were made. The installed Riela 0.2.1 CLI remains stale until release.

## Completion criteria

- [x] Reconcile accepted predecessor file intent and hashes; no lost changes.
- [x] Run combined targeted tests, selected-file strict SwiftLint, repository-wide SwiftLint, build and diff check with terminal evidence.
- [x] Validate all 75 examples using the built source executable and account for every outcome.
- [x] Confirm all catalog-caused `unresolvedAddonExecutable` failures are removed and classify the one remaining example failure separately.
- [x] Update issue 116 design status and verification evidence without claiming live provider behavior or review acceptance.
- [ ] Final completion record, exact-file commit, non-force push, and remote-head verification. Independent adversarial and combined-tree reviews accepted the implementation with no blocking findings; Step 7b skipped browser E2E because no browser-facing file changed.
