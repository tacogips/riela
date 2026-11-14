# wh-05 History Import Progress

Status: implementation complete; awaiting test-integrity, adversarial, and serial integration review.

## Assigned scope

- Added `HistoryImportSource.session` and `.bundle`, preserving the original `WorkflowHistoryImportInput` initializer and adding the bundle initializer.
- Same-store import accepts only a failed (any failure kind) or suspended source in the same workflow and retains canonical message and execution checks.
- Bundle import accepts an absent source session, rejects truncation and input/bundle divergence, and validates completed accepted executions, unique step and execution IDs, unique message communication IDs, and message execution references before mutating the target.
- Imported execution lineage carries optional `handoverId`; the optional Codable field decodes as nil for prior records. Imported messages and execution references are remapped. The created target remains at its entry step and status.

## Completion criteria

- [x] Source enum, bundle initializer, and import rules are implemented; existing API remains source-compatible.
- [x] Handover tests and preserved-history suites pass: 12 tests, 0 failures.
- [x] Progress log records commands, outcomes, source hashes, and earlier failed attempts.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-05-history-import/attempt-07-build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-05-history-import/attempt-07-build.log'` — exit 0; log ends `Build complete!` then `exit=0`.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "RuntimeHistoryImport|PreservedHistory|SessionPreservedHistoryTests" > tmp/work-handover/wh-05-history-import/attempt-07-focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-05-history-import/attempt-07-focused.log'` — exit 0; 12 tests passed, 0 failures (5 new handover tests, 6 existing workflow-preserved-history tests, 1 CLI session-preserved-history test).
- `arch -arm64 /bin/zsh -lc 'changed_swift_manifest=tmp/work-handover/wh-05-history-import/changed-swift-files.nul; if [ -s "$changed_swift_manifest" ]; then xargs -0 swiftlint lint --strict --quiet --no-cache < "$changed_swift_manifest"; else printf "%s\n" "No Swift files changed; selected-file SwiftLint not run."; fi'` — exit 0; exact changed-file manifest is `tmp/work-handover/wh-05-history-import/changed-swift-files.nul`; complete log `tmp/work-handover/wh-05-history-import/attempt-06/swiftlint.log`.
- `git diff --check` — exit 0; log `tmp/work-handover/wh-05-history-import/attempt-07-diff-check.log`.
- Final source hashes: `tmp/work-handover/wh-05-history-import/final-source-sha256.txt`.

## Retained earlier verification attempts

- `tmp/work-handover/wh-05-history-import/build.log` — exit 1 because concurrent shared-tree source referenced `suspendSession` before its implementation appeared.
- `tmp/work-handover/wh-05-history-import/focused.log` — exit 1 because `DeterministicWorkflowRunner.swift` changed during the build.
- `tmp/work-handover/wh-05-history-import/attempt-05-build.log` — exit 1 because concurrent `HandoverBriefRenderer.swift` was incomplete (missing returns). The shared tree was subsequently completed; attempt 07 build and focused tests pass.
- `tmp/work-handover/wh-05-history-import/swiftlint.log` — initial strict lint exit 1; its two diagnostics were corrected. The final exact-file strict lint in attempt 06 passes.

No git state changes were made. Formal reviews and later workflow finalization remain downstream.
