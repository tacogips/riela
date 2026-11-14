# Apple Notifications Add-ons Implementation Plan

**Status**: Completed
**Workflow Mode**: issue-resolution
**Issue Reference**: Add apple-gateway Notifications builtin add-ons and an example
**Design Reference**: `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
**Created**: 2026-07-07

---

## Source Of Truth

Step 3 accepted the design update in
`design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`.
Implement the accepted sections for:

- `riela/apple-notifications-list`
- `riela/apple-notification-post`
- `riela/apple-notifications-dismiss`
- AppleGatewayNotifier.app helper and permission guidance

No Codex-agent references were provided, so this plan has no Codex-reference
behavior to trace and no Cursor/Codex adapter divergence to preserve.

## Scope

### Included

- Reuse the existing shared apple-gateway bridge in
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`.
- Keep executable resolution as literal `addon.config.binaryPath`,
  `APPLE_GATEWAY_BIN`, then `PATH`.
- Keep `addon.env` rejected and pass only the existing minimal child
  environment allowlist.
- Add notification-specific executors in a new focused Swift extension file.
- Register all three add-on ids in catalog, validation, and runtime dispatch.
- Add a deterministic fake-executable test matrix with no live Apple access.
- Add an offline-validating `examples/apple-notifications/` bundle that posts
  one notification and dismisses only the returned id.
- Keep docs aligned with the accepted gateway built-ins design.

### Excluded

- Vendoring or copying `apple-gateway` source.
- Shell interpolation or authored arbitrary command lines.
- Reading executable paths from `addon.inputs`, workflow input, variables, or
  upstream payloads.
- Live notification posting, live notification database access, or macOS
  permission prompts in tests.
- Modifying unrelated dirty files, especially
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

## Task Breakdown

### TASK-001 - Confirm Existing Bridge Reuse Points

**Status**: Completed
**Write Scope**: none
**Parallelizable**: yes, with TASK-005 documentation/example drafting

Tasks:
- Inspect `ProductionNodeAdapter+AppleGatewaySupport.swift`,
  `ProductionNodeAdapter+AppleGatewayAddons.swift`, and
  `ProductionNodeAdapter+AppleNotesCrudAddons.swift`.
- Confirm reusable helpers are internal to the `RielaCLI` target and cover
  process execution, timeout handling, pipe draining, binary resolution,
  GraphQL envelope parsing, string literals, compact diagnostics, and arrays.
- If any accepted helper still lives only in the notes-list file, move it into
  the shared bridge before notification executors depend on it.
- Preserve the existing process-group timeout and minimal environment behavior.

Deliverable:
- Confirmed bridge reuse path, with any needed helper extraction completed
  before TASK-002.

### TASK-002 - Implement Notification Executors

**Status**: Completed
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` only if a
  shared helper extraction from TASK-001 is required

**Parallelizable**: no
**Depends On**: TASK-001

Tasks:
- Add `executeAppleNotificationsList`, `executeAppleNotificationPost`, and
  `executeAppleNotificationsDismiss` on `BuiltinWorkflowAddonResolver`.
- Enforce version `1` only and reject any authored `addon.env`.
- Build fixed GraphQL documents as separate `graphql`, `--query`, `<document>`
  process arguments.
- For list, render supported filters, validate `source` as
  `GATEWAY_HELPER` or `SYSTEM_DB`, default `first` to `25`, enforce `1...100`,
  and parse `notifications`, `pageInfo`, `totalCount`, and `requestId`.
- For post, render `title`, `subtitle`, `body`, and `actions`; require a
  non-empty title; validate `actions` as rendered string values; validate
  configured `sound` as a boolean using the repository's local config parsing
  conventions and reject invalid non-boolean values when those conventions make
  the type observable; pass configured `sound: true` or `sound: false` into
  `PostNotificationInput` as bare GraphQL booleans; enforce `waitSeconds` in
  `0...300`; parse `posted` and optional `activation`; expose top-level
  `postedNotificationId` and `when`.
- For dismiss, render `ids`, require exactly one of non-empty `ids` or
  `all: true`, build either dismiss-by-id or dismiss-all mutation, and expose
  `dismissedCount`, `mode`, `requestId`, and `replyText`.
- Map invalid config to `.policyBlocked`, non-zero process exits and GraphQL
  errors to `.providerError`, malformed/missing data to `.invalidOutput`, and
  missed deadlines to `.timeout`.
- Append deterministic advisory guidance for helper-unavailable and Full Disk
  Access error text without changing the error category.
- Keep the new file under 1000 lines.

Deliverable:
- Notification executor implementation that matches the accepted output and
  error contracts.

### TASK-003 - Register Catalog And Runtime Dispatch

**Status**: Completed
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Parallelizable**: no
**Depends On**: TASK-002 for dispatch target names

Tasks:
- Add all three notification add-ons to
  `RielaBuiltinAddonCatalog.appleGatewayAddons` with version `1`.
- Add runtime dispatch branches near the existing apple-gateway add-ons.
- Update catalog contract assertions to include the three add-on names and
  reject unsupported versions.

Deliverable:
- All three ids resolve as built-ins and route to notification executors.

### TASK-004 - Add Fake-Executable Runtime Tests

**Status**: Completed
**Write Scope**:
- `Tests/RielaCLITests/AppleGatewayNotificationsAddonTests.swift`
- shared test helpers only when existing helpers cannot be reused without
  duplication

**Parallelizable**: no
**Depends On**: TASK-002 and TASK-003

Tasks:
- Create per-test fake `apple-gateway` executables under XCTest temporary
  directories only.
- Cover list success with `source: GATEWAY_HELPER`, paging fields, selected
  notification fields, request id, and top-level count/reply text.
- Cover post success with actions, `allowReply`, `waitSeconds`,
  `allowFallback`, configured `sound`, activation action label, reply text,
  and `postedNotificationId`; assert the fake executable receives a query whose
  `postNotification(input:)` includes `sound: true` or `sound: false` when
  configured.
- Cover post fallback, missing title, and out-of-range `waitSeconds`.
- Cover invalid non-boolean `sound` values as `.policyBlocked` when local
  config parsing conventions allow such invalid authored values to reach the
  executor.
- Cover dismiss by ids, dismiss all, neither mode, both modes, and empty ids.
- Cover binary precedence `config.binaryPath` over `APPLE_GATEWAY_BIN` over
  `PATH`, and prove inputs/payloads cannot set `binaryPath`.
- Cover secret-like environment stripping, `addon.env` rejection, unsupported
  versions, non-zero exit, malformed JSON, missing data, missing mutation
  result, helper-unavailable guidance, Full Disk Access guidance, and timeout.
- Ensure no test requires live Apple notification permissions.

Deliverable:
- Focused fake-executable coverage for the full notification add-on contract.

### TASK-005 - Add Offline Example Bundle

**Status**: Completed
**Write Scope**:
- `examples/apple-notifications/workflow.json`
- `examples/apple-notifications/nodes/*.json`
- `examples/apple-notifications/README.md`
- example index files only if repository convention requires them

**Parallelizable**: yes, after TASK-003 catalog names are known; coordinate
with TASK-004 because both may inspect example parity tests

Tasks:
- Model the bundle on `examples/apple-notes-list`.
- Add `post-demo-notification` using `riela/apple-notification-post` with
  benign demo text, `allowFallback: true`, and `waitSeconds: 0`.
- Add `dismiss-posted-notification` using
  `riela/apple-notifications-dismiss` with
  `["{{_rielaInput.latest.payload.postedNotificationId}}"]`.
- Add an output/display node; add a read-only list node only if it improves the
  example without requiring execution during validation.
- Keep validation offline and never use dismiss-all in the shipped example.
- Document external `apple-gateway` installation, AppleGatewayNotifier.app,
  first-post authorization, `permissions status --json`, notifications helper
  permission, Full Disk Access for `SYSTEM_DB`, `binaryPath`, and
  `APPLE_GATEWAY_BIN`.

Deliverable:
- A valid example bundle that demonstrates post plus cleanup by returned id.

### TASK-006 - Update Docs If Implementation Requires Clarification

**Status**: Completed
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- related catalog validation docs only if implementation reveals a mismatch

**Parallelizable**: no
**Depends On**: TASK-002 through TASK-005

Tasks:
- Keep the accepted Step 3 design text as the baseline.
- Update docs only for concrete implementation clarifications or accepted
  divergences discovered while coding.
- Preserve explicit security notes for mutations, helper permissions, Full
  Disk Access, binary resolution, and fake-executable verification.

Deliverable:
- Catalog docs remain accurate after implementation.

### TASK-007 - Final Verification And Progress Log

**Status**: Completed
**Write Scope**:
- `impl-plans/active/apple-notifications-addons.md`

**Parallelizable**: no
**Depends On**: TASK-001 through TASK-006

Tasks:
- Run required verification commands.
- Record pass/fail results, changed files, decisions, blockers, and any
  residual risks in the progress log.
- Confirm pre-existing unrelated dirty files remain untouched.
- Confirm no hardcoded `/Users/taco` apple-gateway binary paths entered source.

Deliverable:
- Completed progress log and verification evidence for implementation review.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | accepted Step 3 design | Confirms existing shared bridge before coding |
| TASK-002 | TASK-001 | Executors depend on bridge/helper boundaries |
| TASK-003 | TASK-002 | Dispatch must call concrete executor entry points |
| TASK-004 | TASK-002, TASK-003 | Tests need registered executors |
| TASK-005 | TASK-003 | Example validation needs known catalog ids |
| TASK-006 | TASK-002, TASK-003, TASK-004, TASK-005 | Docs should reflect actual implementation |
| TASK-007 | TASK-001 through TASK-006 | Final verification needs all deliverables |

## Parallelizable Tasks

- TASK-001 and early TASK-005 README/workflow drafting can run in parallel
  because TASK-001 is read-only and TASK-005 writes only `examples/`.
- TASK-004 fake test planning and TASK-005 README drafting can run in parallel
  until either task needs shared test/helper or example parity files.
- Do not parallelize TASK-002 with TASK-003 or TASK-004 implementation because
  executor names, helper visibility, and error surfaces must stay synchronized.
- Do not parallelize TASK-006 with any source or example edit touching the same
  accepted design sections.

## Verification

Required commands:

```sh
swift test --filter AppleGatewayNotifications
swift test --filter AppleGateway
swift test --filter AddonExecutionContractsTests
swift build
swift run riela workflow validate apple-notifications --workflow-definition-dir examples
rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans
git status --short
```

Optional non-live smoke command:

```sh
apple-gateway graphql --query '{ permissions { notificationsHelper notificationDbFullDiskAccess } }'
```

The optional smoke must not be required for CI, tests, or workflow validation.

## Completion Criteria

- [x] `riela/apple-notifications-list`, `riela/apple-notification-post`, and
  `riela/apple-notifications-dismiss` are registered in catalog and dispatch.
- [x] Node add-on validation accepts version `1` and rejects unsupported versions.
- [x] Executors reuse the shared apple-gateway bridge and do not duplicate process
  invocation logic.
- [x] Binary resolution remains `addon.config.binaryPath`, `APPLE_GATEWAY_BIN`,
  then `PATH`, with no input/payload override path.
- [x] `addon.env` is rejected and secret-like ambient environment variables are not
  forwarded to child processes.
- [x] List/post/dismiss GraphQL documents are fixed, passed as separate process
  arguments, contain no shell interpolation, and include post `sound` as a bare
  boolean whenever configured.
- [x] Outputs match the accepted `appleNotifications`, `appleNotification`,
  `postedNotificationId`, `dismissedCount`, `notificationCount`, `replyText`,
  and `appleGateway.binary` contracts.
- [x] Fake-executable tests cover success, validation failures, subprocess
  failures, malformed output, permission guidance, and timeout behavior.
- [x] `examples/apple-notifications` validates offline and dismisses only the
  notification id returned by its own post node, using the runtime-supported
  `_rielaInput.latest.payload.postedNotificationId` template path.
- [x] Required verification commands pass or failures are explicitly logged with
  follow-up actions.
- [x] Pre-existing unrelated dirty files remain untouched.

## Progress Log Expectations

Each implementation session must append:

- timestamp and actor
- tasks completed and tasks in progress
- blockers, decisions, and accepted divergences from the plan
- verification commands run with pass/fail result
- files intentionally changed
- confirmation that unrelated dirty files were left untouched

### Session: 2026-07-07 Step 4 Plan Creation

**Tasks Completed**: Created implementation plan from accepted Step 3 design.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: The codebase already has shared apple-gateway support in
`ProductionNodeAdapter+AppleGatewaySupport.swift`; implementation should reuse
that bridge and only extract additional helpers if the notification executors
need a notes-local helper. No Codex-agent references were provided, so no
Codex-reference divergence mapping is required.
**Verification**:
- PASS `git status --short`; only the accepted design-doc update was dirty
  before this plan file was added.
- PASS read
  `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
  notification sections as accepted source of truth.
**Files Changed Intentionally**:
- `impl-plans/active/apple-notifications-addons.md`

### Session: 2026-07-07 Step 4 Revision After Step 5 Review

**Tasks Completed**: Revised TASK-002 and TASK-004 to explicitly require
`sound` handling for `riela/apple-notification-post`.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Configured `sound` values must be passed into
`PostNotificationInput` as GraphQL booleans. Invalid non-boolean `sound` values
must be rejected when the repository's local config parsing conventions allow
that invalid authored shape to be observed by executor validation.
**Verification**:
- PASS addressed Step 5 mid-severity finding for missing `sound` implementation
  and fake-executable coverage requirements.
**Files Changed Intentionally**:
- `impl-plans/active/apple-notifications-addons.md`

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: Implemented notification list/post/dismiss executors,
catalog registration, runtime dispatch, fake-executable tests, offline example
bundle, nested add-on input rendering for array/object templates, and active
plan status updates.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Reused the existing shared bridge in
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` instead of
creating a duplicate bridge file. Updated shared `renderAddonInputs` to render
nested arrays/objects so add-on input arrays such as dismiss ids can use
templates deterministically.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGatewayNotifications`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notifications --workflow-definition-dir examples`
- PASS `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`; matches were only implementation-plan verification text, not committed source/example binary paths.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleGatewayNotificationsAddonTests.swift`; notification executor is 498 lines, shared bridge is 898 lines, notification tests are 548 lines.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`; remaining 6 warnings are pre-existing outside the new notification files.
- PASS `git status --short`; implementation files are dirty/untracked as expected and no unrelated timeline files are modified.
**Files Changed Intentionally**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaAddons/RielaAddons.swift`
- `Tests/RielaCLITests/AppleGatewayNotificationsAddonTests.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- `examples/apple-notifications/workflow.json`
- `examples/apple-notifications/nodes/node-workflow-output.json`
- `examples/apple-notifications/README.md`
- `impl-plans/active/apple-notifications-addons.md`

### Session: 2026-07-07 Step 6 Revision After Step 7 Review

**Tasks Completed**: Addressed the adversarial review finding by replacing the
example cleanup template with a runtime-supported `_rielaInput.latest.payload`
path and adding a workflow-run regression that executes the shipped
`examples/apple-notifications` bundle against a fake `apple-gateway` executable.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Used `_rielaInput.latest.payload.postedNotificationId` instead of
the rejected `steps.post-demo-notification.postedNotificationId` path because
the runtime always publishes latest input metadata there for downstream steps.
The fake workflow-run test asserts `dismissNotifications(ids: ["posted-example"])`
and rejects `dismissAllGatewayNotifications`.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGatewayNotifications`
  including `testAppleNotificationsExampleDismissesPostedNotificationId`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-notifications --workflow-definition-dir examples`.
- PASS `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  matches remain limited to implementation-plan verification text and the
  separate apple-notes CRUD plan, not committed Swift source or example paths.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayNotifications.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleGatewayNotificationsAddonTests.swift`;
  notification executor is 498 lines, shared bridge is 898 lines, notification
  tests are 626 lines.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`;
  reported 6 warning-only baseline violations outside the new notification files.
- PASS `git status --short`; implementation files are dirty/untracked as
  expected and the unrelated timeline files are not modified.
**Files Changed Intentionally**:
- `Tests/RielaCLITests/AppleGatewayNotificationsAddonTests.swift`
- `examples/apple-notifications/workflow.json`
- `impl-plans/active/apple-notifications-addons.md`

### Session: 2026-07-07 Step 6 Self-Review Revision

**Tasks Completed**: Addressed the Step 6 self-review finding by updating the
catalog docs dismiss authored example to use the same runtime-supported
`_rielaInput.latest.payload.postedNotificationId` path as the shipped example.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Kept the documentation aligned with
`examples/apple-notifications/workflow.json` so workflow authors do not copy the
unsupported `steps.post-demo-notification.postedNotificationId` template path.
**Verification**:
- PASS `rg -n "steps\\.post-demo-notification" examples/apple-notifications design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`;
  no shipped example or catalog-doc authored example references the unsupported
  path. Historical plan evidence still names the rejected path as review
  context.
- PASS `rg -n "_rielaInput\\.latest\\.payload\\.postedNotificationId" examples/apple-notifications design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md impl-plans/active/apple-notifications-addons.md`;
  the runtime-supported cleanup path is present in the shipped workflow, docs,
  and implementation plan evidence.
- PASS `git status --short`; implementation files are dirty/untracked as
  expected and the unrelated timeline files are not modified.
**Files Changed Intentionally**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `impl-plans/active/apple-notifications-addons.md`

## Risks

- The current shared bridge file is named `ProductionNodeAdapter+AppleGatewaySupport.swift`
  rather than the design-plan name `ProductionNodeAdapter+AppleGatewayBridge.swift`;
  implementation should prefer the existing shared file unless a rename is
  necessary for repository convention.
- GraphQL schema drift in external `apple-gateway` could invalidate field
  names; fake tests should lock the Riela-side contract while optional smoke
  checks stay non-required.
- Post/reply behavior can wait on user action; timeout tests must prove the
  existing deadline handling terminates subprocess groups promptly.
- Permission guidance is advisory text on provider errors, so tests must assert
  category remains `.providerError`.
