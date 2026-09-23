# Monja multi-agent collaboration implementation plan

**Status**: Completed
**Design Reference**: ../../design-docs/specs/design-monja-agent-collaboration.md#outcome
**Created**: 2026-09-15
**Last Updated**: 2026-09-15

## Modules

### Authored workflow bundle

```typescript
type PersonaId = "architect" | "skeptic" | "integrator";

interface PersonaOutputMap {
  readonly architect: ArchitectOutput;
  readonly skeptic: SkepticOutput;
  readonly integrator: IntegratorOutput;
}
```

### Monja collaboration runner

```typescript
interface CollaborationRunner {
  run(config: CollaborationConfig): Promise<CollaborationResult>;
}

interface MonjaGateway {
  getTask(taskId: string): Promise<MonjaTask>;
  createRoot(channelId: string, content: string): Promise<MonjaMessage>;
  postTurn(persona: PersonaId, rootId: string, content: string): Promise<MonjaMessage>;
  linkTask(taskId: string, messageId: string): Promise<void>;
  completeTask(taskId: string): Promise<void>;
}

interface RielaSessionRunner {
  start(task: MonjaTask): Promise<string>;
  inspect(sessionId: string): Promise<RielaSessionView>;
}
```

## Module status

| Module | Path | Status | Tests |
| --- | --- | --- | --- |
| Workflow/personas | `examples/monja-agent-collaboration/{workflow.json,nodes/,prompts/}` | Completed | Pass |
| Runner/providers | `examples/monja-agent-collaboration/*.ts` | Completed | Pass |
| Fixture/runbook | `examples/monja-agent-collaboration/{mock-scenario.json,README.md,EXPECTED_RESULTS.md,*test.ts,verify-workflow.ts}` | Completed | Pass |

### TASK-001: Implement workflow and Monja discussion runner

**Status**: Completed
**Parallelizable**: Yes
**Dependencies**: None
**Deliverables**: `examples/monja-agent-collaboration/workflow.json`, persona
node/prompt files, typed runner, Monja adapter, state/reconciliation logic, CLI.

- [x] Three agents have materially distinct system prompts and typed outputs.
- [x] One Riela workflow passes prior outputs to later agents.
- [x] Each accepted turn is posted into one linked Monja task thread.
- [x] Separate persona tokens produce distinct chat authors.
- [x] Completion occurs only after solved synthesis and observable publication.
- [x] Monja credentials are excluded from the Riela child environment.

### TASK-002: Add reproducible fixtures and independent review

**Status**: Completed
**Parallelizable**: No
**Dependencies**: TASK-001
**Deliverables**: deterministic fake Monja fixture, Riela mock scenario,
integration/unit tests, verifier, README, expected results, example indexes.

- [x] Workflow validate and inspect pass using the direct examples root.
- [x] Real Riela CLI mock run proves all three accepted persona outputs.
- [x] Tests prove order, context, tokens, linked thread, retry, and fail-closed behavior.
- [x] Lint, strict typecheck, tests, verification, and independent review pass.

### TASK-003: Live Monja collaboration acceptance

**Status**: Completed
**Parallelizable**: No
**Dependencies**: TASK-002
**Deliverables**: ignored live config/state and sanitized acceptance evidence.

- [x] Create or reuse three distinct scoped Monja bot identities.
- [x] Run a real task through all three Riela agents.
- [x] Verify ordered thread authors/content, linked task, sessions, and final done status.

## Dependencies

| Task | Depends on | Status |
| --- | --- | --- |
| TASK-001 | None | Completed |
| TASK-002 | TASK-001 | Completed |
| TASK-003 | TASK-002 | Completed |

## Completion criteria

- [x] All three tasks completed.
- [x] Deterministic and live evidence satisfy the design.
- [x] No credentials or workstation-specific paths are committed.

## Progress log

### 2026-09-15

Designed a three-persona workflow with a credential-isolated Monja discussion
projection. TASK-001 begins through the required implementation/review workflow;
the existing dirty worktree is preserved.

### 2026-09-15: TASK-001 and TASK-002 completed

Implemented the three fresh-session persona workflow, API-only Monja
coordinator, credential-isolated child execution, canonical publication
reconciliation, and deterministic fixtures. The required implementation,
check-and-test, and review cycles completed with review iteration 2 approved.
Verification passed with 21 tests and 62 assertions, 99.47% function coverage,
98.58% line coverage, and successful actual-CLI validate, inspect, and mock-run
checks. Live acceptance remains tracked in TASK-003.

### 2026-09-15: TASK-003 completed

The final API-only acceptance run used three distinct scoped Monja bot authors
and three real `gpt-5.6-luna` executions. The canonical thread contains one
linked root and three ordered persona replies; accepted-output deep equality
proved the Aster-to-Flint and cumulative Flint-to-Mira handoffs. Mira returned
`solved: true`, no unresolved blockers, and ten testable acceptance criteria,
after which the task reached done. Sanitized evidence is recorded in
`design-docs/specs/design-monja-agent-collaboration-live-acceptance.md`.
