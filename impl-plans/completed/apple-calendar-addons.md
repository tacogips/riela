# Apple Calendar Add-ons Implementation Plan

**Status**: Implemented and verified
**Workflow Mode**: issue-resolution
**Issue Reference**: not applicable; workflow input did not include a GitHub issue
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#apple-calendar-add-ons
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

Step 3 accepted the design in communication `comm-000011` with decision
`accepted_for_implementation_planning`. This plan treats the accepted design-doc
update as the source of truth. There are no Codex-agent references, no Cursor
adapter references, and no user-facing decision gaps to resolve before
implementation. The only implementation-time confirmation item is verifying
that the local `apple-gateway graphql` command supports `--variables`.

Step 5 self-review communication `comm-000013` rejected the first implementation
plan for one plan-only issue: it directed implementation to add
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayShared.swift` even though
the codebase already has shared Apple Gateway support in
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`. This
revision addresses `PLAN-001` by requiring implementation to reuse or extend the
existing support file instead of creating duplicate subprocess bridge logic.

### Summary

Expose the Apple Calendar domain of the external `apple-gateway` CLI as seven
worker-only built-in node add-ons:

- `riela/calendar-list`
- `riela/event-search`
- `riela/event-get`
- `riela/event-create`
- `riela/event-update`
- `riela/event-delete`
- `riela/event-alarms-set`

The implementation must reuse the existing Apple Gateway subprocess bridge,
invoke `apple-gateway graphql --query <fixed-document> --variables <json>` with
separate process arguments, support recurrence `span` and `occurrenceDate`
where applicable, and ship one read-only example bundle that lists calendars
and fetches upcoming events.

### Scope

**Included**:
- Reuse and extend the existing shared Apple Gateway subprocess support in
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`.
- Refactor `riela/apple-notes-list` only if required by support-file changes,
  preserving unchanged behavior.
- Implement three read add-ons and four mutation add-ons in focused Swift
  extensions, keeping every Swift file under 1000 lines.
- Register all seven add-ons in built-in catalog, resolver dispatch, and node
  add-on validation tests.
- Add fake-executable tests for operation arguments, variables JSON, output
  mapping, validation failures, provider errors, invalid output, timeout, and
  binary resolution.
- Add `examples/apple-calendar-fetch/` as a read-only example bundle.
- Update catalog docs only for implementation-confirmed details that narrow or
  clarify the accepted design.

**Excluded**:
- Vendoring or copying `apple-gateway` source into this repository.
- Requiring live Apple Calendar access, macOS automation permission, or real
  user calendar data in tests or workflow validation.
- Adding reminders, mail, notes, notification, or clock domain work.
- Shipping mutation example bundles that can delete or overwrite user data.
- Modifying the pre-existing dirty files
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

---

## Task Breakdown

### TASK-001: Confirm Apple Gateway CLI Variable Support

**Status**: COMPLETED_WITH_ENVIRONMENT_LIMITATION
**Write Scope**: this plan's progress log only
**Parallelizable**: yes, with TASK-006 README drafting

**Tasks**:
- [x] Confirm `apple-gateway graphql --query <doc> --variables <json>` is
  accepted by the locally available CLI.
- [x] Capture a short note on the observed success and error envelope shape.
- [x] Confirmed the accepted fallback was not needed because the locally built
  CLI accepts `--variables`.
- [x] Record commands and conclusions in the progress log.

**Deliverable**: Progress-log entry that records whether `--variables` is
available and whether implementation can proceed on the accepted variables
contract.

### TASK-002: Reuse And Extend Shared Apple Gateway Support

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`

**Tasks**:
- [x] Audit the existing shared support file for reusable process runner, pipe
  draining, deadline handling, GraphQL envelope decoding, output models, binary
  provenance, binary resolution, and JSON helpers.
- [x] Extend `ProductionNodeAdapter+AppleGatewaySupport.swift` only where the
  Calendar add-ons need support that does not already exist; do not add a new
  shared bridge file or duplicate subprocess invocation logic.
- [x] Preserve binary resolution precedence:
  `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] Keep `binaryPath` config-only and literal-only; never source it from
  inputs, variables, workflow input, or upstream payloads.
- [x] Preserve minimal allowlisted child environment behavior and secret
  non-forwarding.
- [x] Refactor the existing Notes add-on only if required by support changes,
  with unchanged behavior.
- [x] Keep each touched Swift file under 1000 lines.

**Deliverable**: Existing Apple Gateway support file reused or minimally
extended so Calendar add-ons and Notes add-ons share subprocess invocation logic
without duplication.

### TASK-003: Implement Calendar Read Add-ons

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`

**Tasks**:
- [x] Define `BuiltinCalendarAddon` cases for all seven Calendar add-on ids and
  an `executeCalendarAddon` switch.
- [x] Implement `riela/calendar-list` with optional `entityType`, defaulting to
  `EVENT`, and output `appleCalendar.calendars` plus `calendarCount`.
- [x] Implement `riela/event-search` with required non-empty `calendarIds`,
  optional `startDate`, `endDate`, `query`, `first`, and `after`; default
  `first` to `25` and reject values outside `1...100`.
- [x] Implement `riela/event-get` with required `eventId` and optional
  `occurrenceDate`; return `appleCalendar.event` and `when.has_event`.
- [x] Send input values only through the `--variables` JSON argument.
- [x] Map missing fields, invalid enums, bad `first`, unsupported versions, and
  authored `addon.env` to policy-blocked errors.

**Deliverable**: Three read executors matching the accepted Calendar output and
validation contract.

### TASK-004: Implement Calendar Mutation Add-ons

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`

**Tasks**:
- [x] Implement `riela/event-create` with required `title`, `startDate`, and
  `endDate`; support optional all-day, notes, location, url, time zone,
  availability, alarms, and recurrence rules.
- [x] Implement `riela/event-update` with required `eventId`, default
  `span = THIS_EVENT`, optional `occurrenceDate`, and optional event field
  updates.
- [x] Implement `riela/event-delete` with required `eventId`, default
  `span = THIS_EVENT`, optional `occurrenceDate`, and `deleteResult.success`.
- [x] Implement `riela/event-alarms-set` with required `eventId` and `alarms`
  field; allow an empty alarms array to clear alarms; support default span and
  optional occurrence date.
- [x] Validate availability, recurrence span, recurrence frequency, and other
  enum-like fields before dispatch.
- [x] Send all user-controlled values through `--variables`, never interpolated
  into GraphQL documents.

**Deliverable**: Four mutation executors that are reachable as add-ons while
keeping example workflows read-only.

### TASK-005: Register Catalog, Dispatch, And Validation

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Tasks**:
- [x] Add the seven Calendar descriptors to the built-in add-on catalog at
  version `1`.
- [x] Dispatch Calendar add-ons from `BuiltinWorkflowAddonResolver` beside the
  Notes branch and thread `AdapterExecutionContext` for deadlines.
- [x] Extend add-on execution contract tests so all seven ids validate as
  built-ins and unsupported versions are rejected.
- [x] Preserve worker-only behavior for all add-ons.

**Deliverable**: Calendar add-ons are discoverable, validatable, and routed to
their executors.

### TASK-006: Add Read-only Example Bundle

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-calendar-fetch/workflow.json`
- `examples/apple-calendar-fetch/nodes/node-workflow-output.json`
- `examples/apple-calendar-fetch/README.md`

**Tasks**:
- [x] Add a workflow that lists `EVENT` calendars with `riela/calendar-list`.
- [x] Add an event-search node that fetches upcoming events using
  `workflowInput.calendarIds`, `startDate`, and `endDate`.
- [x] Keep the bundle mutation-free and validation-offline.
- [x] Document installing/building `apple-gateway` outside this repository,
  requesting Calendar permission, checking permission status, and configuring
  `binaryPath` or `APPLE_GATEWAY_BIN`.
- [x] Keep any local `/Users/taco` examples in README only, never in Swift
  source.

**Deliverable**: A valid read-only `apple-calendar-fetch` example bundle.

### TASK-007: Add Fake Executable Test Coverage

**Status**: COMPLETED
**Write Scope**:
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- test helper edits only if required by existing patterns

**Tasks**:
- [x] Build fake `apple-gateway` executables in per-test temporary directories.
- [x] Cover each operation's argv shape:
  `graphql --query <fixed-document> --variables <json>`.
- [x] Assert variables JSON for calendar list, event search, get, create,
  update, delete, and alarms-set.
- [x] Cover output parsing for calendars, event connections, nullable event
  get, created/updated events, delete result, and alarms-set event.
- [x] Cover required-field failures, invalid enums, `first = 101`,
  unsupported versions, and authored `addon.env`.
- [x] Cover binary precedence `config > APPLE_GATEWAY_BIN > PATH`, and prove
  `binaryPath` is not sourced from inputs, variables, workflow input, or
  upstream payload.
- [x] Cover non-forwarding of secret-like environment variables.
- [x] Cover GraphQL errors, non-zero exit, malformed JSON, missing data,
  missing operation field, and deadline timeout.
- [x] Ensure no test requires live Apple Calendar access.

**Deliverable**: Deterministic Calendar add-on tests with fake executables only.

### TASK-008: Refresh Catalog Docs For Confirmed Details

**Status**: COMPLETED
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

**Tasks**:
- [x] Update docs only when implementation confirms an upstream detail or
  needs a narrow accepted-design clarification.
- [x] Keep the seven ids, config/input/output contracts, security notes, and
  read-only example limits aligned with implementation.
- [x] Do not reopen user QA unless implementation discovers a product decision
  not covered by the accepted design.

**Deliverable**: Catalog docs remain synchronized with implemented behavior.

### TASK-009: Verification And Safety Audit

**Status**: COMPLETED
**Write Scope**: this plan's progress log only

**Tasks**:
- [x] Run `swift test --filter AppleCalendar`.
- [x] Run `swift test --filter AppleGateway`.
- [x] Run `swift test --filter AddonExecutionContracts`.
- [x] Run `swift build`.
- [x] Run `swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`.
- [x] Run `git status --short` and confirm unrelated dirty timeline files are
  untouched if present.
- [x] Run `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`
  and confirm any local path appears only in documentation/README text.
- [x] Run `git diff --check -- Sources Tests examples design-docs impl-plans`.

**Deliverable**: Progress-log entry with verification commands and results.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Step 3 accepted design | Confirms the implementation-time `--variables` assumption |
| TASK-002 | Step 3 accepted design | Shared support must precede Calendar executors |
| TASK-003 | TASK-001, TASK-002 | Read executors need the shared bridge and variables contract |
| TASK-004 | TASK-001, TASK-002 | Mutation executors need the shared bridge and variables contract |
| TASK-005 | TASK-003, TASK-004 | Dispatch and catalog should target implemented executor entry points |
| TASK-006 | TASK-005 | Example validation depends on catalog recognition |
| TASK-007 | TASK-003, TASK-004, TASK-005 | Tests need executors and registration surfaces |
| TASK-008 | TASK-001 through TASK-007 | Docs refresh follows confirmed implementation details |
| TASK-009 | TASK-001 through TASK-008 | Verification runs after implementation and docs are complete |

## Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| TASK-001 | TASK-006 README drafting | CLI inspection and README drafting have disjoint write scopes |
| TASK-003 | TASK-004 after TASK-002 | Read and mutation executor files are disjoint, sharing only the common support contract |
| TASK-005 catalog descriptor edits | TASK-006 initial example files | Source registration and example bundle paths are disjoint |
| TASK-007 test scaffolding | TASK-006 README/workflow drafting | Test target and example paths are disjoint |

Do not parallelize TASK-002 with TASK-003 or TASK-004 because the executors
depend on the final shared support API. Do not parallelize TASK-008 with active
source changes unless the implementers coordinate confirmed deviations first.

## Verification

Required commands:

```sh
swift test --filter AppleCalendar
swift test --filter AppleGateway
swift test --filter AddonExecutionContracts
swift build
swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples
git status --short
rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans
git diff --check -- Sources Tests examples design-docs impl-plans
```

Optional read-only smoke check:

```sh
APPLE_GATEWAY_BIN=<path-to-local-apple-gateway> swift test --filter AppleCalendar
```

The optional check must not become required for CI or local validation because
live Apple Calendar access is permission-gated.

## Completion Criteria

- [x] All seven Calendar add-on ids are registered at version `1` and pass node
  add-on validation.
- [x] Each Calendar operation is reachable through add-on inputs and uses a
  fixed GraphQL document with values passed through `--variables`.
- [x] `span` and `occurrenceDate` are first-class fields for update, delete,
  and alarms-set.
- [x] Binary resolution remains `addon.config.binaryPath`,
  `APPLE_GATEWAY_BIN`, then `PATH`; no committed Swift source hardcodes
  `/Users/taco` paths.
- [x] Fake-executable tests cover argument construction, variables, output
  mapping, validation failures, error envelopes, invalid output, timeout,
  binary precedence, and environment non-forwarding.
- [x] `riela/event-get` treats `data.event = null` as not found and rejects
  non-object `data.event` values as invalid provider output.
- [x] `riela/event-delete` requires `data.deleteEvent.success` to be present
  and boolean; malformed success values fail as invalid provider output.
- [x] `riela/event-create`, `riela/event-update`, and
  `riela/event-alarms-set` publish shared `when.has_event` alongside their
  operation-specific success flags.
- [x] Calendar field resolution merges literal `addon.config` with rendered
  `addon.inputs` only; rendered inputs override config, and unrelated runtime
  variables or `resolvedInputPayload` keys cannot override authored config.
- [x] `examples/apple-calendar-fetch/` validates and remains read-only.
- [x] `swift build` and the filtered tests pass.
- [x] Catalog docs remain aligned with implementation.
- [x] The pre-existing dirty RielaApp timeline files are untouched.

## Progress Log Expectations

Each implementation session should append a dated entry below with:

- completed tasks by task id
- files changed
- verification commands run and summarized results
- any accepted-design divergence and the design-doc update that records it
- blockers, especially if `apple-gateway graphql --variables` is unavailable

## Progress Log

### Session: 2026-07-07 Step 4 Planning

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
**Tasks In Progress**: None.
**Blockers**: None known; `apple-gateway --variables` remains a
TASK-001 implementation-time confirmation.
**Notes**: No Codex-agent, Cursor, or user-QA mapping applies for this
worker-only Calendar add-on work.

### Session: 2026-07-07 Step 4 Planning Revision

**Tasks Completed**: Addressed Step 5 self-review finding `PLAN-001` from
communication `comm-000013`.
**Tasks In Progress**: None.
**Blockers**: None known; `apple-gateway --variables` remains a
TASK-001 implementation-time confirmation.
**Notes**: TASK-002 now requires reuse or minimal extension of
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` and forbids
creating a duplicate shared bridge file.

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: TASK-002 through TASK-008. Added Calendar read and mutation
executors, registered all seven built-ins, added deterministic fake-executable
coverage, added the read-only `examples/apple-calendar-fetch` bundle, and
refreshed the catalog docs to record reuse of the existing Apple Gateway
support file.
**Tasks In Progress**: None.
**Verification So Far**:
- `swift test --filter AppleCalendar`: passed, 7 tests.
- `swift test --filter AppleGateway`: passed, 11 tests.
- `swift test --filter AddonExecutionContracts`: passed, 5 tests.
- `swift build`: passed.
- `swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `swiftlint` with Xcode toolchain: completed with 0 serious violations; the
  remaining 6 warnings are pre-existing outside the new Calendar files.
- `git status --short`: showed only implementation/doc/example changes and the
  previously modified design-doc file; no RielaApp timeline files were touched.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only the verification command text in this plan, not committed Swift,
  test, example, or design-doc content.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `ls -la riela-package.json`: no repository-root package manifest exists, so
  no `riela-package.json` digest refresh was applicable.
**Blockers**: `apple-gateway` is not available on this session's `PATH`, so
TASK-001 could not perform a live upstream `--variables` probe. Implementation
continues on the accepted `--variables` contract and verifies argv/variables
transport through fake executables, matching existing Notes CRUD coverage.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaAddons/RielaAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- `examples/apple-calendar-fetch/workflow.json`
- `examples/apple-calendar-fetch/nodes/node-workflow-output.json`
- `examples/apple-calendar-fetch/README.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`

### Session: 2026-07-07 Step 6 Test Integrity Revision

**Tasks Completed**: Addressed Step 7 feedback from communication
`comm-000019`. Strengthened `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
so mutation coverage now asserts the logged GraphQL query document contains the
expected mutation operation and field for `riela/event-create`,
`riela/event-update`, `riela/event-delete`, and
`riela/event-alarms-set`, while separately asserting variables transport and
that user-controlled values are not interpolated into the query text.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 7 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `swiftlint` with Xcode toolchain: completed with 6 non-serious warnings in
  pre-existing unrelated files; no Calendar-file warnings were reported.
- `git status --short`: showed only Calendar implementation, docs, example,
  test, and active-plan changes; no RielaApp timeline files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only the verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 574, 208, and 691 lines respectively.
**Blockers**: None for the Step 7 test-integrity finding. The previous live
`apple-gateway --variables` PATH limitation remains unchanged and is outside
this deterministic gate.
**Files Changed**:
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Adversarial Revision

**Tasks Completed**: Addressed Step 7 adversarial feedback from communication
`comm-000024`. Updated Calendar scalar resolution so values already present in
rendered add-on variables are treated as literals instead of being passed
through a second prompt-template render. Added an `event-create` regression test
where `workflowInput.title` and `workflowInput.notes` contain
`{{workflowInput.secret}}`, asserting the variables JSON preserves the literal
braces and does not contain the secret value. Also normalized accepted
`recurrenceRules.frequency` values before forwarding them.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 8 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `swiftlint` with Xcode toolchain: completed with 6 non-serious warnings in
  pre-existing unrelated files; no Calendar-file warnings were reported.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only the verification command text in this plan.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 582, 208, and 722 lines respectively.
- `rg --files -g 'riela-package.json'`: no repository package manifest was
  present, so no digest refresh was applicable.
**Blockers**: None for the Step 7 adversarial finding. The previous live
`apple-gateway --variables` PATH limitation remains unchanged and is outside
this deterministic gate.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Field Resolution Revision

**Tasks Completed**: Addressed Step 7 review feedback from communication
`comm-000028`. Calendar operation fields now resolve from literal
`addon.config` merged with rendered `addon.inputs` only, with inputs overriding
config. Arbitrary runtime variables and `resolvedInputPayload` keys no longer
override config unless the add-on author explicitly binds them through
`addon.inputs`. Added regression coverage for conflicting
`config.calendarIds` and `config.eventId` versus same-named
`resolvedInputPayload` keys, plus an explicit input template override case.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 9 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`:
  completed with 6 non-serious warnings in pre-existing unrelated files; no
  Calendar-file warnings were reported.
- `git status --short`: showed Calendar implementation, docs, example, test,
  and active-plan changes; no RielaApp timeline files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 595, 208, and 766 lines respectively.
- `rg --files -g "*.swift" | xargs wc -l | awk '$1 > 1000 {print}'`: reported
  pre-existing over-1000-line Swift files outside the Calendar files; no
  touched Calendar file is over 1000 lines.
**Blockers**: None for `comm-000028`. The previous live
`apple-gateway --variables` PATH limitation remains unchanged and is outside
this deterministic gate.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Documentation Revision

**Tasks Completed**: Addressed Step 6 self-review feedback from communication
`comm-000030`. Updated the Calendar catalog docs so the field-resolution
contract matches the implementation: literal `addon.config` is merged with
rendered `addon.inputs` only, `addon.inputs` overrides config, rendered input
strings are treated as literals after the first render, and arbitrary runtime
variables or `resolvedInputPayload` keys are ignored unless explicitly bound
through `addon.inputs`.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 9 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `git status --short`: showed Calendar implementation, docs, example, test,
  and active-plan changes; no RielaApp timeline files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `rg --files -g 'riela-package.json'`: no repository package manifest was
  present, so no digest refresh was applicable.
**Blockers**: None for `comm-000030`. The previous live
`apple-gateway --variables` PATH limitation remains unchanged and is outside
this deterministic gate.
**Files Changed**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Event-Get Output Validation Revision

**Tasks Completed**: Addressed Step 7 adversarial feedback from communication
`comm-000035`. `riela/event-get` now requires `data.event` to be either
`null` or an object. Scalar, array, or boolean provider values now fail with
`invalidOutput` instead of producing a misleading successful not-found result.
Added fake-executable regression coverage for scalar `data.event` while keeping
the existing null-event behavior covered. Also corrected the example README's
Calendar permission command to use `--domain calendar` and marked completed
implementation-plan task checkboxes complete.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 10 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`:
  completed with 6 non-serious warnings in pre-existing unrelated files; no
  Calendar-file warnings were reported.
- `git status --short`: showed Calendar implementation, docs, example, test,
  and active-plan changes; no RielaApp timeline files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 606, 208, and 782 lines respectively.
- `rg --files -g 'riela-package.json'`: no repository package manifest was
  present, so no digest refresh was applicable.
**Blockers**: None for `comm-000035`.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `examples/apple-calendar-fetch/README.md`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Mutation Output Contract Revision

**Tasks Completed**: Addressed Step 7 adversarial feedback from communication
`comm-000040`. `riela/event-delete` now requires
`data.deleteEvent.success` to be present and boolean, returning
`invalidOutput` for missing or scalar success values instead of a misleading
successful `deleted = false` result. Event-returning mutation add-ons now
publish shared `when.has_event = true` alongside `when.created`,
`when.updated`, or `when.alarms_set`. Added fake-executable regression
coverage for malformed delete success values and assertions for mutation
`has_event` flags. Updated Calendar catalog docs to include the shared
mutation `when.has_event` contract.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`:
  completed with 6 non-serious warnings in pre-existing unrelated files; no
  Calendar-file warnings were reported.
- `git status --short`: showed Calendar implementation, docs, example, test,
  and active-plan changes; no RielaApp timeline files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 606, 215, and 815 lines respectively.
- `rg --files -g 'riela-package.json'`: no repository package manifest was
  present, so no digest refresh was applicable.
**Blockers**: None for `comm-000040`.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-calendar-addons.md`

### Session: 2026-07-07 Step 6 Timeout And Delete Failure Revision

**Tasks Completed**: Addressed Step 7 adversarial feedback from communication
`comm-000045`. `riela/event-delete` now treats
`data.deleteEvent.success = false` as a provider failure instead of returning a
successful `deleted = false` payload. `AppleGatewayProcessRunner` now tracks an
isolated process group for the spawned apple-gateway process, sends timeout
termination to the group, and escalates to SIGKILL before pipe drains. Added
fake-executable regression coverage for failed delete success and for a
timeout child process that must not survive after the parent is terminated.
Also updated the Apple Calendar example README run command from deprecated
`--input` usage to `--variables '{"workflowInput":{...}}'`.
**Tasks In Progress**: None.
**Verification So Far**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleCalendar`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed, 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContracts`:
  passed, 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-calendar-fetch --workflow-definition-dir examples`:
  passed with `valid: true` and no diagnostics.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`:
  completed with 6 non-serious warnings in pre-existing unrelated files; no
  Calendar or Apple Gateway support warnings were reported.
- `git status --short`: showed Calendar implementation, docs, example, test,
  shared Apple Gateway support, and active-plan changes; no RielaApp timeline
  files were listed.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only verification command text in this plan.
- `git diff --check -- Sources Tests examples design-docs impl-plans`: passed
  with no output.
- `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarReadAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift Tests/RielaCLITests/AppleCalendarAddonTests.swift`:
  reported 426, 606, 221, and 845 lines respectively; touched Swift files are
  under 1000 lines.
- `rg --files -g 'riela-package.json'`: no repository package manifest was
  present, so no digest refresh was applicable.
**Blockers**: None for `comm-000045`.
**Files Changed**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleCalendarWriteAddons.swift`
- `Tests/RielaCLITests/AppleCalendarAddonTests.swift`
- `examples/apple-calendar-fetch/README.md`
- `impl-plans/active/apple-calendar-addons.md`
