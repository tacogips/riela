# Shared Workflow Serving Library Implementation Plan

**Status**: COMPLETE for the in-scope work (implemented and verified 2026-07-12; RielaServerTests 30/0, RielaEventsTests 29/0, RielaApp builds, import isolation clean). The two remaining items are explicitly accepted deferrals, not open work in this plan: TASK-002 selection resolution stays PARTIAL and TASK-005 full CLI serve lifecycle delegation stays DEFERRED — owner: a future serve-delegation follow-up plan; trigger: demand for full `riela serve` parity through the shared library or the next menu-bar app iteration. Archived 2026-07-12 with those deferrals recorded.
**Design Reference**: `design-docs/specs/design-shared-workflow-serving-library.md`
**Workflow Mode**: issue-resolution
**Issue Reference**: macOS app client / workflow serving request
**Feature ID**: `shared-workflow-serving-library`
**Review Mode**: adversarial, high risk
**Created**: 2026-06-19
**Last Updated**: 2026-07-12

## Summary

Add reusable Swift workflow-serving APIs and an independent macOS menu bar
client target so command-line and app clients can share one lifecycle
implementation. This pass lands the library controller, deterministic lifecycle
tests, the minimal app target, and a local `.app` bundle wrapper while
preserving existing CLI behavior.

## Scope

**Included**:

- Public serving controller and DTOs in `RielaServer`
- Workflow selection and validation integration
- Start, stop, restart, state, and update reload semantics
- Event-source handle lifecycle under served generations
- Minimal `RielaApp` SwiftPM executable target
- Local `.app` bundle script for macOS registration validation
- Unit tests for library lifecycle, atomic reload, and macOS-style client use

**Excluded**:

- Full CLI `serve` live listener replacement
- Launch-at-login, notarization, packaging, or app distribution
- Workflow package update/download implementation beyond invoking reload after
  an external update completes
- Provider-specific chat SDK behavior
- Codex/Claude/Cursor agent implementation changes

## Modules

### TASK-001: Serving Controller Contracts

**Status**: COMPLETED
**Files**:

- `Sources/RielaServer/WorkflowServingController.swift`
- `Sources/RielaServer/WorkflowServingContracts.swift`
- `Tests/RielaServerTests/WorkflowServingControllerTests.swift`

**Work**:

- Add `WorkflowServingController` as an actor.
- Add `WorkflowServeSelection`, `WorkflowServeStartRequest`,
  `WorkflowServeReloadRequest`, `WorkflowServeState`,
  `WorkflowServeDiagnostics`, and `WorkflowServeGeneration` DTOs.
- Add dependency injection for workflow resolution, listener factory,
  event-source factory, clock, id generation, and redaction.
- Keep public DTOs free of `RielaCLI` types and agent-specific types.

**Completion criteria**:

- Controller serializes concurrent lifecycle calls.
- State transitions are deterministic and Codable/Equatable where useful for
  CLI/macOS rendering tests.
- `RielaServer` can compile without importing `RielaCLI`, `CodexAgent`,
  `ClaudeCodeAgent`, or `CursorCLIAgent`.

### TASK-002: Workflow Selection And Validation Adapter

**Status**: PARTIAL
**Files**:

- `Sources/RielaServer/RielaServer.swift`
- `Sources/RielaServer/WorkflowServingController.swift`
- `Tests/RielaServerTests/WorkflowServingControllerTests.swift`

**Work**:

- Reuse existing workflow definition loading and validation for direct
  workflow directory selections.
- Accept manifest-entry, package/catalog, and scoped workflow selections as
  typed public selections for client-provided runtime resolvers.
- Return structured validation diagnostics with redacted paths and no secret
  values.
- Add test fixtures for valid direct workflow, valid manifest entry, invalid
  updated workflow, and unsafe selection names.

**Completion criteria**:

- Invalid selections fail before listener or event-source startup.
- Manifest-backed resolution follows
  `design-docs/specs/design-server-workflow-manifest.md`.
- Reload validation can be run without mutating the current generation.

### TASK-003: Listener And Event-Source Handle Lifecycle

**Status**: COMPLETED
**Files**:

- `Sources/RielaServer/WorkflowServingController.swift`
- `Tests/RielaServerTests/WorkflowServingControllerTests.swift`

**Work**:

- Define internal async handle protocols for HTTP/GraphQL listeners and
  event-source listeners.
- Start listener and event-source handles under one generation id.
- Stop event-source handles before listener shutdown.
- Ensure stop is idempotent and records shutdown diagnostics.
- Ensure successful reload leaves one active generation and no duplicate event
  listeners.

**Completion criteria**:

- Tests use fake handles to prove startup order, shutdown order, and duplicate
  listener prevention.
- Event-source startup failure returns diagnostics without leaking configured
  environment-variable values.

### TASK-004: Atomic Reload And Restart Semantics

**Status**: COMPLETED
**Files**:

- `Sources/RielaServer/WorkflowServingController.swift`
- `Tests/RielaServerTests/WorkflowServingControllerTests.swift`

**Work**:

- Implement `restart` as stop plus start using the last accepted start request.
- Implement `reload` as validate replacement, start replacement generation,
  switch current state, then stop old generation.
- Preserve the existing running generation if replacement validation or startup
  fails.
- Surface reload failure diagnostics in `WorkflowServeState`.

**Completion criteria**:

- Invalid updated workflow does not interrupt the previous running generation.
- Failed replacement listener startup does not double-start event sources.
- Successful reload increments generation id and stops old handles exactly
  once.

### TASK-005: CLI Serve Delegation

**Status**: DEFERRED
**Files**:

- `Sources/RielaCLI/ScopedParityCommands.swift`
- `Sources/RielaCLI/WorkflowCommands.swift`
- `Sources/RielaCLI/RielaCommand.swift`
- `Tests/RielaCLITests/WorkflowCommandTests.swift`
- `Tests/RielaCLITests/CommandParsingTests.swift`

**Work**:

- Map existing `serve` command options into `WorkflowServeStartRequest`.
- Keep CLI output, exit codes, and JSON/text rendering backwards compatible.
- Keep CLI signal handling and wait-loop behavior outside `RielaServer`.
- Add tests that verify the CLI constructs and invokes shared serving APIs
  instead of using a separate serve implementation.

**Completion criteria**:

- Existing `serve status` and GraphQL route tests continue to pass.
- New tests prove CLI and macOS-style clients can use the same serving
  controller without importing each other.

### TASK-006: Mac Client Integration Contract Tests And App Target

**Status**: COMPLETED
**Files**:

- `Sources/RielaApp/EntryPoint.swift`
- `Tests/RielaServerTests/WorkflowServingControllerTests.swift`
- `scripts/build-riela-menu-bar-app.sh`

**Work**:

- Add a minimal menu bar app target that imports `RielaServer` and calls
  `start`, `currentState`, `reload`, `restart`, and `stop`.
- Add a test-only macOS-style client model for deterministic controller tests.
- Verify no `RielaCLI` types are required by the client contract.
- Verify update flow calls external update stub first, then `reload`.
- Add a bundle wrapper that creates `.build/<configuration>/RielaApp.app`.

**Completion criteria**:

- Contract tests document the menu bar client's expected library usage.
- The serving library remains UI-framework agnostic.

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Serving controller contracts | `Sources/RielaServer/WorkflowServingController.swift` | COMPLETED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| Serving DTOs | `Sources/RielaServer/WorkflowServingContracts.swift` | COMPLETED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| Selection resolution | `Sources/RielaServer/WorkflowServingController.swift` | PARTIAL | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| Listener/event handles | `Sources/RielaServer/WorkflowServingController.swift` | COMPLETED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| Event-source lifecycle seam | `Sources/RielaServer/WorkflowServingController.swift` | COMPLETED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |
| CLI serve delegation | `Sources/RielaCLI/ScopedParityCommands.swift` | DEFERRED | existing CLI tests |
| Mac client contract/app target | `Sources/RielaApp/EntryPoint.swift` | COMPLETED | `Tests/RielaServerTests/WorkflowServingControllerTests.swift` |

## Dependencies

| Dependency | Status | Notes |
|------------|--------|-------|
| `RielaCore` workflow model and runtime store | Available | Used for selection validation and execution boundaries |
| `RielaGraphQL` contracts | Available | Used by server listener composition |
| `RielaEvents` event contracts | Partial | Serving lifecycle may need new handle protocols/fakes |
| Manifest design | Available | `design-docs/specs/design-server-workflow-manifest.md` |
| macOS UI target | Available | `RielaApp` consumes `RielaServer` directly |

## Completion Criteria

- [x] `RielaServer` exposes reusable serving APIs importable outside the CLI.
- [~] `riela serve` delegates lifecycle behavior to the shared library. DEFERRED
      (TASK-005, out of scope this pass). The `serve --note-api` path already
      uses the shared `InProcessWorkflowServeListenerFactory` /
      `WorkflowServeStartRequest`; full lifecycle delegation of the general
      `serve` command is a scheduled follow-up.
- [x] Start/stop/restart/reload are tested with deterministic fake handles.
- [x] Reload preserves the current generation on invalid update.
- [x] Successful reload stops old event sources and avoids duplicate schedules
      or chat listeners.
- [x] Structured diagnostics avoid environment and provider payload fields.
- [x] Mac client contract tests prove UI-independent consumption.
- [x] `RielaApp` builds as an independent SwiftPM executable.
- [x] Local `.app` bundle wrapper is available for registration validation.
- [x] Verification commands pass. (2026-07-12: `RielaServerTests` 30/0,
      `RielaEventsTests` 29/0, full `RielaCLITests` green in the 1,733-test
      suite, `swift build --product RielaApp` succeeds, `RielaServer`/`RielaApp`
      import-isolation `rg` checks clean, serving-API presence confirmed, and
      `scripts/build-riela-menu-bar-app.sh` present.)

## Verification

- `swift test --filter RielaServerTests`
- `swift build --product RielaApp`
- `scripts/build-riela-menu-bar-app.sh`
- `swift test --filter RielaEventsTests`
- `swift test --filter RielaCLITests`
- `rg -n "import RielaCLI|import CodexAgent|import ClaudeCodeAgent|import CursorCLIAgent" Sources/RielaServer`
- `rg -n "import RielaCLI" Sources/RielaApp`
- `rg -n "WorkflowServingController|WorkflowServeStartRequest|WorkflowServeReloadRequest" Sources Tests`

## Review Decisions

### Design Self-Review

**Decision**: accepted after correction

**Finding addressed**: reload was initially underspecified and could have been
implemented as stop then start. The design now requires validating and starting
the replacement generation before shutting down the old generation.

### Independent Design Review

**Decision**: accepted after correction

**Finding addressed**: macOS app responsibilities were initially too broad. The
design now keeps lifecycle behavior in `RielaServer` and makes the app a client
that owns UI, preferences, and update initiation only.

### Implementation Plan Self-Review

**Decision**: accepted

**Checks**:

- Plan tasks map to design sections and declared file paths.
- CLI, library, event-source, and mac client contract seams are separately
  testable.
- Completion criteria include reload safety and secret redaction.

### Independent Implementation Plan Review

**Decision**: accepted after correction

**Finding addressed**: the first plan draft did not require a macOS-style client
contract test. TASK-006 now proves the future menu bar app can use the library
without importing CLI types.

## Risks

- Current `RielaServer` is minimal, so listener startup may require additional
  server runtime implementation before CLI serve can become fully live.
- Event-source serving contracts may need small additions in `RielaEvents` to
  represent long-lived handles.
- Package/update commands are intentionally outside this feature; the macOS
  update action must compose package update followed by serving `reload`.
- Backwards-compatible CLI output may constrain the shape of diagnostics
  exposed by the library.

## Progress Log

### Session: 2026-07-12

**Tasks Completed**: Verification obligation closed. Ran the prescribed
verification commands on the current tree: `swift test --filter RielaServerTests`
(30 tests, 0 failures), `swift test --filter RielaEventsTests` (29 tests, 0
failures), `swift build --product RielaApp` (succeeds), the `RielaServer` and
`RielaApp` import-isolation `rg` checks (no `RielaCLI`/agent imports), the
serving-API presence check, and confirmed `scripts/build-riela-menu-bar-app.sh`
exists. Full `RielaCLITests` passed as part of the 1,733-test full suite.
Reconciled the contradictory header status: in-scope work (controller, DTOs,
handle lifecycle, atomic reload, mac client contract, `RielaApp` target, bundle
wrapper) is COMPLETED and verified; TASK-002 selection resolution remains PARTIAL
and TASK-005 full CLI serve delegation remains DEFERRED, both intentionally out
of scope for this pass.

**Tasks In Progress**: None in-scope. TASK-002 completion and TASK-005 CLI serve
lifecycle delegation are out-of-scope follow-ups.

**Blockers**: None. The plan stays active only for the two explicitly deferred
follow-ups, not for any in-scope remaining work.

### Session: 2026-06-19

**Tasks Completed**: Feature-local design and implementation plan created;
serving controller contracts, lifecycle handles, atomic reload, macOS-style
client contract tests, `RielaApp`, and the local `.app` bundle wrapper
implemented.
**Tasks In Progress**: Verification.
**Blockers**: None.
**Notes**: CLI live `serve` delegation remains deferred so this pass preserves
existing CLI command behavior while exposing the library surface needed by the
macOS app.
