# Monja project task orchestrator implementation plan

**Status**: Completed
**Design Reference**: ../../design-docs/specs/design-monja-project-task-orchestrator.md#execution-contract
**Created**: 2026-09-14
**Last Updated**: 2026-09-14

## Deliverables

Implement `examples/monja-project-task-orchestrator/` with workflow/node/prompt
files, typed orchestration and provider adapters, fixture project directories,
event inputs, deterministic integration tests and a verifier/runbook.
Public boundaries: project configuration, task event, scheduler decision,
provider adapter, temporary workflow executor and durable scheduler state.
No implementation bodies belong in this plan.

### TASK-001: Runnable example and reproducible fixture

**Status**: Completed
**Parallelizable**: Yes
**Dependencies**: None
**Deliverables**: `examples/monja-project-task-orchestrator/**`

- [x] Task registration triggers receipt notification and todo reconciliation.
- [x] Project mappings include multiple local directories and optional repositories.
- [x] Decomposition/goal/temporary workflow persist in Monja before execution.
- [x] All example agent nodes explicitly use Codex gpt-5.6-luna.
- [x] Real Riela temporary execution reports session/result evidence.
- [x] Start/progress/completion update Monja chat and Wrike as designed.
- [x] Wait, acknowledged pause/merge/restart and parallel decisions are executable.
- [x] Durable deduplication/recovery and notification failures are tested.
- [x] Fixture verifier, workflow validation, typecheck and independent review pass.

### TASK-002: Deployed integration acceptance

**Status**: Completed
**Parallelizable**: No
**Dependencies**: TASK-001
**Deliverables**: README live runbook and deployment acceptance evidence

- [x] Monja Cloudflare URL and deployment/migration IDs verified.
- [x] Project A Kanban is project-bound and subdirectories work.
- [x] End-to-end live task registration/execution/notifications verified.

## Progress log

### 2026-09-14

Existing Monja workspace/project changes inspected. Cloudflare configuration
contains placeholder D1/VPC IDs; deployment credentials being checked separately.
No prior example implements this complete contract. TASK-001 implementation
begins alongside Cloudflare readiness work in the sibling Monja checkout.

### 2026-09-14: API contract inspection

TASK-001 implementation is running through the required TypeScript agent.
Current Riela is Swift and installed CLI version is 0.1.38: temporary workflow
JSON is a positional `workflow run` target. Steps use `transitions` with
`toStepId`; live JSONL reports session identity. Cancellation uses SIGTERM and
must await session `failed` with `failureKind: cancelled` before merge/restart.
Monja maps user-facing todo/doing to API `open`/`in_progress`; task descriptions
and task comments each have an 8000-character limit. Webhook HMAC signs the
timestamp prefix and exact request bytes. These boundaries are being applied
to real adapters and fixture expectations before verification.

### 2026-09-14: Executable fixture and cancellation gate

The standalone example now has strict TypeScript configuration and pinned Bun
dependencies, twelve initial behavior tests, native HTTP adapters, continuous
registration discovery, and real temporary workflow execution. A real CLI mock
run completed `work-0`, `work-1`, and `verify` with positive verification evidence
in `tmp/monja-project-task-orchestrator-verification/run-DA0fRv/verification.json`.
Independent checking and review remain pending while automatic Wrike counterpart
provisioning is added.

An actual SIGTERM test exposed a Riela runtime defect: the process exited after
cancellation but persisted session status remained running. The example correctly
refused pause acknowledgment; the verifier retains this failing acceptance gate.
Root is investigating the Swift cancellation finalization path while example
implementation continues. This does not count as successful merge verification.

### 2026-09-14: Independent verification

The Swift cancellation finalizer fix passed its targeted regression, and the
rebuilt CLI passed the example's unchanged real SIGTERM acknowledgment gate.
Independent checking passed Biome, strict typecheck, and all 15 tests with 64
assertions (98.29% function and 99.68% line coverage). The full real CLI verifier
passed at `tmp/monja-project-task-orchestrator-verification/run-QSAVgY`, including
completed work/verification steps and persisted cancellation failure kind.
Automatic Wrike mirror creation and ambiguous-response reconciliation are now
implemented and tested. Final independent TypeScript review is in progress;
TASK-001 remains open until its review findings are resolved.

### 2026-09-14: Review iteration 1

Independent review requested five fixes: atomically persist terminal observations
and notification intents; persist merge intent before cancellation and reconcile
delayed acknowledgment; retain explicit prior session/generation/artifact
checkpoints in merged work; close a path-overlap check bypass for child names
beginning `..`; and exercise executor exit-persistence failure recovery. These
fixes are being implemented with targeted regressions. The review did not approve
TASK-001 despite previously passing automated checks.

### 2026-09-14: Review fixes independently verified

All five requested fixes are implemented. Independent verification passed lint,
strict typecheck, 23 tests with 94 assertions, and 100% function/line coverage.
The full real CLI verifier passed execution and cancellation at
`tmp/monja-project-task-orchestrator-verification/run-Wo6rDT`. Regressions cover
atomic state/outbox rollback, durable merge intent after signal/crash, delayed
acknowledgment and completion races, checkpoint persistence, path overlap,
expanded scopes/dependencies, and exit-receipt failure recovery. Review iteration
2 is in progress; the final review criterion remains open.

### 2026-09-14: Completion

**Tasks Completed**: TASK-001, TASK-002.
**Review Iterations**: 2; iteration 2 APPROVED with no remaining critical findings.
**Final Verification**: Independent lint/typecheck, 23 tests and 94 assertions,
100% function/line coverage, real Riela temporary execution and actual SIGTERM
acknowledgment all passed. Final verifier evidence:
`tmp/monja-project-task-orchestrator-verification/run-Wo6rDT`.

The [live acceptance record](../../design-docs/specs/design-monja-project-task-live-acceptance.md)
documents Cloudflare version `3695fdba-0d5f-42c0-b08b-3111ce4188c5`, eleven applied
migrations, project-scoped Kanban/subdirectories, and two completed real Luna
tasks with Monja/Wrike/chat evidence. The second registration automatically
created its Wrike counterpart without a per-task mapping. A final read-only
scheduler inspection independently confirmed both live runs succeeded, their
session IDs persisted, the automatic Wrike mapping exists, and the outbox is
empty. Test listeners are stopped; the deployment remains available. The
source-built Riela cancellation fix is commit `43edf93`.

Plan archived under `impl-plans/completed/`; root updates progress/index files.
