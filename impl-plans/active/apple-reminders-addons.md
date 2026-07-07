# Apple Reminders Add-ons Implementation Plan

**Status**: Completed
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-reminder-
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Source of Truth**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`

**Accepted Review Input**:
- Step 3 design review accepted the Reminders design update.
- `needs_revision` was `false`.
- No issue number or repository was supplied in workflow input.
- No Codex-agent references were supplied, so there is no Cursor CLI or
  Codex-reference divergence to trace.

### Summary

Expose the `apple-gateway` Reminders domain as nine built-in Riela node add-ons.
The add-ons invoke a locally installed external `apple-gateway` binary through
the shared Apple Gateway subprocess bridge, using fixed GraphQL documents and
typed `--variables` JSON. Ship a read-only example workflow that lists reminder
lists and open reminders without requiring live Apple Reminders access during
validation.

### Scope

**Included**:
- Register read add-ons:
  - `riela/apple-reminder-lists`
  - `riela/apple-reminders-list`
  - `riela/apple-reminder-get`
- Register mutation add-ons:
  - `riela/apple-reminder-list-create`
  - `riela/apple-reminder-create`
  - `riela/apple-reminder-update`
  - `riela/apple-reminder-delete`
  - `riela/apple-reminder-complete`
  - `riela/apple-reminder-alarms-set`
- Reuse the Apple Gateway subprocess bridge introduced for
  `riela/apple-notes-list`.
- Invoke only `apple-gateway graphql --query <fixed-document> --variables <json>`
  with separate process arguments.
- Resolve the binary from literal `addon.config.binaryPath`, then
  `APPLE_GATEWAY_BIN`, then `PATH`.
- Validate operation inputs before spawning the process.
- Return the common `provider`, `model`, `completionPassed`, `appleGateway`, and
  operation-specific `appleReminders` output envelope.
- Add fake-executable tests for success and error paths.
- Add `examples/apple-reminders-list/` as a read-only workflow bundle.
- Keep catalog design docs and validation surfaces aligned with every new add-on
  id.

**Excluded**:
- Vendoring or copying `apple-gateway` source into this repository.
- Allowing workflow-authored arbitrary GraphQL documents.
- Exposing `recurrenceRules` in create/update version `1`.
- Requiring live Apple Reminders access in tests or workflow validation.
- Changing unrelated dirty files:
  - `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift`
  - `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`

---

## Task Breakdown

### 1. Confirm Current Code Shape And CLI Contract

**Status**: COMPLETED
**Write Scope**: none
**Depends On**: accepted Step 3 design

**Tasks**:
- [x] Inspect the current Apple Notes gateway implementation and tests.
- [x] Confirm whether `apple-gateway graphql --query <q> --variables <json>` is
  already covered by local fake-executable tests or needs new coverage.
- [x] Confirm the dispatch and catalog files to edit before implementation.
- [x] Record observations and any design-compatible implementation constraints
  in this plan's progress log.

**Deliverable**: Progress-log entry with observed files, reusable helpers, and
any code-shape constraints.

### 2. Extract Or Reuse Shared Apple Gateway Bridge

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGateway.swift`
- existing Apple Gateway tests as needed
**Depends On**: Task 1

**Tasks**:
- [x] Move reusable process runner, binary resolver, GraphQL envelope parsing,
  deadline handling, diagnostics compaction, and allowlisted child environment
  logic into a shared Apple Gateway file if they are still notes-private.
- [x] Keep Notes-specific query and output projection in the Notes file.
- [x] Preserve binary precedence: `config.binaryPath`, `APPLE_GATEWAY_BIN`,
  then `PATH`.
- [x] Keep `binaryPath` sourced only from literal config, never inputs, workflow
  input, upstream payloads, or local hardcoded paths.
- [x] Preserve existing Apple Notes behavior and tests.
- [x] Keep each Swift file under 1000 lines.

**Deliverable**: Shared Apple Gateway support reusable by Notes and Reminders.

### 3. Implement Reminders Executor

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- shared Apple Gateway helper file only if Task 2 leaves required gaps
**Depends On**: Task 2

**Tasks**:
- [x] Add `BuiltinAppleReminderAddon` with the nine accepted add-on ids.
- [x] Add `executeAppleReminderAddon(_:context:)` and route every id to a fixed
  GraphQL query or mutation.
- [x] Reject unsupported versions and authored `addon.env`.
- [x] Merge literal config defaults and rendered operation inputs while ignoring
  input-supplied `binaryPath`.
- [x] Validate required fields, scalar types, enums, `first` range, `priority`
  range, sparse update fields, and alarm arrays before process launch.
- [x] Build typed variables JSON for every operation.
- [x] Invoke `graphql --query <fixed-document> --variables <json>` through the
  shared runner with the execution deadline.
- [x] Map GraphQL envelope data into `appleReminders` output:
  - lists: `lists`, `listCount`
  - reminders-list: `reminders`, `pageInfo`, `totalCount`, `reminderCount`,
    `when.has_reminders`
  - get: `reminder`, `found`
  - list-create: `list`
  - create/update/complete/alarms-set: `reminder`
  - delete: `deleted.reminderId`, `deleted.success`
- [x] Preserve `provider: "apple-gateway"`, `model`, `completionPassed: true`,
  `status`, `addon`, `stepId`, and `appleGateway` metadata.

**Deliverable**: Reminders add-ons execute through the shared bridge and return
the accepted output envelope.

### 4. Register Catalog And Dispatch Surfaces

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
**Depends On**: Task 3 for dispatch compile target; can start after Task 1 for
catalog-only edits.

**Tasks**:
- [x] Add read and mutation descriptor groups for all nine add-ons, version `1`.
- [x] Include both groups in the built-in catalog `.all` collection.
- [x] Dispatch Reminders ids from `BuiltinWorkflowAddonResolver`.
- [x] Extend add-on contract tests so all nine ids validate and unsupported
  versions remain rejected.

**Deliverable**: All nine add-ons are known by catalog validation and runtime
dispatch.

### 5. Add Fake-Executable Test Matrix

**Status**: COMPLETED
**Write Scope**:
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- shared Apple Gateway test helper files only if the repo already uses that
  pattern
**Depends On**: Tasks 2, 3, and 4

**Tasks**:
- [x] Create per-test fake `apple-gateway` executables in test temporary
  directories.
- [x] Assert argument shape includes `graphql`, `--query`, fixed operation text,
  `--variables`, and expected variables JSON.
- [x] Cover success for list/search/get, list creation, create/update/delete,
  completion, and alarm replacement.
- [x] Cover get-null as `found=false` without treating it as provider failure.
- [x] Cover validation failures for missing required fields, invalid status,
  invalid priority, invalid `first`, malformed alarms, unsupported version, and
  authored `addon.env`.
- [x] Cover GraphQL `errors`, non-zero exit, malformed JSON, missing `data`,
  missing expected operation field, missing binary, non-executable binary, and
  deadline timeout.
- [x] Add at least one Reminders-side assertion for shared binary precedence and
  environment sanitization.
- [x] Confirm no test requires live Apple Reminders permission.

**Deliverable**: Deterministic fake-executable coverage for the accepted matrix.

### 6. Add Read-only Example Bundle

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-reminders-list/workflow.json`
- `examples/apple-reminders-list/nodes/node-workflow-output.json`
- `examples/apple-reminders-list/README.md`
- repository example index only if required by existing conventions
**Depends On**: Task 4 for validation ids
**Parallelizable**: Can proceed in parallel with Task 5 after Task 4 because
write scopes are disjoint.

**Tasks**:
- [x] Model the bundle on the existing Apple Notes example conventions.
- [x] Add one worker node for `riela/apple-reminder-lists`.
- [x] Add one worker node for `riela/apple-reminders-list` with read-only
  defaults `status: "INCOMPLETE"` and `first: 25`.
- [x] Map optional `workflowInput.listIds` and `workflowInput.query` into
  operation inputs.
- [x] Add an output/display node that exposes lists and open reminders.
- [x] Document external `apple-gateway` installation/build, Reminders permission
  request, permission status check, `binaryPath`, and `APPLE_GATEWAY_BIN`.
- [x] Keep mutation add-ons out of the shipped example workflow.

**Deliverable**: Offline-validating read-only example bundle.

### 7. Align Docs And Catalog Design Surfaces

**Status**: COMPLETED
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- generated or catalog-validation docs only if the implementation requires an
  update
**Depends On**: Tasks 3 and 4
**Parallelizable**: Can proceed in parallel with Task 6 if implementation has
not changed the accepted contract.

**Tasks**:
- [x] Keep the accepted Reminders section as source of truth.
- [x] Update docs only for design-compatible implementation facts discovered
  during coding.
- [x] Do not add unresolved user questions unless implementation reveals a real
  product decision.
- [x] Preserve explicit security notes: fixed operations, no arbitrary GraphQL,
  no vendored gateway, binary precedence, and allowlisted child environment.

**Deliverable**: Design docs remain consistent with implemented behavior.

### 8. Verification And Handoff

**Status**: COMPLETED
**Write Scope**: progress-log updates only
**Depends On**: Tasks 2 through 7

**Tasks**:
- [x] Run `swift test --filter AppleGateway`.
- [x] Run `swift test --filter AppleReminder`.
- [x] Run `swift test --filter AddonExecutionContracts`.
- [x] Run `swift build`.
- [x] Run `swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`.
- [x] Run `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs impl-plans`.
- [x] Run `git status --short`.
- [x] Confirm the two unrelated timeline files were not modified by this work.
- [x] Record command results in this plan's progress log.

**Deliverable**: Verification evidence and explicit remaining risks, if any.

---

## Dependencies

| Task | Depends On | Reason |
|------|------------|--------|
| 1. Confirm code shape | Accepted Step 3 design | Implementation must follow accepted design rather than redesign |
| 2. Shared bridge | Task 1 | Existing helper visibility and tests determine extraction shape |
| 3. Reminders executor | Task 2 | Reminders must reuse the shared subprocess bridge |
| 4. Catalog and dispatch | Task 1, Task 3 for compile | Catalog can start early; dispatch needs executor symbol |
| 5. Fake tests | Tasks 2, 3, 4 | Tests need executor, dispatch, and shared bridge behavior |
| 6. Example bundle | Task 4 | Workflow validation needs registered add-on ids |
| 7. Docs alignment | Tasks 3, 4 | Only update docs for implementation-compatible facts |
| 8. Verification | Tasks 2-7 | Full verification requires all implementation artifacts |

---

## Parallelizable Tasks

- Task 4 catalog descriptor edits can start after Task 1 while Task 2 extraction
  is underway, but dispatch wiring should wait for Task 3.
- Task 6 example bundle can run in parallel with Task 5 after Task 4 because the
  write scopes are disjoint.
- Task 7 docs alignment can run in parallel with Task 6 if no code behavior has
  diverged from the accepted design.

Do not parallelize Task 2 and Task 3 edits if both touch shared Apple Gateway
helper names. Do not parallelize tests that mutate the same fake helper files.

---

## Completion Criteria

- [x] All nine add-ons are registered in `RielaBuiltinAddonCatalog`.
- [x] `BuiltinWorkflowAddonResolver` dispatches all nine add-ons.
- [x] Reminders execution reuses the shared Apple Gateway bridge.
- [x] No committed source hardcodes `/Users/taco` or local `apple-gateway` paths.
- [x] Mutation add-ons exist but the shipped example remains read-only.
- [x] Fake-executable tests cover accepted success, validation, and error
  mapping scenarios.
- [x] `deleteReminder.success=false` maps to provider error and has regression
  coverage.
- [x] `riela/apple-reminder-create` omits `dueDateHasTime` unless explicitly
  configured or supplied through `addon.inputs`, preserving the upstream
  `apple-gateway` create default.
- [x] `swift build` passes.
- [x] Filtered Apple Gateway, Apple Reminder, and add-on contract tests pass.
- [x] `examples/apple-reminders-list` validates offline.
- [x] Design docs and catalog surfaces list every new add-on id.
- [x] Unrelated dirty timeline files remain untouched.

---

## Progress Log Expectations

Every implementation session should append a dated progress-log entry below with:
- tasks completed
- tasks in progress
- files changed
- verification commands run and results
- blockers or risks
- confirmation that unrelated dirty files were not modified when applicable

## Progress Log

### Session: 2026-07-07 Planning

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
**Tasks In Progress**: None.
**Files Changed**:
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Recorded From Step 3**:
- `git status --short`
- `git --no-pager diff -- design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `rg -n "Apple Reminders|apple-reminder|recurrenceRules|Codex|Cursor|Open questions|Question|TODO|TBD|user-qa|Common output envelope|provider|completionPassed" design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md design-docs/user-qa 2>/dev/null`
**Blockers**: None.
**Notes**: No Codex-agent references were provided. The Step 3 review accepted
the design with no findings, so `addressedFeedback` is empty for this planning
step.

### Session: 2026-07-07 Implementation

**Tasks Completed**: Implemented all nine Apple Reminders built-in add-ons,
catalog registration, resolver dispatch, deterministic fake-executable tests,
the read-only `examples/apple-reminders-list` bundle, and verification updates.
The accepted design and Step 5 review were aligned: workflow mode was
`issue-resolution`, `reviewDecision` was `accepted for implementation`, and no
high or mid findings were supplied.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `examples/apple-reminders-list/workflow.json`
- `examples/apple-reminders-list/nodes/node-workflow-output.json`
- `examples/apple-reminders-list/README.md`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift Sources/RielaAddons/RielaAddons.swift Sources/RielaCLI/ProductionNodeAdapter.swift Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches
- INFO `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs impl-plans`; matches are pre-existing parity-plan/design references and this impl-plan verification command, with no new source/test/example hardcoded local apple-gateway paths
- PASS `git status --short`; changed files are limited to Reminders add-on source, tests, example, docs, and this plan
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; coverage uses fake `apple-gateway` executables.
**Unrelated Dirty Files**: The two timeline files named in the constraints were
not modified and do not appear in `git status --short`.

### Session: 2026-07-07 Step 7 Review Revision

**Tasks Completed**: Addressed the Step 7 high findings against the real
`apple-gateway` Reminders schema. Reminder selections now use GraphQL aliases
`completed: isCompleted` and `modificationDate: lastModifiedDate` so the Riela
output contract keeps its accepted names while validating against the upstream
schema. The delete mutation now selects only `DeleteResult.success` and derives
`appleReminders.deleted.reminderId` from the submitted variables. Added
query-document assertions covering Reminder field aliases and the DeleteResult
selection so fake-executable tests cannot mask these schema-field regressions
again.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift Sources/RielaAddons/RielaAddons.swift Sources/RielaCLI/ProductionNodeAdapter.swift Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches
- PASS `git status --short`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; schema compatibility is covered by static query assertions and
fake-executable regression tests.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 6 Test-Integrity Revision

**Tasks Completed**: Addressed the latest Step 6 test-integrity feedback. Added
`riela/apple-reminders-list` validation coverage for `first` outside the
accepted 1...100 range, asserted validation failures do not create any fake
gateway invocation logs, and added explicit `riela/apple-reminder-complete`
coverage for `completed: false` preserving `false` in the variables JSON.
Confirmed this rerun remains aligned with the accepted design and implementation
contract: workflow mode is `issue-resolution`, prior planning-only mode is not
in effect, and the latest review findings are test-coverage gaps rather than
design changes.
**Tasks In Progress**: None.
**Files Changed**:
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 7 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `rg -n "first|completed" Tests/RielaCLITests/AppleReminderAddonTests.swift impl-plans/active/apple-reminders-addons.md`; found the new invalid `first` and explicit `completed: false` coverage.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 7 Adversarial Due-Date-Time Revision

**Tasks Completed**: Addressed the latest Step 7 adversarial mid finding.
`riela/apple-reminder-create` no longer injects `dueDateHasTime: false` when the
workflow omits the field, so timestamp due dates can keep the upstream
`apple-gateway` `CreateReminderInput` default semantics. Explicit config or
`addon.inputs` values for `dueDateHasTime` are still validated as booleans and
forwarded. Updated the Reminders design doc and fake-gateway regression coverage
to reflect omitted-by-default create behavior. The low example aggregation
finding remains a follow-up because the example output contract describes the
latest add-on payload.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 826 and 705 lines, both under 1000.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `git diff --check`; no whitespace errors.
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches.
- PASS `git status --short --untracked-files=all`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 7 Adversarial Review Revision

**Tasks Completed**: Addressed the adversarial high and mid findings. Reminders
operation fields are now resolved only from literal `addon.config` and
explicitly authored `addon.inputs`; ambient `resolvedInputPayload` and workflow
variables remain available only as template-rendering context. `deleteReminder`
now fails with `.providerError` when the gateway returns `success: false`
instead of reporting a successful add-on completion. Added adversarial
regressions covering ambient/config collisions for update, delete, and
complete, explicit `addon.inputs` rendering from ambient payload, and
`deleteReminder.success=false`.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 9 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`; 5 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `git diff --check`; no whitespace errors.
- PASS `rg -n "resolvedInputPayload|operationValue\(|success\\\":false|delete-false|AmbientPayload" Tests/RielaCLITests/AppleReminderAddonTests.swift Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`; found the new regression coverage and confined operation-value resolution.
- PASS `git status --short`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 7 Review Scalar/String/Delete Revision

**Tasks Completed**: Addressed the latest Step 7 mid findings. Rendered scalar
templates now decode JSON scalars as well as arrays and objects, so templated
`first`, `priority`, and `completed` materialize as typed variables. Optional
string operation fields now reject malformed explicit `addon.inputs` or config
values with `.policyBlocked` instead of silently omitting them or falling back.
`deleteReminder.success=false` was temporarily returned as
`appleReminders.deleted.success=false`; the later test-integrity revision below
supersedes that behavior and maps it to `.providerError`.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`; 5 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `git diff --check`; no whitespace errors.
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches.
- PASS `rg -n "materializedJSONValue|testTemplatedScalarInputsMaterializeTypedVariables|testMalformedOptionalStringFieldsFailValidation|delete-false|success\\\":false|query must be a string|notes must be a string" Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift impl-plans/active/apple-reminders-addons.md`; found implementation and regression coverage.
- PASS `git status --short`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 6 Test-Integrity Delete Revision

**Tasks Completed**: Addressed the Step 6 test-integrity finding. The
`riela/apple-reminder-delete` output handler now throws `.providerError` when
`data.deleteReminder.success` is `false`, and the `delete-false` fake-gateway
regression now expects that failure instead of accepting a successful payload.
The Reminders design doc error rules were aligned with the accepted failure
mapping.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`; 5 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `git diff --check`; no whitespace errors.
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches.
- PASS `git status --short --untracked-files=all`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.

### Session: 2026-07-07 Step 7 Review Double-Render Revision

**Tasks Completed**: Addressed the latest Step 7 mid finding. Reminders
`addon.inputs` values are now rendered exactly once into operation inputs, then
preserved when operation fields are materialized into typed GraphQL variables.
Literal user text containing `{{stepId}}`, missing-template-like braces, or
other `{{...}}` fragments is no longer rendered a second time after it comes
from `workflowInput` or another template source. Config values keep the
existing template-rendering path. Added fake `apple-gateway` regressions for
`riela/apple-reminders-list` query text and `riela/apple-reminder-create` title
text containing literal brace templates.
**Tasks In Progress**: None.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift`
- `Tests/RielaCLITests/AppleReminderAddonTests.swift`
- `impl-plans/active/apple-reminders-addons.md`
**Verification Commands Run**:
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint lint Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; 0 violations.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleReminder`; 12 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`; 11 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`; 5 tests, 0 failures.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-reminders-list --workflow-definition-dir examples`; `valid: true`.
- PASS `git diff --check`; no whitespace errors.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`; 864, 732, and 373 lines, all under 1000.
- PASS `rg -n "/Users/taco/.*apple-gateway|/Users/taco/gits" Sources Tests examples design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`; no matches.
- PASS `rg -n "renderAppleReminderInputs|AppleReminderOperationValue|testRenderedAddonInputStringsPreserveLiteralTemplateLikeText|materializedJSONValue|renderedNonEmptyString" Sources/RielaCLI/ProductionNodeAdapter+AppleReminderAddons.swift Tests/RielaCLITests/AppleReminderAddonTests.swift`; found the single-render implementation and regression.
- PASS `git status --short --untracked-files=all`; changed files remain limited to Reminders add-on source, tests, example, docs, catalog/dispatch, and this plan.
**Blockers**: None.
**Risks**: Live Apple Reminders access remains permission-gated and intentionally
untested; deterministic fake `apple-gateway` executables remain the automated
coverage strategy.
**Unrelated Dirty Files**: Not touched by this revision.
