# Scheduled Overlap Policy: Open Decisions

Design: `design-docs/specs/design-scheduled-overlap-policy.md`

Implementation can go ahead with each recommended decision below. Each
question records an interpretation that the user may want to override.

## Q1: Representation of a cancelled run

The intake asks that a run cancelled by `cancelRunning` end "in a cancelled
terminal status owned by the runtime store".

What the runtime does today (`main` @ `3e6d4adf`): `WorkflowSessionStatus` has
no `cancelled` case. A cancelled run is persisted as `status: failed`,
`failureKind: cancelled` and `failureReason: "workflow run cancelled"`. The
`WorkflowSessionFailureKind.cancelled` value is in
`Sources/RielaCore/RuntimeSession.swift`. P1 of
`design-cancellation-and-orphan-session-resilience.md` is not implemented.

Recommended decision: reuse `failed` + `failureKind: cancelled` as the
runtime-owned cancelled terminal state. The event receipt for the run gets the
explicit status `cancelled`. Adding `WorkflowSessionStatus.cancelled` is a
cross-surface migration covering GraphQL, the web UI, status filters and
supervision. It should stay with the cancellation design.

## Q2: Skill docs outside this repository

The intake asks for updates to the `riela-event-sources` and `riela-workflow`
skill docs. Neither `SKILL.md` is tracked in this repository. `git ls-files
'*SKILL.md'` lists only `.agents`, `.codex` and
`Resources/skills/riela-workflow-{reference,run}`, and the `riela-workflow`
skill dirs under `.claude/` and `.codex/` are gitignored.

Recommended decision: keep the in-repo docs to the design doc,
`event-listener-workflow-trigger/provider-source-types.md` and
`routine-management.md`. Apply the ready-made delta in design §13 wherever
those skills are maintained, which is likely the `riela-packages` registry, in
a separate change. This run is local-only (`gitPush=false`) and must not
modify unrelated repositories.

## Q3: Default `maxQueuedRuns` and concurrency cap

Recommended decision: `maxQueuedRuns` defaults to `1`. `concurrent` has no cap
unless `maxConcurrentRuns` is set, matching the intake's "optional cap".
Overflow in both cases is drop-newest and recorded.
