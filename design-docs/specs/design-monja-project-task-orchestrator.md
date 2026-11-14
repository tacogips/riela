# Monja project task orchestration

Live verification evidence: [deployed acceptance](design-monja-project-task-live-acceptance.md).

## Overview

Deploy the sibling Monja service on Cloudflare, then provide a runnable example
under `examples/monja-project-task-orchestrator`. Project A owns one Kanban;
directories represent subprojects. Riela maps that project to one or more local
directories and optional GitHub repositories. Include real fixture directories.

## Execution contract

A newly registered Monja task triggers a durable receipt and a notification to
the configured Monja chat channel. Reconcile the project's current todo and doing
tasks before scheduling. Persist the task decomposition, goal and generated
temporary workflow in the Monja task before claiming/starting work. Notify chat
at start, progress and completion, and mirror progress/completion to a configured
Wrike task. Use only `codex-agent` with `gpt-5.6-luna` in this example's planner
and generated agent nodes. Real deployments choose nodes/models per task.

The implementation must execute the generated temporary workflow through Riela,
not merely print a plan. Retain session IDs, results and failure evidence.
Completion requires successful execution evidence and verification; failures
must never transition a task to done. Credentials remain environment-only.

## Coordination

Support wait, pause-and-merge, and independent parallel execution. Decisions
consider goal overlap, dependencies and repository/directory write conflicts.
Wait when active work is unrelated but conflicts or cannot safely pause. Merge
only after actual execution cancellation/pause acknowledgment; update the owning
task's content, goal and workflow, preserving absorbed-task links and checkpoint
evidence, then execute a new generation. Parallel work requires disjoint write
scopes or isolated worktrees. A durable project scheduler lease and event/run
deduplication prevent concurrent dispatch and duplicate work. A live process or
session check governs recovery; timeout alone must not restart running work.

## Reproducibility

Ship fixture project mappings, local source directories, task-registration
payloads, fake HTTP Monja/Wrike services, deterministic planner/executor seams,
and an executable verifier. Verify receipt -> plan persisted -> doing/start ->
progress -> completion ordering, generated temporary workflow validity, all
coordination branches, duplicate events, crash/restart and failed notifications.
Include a local real-Monja smoke path and live configuration instructions.
Fixture success and live/deployed success must be reported separately.
