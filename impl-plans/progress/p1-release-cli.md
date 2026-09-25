# p1-release-cli progress

- Mode: `issue-resolution`; issue: `tacogips/riela` Draft PR #113, `comm-000002`; branch: `fix/work-runtime-p1-release`; checkpoint: `32163111b6e9f31b91d1e95e535c115e9f798890`.
- Agent: native Step 6 `/root`, with read-only Codex agents `/root/diagnose_cli` and `/root/diagnose_addon`. Step 3 design decision `comm-000004` accepted; Step 5 plan acceptance supplied by native dispatch; no review feedback findings.
- Plan: `impl-plans/completed/work-runtime-p1-release-cli.md` (original active path preserved in dispatch history); design: `design-docs/specs/design-work-runtime-consolidation.md` §17.13. C1–C8 implementation complete under the amended exact ownership accepted by Step 5 `comm-000006`.
- Immutable per-edit preimages, intents, postimages, hashes and diffs: `tmp/p1-release-remediation/p1-release-cli/edits/`. Native pre-node snapshot: `tmp/riela-fanout/DA9AE836-9031-40B6-A9A1-378CB6E9FCC1/297818E0-2DC2-4C9C-9BD2-D63B638095C3.json`.

## Assertion ledger

| ID | Cause and contract | Changed path | Focused result |
| --- | --- | --- | --- |
| 01 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 02 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 03 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 04 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 05 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 06 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 07 | ISO-8601 doctor JSON consumer | `Tests/RielaCLITests/DoctorCommandTests.swift` | passed |
| 09 | scratch-path product discovery | `Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift` | passed |
| 10 | scratch-path subprocess launch | `Tests/RielaCLITests/WorkflowCommandCatalogTests+Temporary.swift` | passed |
| 11 | explicit agent sandbox | `Tests/RielaCLITests/ScopedParityCallStepFanoutTests.swift` | passed |
| 12 | error-severity inspect exit | `Tests/RielaCLITests/WorkflowCommandCatalogTests.swift` | passed |
| 13 | self-contained callable metadata fixture | `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift` | passed |
| 14 | chat reply version-1 adapter/catalog contract; unresolved executable diagnostic was correct | `Sources/RielaAddons/RielaAddons.swift`; `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift` | catalog red 1 test/3 assertions, then green 6/6; real Matrix usage and focused CLI 165/165 passed |
| 15 | error-severity inspect exit | `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift` | passed |
| 16 | error-severity inspect exit | `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift` | passed |
| 17 | error-severity inspect exit | `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift` | passed |
| 18 | error-severity inspect exit | `Tests/RielaCLITests/WorkflowCommandRuntimeCapabilityDiagnosticsTests.swift` | passed |
| 20 | resolvable add-on in metadata fixture | `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | passed |
| 21 | resolvable add-on in metadata fixture | `Tests/RielaCLITests/WorkflowTemporaryRegistrationTests+Matrix.swift` | passed |

Contracts: `RielaCLIApplication.swift` ISO-8601 encoding; `WorkflowValidation.swift` mandatory sandbox; `WorkflowValidateInspectCommands.swift` failure for error-severity gaps and catalog projection; `ProductionNodeAdapter.swift` chat reply version 1/nil execution; `WorkflowRequirements.swift` rejects unresolved add-ons. Positive controls are the callable metadata fixture, exact version-1 catalog descriptor, built CLI Matrix usage and 165-test focused run. Negative controls remain in `Tests/RielaCoreTests/AgentNodeOutputContractValidationTests.swift` (missing sandbox), `Tests/RielaCLITests/WorkflowHostCapabilityTests.swift` (unresolved add-on), and the new version-2/unknown-name catalog assertions. No tests were deleted, skipped, or muted.

## Command evidence

| Command | Complete log / receipt | Exit | Counts |
| --- | --- | ---: | --- |
| `swift build --scratch-path tmp/p1-release-remediation/build --product riela` | `tmp/p1-release-remediation/p1-release-cli/attempt-1/build.log`, `build.json` | 0 | product built |
| `swift test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests\|WorkflowCommandCatalogTests\|WorkflowCommandTests\|WorkflowTemporaryRegistrationTests'` | `tmp/p1-release-remediation/p1-release-cli/attempt-1/focused.log`, `focused.json` | 1 | 165 run, 164 passed, 1 failed, 0 skipped |
| `tmp/p1-release-remediation/build/arm64-apple-macosx/debug/riela workflow usage matrix-chat-reply --workflow-definition-dir examples --output json` | `tmp/p1-release-remediation/p1-release-cli/attempt-1/usage-diagnostic.log`, `usage-diagnostic.json` | 1 | `workflow.requirements`: `unresolvedAddonExecutable` |
| changed-file `xargs -0 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache` | `tmp/p1-release-remediation/p1-release-cli/attempt-1/lint.log`, `lint.json`, `changed-swift.nul` | 0 | seven owned Swift files |
| `git diff --check` | `tmp/p1-release-remediation/p1-release-cli/attempt-1/diff-check.log`, `diff-check.json` | 0 | clean |

All receipts include cwd, Xcode toolchain environment, checkpoint, source diff hash, start/end and exit. The focused suite ran while the disjoint runtime worker edited Work/Core files, so only serial combined-tree verification can establish a stable final tree. Its one failure is the owned ID 14; no baseline-match pass is claimed.

## Blocker and completion

The accepted ownership amendment includes both catalog paths. The new catalog regression failed before production repair with the expected missing-descriptor assertions (1 test, 3 failures, exit 1), then passed after adding only the version-1 descriptor (6/6, exit 0). The host-capability negative-control suite passed 20/20 and the focused CLI suite passed 165/165, including `testUsageSupportsAddonSmokeWorkflow`; zero skips or failures were reported. The current built CLI subprocess returned exit 0 and emitted `reply-to-matrix:riela/chat-reply-worker` for the real Matrix example. All 19 owned rows are green. Broad suites, independent test-integrity/Sol/Astra reviews, shared docs, Draft PR #113 update, commit and non-force push remain downstream work.

## Catalog continuation receipts

- Native fanout pre-node snapshot: `tmp/riela-fanout/836C1E76-7361-4C28-A53B-FE4E97708989/64F672B7-D1C9-4430-AA67-270F1324DCBE.json`. Immutable per-edit preimages, intent, postimages, hashes and diffs: `tmp/p1-release-remediation/p1-release-cli/catalog-continuation/edits/`.
- Execution: native Step 6 `/root`, read-only Codex agent `/root/audit`; branch `fix/work-runtime-p1-release`, HEAD `65c5eddb3fa7ef4d64c3474c98fe5852d6290cb8`; source tracked-diff SHA-256 for green gates `0407c0e625f81da03c2553443d96f2c5b5f20e2314bc65702caf3465ccd5b025`. Complete logs and terminal receipts are under `tmp/p1-release-remediation/p1-release-cli/catalog-continuation/attempt-2/`; each JSON receipt records argv, cwd, toolchain, times, HEAD, diff hash, log and exit.
- `swift test --scratch-path tmp/p1-release-remediation/build --filter AddonExecutionContractsTests.testChatReplyWorkerBuiltinCatalogContract`: red exit 1, 1 test, 3 expected missing-descriptor assertions, `catalog-red.log`/`.json`.
- `swift build --scratch-path tmp/p1-release-remediation/build --product riela`: exit 0, `build.log`/`.json`.
- `swift test --scratch-path tmp/p1-release-remediation/build --filter AddonExecutionContractsTests`: exit 0, 6/6 tests, zero failures/skips, `catalog-green.log`/`.json`.
- `swift test --scratch-path tmp/p1-release-remediation/build --filter WorkflowHostCapabilityTests`: exit 0, 20/20 tests, zero failures/skips, `host-capability.log`/`.json`.
- `swift test --scratch-path tmp/p1-release-remediation/build --filter 'DoctorCommandTests|WorkflowCommandCatalogTests|WorkflowCommandTests|WorkflowTemporaryRegistrationTests'`: exit 0, 165/165 tests, zero failures/skips, `cli-focused.log`/`.json`.
- Built CLI `workflow usage matrix-chat-reply --workflow-definition-dir examples --output json` with isolated HOME: exit 0, real source metadata present, `usage-current.log`/`.json`.
- Strict changed-file SwiftLint through `changed-swift.nul`: exit 0, `lint-changed.log`/`.json`; explicit 10-path allowlist SwiftLint: exit 0, `lint-allowlist.log`/`.json`.
