# ds179-02 Definition Service Progress

**Workflow mode:** `issue-resolution` (Step 6 implementation)  
**Issue:** `tacogips/riela#179`  
**Plan:** `impl-plans/active/ds179-02-definition-service.md`  
**Status:** assigned implementation complete; TI-02-001 and ADV-02-001 corrections are implemented; pending independent re-review.

## Implementation

- Added canonical `WorkflowDefinitionDocument` serialization, authored file collection, best-effort file provenance digests, resolved store bundle reconstruction, and authored-view conversion.
- Added normalized `WorkflowAuthoredFileOverlay`; threaded it through direct workflow resolution, own node/prompt hydration, and missing-key rejection without changing nil-overlay reads.
- Added RFC 6902 `add`, `remove`, `replace`, and `test` support with RFC 6901 pointer handling.
- Added `WorkflowDefinitionService` operations for lookup, pinned load, seed, import/force import, whole-workflow update, prompt update, restore, history, show, diff, authored view, and export.
- Unified authored updates behind re-derivation at the registered source directory, with reason/version validation, authored-file-set validation, definition validation, audit diffs, and optimistic store commits.
- Derived workflows now collect only their authored `workflow.json`; base node and prompt files remain resolved from disk. The overlay key-set equality check remains strict.
- Added 12 service tests covering canonical round-trip and store provenance; import no-op/diff/force overwrite and restore; structure-plus-prompt patches and audit pointers; zero-row rejection for removed/orphan files, invalid runtime definitions, missing patch members, unsupported move operations, unregistered workflows, and stray derived authored files; blank/unknown/variant/nodeRef prompt rejection; inline and shared prompt updates; extends update and fromDirectory re-derivation over a disk-read base; stdio re-anchoring; force-import audit references; `.authoredFiles` updates; exact export; overlay diagnostics; and JSON Patch error codes. Rejections assert history and head version remain unchanged.

## Shared-write evidence

Each original implementation edit intention was recorded before mutation under `tmp/ds179/ds179-02-definition-service/edit-intent-001.md` through `edit-intent-015.md`. TI-02-001 repair intentions and pre-edit hashes are under `attempt-004/`; ADV-02-001 intentions and pre/post hashes are under `attempt-005/`. Attempt-005 final source hashes are in `tmp/ds179/ds179-02-definition-service/attempt-005/final-source-sha256.txt`.

No shared-path drift or lost concurrent behavior was observed during the bounded diff review. No package dependencies or generated files were added.

| ADV-02-001 file | pre-edit SHA-256 | post-edit SHA-256 |
| --- | --- | --- |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionDocument.swift` | `6f81aca6ac8ef91d6336c5cb1544f625d74a9816724fde0a3da62d59b78cf8e3` | `992160e6bee92f74b6bc47b9f6eb74fe875321626da6c6eefc0ae39dcc8cf30f` |
| `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift` | `4c67b4e07f77077c42042ca1b954cd556be959dc1e81e6fc9ca8149ec289b574` | `681404bb2cb22afaf0bf81d439d0d2903e7bfecac74e547379c0b361d53fff86` |

## Final-source verification

All commands ran in the foreground from the repository root in an arm64 shell. Logs are complete and plan-local. The current test source sha256 is recorded in `attempt-005/final-source-sha256.txt` (`Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift`: `681404bb2cb22afaf0bf81d439d0d2903e7bfecac74e547379c0b361d53fff86`).

| Command | exitStatus | testsRun | failureCount | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-02-definition-service/attempt-005/build.log 2>&1; rc=$?; tail -60 tmp/ds179/ds179-02-definition-service/attempt-005/build.log; print "EXIT_STATUS=$rc"; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-005/build.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionServiceTests > tmp/ds179/ds179-02-definition-service/attempt-005/test.log 2>&1; rc=$?; tail -130 tmp/ds179/ds179-02-definition-service/attempt-005/test.log; print "EXIT_STATUS=$rc"; exit $rc'` | 0 | 12 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-005/test.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionStoreTests > tmp/ds179/ds179-02-definition-service/attempt-005/store-regression.log 2>&1; rc=$?; tail -80 tmp/ds179/ds179-02-definition-service/attempt-005/store-regression.log; print "EXIT_STATUS=$rc"; exit $rc'` | 0 | 10 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-005/store-regression.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'PromptTemplateTests|WorkflowInheritanceResolutionTests|WorkflowSharedNodeVersioningTests' > tmp/ds179/ds179-02-definition-service/attempt-005/loader-regression.log 2>&1; rc=\$?; tail -80 tmp/ds179/ds179-02-definition-service/attempt-005/loader-regression.log; print \"EXIT_STATUS=\$rc\"; exit \$rc"` | 0 | 17 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-005/loader-regression.log` |
| `arch -arm64 /bin/zsh -lc 'xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-02-definition-service/changed-swift-files.nul > tmp/ds179/ds179-02-definition-service/attempt-005/lint.log 2>&1; rc=$?; cat tmp/ds179/ds179-02-definition-service/attempt-005/lint.log; print "EXIT_STATUS=$rc"; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-005/lint.log` |

The NUL-delimited changed Swift file manifest is `tmp/ds179/ds179-02-definition-service/changed-swift-files.nul`.

## Superseded attempts

Earlier attempts are not final-source evidence. The following failures were corrected and rerun successfully above:

- Initial build attempts recorded in `build-attempt-001.log`, `build-attempt-002.log`, and `build-final-attempt-001.log` exposed compile errors in the new service; a shell wrapper also used zsh's read-only `status` variable.
- Prior Step 6 attempts are described above. In this repair, `test-attempt-001.log`, `test-attempt-002.log`, `test-attempt-003.log`, and `test-attempt-004-before-fix.log` record fixture/assertion failures while expanding coverage; these were corrected and superseded by `attempt-004/test.log` (11 tests, 0 failures). `attempt-004/lint-attempt-001.log` records two long fixture lines; those were reformatted and final strict lint passed in `attempt-004/lint.log`. `test-before-format.log` is a passing 11-test run before a literal-only fixture formatting change; final gates were rerun after that change.

## Handoff

TI-02-001 and ADV-02-001 are implemented in the service tests and `WorkflowDefinitionDocument.swift`; attempt-005 has 12 passing service tests and all required regressions and lint pass. The six other tracked production files retain their attempt-004 hashes. Independent adversarial re-review remains pending. No implementation blocker remains for ds179-02. Downstream CLI/service-resolution/GraphQL/improvement-node plans, review-dependent documentation/index changes, exact-file staging, commit, and push remain owned by later workflow steps.

## Integration feedback repair — attempt-006

Addressed `INT-02-001` and `INT-02-002` from the `ds179-02-definition-service` integration review.

- `WorkflowDefinitionDocument.containedAuthoredURL` now normalizes relative paths and verifies the symlink-resolved candidate remains within the symlink-resolved root. `make(from:)` uses it for `workflow.json` and own `nodeFile` paths, while `promptFile` still uses `resolvePromptTemplatePath` so prompt reservation behavior remains unchanged. `WorkflowDefinitionService.export` validates every key with the same containment helper before writing any file.
- `WorkflowDefinitionJSONPatch`, `apply(_:to:)`, and `pointer(_:)` are public for cross-module callers. Patch implementation and private helpers are unchanged.
- Added `testCanonicalNodeDashFilesRoundTripAndStayContained`: seed and preserve `nodes/node-worker.json` and `nodes/node-inline.json`; update file-backed and inline prompts; patch the inline prompt; export byte-identically and resolve the exported prompt; verify node JSON byte changes alter the file digest; reject traversal, absolute, and symlink escapes in document collection and symlink escape in source export.
- Corrected the active plan's path-resolution guidance and added explicit completion criteria for canonical node paths, containment, and the public JSON Patch seam.

Edit intentions: `attempt-006/edit-intent-001.md` through `edit-intent-012.md`. Initial source hashes are in `attempt-006/pre-edit-sha256.txt`; plan/progress hashes before plan update are in `attempt-006/pre-plan-update-sha256.txt`; attempt source hashes are in `attempt-006/post-edit-sha256.txt`. Final Swift source hashes after all code edits are:

| File | SHA-256 |
| --- | --- |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionDocument.swift` | `d8377a7c5eea4145ea8edde51ed28440e881810f32c95d967ee7ea8123a19455` |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionService.swift` | `63d0a0bdbbd5b7f2d416ccae2939569fbbec9a117108a45ee97670cf018da9b1` |
| `Sources/RielaWorkflowRegistry/WorkflowDefinitionJSONPatch.swift` | `ec002dcdfc6fcd24828d51d4f9c879f3c9cb131e1fae69345b143bf6658143a6` |
| `Tests/RielaCLITests/WorkflowDefinitionServiceTests.swift` | `01ae622b2554779696b8737b1b17dbb1318de8f3504425293207448f1c93269b` |

Attempt-006 first test compilation failed because the new test treated `updatePrompt`'s returned version as an update result; `attempt-006/test.log` records the failure. The test was corrected and final-source verification passed. Earlier successful runs (`attempt-006/final-test.log` and `attempt-006/final-service-tests.log`) are superseded; the final test additionally checks every exported disk file byte-for-byte. `attempt-006/final-service-tests-2.log` is the final-source service evidence.

## Attempt-006 final-source verification

Commands ran in the foreground from the repository root under `arch -arm64 /bin/zsh -lc`. Every log includes the command's exit status. Changed Swift files were selected using `changed-swift-files-attempt-006.nul`.

| Command | exitStatus | testsRun | failureCount | Complete log |
| --- | ---: | ---: | ---: | --- |
| `arch -arm64 /bin/zsh -lc 'swift build > tmp/ds179/ds179-02-definition-service/attempt-006/final-build-2.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/final-build-2.log; tail -20 tmp/ds179/ds179-02-definition-service/attempt-006/final-build-2.log; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/final-build-2.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionServiceTests > tmp/ds179/ds179-02-definition-service/attempt-006/final-service-tests-2.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/final-service-tests-2.log; tail -55 tmp/ds179/ds179-02-definition-service/attempt-006/final-service-tests-2.log; exit $rc'` | 0 | 13 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/final-service-tests-2.log` |
| `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowDefinitionStoreTests > tmp/ds179/ds179-02-definition-service/attempt-006/store-regression-final.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/store-regression-final.log; tail -35 tmp/ds179/ds179-02-definition-service/attempt-006/store-regression-final.log; exit $rc'` | 0 | 10 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/store-regression-final.log` |
| `arch -arm64 /bin/zsh -lc "swift test --filter 'PromptTemplateTests|WorkflowInheritanceResolutionTests|WorkflowSharedNodeVersioningTests' > tmp/ds179/ds179-02-definition-service/attempt-006/loader-regression-final.log 2>&1; rc=\$?; print \"EXIT_STATUS=\$rc\" >> tmp/ds179/ds179-02-definition-service/attempt-006/loader-regression-final.log; tail -30 tmp/ds179/ds179-02-definition-service/attempt-006/loader-regression-final.log; exit \$rc"` | 0 | 17 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/loader-regression-final.log` |
| `arch -arm64 /bin/zsh -lc 'PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH xargs -0 swiftlint lint --strict --quiet --no-cache < tmp/ds179/ds179-02-definition-service/changed-swift-files-attempt-006.nul > tmp/ds179/ds179-02-definition-service/attempt-006/lint-final.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/lint-final.log; cat tmp/ds179/ds179-02-definition-service/attempt-006/lint-final.log; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/lint-final.log` |
| `arch -arm64 /bin/zsh -lc 'grep -n "public enum WorkflowDefinitionJSONPatch\\|public static func apply\\|public static func pointer" Sources/RielaWorkflowRegistry/WorkflowDefinitionJSONPatch.swift > tmp/ds179/ds179-02-definition-service/attempt-006/public-json-patch-seam.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/public-json-patch-seam.log; cat tmp/ds179/ds179-02-definition-service/attempt-006/public-json-patch-seam.log; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/public-json-patch-seam.log` |
| `arch -arm64 /bin/zsh -lc 'git diff --check > tmp/ds179/ds179-02-definition-service/attempt-006/diff-check-final.log 2>&1; rc=$?; print "EXIT_STATUS=$rc" >> tmp/ds179/ds179-02-definition-service/attempt-006/diff-check-final.log; cat tmp/ds179/ds179-02-definition-service/attempt-006/diff-check-final.log; exit $rc'` | 0 | 0 | 0 | `tmp/ds179/ds179-02-definition-service/attempt-006/diff-check-final.log` |

No unresolved high or mid review findings remain in this plan. Independent re-review remains pending; downstream service-resolution, CLI, GraphQL, improvement-node, and docs plans remain outside this implementation assignment.
