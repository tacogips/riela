# Apple Gateway Review Hardening Implementation Plan

**Status**: Implemented
**Workflow Mode**: issue-resolution
**Issue Reference**: workflow input only; no repository, number, or URL provided
**Created**: 2026-07-08
**Last Updated**: 2026-07-08

---

## Design References

**Accepted source of truth**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md:17`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md:40`
- `design-docs/user-qa/qa-apple-mail-gateway-file-download.md`
- `design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md`
- `design-docs/user-qa/qa-apple-notes-crud-gateway-confirmations.md`

Step 3 accepted the design in communication `comm-000756` with decision
`accepted_for_step3_design_review`. No Codex agent references were provided.

### Summary

Review the Apple Gateway built-in add-ons introduced in commits
`8ebe1ed..afd441f`, then fix every confirmed correctness, robustness, security,
or consistency issue inside the Apple Gateway source, test, and example scope.
The accepted design treats the Apple Gateway surface as one cohesive local-CLI
boundary: shared support, Notes, Mail, Reminders, Calendar, Clock alarms,
Notifications, Admin commands, tests, and `examples/apple-*`.

### Scope

**Included**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift`
- `Tests/RielaCLITests/Apple*AddonTests.swift`
- `examples/apple-*`

**Excluded**:
- Public add-on id, version, workflow input, workflow output, or node contract
  changes unless a confirmed defect strictly requires a documented exception.
- Shared adapter fixes outside the Apple Gateway source files; record those as
  TODOs with file-and-line evidence.
- Live Apple app, TCC, or locally installed `apple-gateway` dependencies in
  automated tests.
- Broad refactors or unrelated subsystem changes.

Intentional divergences from the accepted design: none.

## Task Breakdown

### TASK-001: Establish Review Baseline

**Status**: COMPLETED
**Write Scope**: this plan progress log only

**Work**:
- Record `git status --short`.
- Inspect the restricted diff for `8ebe1ed..afd441f` across the in-scope
  Apple Gateway sources, tests, and examples.
- Record the exact source files and existing Apple test files reviewed.
- Keep scratch logs, if any, under `tmp/apple-gateway-review-hardening/`.

**Deliverables**:
- Baseline command log.
- Reviewed-file inventory.
- Initial findings ledger with no untriaged entries.

### TASK-002: Shared Support And Process-boundary Review

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- matching Apple Gateway support tests

**Work**:
- Verify fixed subcommands, separate argv elements, no shell interpolation, and
  deadline cleanup.
- Verify executable resolution remains literal `addon.config.binaryPath`, then
  documented environment fallback, then `PATH`.
- Verify `binaryPath` is never rendered from workflow input, upstream payloads,
  or `addon.inputs`.
- Verify child environments use the minimal allowlist and do not leak
  secret-like ambient values into output diagnostics.
- Verify malformed JSON, missing data, GraphQL errors, non-zero exits,
  timeouts, and permission failures map to the accepted error classes.

**Deliverables**:
- Fixed or rejected findings for the shared bridge.
- Focused regression tests for any confirmed shared-boundary fix.

### TASK-003: Domain Add-on Correctness Review

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift`
- matching `Tests/RielaCLITests/Apple*AddonTests.swift`

**Work**:
- Check each add-on id against its fixed GraphQL document, variables payload,
  config/input precedence, default handling, and output parsing contract.
- Verify read add-ons cannot be transformed into mutation behavior through
  config, inputs, or upstream payloads.
- Verify mutation add-ons use validated variables and fail closed on transport
  errors without retrying state-changing requests.
- Compare error-shape parity across Notes, Mail, Reminders, Calendar, Clock,
  Notifications, and Admin add-ons.

**Deliverables**:
- Findings ledger entries with severity, file:line, status, and rationale.
- Minimal source and test fixes for confirmed domain correctness defects.

### TASK-004: File Materialization And Path-safety Review

**Status**: COMPLETED
**Write Scope**:
- Apple Gateway source files that implement Notes, Mail, or Admin file download
  behavior
- matching Apple file materialization tests

**Work**:
- Verify all materialization roots are Riela-owned, validated before writes,
  and resistant to traversal and intermediate symlink escapes.
- Verify gateway-provided filenames are metadata only and sanitized before
  deriving deterministic leaf names.
- Verify download mappings reject ambiguous or missing `downloadKey` to local
  path relationships instead of reporting partial success.
- Preserve the existing unresolved upstream confirmations in the user-QA docs
  unless local implementation evidence requires a documentation refresh.

**Deliverables**:
- Fixed or rejected findings for Notes, Mail, and Admin download behavior.
- Regression tests for confirmed traversal, symlink, size-limit, or mapping
  issues.

### TASK-005: Examples And Documentation Consistency Check

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-*`
- this plan progress log
- accepted design/user-QA docs only if implementation evidence changes a stated
  behavior

**Work**:
- Verify shipped examples stay read-only unless intentionally named as Admin or
  explicit mutation examples.
- Verify examples validate without live Apple app access, TCC state, or a local
  production `apple-gateway` binary.
- Record any implementation divergence from the accepted design and update docs
  only when the behavior is confirmed.

**Deliverables**:
- Example fixes, if needed.
- Documentation refresh only for confirmed behavior changes or user-QA evidence.

### TASK-006: Verification, Findings Ledger, And Handoff

**Status**: COMPLETED
**Write Scope**:
- this plan progress log
- final implementation result payload

**Work**:
- Run `swift build`.
- Run `swift test --filter Apple`.
- Run `git status --short` and `git diff --stat` to prove changes are limited
  to the accepted Apple Gateway scope plus this plan.
- Prepare the final findings table with severity, file:line, fixed or rejected
  status, and rationale.

**Deliverables**:
- Passing verification command log or explicit environment-dependent failure
  classification.
- Final changed-file list.
- Completion report with no silent findings.

## Dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-002 | TASK-001 | Shared bridge review needs the baseline diff and reviewed-file inventory. |
| TASK-003 | TASK-001, TASK-002 | Domain review depends on shared process-boundary behavior. |
| TASK-004 | TASK-001, TASK-002 | File materialization uses shared binary, runner, and diagnostics behavior. |
| TASK-005 | TASK-003, TASK-004 | Examples and docs must reflect the final domain and download behavior. |
| TASK-006 | TASK-002, TASK-003, TASK-004, TASK-005 | Final verification runs after all fixes and docs/examples are settled. |

## Parallelizable Tasks

| Task group | Parallelizable | Conditions |
| --- | --- | --- |
| TASK-003 domain review by Apple domain | conditional | Read-only review may run in parallel; writes may parallelize only when each worker owns disjoint source and test files. |
| TASK-004 materialization review and non-materialization domain review | conditional | Allowed only when source and test write scopes do not overlap. |
| TASK-005 example checks | conditional | May run after the relevant domain review is complete and before final verification. |
| TASK-006 verification | no | Must run after all implementation and documentation changes. |

## Verification

- `GIT_OPTIONAL_LOCKS=0 git --no-pager status --short --untracked-files=all`
- `git diff --stat`
- `git diff -- Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleNotesCrudAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift Tests/RielaCLITests examples/apple-*`
- `swift build`
- `swift test --filter Apple`

## Completion Criteria

- [x] Every review finding is enumerated with severity, file:line, status, and
  rationale.
- [x] Every confirmed issue inside scope is fixed with minimal targeted changes.
- [x] Rejected findings include evidence-backed rationale; no findings were rejected in Step 6.
- [x] Public add-on ids, versions, node contracts, and workflow input/output schemas
  are preserved unless a documented exception is required.
- [x] Tests use fake `apple-gateway` executables and deterministic fixtures.
- [x] `swift build` succeeds.
- [x] `swift test --filter Apple` passes, or any failure is clearly classified as
  environment-dependent rather than a regression.
- [x] `GIT_OPTIONAL_LOCKS=0 git --no-pager status --short --untracked-files=all`
  shows only accepted in-scope Apple Gateway files plus this intentional workflow
  plan artifact.

## Progress Log Expectations

Each implementation session must append a dated progress-log entry with:

- tasks completed
- tasks in progress
- findings added, fixed, rejected, or deferred
- files changed
- verification commands and outcomes
- residual risks or environment-dependent blockers

## Progress Log

### Session: 2026-07-08

**Tasks Completed**: Created implementation plan from Step 3 accepted design.
**Tasks In Progress**: None.
**Blockers**: None.
**Notes**: Step 3 reported no findings and no required design revision.

### Session: 2026-07-08 Step 6 Implementation

**Tasks Completed**: TASK-001 through TASK-006.
**Tasks In Progress**: None.
**Findings**:
- Major, `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift:713`, fixed: file-download parsing accepted duplicate `downloadKey` local-path mappings by overwriting the earlier path, so ambiguous upstream output could be reported as a clean materialization.
- Major, `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift:704`, fixed: file-download parsing skipped entries that contained a local path but no `downloadKey`, which could hide malformed upstream output until a less-specific missing-key error.
- Major, `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift:219`, fixed: the admin file-download add-on forwarded rendered `outputDir` without applying the shared private runtime root validation used by Apple file materialization.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift`
- `Tests/RielaCLITests/AppleNotesCrudAddonTests.swift`
- `Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift`
**Verification**:
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` exited 0 with 11 pre-existing warnings and no new warnings in changed files.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` exited 0; `Build complete!`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter Apple` exited 0; 98 selected tests passed.
**Residual Risks**: Upstream Mail download, Clock alarm, and Notes CRUD envelope confirmations remain intentionally user-QA-tracked. Shared adapter fixes outside Apple Gateway files were not required.

### Session: 2026-07-08 Step 6 Revision After Adversarial Review

**Tasks Completed**: Addressed Step 7 high finding against Mail materialization
root validation; TASK-004 and TASK-006 refreshed.
**Tasks In Progress**: None.
**Findings**:
- High, `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift:497`,
  fixed: Mail materialization accepted any owner-private `downloadDir` or
  `APPLE_GATEWAY_DOWNLOAD_DIR`; it now delegates root validation to
  `AppleGatewayFileDownloader.validatedOutputRootPath` before writing.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleMailAddons.swift`
- `Tests/RielaCLITests/AppleMailAddonTests.swift`
**Verification**:
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint` exited 0 with 11 pre-existing warnings and no new warnings in changed files.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` exited 0; `Build complete!`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter Apple` exited 0; 100 selected tests passed.
- `git status --short` and `git diff --stat` were reviewed after verification.
**Residual Risks**: Upstream Mail download, Clock alarm, and Notes CRUD
envelope confirmations remain intentionally user-QA-tracked. The worktree also
contains unrelated pre-existing OfficialSDK adapter changes outside this Apple
Gateway workflow scope.

### Session: 2026-07-08 Step 6 Revision After Step 7 Review

**Tasks Completed**: Addressed Step 7 mid finding by keeping this active
implementation plan as an intentional workflow artifact and refreshing status
verification with untracked files included.
**Tasks In Progress**: None.
**Findings**:
- Mid, `impl-plans/active/apple-gateway-review-hardening.md:1`, fixed: the
  active implementation plan is now explicitly included in the handoff as an
  intentional workflow artifact, and status verification uses
  `--untracked-files=all` instead of hiding untracked files.
**Files Changed**:
- `impl-plans/active/apple-gateway-review-hardening.md`
**Verification**:
- `GIT_OPTIONAL_LOCKS=0 git --no-pager status --short --untracked-files=all`
  was rerun and reviewed with the active plan visible.
**Residual Risks**: Upstream Mail download, Clock alarm, and Notes CRUD
envelope confirmations remain intentionally user-QA-tracked. Shared adapter
fixes outside Apple Gateway files were not required.
