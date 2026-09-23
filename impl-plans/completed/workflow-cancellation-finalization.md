# Workflow cancellation finalization

**Status**: Completed
**Design Reference**: ../../design-docs/specs/design-monja-project-task-orchestrator.md#coordination
**Created**: 2026-09-14
**Last Updated**: 2026-09-14

### TASK-001: Persist cancelled execution before acknowledging stop

**Status**: Completed
**Parallelizable**: Yes
**Dependencies**: None
**Deliverables**: `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`,
`Tests/RielaCLITests/WorkflowCommandAutoImproveTests.swift`

- [x] Cancellation finalization runs without inheriting the cancelled task flag.
- [x] Task-local context and original cancellation error remain intact.
- [x] Actual CLI cancellation without auto-improve persists failed/cancelled state.
- [x] Targeted regression and example subprocess cancellation verifier pass.

## Progress log

### 2026-09-14

Example verifier reproduced SIGTERM exiting the CLI while its SQLite session and
step remained running. The runner calls terminal finalization in a cancelled
Swift task; SQLite WAL initialization checks cancellation and rejects the write.
Existing core cancellation tests throw CancellationError without actually
cancelling a Swift task, so they do not cover the persisted failure.

The explicitly awaited unstructured task preserves task-local values and runs
only terminal finalization outside the parent's cancellation flag. The runner
continues to throw the original error. New CLI regression passed; four nearby
core/auto-improve cancellation tests passed. The rebuilt CLI passed the example's
real subprocess SIGTERM test independently (verification run-QSAVgY), with a
persisted failed session and cancelled failure kind. No external issue published;
local reproduction report is retained under tmp/monja-project-task-orchestrator.
