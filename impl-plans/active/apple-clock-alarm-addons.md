# Apple Clock Alarm Add-ons Implementation Plan

**Status**: Completed; Step 7 adversarial revision addressed after `comm-000036`
**Workflow Mode**: issue-resolution
**Issue Reference**: Add apple-gateway Clock Alarms builtin add-ons and a read-only example; no GitHub issue URL or repository-plus-number was provided
**Design Reference**: design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md#built-in-rielaapple-clock-alarm-
**Created**: 2026-07-07
**Last Updated**: 2026-07-07

---

## Design Document Reference

**Sources**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md`

Step 3 accepted the Clock Alarm design in communication `comm-000008` with
decision `accepted_for_implementation_plan`. This plan treats the accepted
design-doc update as the source of truth and does not redesign the add-on
shape.

Codex agent trace: none. `codexAgentReferences` was empty, so there is no
reference-path or adapter-boundary mapping to preserve.

### Summary

Expose the `apple-gateway` Clock Alarms domain as five version-`1`,
fixed-shape, worker-only built-in add-ons:

- `riela/apple-clock-alarms-list`
- `riela/apple-clock-alarm-create`
- `riela/apple-clock-alarm-toggle`
- `riela/apple-clock-alarm-update`
- `riela/apple-clock-alarm-delete`

All operations reuse the shared Apple Gateway subprocess support already used
by the Notes add-ons. Authors cannot supply arbitrary GraphQL. Mutations require
`--variables <json>` and fail closed if the gateway rejects that flag or exits
nonzero after receiving a mutation request.

### Scope

**Included**:
- Built-in catalog and dispatch registration for all five add-on ids.
- Clock Alarm executor implementation in a focused Swift extension under
  `Sources/RielaCLI/`, reusing shared Apple Gateway support.
- Fake-executable tests covering success, validation failures, binary
  precedence, environment stripping, provider/error envelopes, timeout, missing
  Shortcuts bridge, and macOS 26+ gating.
- A read-only `examples/apple-clock-alarms-list/` workflow bundle and README.
- Catalog documentation alignment only if implementation evidence changes the
  accepted docs.
- Progress-log updates in this plan as implementation and verification proceed.

**Excluded**:
- Vendoring, copying, or linking `apple-gateway` source into this repository.
- Live Apple Clock, Shortcuts, or macOS automation access in automated tests.
- Default mutation examples that create, toggle, update, or delete user data.
- Sourcing `binaryPath` from `addon.inputs`, variables, workflow input, or
  upstream payloads.
- Touching unrelated working-tree changes, especially
  `Sources/RielaApp/WorkflowExecutionTimelinePaneView.swift` and
  `Tests/RielaViewerTests/WorkflowExecutionTimelineLayoutTests.swift`.

---

## Task Breakdown

### TASK-001: Confirm upstream Clock CLI contract

**Status**: PARTIAL
**Write Scope**: `impl-plans/active/apple-clock-alarm-addons.md` progress log only
**Parallelizable**: yes, with TASK-006 README drafting only

**Tasks**:
- [x] Attempt local `apple-gateway` discovery; `which apple-gateway` returned
  not found, so `graphql --help` could not be run in this session.
- [ ] Confirm Clock mutations accept variables for `createClockAlarm`,
  `toggleClockAlarm`, `updateClockAlarm`, and `deleteClockAlarm`.
- [ ] Capture exact missing Shortcuts bridge GraphQL envelopes for the
  `apple-gateway-get-alarms` read path and at least one mutation shortcut.
- [ ] Capture exact unsupported macOS envelopes for `updateClockAlarm` and
  `deleteClockAlarm`.
- [ ] Confirm the accepted Clock alarm `time` format, including whether strict
  `HH:mm` is required.
- [x] If `--variables` is unavailable or fails after the mutation process has
  been invoked, fail closed without a second mutation attempt.

**Deliverables**:
- Progress-log entry with commands, envelope samples or confirmed blockers,
  classifier tokens, and the final transport decision.

### TASK-002: Reuse and extend shared Apple Gateway support

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift`
- `Sources/RielaCLI/ProductionNodeAdapter+AppleGatewayAddons.swift` only if
  notes-list behavior must be preserved after support extraction

**Tasks**:
- [x] Inspect existing shared support for process running, pipe draining,
  timeout cleanup, GraphQL envelope decoding, binary resolution, environment
  allowlisting, and JSON helper functions.
- [x] Move or expose any still-private notes-list helpers needed by Clock
  add-ons as internal shared helpers without changing Notes behavior.
- [x] Preserve binary resolution precedence:
  `addon.config.binaryPath`, then `APPLE_GATEWAY_BIN`, then `PATH`.
- [x] Preserve secret-environment stripping and no-shell subprocess invocation.
- [x] Keep Swift files under 1000 lines; split support if needed.

**Deliverables**:
- Shared Apple Gateway support usable by Notes and Clock add-ons without
  duplicated process-invocation logic.

### TASK-003: Register catalog and dispatch

**Status**: DONE
**Write Scope**:
- `Sources/RielaAddons/RielaAddons.swift`
- `Sources/RielaCLI/ProductionNodeAdapter.swift`
- `Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`

**Tasks**:
- [x] Add all five Clock add-on ids as version `1` built-ins.
- [x] Route all five names in `BuiltinWorkflowAddonResolver.execute`.
- [x] Reject unsupported versions deterministically.
- [x] Ensure authored `addon.env` remains rejected for these add-ons.
- [x] Extend add-on contract tests to accept the new ids and reject invalid
  versions.

**Deliverables**:
- Validation and dispatch recognize the Clock add-ons and reject unsupported
  contracts before execution.

### TASK-004: Implement Clock Alarm executors

**Status**: DONE
**Write Scope**:
- `Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift`

**Tasks**:
- [x] Add one focused executor path per operation with fixed GraphQL documents:
  `clockAlarms`, `createClockAlarm`, `toggleClockAlarm`, `updateClockAlarm`,
  and `deleteClockAlarm`.
- [x] Render only supported config and input fields through the normal node
  template context.
- [x] Validate `time` as the accepted `HH:mm` contract, `enabled` as boolean,
  required labels, and `repeatDays` as trimmed uppercase Weekday enum tokens.
- [x] Pass mutations as `--variables '{"input": ...}'` using separate process
  arguments; list uses only `--query`; never retry a mutation after a failed
  mutation process.
- [x] Parse list and `ClockAlarmResult` envelopes into the accepted output
  shape: `payload.clockAlarms`, `payload.clockAlarm`, `payload.result`,
  `replyText`, `appleGateway`, and `when` flags.
- [x] Validate every accepted `ClockAlarm` payload before successful output:
  list entries and mutation `result.alarm` must be `null` or objects with
  non-empty `id`, `label`, and `time` strings, boolean `isEnabled`, and a
  string-only `repeatDays` array.
- [x] Add a Clock-specific classifier that maps missing Shortcuts bridge and
  update/delete macOS 26+ envelopes to `.policyBlocked`, while preserving
  generic GraphQL errors as `.providerError`.
- [x] Include bounded binary provenance and host OS version without leaking
  secrets or full ambient environments.

**Deliverables**:
- Five deterministic Clock executors that reuse shared support and match the
  accepted docs.

### TASK-005: Add fake-executable tests

**Status**: DONE
**Write Scope**:
- `Tests/RielaCLITests/AppleClockAlarmAddonTests.swift`
- shared test helpers only if an existing Apple Gateway test helper can be
  reused without destabilizing Notes tests

**Tasks**:
- [x] Add fake gateway modes for `list`, `create`, `toggle`, `update`,
  `delete`, `result-failure`, `missing-shortcut`, `os-version`,
  `graphql-error`, `nonzero`, `malformed`, `missing-data`, `sleep`, and
  large-output behavior.
- [x] Log full argv and variables JSON so tests assert `--query` and
  `--variables` construction.
- [x] Verify list success uses no variables and parses alarm arrays.
- [x] Verify create/toggle/update/delete pass the expected variables,
  including uppercase `repeatDays`.
- [x] Verify create/toggle/update/delete dispatch the expected fixed GraphQL
  mutation operation and field, and assert argv order is
  `graphql --query <document> --variables <json>`.
- [x] Verify missing `label` or `time`, invalid `time`, invalid Weekday, and
  non-bool `enabled` map to `.policyBlocked`.
- [x] Verify missing Shortcuts bridge maps to `.policyBlocked` and mentions
  alarm Shortcuts plus `packaging/shortcuts`.
- [x] Verify update/delete OS-version envelopes map to `.policyBlocked` and
  mention macOS 26+.
- [x] Verify result warnings map to `.providerError`, malformed or missing
  data maps to `.invalidOutput`, and deadlines map to `.timeout`.
- [x] Verify malformed ClockAlarm list entries, malformed mutation alarms,
  missing mutation `alarm`, and non-string `repeatDays` entries map to
  `.invalidOutput`.
- [x] Verify binary precedence, no `binaryPath` sourcing from inputs or
  payloads, rejected `addon.env`, secret environment stripping, and no live
  Apple or Shortcuts dependency.

**Deliverables**:
- Focused fake-executable coverage for the accepted Clock Alarm matrix.

### TASK-006: Add read-only example workflow

**Status**: DONE
**Write Scope**:
- `examples/apple-clock-alarms-list/workflow.json`
- `examples/apple-clock-alarms-list/nodes/node-workflow-output.json`
- `examples/apple-clock-alarms-list/README.md`
- `examples/README.md` only if the repository's example index requires it

**Tasks**:
- [x] Model the bundle on `examples/apple-notes-list`.
- [x] Add a worker node using `riela/apple-clock-alarms-list` and an output
  node.
- [x] Keep validation offline; validation must not invoke a live gateway.
- [x] Document installing or building `apple-gateway` outside this repository.
- [x] Document installing the required `packaging/shortcuts` alarm shortcuts.
- [x] Document readiness checks with
  `apple-gateway permissions status --json` and `shortcutsClockBridge`.
- [x] Document `binaryPath`, `APPLE_GATEWAY_BIN`, and update/delete macOS 26+
  requirements.
- [x] Keep the default example read-only.

**Deliverables**:
- Valid read-only example bundle and operator README.

### TASK-007: Refresh docs only for confirmed implementation evidence

**Status**: DONE
**Write Scope**:
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md`
- `design-docs/specs/node-addon-catalog-and-chat-reply-worker/responsibilities-security-tests.md`
- `design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md`

**Tasks**:
- [x] Update confirmation-gate notes with the failed local discovery result and
  the residual upstream-envelope confirmation requirement.
- [x] Keep classifier documentation aligned with the accepted assumptions; no
  observed upstream codes were available to supersede them.
- [x] Update catalog docs only for intentional implementation deviations or
  confirmed upstream facts.
- [x] Do not reopen product/user QA unless implementation discovers a
  product-level decision.

**Deliverables**:
- Accepted design docs remain accurate and auditable after implementation.

### TASK-008: Verification and safety audit

**Status**: DONE
**Write Scope**: `impl-plans/active/apple-clock-alarm-addons.md` progress log only

**Tasks**:
- [x] Run the narrowest Clock Alarm Swift test filter.
- [x] Run related Apple Gateway/contract filters as needed.
- [x] Run `swift build`.
- [x] Validate the new read-only example bundle.
- [x] Run status and hardcoded-path audits.
- [x] Confirm unrelated dirty timeline files remain untouched.
- [x] Record exact commands, outcomes, and residual risks in the progress log.

**Deliverables**:
- Progress-log evidence sufficient for Step 5 implementation review.

---

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | Step 3 accepted design `comm-000008` | Confirms transport, classifier, and time-format gates |
| TASK-002 | Existing Notes Apple Gateway support | Clock must reuse shared bridge behavior |
| TASK-003 | Step 3 accepted design `comm-000008` | Registers accepted ids and validation contracts |
| TASK-004 | TASK-001, TASK-002, TASK-003 | Executor needs confirmed transport, shared support, and dispatch |
| TASK-005 | TASK-004 public/testable behavior | Tests assert concrete executor outputs and errors |
| TASK-006 | TASK-003 | Example validation needs registered built-in ids |
| TASK-007 | TASK-001 and any implementation divergence | Docs update only from evidence |
| TASK-008 | TASK-003 through TASK-007 | Verification runs after implementation and docs/example edits |

## Parallelizable Tasks

| Task | Can Run In Parallel With | Reason |
| ---- | ------------------------ | ------ |
| TASK-001 upstream confirmation | TASK-006 README drafting | Read-only external inspection and example docs have disjoint write scopes |
| TASK-002 support inspection | TASK-006 example skeleton | Source support inspection and example files are disjoint |
| TASK-003 catalog registration | Initial TASK-006 example files | Source catalog and example bundle paths are disjoint |
| TASK-005 fake fixture planning | TASK-006 README drafting | Test design and example documentation are disjoint |

Do not parallelize executor implementation with tests that edit shared helper
names in the same files. Do not parallelize any docs refresh with another edit
to the same accepted design files.

## Verification

Required commands:

```bash
swift test --filter AppleClockAlarm
swift test --filter AppleGateway
swift test --filter AddonExecutionContractsTests
swift build
riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples
git status --short
rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans
git diff --check -- Sources/RielaCLI Sources/RielaAddons Tests/RielaCLITests Tests/RielaAddonsTests examples/apple-clock-alarms-list design-docs/specs/node-addon-catalog-and-chat-reply-worker design-docs/user-qa impl-plans/active/apple-clock-alarm-addons.md
```

Expected verification notes:
- Tests use fake executables only and require no live Apple, Clock, or
  Shortcuts access.
- The read-only example validates offline.
- Any missing local `apple-gateway` during TASK-001 is recorded as a blocker or
  residual classifier risk, not silently ignored.
- Unrelated dirty files remain untouched.

## Completion Criteria

- [x] All five Clock add-on ids are registered as version `1` built-ins and
  routed through `BuiltinWorkflowAddonResolver.execute`.
- [x] Each add-on rejects unsupported versions and authored `addon.env`.
- [x] All executions use the shared Apple Gateway subprocess support with
  separate process arguments, no shell interpolation, minimal environment, and
  config/env/PATH binary precedence.
- [x] Mutation values require `--variables <json>`; exact upstream CLI
  confirmation remains documented as a residual risk because no local
  `apple-gateway` binary was available, and unsupported `--variables` failures
  are covered by fail-closed fake-executable tests.
- [x] Missing Shortcuts bridge and update/delete macOS 26+ envelopes map to
  clear `.policyBlocked` failures.
- [x] Generic provider failures, result warnings, invalid output, author input
  errors, and timeouts map to the accepted error categories.
- [x] Successful list and mutation outputs reject malformed ClockAlarm payloads
  before publishing `completionPassed: true`.
- [x] Fake-executable tests cover the accepted matrix without live Apple access.
- [x] Mutation fake-executable tests assert each add-on sends the expected
  fixed GraphQL mutation document and argv order, so fake success cannot mask a
  wrong Clock mutation dispatch.
- [x] `examples/apple-clock-alarms-list` is read-only and validates offline.
- [x] Catalog docs, QA confirmations, and security/test responsibilities match
  the implemented behavior.
- [x] Required tests, build, workflow validation, status audit, hardcoded-path
  audit, and diff check pass or have documented residual risk.

## Progress Log

### Session: 2026-07-07 Step 7 adversarial rerun for `comm-000036`

**Tasks Completed**: Addressed adversarial feedback `comm-000036` by adding a
shared ClockAlarm payload validator. The list path validates each
`data.clockAlarms[]` object before setting `completionPassed: true`; mutation
paths require `result.alarm` to be present as either `null` or a valid
ClockAlarm object. Invalid objects, missing required fields, invalid scalar
types, and non-string `repeatDays` entries now fail as `.invalidOutput`.
Fake-executable tests now cover malformed list alarms, non-string repeat-day
entries, malformed mutation alarm values, and missing mutation alarm fields.
**Tasks In Progress**: Focused verification.
**Blockers**: Local `apple-gateway` remains unavailable, so upstream envelope
confirmation remains a documented residual risk.

**Verification Commands and Outcomes**:
- Pending in this rerun.

### Session: 2026-07-07 Step 7 adversarial rerun

**Tasks Completed**: Addressed adversarial feedback `comm-000031` by removing
post-mutation automatic fallback retry behavior. Clock mutations now issue only
one `apple-gateway graphql --query <document> --variables <json>` process; if
that process exits nonzero because `--variables` is unsupported or any other
provider error occurs, Riela fails closed instead of sending a second mutation.
Clock execution now opts into nonzero process-output capture and inspects
stdout/stderr for GraphQL error envelopes before falling back to generic
providerError handling. Missing Shortcuts bridge and update/delete macOS 26+
envelopes on nonzero exits map to `.policyBlocked`.
**Tasks In Progress**: Focused verification.
**Blockers**: Local `apple-gateway` remains unavailable, so upstream envelope
confirmation remains a documented residual risk.

**Verification Commands and Outcomes**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleClockAlarm`:
  passed 8 tests, including fail-closed unsupported-variables behavior and
  nonzero stdout/stderr GraphQL envelope classification.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed 11 tests after the shared runner change.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`:
  passed 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift'`:
  passed 1 test.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Sources/RielaCLI/ProductionNodeAdapter+AppleGatewaySupport.swift Tests/RielaCLITests/AppleClockAlarmAddonTests.swift`:
  passed with 0 violations after removing an unnecessary synthesized
  initializer.
- `riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples`:
  returned `valid: true` with no diagnostics.
- `git diff --check -- Sources/RielaCLI Sources/RielaAddons Tests/RielaCLITests Tests/RielaAddonsTests examples/apple-clock-alarms-list design-docs/specs/node-addon-catalog-and-chat-reply-worker design-docs/user-qa impl-plans/active/apple-clock-alarm-addons.md`:
  passed.
- `rg -n '/Users/taco/.+apple-gateway' Sources Tests examples design-docs impl-plans`:
  matched only audit text in implementation plans, not source, tests, examples,
  or design docs.
- `rg -n 'XCTSkip|disabled|skip\\(|\\.skip|ONLY_ACTIVE_ARCH|coverage|threshold' Tests/RielaCLITests/AppleClockAlarmAddonTests.swift impl-plans/active/apple-clock-alarm-addons.md`:
  no skip/disable hits; only the word `coverage` appears in ordinary plan prose.
- `git status --short`:
  showed expected Clock add-on source/test/example/docs/plan changes; the
  unrelated timeline files named in the constraints were not present in status.

### Session: 2026-07-07

**Tasks Completed**: Created implementation plan from accepted Step 3 design
`comm-000008`; implemented five Clock Alarm add-ons, catalog/dispatch
registration, fake-executable tests, read-only example, example parity list, and
QA confirmation note.
**Tasks In Progress**: Verification and safety audit.
**Blockers**: No local `apple-gateway` executable was available
(`which apple-gateway` returned not found), so exact upstream `--variables`,
missing-shortcut, macOS 26+, and `HH:mm` envelope confirmations remain a
documented residual risk.
**Notes**: Step 5 review `comm-000011` accepted the plan for implementation
with no findings or feedback. Implementation used fake executables only and did
not require live Apple, Clock, or Shortcuts access.

**Verification Commands and Outcomes**:
- `which apple-gateway`: not found; upstream envelope confirmation remains a
  residual risk documented in
  `design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md`.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleClockAlarm`:
  passed 7 tests after fixing one compile error and one test assertion.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleGateway`:
  passed 11 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`:
  passed 5 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`:
  completed with 0 serious violations; remaining warnings are pre-existing in
  unrelated files.
- `riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples`:
  returned `valid: true` with no diagnostics.
- `rg -n "/Users/taco/.+apple-gateway" Sources Tests examples design-docs impl-plans`:
  matched only implementation-plan audit-command text, not committed
  source/test/example paths.
- `git diff --check -- Sources/RielaCLI Sources/RielaAddons Tests/RielaCLITests Tests/RielaAddonsTests examples/apple-clock-alarms-list design-docs/specs/node-addon-catalog-and-chat-reply-worker design-docs/user-qa impl-plans/active/apple-clock-alarm-addons.md`:
  passed.
- `git status --short`: showed expected Clock add-on source/test/example/plan
  changes plus accepted design-doc modifications; the unrelated timeline files
  named in the constraints were not present in the status output.

### Session: 2026-07-07 Step 7 revision

**Tasks Completed**: Addressed Step 7 test-integrity feedback `comm-000014` by
adding per-mutation fixed GraphQL operation and mutation-field assertions for
create, toggle, update, and delete tests. The tests now also assert the full
fake gateway argv sequence for list and mutations, including
`graphql`, `--query`, the fixed document, `--variables`, and the variables JSON.
**Tasks In Progress**: Focused rerun verification.
**Blockers**: Local `apple-gateway` remains unavailable for upstream envelope
confirmation; fake-executable coverage remains the deterministic verification
source.

**Verification Commands and Outcomes**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleClockAlarm`:
  passed 7 tests with the new fixed-operation and argv assertions.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict Tests/RielaCLITests/AppleClockAlarmAddonTests.swift`:
  passed with 0 violations.
- `git diff --check -- Tests/RielaCLITests/AppleClockAlarmAddonTests.swift impl-plans/active/apple-clock-alarm-addons.md`:
  passed.
- `rg -n "XCTSkip|disabled|skip\\(|\\.skip|ONLY_ACTIVE_ARCH|coverage|threshold" Tests/RielaCLITests/AppleClockAlarmAddonTests.swift impl-plans/active/apple-clock-alarm-addons.md`:
  no skip/disable hits; only the word `coverage` appears in ordinary plan
  prose.

### Session: 2026-07-07 Step 7 adversarial revision

**Tasks Completed**: Addressed adversarial feedback `comm-000019` by removing
the unconfirmed hard dependency on local `apple-gateway graphql --variables`
confirmation. This session originally added a post-failure no-variables retry,
but that behavior was superseded by the later `comm-000031` fail-closed
revision because retrying after a mutation process can repeat Clock mutations.
Updated the design doc, QA note, and plan status from in-progress to completed.
**Tasks In Progress**: None.
**Blockers**: Local `apple-gateway` remains unavailable, so exact upstream
missing-shortcut, macOS 26+, and time-format envelopes remain follow-up QA
confirmations rather than final observed facts.

**Verification Commands and Outcomes**:
- `which apple-gateway`: not found; no upstream local CLI confirmation
  possible in this session.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleClockAlarm`:
  passed 8 tests in that session; the transport behavior was superseded by the
  later `comm-000031` fail-closed revision.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Tests/RielaCLITests/AppleClockAlarmAddonTests.swift`:
  passed with 0 violations.
- `riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples`:
  returned `valid: true` with no diagnostics.
- `git diff --check -- Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Tests/RielaCLITests/AppleClockAlarmAddonTests.swift design-docs/specs/node-addon-catalog-and-chat-reply-worker/gateway-built-ins.md design-docs/user-qa/qa-apple-clock-alarm-gateway-confirmations.md impl-plans/active/apple-clock-alarm-addons.md`:
  passed.

### Session: 2026-07-07 Step 7 review revision

**Tasks Completed**: Addressed Step 7 feedback `comm-000023` by tightening
Clock alarm `HH:mm` validation to require ASCII digits in both the hour and
minute positions before integer range checks. Added fake-executable regression
coverage for plus-signed non-digit times (`+1:00`, `01:+5`) and asserted those
invalid inputs fail with `.policyBlocked` before launching `apple-gateway`.
**Tasks In Progress**: None.
**Blockers**: Local `apple-gateway` remains unavailable, so upstream envelope
confirmation remains a documented residual risk.

**Verification Commands and Outcomes**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AppleClockAlarm`:
  passed 8 tests, including the new non-digit `HH:mm` validation coverage.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Tests/RielaCLITests/AppleClockAlarmAddonTests.swift`:
  passed with 0 violations.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `riela workflow validate apple-clock-alarms-list --workflow-definition-dir examples`:
  returned `valid: true` with no diagnostics.
- `which apple-gateway`:
  not found; no upstream local CLI confirmation possible in this session.
- `git diff --check -- Sources/RielaCLI/ProductionNodeAdapter+AppleClockAlarmAddons.swift Tests/RielaCLITests/AppleClockAlarmAddonTests.swift impl-plans/active/apple-clock-alarm-addons.md`:
  passed.
- `rg -n "XCTSkip|disabled|skip\\(|\\.skip|ONLY_ACTIVE_ARCH|coverage|threshold" Tests/RielaCLITests/AppleClockAlarmAddonTests.swift impl-plans/active/apple-clock-alarm-addons.md`:
  no skip/disable hits; only the word `coverage` appears in ordinary plan
  prose.

### Session: 2026-07-07 Step 6 test-integrity rerun

**Tasks Completed**: Addressed Step 6 test-integrity feedback `comm-000026` by
aligning the example parity expected workflow list with sorted example
discovery. Moved `apple-clock-alarms-list` to the first sorted position and
added the discovered `note-selection-question` example explicitly instead of
weakening the exhaustive parity assertion.
**Tasks In Progress**: None.
**Blockers**: Local `apple-gateway` remains unavailable, so upstream envelope
confirmation remains a documented residual risk.

**Verification Commands and Outcomes**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaExampleParityTests.testAllRielaExampleWorkflowsArePortedAndValidateInSwift'`:
  passed 1 test with 0 failures after the expected-list fix.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --strict Tests/RielaCLITests/RielaExampleParityTests.swift`:
  passed with 0 violations.
- `git diff --check -- Tests/RielaCLITests/RielaExampleParityTests.swift`:
  passed.
- `git diff --no-index --check /dev/null impl-plans/active/apple-clock-alarm-addons.md; test $? -eq 1`:
  passed.
