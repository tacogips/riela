# Apple Gateway Admin Add-ons Implementation Plan

**Status**: Implemented and verified (reconciled 2026-07-12). All 51 checklist boxes are checked, `ProductionNodeAdapter+AppleGatewayAdminAddons.swift` is present, and `AppleGatewayAdminAddonTests` (9 tests) pass in the full suite. The prior "ready for implementation" header was stale — implementation landed after that self-review.
**Workflow Mode**: issue-resolution
**Issue Reference**: Add apple-gateway CLI/Admin builtin add-ons and an example
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-gateway--admin-cli-add-ons
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

Step 3 accepted the design in communication `comm-000008` with review decision
`accepted_for_step4_implementation_plan`. Step 4 self-review communication
`comm-000010` requested plan-only corrections for current codebase drift around
the existing apple-gateway support file and catalog grouping. This plan treats
the accepted design-doc update as the source of truth, with those Step 4
corrections applied. There are no Codex-reference inputs for this run, so no
codex-agent behavior trace or divergence mapping is required.

### Summary

Expose the apple-gateway administrative CLI surface as seven built-in,
worker-only add-ons:

- `riela/apple-gateway-graphql`
- `riela/apple-gateway-schema`
- `riela/apple-gateway-permissions-status`
- `riela/apple-gateway-permissions-request`
- `riela/apple-gateway-config-validate`
- `riela/apple-gateway-file-download`
- `riela/apple-gateway-cache-prune`

The implementation must reuse the existing apple-gateway subprocess bridge
introduced for `riela/apple-notes-list`, preserve binary resolution precedence
(`addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`), reject
`addon.env`, use separate argv elements with no shell interpolation, and keep
tests offline through fake executables.

### Scope

**Included**:
- Reuse and extend the existing shared apple-gateway bridge support in
  `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` without
  duplicating bridge architecture or changing current apple-gateway add-on
  behavior.
- Register the seven admin add-ons in
  `Sources/RielaAddons/RielaAddons.swift` and dispatch them from
  `Sources/RielaCLI/ProductionNodeAdapter.swift`.
- Implement fixed argv construction, validation, execution, output parsing,
  and error mapping for every accepted admin add-on.
- Add `examples/apple-gateway-admin/` as a read-only example using permissions
  status and a passthrough GraphQL query.
- Add fake-executable Swift tests covering all required argv, precedence,
  security, timeout, output, and catalog contract behavior.
- Keep catalog docs aligned with implementation if a concrete implementation
  detail intentionally diverges from the accepted docs.

**Excluded**:
- Vendoring or copying apple-gateway source into this repository.
- Live Apple app, TCC, or local Notes access during automated tests or workflow
  validation.
- Redesigning the accepted per-operation add-on id model.
- Modifying unrelated dirty files, especially
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

---

## Task Breakdown

### TASK-001: Reuse Existing Shared Apple Gateway Bridge

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- existing Apple Gateway tests only if refactor fallout requires import or
  visibility adjustment

**Tasks**:
- [x] Confirm the current support file already provides
  `AppleGatewayProcessRunner`, process output, pipe drain, timeout termination
  helpers, `AppleGatewayGraphQLEnvelope`, binary provenance types, compact
  JSON/text helpers, and `AppleGatewayBinaryResolver`.
- [x] Reuse those existing support types from admin add-ons; only add or adjust
  module-internal helpers if the admin executor needs a missing narrow utility.
- [x] Keep the resolver's existing precedence and policy-blocked error behavior:
  literal `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] Avoid creating `ProductionNodeAdapter+AppleGatewayShared.swift` unless a
  later implementation review intentionally splits the current support file for
  size/responsibility reasons.
- [x] Keep `AppleNotesListContext`, Apple Notes CRUD, and Apple Notifications
  behavior unchanged while adding admin reuse.
- [x] Keep Swift files under 1000 lines.

**Deliverables**:
- Existing apple-gateway bridge support reused by notes-list, Apple Notes CRUD,
  Apple Notifications, and admin add-ons.
- Existing apple-gateway tests remain valid.

### TASK-002: Register Catalog and Dispatch

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Tasks**:
- [x] Add `appleGatewayAdminAddons` descriptors for all seven ids, version `1`.
- [x] Preserve the current `RielaBuiltinAddonCatalog.appleGatewayAddons`
  contents, which already include `riela/apple-notes-list`, Apple Notes CRUD,
  and Apple Notifications descriptors.
- [x] Include the admin descriptors in `all` separately from the existing
  `appleGatewayAddons` group.
- [x] Add a dispatch branch that maps the incoming add-on name to
  `BuiltinAppleGatewayAdminAddon`.
- [x] Add catalog contract assertions that `appleGatewayAdminAddons.map(\.name)`
  equals the seven accepted admin ids, every admin id supports version `1`, and
  every admin id rejects version `2`.

**Deliverables**:
- All seven ids validate as built-ins and route to the admin executor.

### TASK-003: Implement Admin Add-on Executor

**Status**: COMPLETED
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift`

**Tasks**:
- [x] Define `BuiltinAppleGatewayAdminAddon` with one case per accepted id.
- [x] Add a shared executor preamble that rejects unsupported versions and
  `addon.env`, resolves the binary through the shared resolver, and renders
  supported config/input fields except literal `binaryPath`.
- [x] Build argv with separate process arguments for each operation:
  `graphql`, `schema print`, `permissions status --json`,
  `permissions request --domain`, `config validate`, `file download`, and
  `cache prune`.
- [x] Enforce accepted precedence rules for `configPath` over `config`,
  `queryFile` over `query`, and `variablesFile` over `variables`.
- [x] Validate operation-specific enums and required inputs before process
  launch.
- [x] Parse outputs into the accepted payload contracts, always including
  `status`, `addon`, `stepId`, and `appleGateway.binary`.
- [x] Map missing or invalid required config to `.policyBlocked`, process
  launch/non-zero/GraphQL errors to `.providerError`, deadline expiry to
  `.timeout`, and malformed required output to `.invalidOutput`.

**Deliverables**:
- Deterministic executors for all seven admin add-ons using the shared bridge.

### TASK-004: Add Read-only Example Bundle

**Status**: COMPLETED
**Write Scope**:
- `examples/apple-gateway-admin/workflow.json`
- `examples/apple-gateway-admin/nodes/node-workflow-output.json`
- `examples/apple-gateway-admin/README.md`
- `examples/README.md` only if the repository index requires it

**Tasks**:
- [x] Create a workflow with `check-permissions` using
  `riela/apple-gateway-permissions-status`.
- [x] Add `gateway-query` using `riela/apple-gateway-graphql` with read-only
  query `{ noteAccounts { id name isDefault } }`.
- [x] Add an output node matching the repository's example projection pattern.
- [x] Document external apple-gateway installation, `binaryPath`,
  `APPLE_GATEWAY_BIN`, and permissions status.
- [x] Explicitly warn that permissions request and cache prune are
  state-changing, file download writes to disk, and the example deliberately
  uses only read-only add-ons.

**Deliverables**:
- Offline-validating `examples/apple-gateway-admin` bundle and README.

### TASK-005: Add Fake-executable Test Matrix

**Status**: COMPLETED
**Write Scope**:
- `Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Tasks**:
- [x] Create per-test temporary fake executables that log argv and emit
  mode-specific stdout, stderr, exit codes, or sleeps.
- [x] Cover shared security behavior: config/env/PATH binary precedence,
  ignored `binaryPath` from inputs/variables/payload, minimal child
  environment, rejected `addon.env`, unsupported version, and timeout.
- [x] Cover GraphQL passthrough query, query-file, variables, variables-file,
  config prepending, GraphQL errors, malformed JSON, missing query, and
  non-zero exit.
- [x] Cover schema role handling and empty stdout.
- [x] Cover permissions status JSON parsing and permissions request domain
  validation.
- [x] Cover config validate with and without config path.
- [x] Cover file download keys/output-dir validation and argv.
- [x] Cover cache prune with and without `--all`.
- [x] Ensure tests require no live Apple app access or permission prompts.

**Deliverables**:
- Focused Swift test coverage for every accepted admin add-on behavior.

### TASK-006: Update Catalog Docs if Implementation Diverges

**Status**: COMPLETED
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`

**Tasks**:
- [x] Compare completed implementation behavior against accepted design docs.
- [x] Update docs only for intentional, reviewable implementation divergences
  or newly confirmed details.
- [x] Preserve security labels for unrestricted GraphQL, state-changing
  permission request/cache prune, and local filesystem file download.

**Deliverables**:
- Catalog docs remain accurate after implementation.

### TASK-007: Verification, Safety Audit, and Progress Log

**Status**: COMPLETED
**Write Scope**:
- `impl-plans/active/apple-gateway-admin-addons.md`

**Tasks**:
- [x] Run required filtered tests, build, workflow validation, path audit, and
  status audit.
- [x] Record exact pass/fail results in this plan's progress log.
- [x] Confirm no hardcoded `/Users/taco` apple-gateway paths appear in
  committed source surfaces.
- [x] Confirm unrelated dirty timeline files remain untouched.

**Deliverables**:
- Progress-log evidence ready for Step 5 implementation review.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Accepted Step 3 design `comm-000008` | Shared bridge shape is source-of-truth for all admin executors |
| TASK-002 | Accepted Step 3 design `comm-000008`; Step 4 self-review `comm-000010` | Add-on ids and versions are fixed by design; catalog grouping must preserve current source layout |
| TASK-003 | TASK-001; TASK-002 | Executor needs shared bridge and dispatch/catalog surface |
| TASK-004 | TASK-002 | Example validation needs registered add-on ids |
| TASK-005 | TASK-003 | Test assertions target concrete executor behavior |
| TASK-006 | TASK-003 through TASK-005 | Docs should reflect final implementation behavior only if it diverges |
| TASK-007 | TASK-001 through TASK-006 | Verification runs after implementation and docs are complete |

## Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| TASK-002 catalog descriptors | TASK-004 initial example README/workflow drafting | Source registration and example paths are disjoint after ids are fixed |
| TASK-004 example bundle | TASK-005 initial fake-executable test scaffolding | Example files and test files are disjoint |
| TASK-006 doc comparison | TASK-007 status/path audit preparation | Read-only inspection can happen before final docs edits |

Do not parallelize TASK-001 with any edit that changes existing apple-gateway
support behavior. Do not parallelize final edits to `ProductionNodeAdapter.swift`,
`ProductionNodeAdapter+AppleGatewaySupport.swift`, or
`AppleGatewayAdminAddonTests.swift` because helper names and dispatch paths must
be reconciled in one pass.

## Verification

Required commands:

```bash
swift test --filter AppleGateway
swift test --filter AddonExecutionContractsTests
swift build
swift run riela workflow validate apple-gateway-admin --workflow-definition-dir examples
rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans
git status --short
```

Expected verification notes:
- `swift test --filter AppleGateway` must cover both existing notes-list and
  new admin add-on tests.
- Workflow validation must not invoke a live apple-gateway binary.
- Fake-executable tests must not require live Apple app access, TCC prompts, or
  local user data.
- `git status --short` must show only intentional changes for this work plus
  any pre-existing unrelated dirty files.

## Completion Criteria

- [x] All seven admin add-on ids are registered, validate as built-ins, and
  reject unsupported versions.
- [x] Admin executors reuse the shared apple-gateway process bridge instead of
  duplicating process invocation logic.
- [x] Binary resolution order is literal `addon.config.binaryPath`,
  `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] `binaryPath` cannot be sourced from `addon.inputs`, workflow input,
  variables, or upstream payloads.
- [x] `addon.env` is rejected for all seven admin add-ons.
- [x] Each subcommand builds the accepted argv shape with no shell
  interpolation.
- [x] Output payloads match the accepted contracts and include binary
  provenance.
- [x] Error cases map to the accepted `AdapterExecutionError` categories.
- [x] `examples/apple-gateway-admin` is read-only and validates offline.
- [x] Fake-executable tests cover the accepted matrix without live Apple app
  access.
- [x] Required verification commands pass or any residual risk is explicitly
  documented for Step 5 review.
- [x] Pre-existing dirty timeline files remain untouched.

## Progress Log Expectations

Each implementation session must append:

- timestamp and actor
- tasks completed
- tasks in progress
- blockers or decisions
- verification commands run with pass/fail result
- files changed intentionally
- confirmation that unrelated dirty files were not modified

### Session: 2026-07-07 Step 4 Implementation Plan

**Tasks Completed**: Created implementation plan from accepted Step 3 design
review `comm-000008`.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: The accepted design-doc update remains the source of truth; no
Codex-reference inputs were provided, so no codex-agent divergence mapping is
required.
**Verification**:
- PASS `git status --short`; observed only the accepted design-doc updates
  before plan creation.
**Files Changed Intentionally**:
- `impl-plans/active/apple-gateway-admin-addons.md`

### Session: 2026-07-07 Step 4 Plan Revision After Self-review

**Tasks Completed**: Addressed Step 4 self-review feedback `comm-000010`.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: TASK-001 now reuses
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` instead of
planning a duplicate shared file. TASK-002 now preserves the current
`RielaBuiltinAddonCatalog.appleGatewayAddons` contents and adds
`appleGatewayAdminAddons` separately.
**Verification**:
- PASS reviewed `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
  references through `rg`; current support file already contains
  `AppleGatewayProcessRunner`, `AppleGatewayGraphQLEnvelope`, and
  `AppleGatewayBinaryResolver`.
- PASS reviewed `Sources/RielaAddons/RielaAddons.swift` references through `rg`;
  current `appleGatewayAddons` includes notes-list, Apple Notes CRUD, and Apple
  Notifications descriptors.
**Files Changed Intentionally**:
- `impl-plans/active/apple-gateway-admin-addons.md`

### Session: 2026-07-07 Step 6 Implementation

**Tasks Completed**: Implemented all seven Apple Gateway admin add-ons, catalog
registration, resolver dispatch, read-only example bundle, fake-executable test
matrix, catalog contract tests, and completion-criteria updates.
**Tasks In Progress**: None.
**Blockers**: None.
**Decisions**: Reused the existing
`Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift` bridge
instead of creating a duplicate shared file. No design divergence required doc
changes beyond the accepted design-doc updates already present.
**Verification**:
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`;
  31 selected tests passed, including existing gateway tests and new admin
  fake-executable tests.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`;
  5 selected tests passed.
- PASS `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`;
  completed with 11 warnings and 0 serious violations, all warnings on
  pre-existing broad repository style issues outside the new admin source.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`.
- PASS `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate apple-gateway-admin --workflow-definition-dir examples`;
  validation returned `valid: true` with no diagnostics.
- PASS `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`;
  matches are implementation-plan audit text only, not source, test, example,
  or design-doc hardcoded binary paths.
- PASS `git status --short`; observed only issue-scope source/test/example/plan
  changes plus accepted design-doc updates. The previously called out timeline
  files were not present as dirty files after this implementation pass and were
  not modified.
- PASS `wc -l Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift`;
  new admin source is 371 lines, support is 900 lines, and admin tests are 530
  lines.
**Files Changed Intentionally**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAdminAddons.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`
- `Tests/RielaCLITests/AppleGatewayAdminAddonTests.swift`
- `examples/apple-gateway-admin/workflow.json`
- `examples/apple-gateway-admin/nodes/node-workflow-output.json`
- `examples/apple-gateway-admin/README.md`
- `impl-plans/active/apple-gateway-admin-addons.md`

## Related Plans

- `impl-plans/active/apple-notes-list-addon.md`
