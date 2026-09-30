# wh-09 handover sinks progress

Plan: `impl-plans/active/wh-09-handover-sinks.md`  
Mode: issue-resolution  
Issue reference: no GitHub issue supplied; tracked by `design-docs/specs/design-work-handover-and-takeover.md` and `impl-plans/active/work-handover-and-takeover.md` on `feat/work-handover-and-takeover`.  
Accepted predecessor: `wh-01-contracts` is present in this plan's runtime-owned `acceptedPlanIds`.  
Codex-agent reference: Step 6 implementation in workflow execution `nested-v1-04712c1051e1d985b9ab2bc92a2e4eca43a8f8d61afbd8368e6c854337762fbd`; read-only sink review delegated to `/root/sink_review` and returned API/process/factory hazards without edits.

## Implementation

- [x] Implemented store, file, command, gitRef, and kaiba sinks in `Sources/RielaCLI/HandoverSinks/`.
- [x] Implemented `HandoverSinkVerification.verify` as the canonical JSON decode + recomputed digest check against both packet and reference digests.
- [x] Implemented factory merge precedence/deduplication and sink construction/reader resolution in `Sources/RielaCLI/HandoverSinks/HandoverSinkFactory.swift`.
- [x] Added seven focused tests in `Tests/RielaCLITests/HandoverSinkTests.swift`.
- [x] Recorded test source hashes in `tmp/work-handover/wh-09-handover-sinks/final-source-sha256.txt`.

Round-trip test names required by the plan:

- `testKaibaSinkRoundTripsBriefAndTags`
- `testGitRefSinkReadsFromFreshClone`
- `testFileSinkRoundTripsAndRejectsDifferentOverwrite`
- `testCommandSinkRoundTripsAndRejectsFailureAndEmptyId`

Additional tests: `testStoreSinkReadsCanonicalStorePacket`, `testDigestVerificationAndSerializedReaderResolution`, and `testFactoryMergesConfigsInOrderAndDeduplicatesByTarget`.

Git blob reads use `FoundationGitCommandRunner` for ref, fetch, hash, and push operations. Its captured stdout is capped at 1 MiB, below the 4 MiB packet ceiling, so `cat-file` stdout is directed to a unique temporary file under the repository `tmp/work-handover/wh-09-handover-sinks/` and removed after reading. The git round-trip test verifies a packet over 1 MiB from a fresh clone.

Command execution uses `FoundationLocalProcessRunner` with argv passed directly, packet bytes on stdin, a deadline, and captured stdout. `reader(for:)` needs `HandoverSinkContext.commandArgv` because the command locator is intentionally only the sink-issued opaque id. Kaiba execution reuses an inherited validated execution snapshot or obtains one through `KaibaExecutionPreflight.direct` before calling `KaibaAddonCatalog.execute`.

## Verification

All final gates below ran on the current source. Complete logs include a final `exit=` line.

| Command | Result | Evidence |
| --- | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift build --target RielaCLI --scratch-path tmp/work-handover/wh-09-handover-sinks/build-scratch > tmp/work-handover/wh-09-handover-sinks/build-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/build-final.log'` | exit=0; target build complete | `tmp/work-handover/wh-09-handover-sinks/build-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverSinkTests" --scratch-path tmp/work-handover/wh-09-handover-sinks/build-scratch > tmp/work-handover/wh-09-handover-sinks/focused-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/focused-final.log'` | 7 tests, 7 passed, 0 failures, exit=0 | `tmp/work-handover/wh-09-handover-sinks/focused-final.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul > tmp/work-handover/wh-09-handover-sinks/swiftlint-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/swiftlint-final.log; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run." > tmp/work-handover/wh-09-handover-sinks/swiftlint-final.log; echo "exit=0" >> tmp/work-handover/wh-09-handover-sinks/swiftlint-final.log; fi'` | selected seven Swift files; exit=0 | Manifest `tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul`; log `tmp/work-handover/wh-09-handover-sinks/swiftlint-final.log` |
| `git diff --check` | exit=0 | `tmp/work-handover/wh-09-handover-sinks/diff-check.log` |

Earlier attempts are preserved and are not final gates: first isolated build caught a redundant JSON helper; the first focused run caught async XCTest autoclosure usage, missing-ref handling, and CLI-kind deduplication; a malformed lint manifest used literal `\\0` separators and was replaced with a verified seven-entry NUL manifest. The current build, focused tests, lint, and whitespace check pass after those repairs.

## Review handoff

Assigned implementation and behavioral verification are complete. Formal test-integrity, adversarial, and serial integration review remain downstream workflow steps; no review acceptance is claimed here. Other plan modules, docs/catalog/SDL integration, full-suite baseline comparison, commit, and push remain owned by their assigned downstream plans/steps.

## Final self-check addendum

A bounded author self-check added two fail-closed details: file reads reject relative locators, and the large Git blob read waits for the terminated child before returning a timeout. Final checks were rerun after these edits; these evidence files supersede the earlier final logs above:

| Command | Result | Evidence |
| --- | --- | --- |
| `arch -arm64 /bin/zsh -lc 'swift build --target RielaCLI --scratch-path tmp/work-handover/wh-09-handover-sinks/build-scratch > tmp/work-handover/wh-09-handover-sinks/build-selfcheck-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/build-selfcheck-final.log'` | RielaCLI target build complete, exit=0 | `tmp/work-handover/wh-09-handover-sinks/build-selfcheck-final.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverSinkTests" --scratch-path tmp/work-handover/wh-09-handover-sinks/build-scratch > tmp/work-handover/wh-09-handover-sinks/focused-selfcheck-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/focused-selfcheck-final.log'` | 7 tests executed, 7 passed, 0 failures, exit=0 | `tmp/work-handover/wh-09-handover-sinks/focused-selfcheck-final.log` |
| `arch -arm64 /bin/zsh -lc 'if [ -s tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul > tmp/work-handover/wh-09-handover-sinks/swiftlint-selfcheck-final.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-09-handover-sinks/swiftlint-selfcheck-final.log; else printf "%s\\n" "No Swift files changed; selected-file SwiftLint not run." > tmp/work-handover/wh-09-handover-sinks/swiftlint-selfcheck-final.log; echo "exit=0" >> tmp/work-handover/wh-09-handover-sinks/swiftlint-selfcheck-final.log; fi'` | Exact seven-path NUL manifest; exit=0 | `tmp/work-handover/wh-09-handover-sinks/changed-swift-files.nul`; `tmp/work-handover/wh-09-handover-sinks/swiftlint-selfcheck-final.log` |
| `git diff --check` | exit=0 | `tmp/work-handover/wh-09-handover-sinks/diff-check-selfcheck-final.log` |

Current source identity: `tmp/work-handover/wh-09-handover-sinks/final-source-sha256-selfcheck.txt`. The earlier `final-source-sha256.txt` and all first-pass logs remain preserved for audit and are not the source identity for the final self-check. No high- or mid-severity author findings remain. Formal review gates and serial integration remain downstream.

## Step 6 test-integrity self-repair

Finding: `GitRefHandoverSink.readBlob(_:)` wrote the `git cat-file blob` output to a scratch file under the hardcoded development-plan path `<repositoryRoot>/tmp/work-handover/wh-09-handover-sinks`, so every production gitRef packet read created that directory inside the user's repository (only the file was removed).

Change: the scratch directory is now `FileManager.default.temporaryDirectory` (the `createDirectory` call was removed since it always exists). The unique `git-blob-<UUID>.tmp` name, createFile check, `defer` removal, file-streamed read (no 1 MiB runner cap), and timeout handling are unchanged.

Verification:
- `arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverSinkTests" --scratch-path tmp/work-handover/wh-09-handover-sinks/build-scratch > tmp/work-handover/wh-09-handover-sinks/step6-test-integrity/focused-repair.log 2>&1; echo "exit=$?" >> ...'` -> 7 tests executed, 0 failures, exit=0 (`tmp/work-handover/wh-09-handover-sinks/step6-test-integrity/focused-repair.log`).
- `swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/HandoverSinks/GitRefHandoverSink.swift` -> see `tmp/work-handover/wh-09-handover-sinks/step6-test-integrity/swiftlint-repair.log` (exit=0, no violations).

## Step 7 adversarial review self-repairs

Finding 1 (mid): `FileHandoverSink.write` threw on an identical re-write because the `.md` mirror went through `FileManager.moveItem`, which fails with EEXIST when the target exists. Fix: `atomicallyWrite` takes a `replacing` flag; the `.md` mirror now renames the temp file over the target with `rename(2)` (atomic, temp file removed on failure). The `.json` path is unchanged (refuse different bytes, accept identical), and the on-disk layout and locator are unchanged. Test: `testFileSinkRoundTripsAndRejectsDifferentOverwrite` now performs an identical second write that must succeed with the same locator before the different-bytes conflict assertion.

Finding 2 (mid): `GitRefHandoverSink.execute` ran git with `environment: [:]`, so git had no HOME (user gitconfig, credential helpers), no SSH_AUTH_SOCK, no PATH, and no `GIT_TERMINAL_PROMPT=0`. Fix: new `environment` stored property (init parameter defaulting to `ProcessInfo.processInfo.environment`), filtered to HOME, LANG, LC_ALL, LC_CTYPE, TZ, SSH_AUTH_SOCK and PATH plus `GIT_TERMINAL_PROMPT=0`. Never-force-push semantics unchanged; the factory call site compiles unchanged. Test: `testGitRefSinkPassesMinimalGitEnvironment` uses a recording fake `GitCommandRunning` and asserts the forwarded environment.

Verification: see the step7-review logs (`tmp/work-handover/wh-09-handover-sinks/step7-review/focused-repair.log`, `swiftlint-repair.log`); results are recorded below.

Results: `swift test --filter "HandoverSinkTests"` -> 8 tests executed, 0 failures, exit=0 (`step7-review/focused-repair.log`); `swiftlint lint --strict` on the seven-path NUL manifest -> exit=0, no violations (`step7-review/swiftlint-repair.log`); `git diff --check` -> exit=0. (Two transient build failures from other agents' concurrent edits in RielaDataGarbageCollector.swift and TaskHandoverGraphQLTests.swift cleared on their own; none were in wh-09 files.)
