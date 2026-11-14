# wh-11: Inactivity-handover director rule and handover notifications

```json
{
  "planId": "wh-11-director-notify",
  "planPath": "impl-plans/active/wh-11-director-notify.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaWork/DeterministicDirector.swift",
    "Sources/RielaCLI/LoopNotificationDispatcher.swift",
    "Tests/RielaWorkTests/DeterministicDirectorHandoverTests.swift",
    "Tests/RielaCLITests/LoopNotificationHandoverTests.swift",
    "impl-plans/progress/wh-11-director-notify.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-11-director-notify.md"
}
```

## Intent and context

Two small policy pieces. (1) When `director.deterministic.handoverOnInactivity` is true, an inactivity violation
yields `Decision.handover(.inactivity)` instead of rerun or stop (design §6.3, R4). (2) A sealed handover notifies
the workflow's LB4 channels when `loop.notifications.on` contains `"handover"` (design §12, R14).
`DeterministicDirectorRules.handoverOnInactivity`, `DecisionKind.handover`, `HandoverReason.inactivity` and
`LoopOutcome.handover` come from wh-01.

Non-goals: applying the decision (wh-03 makes `.handover` require live cancellation) and sealing or calling
the dispatcher (wh-14).

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-11-director-notify/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables

- `DeterministicDirector` (`:77-86`): in the inactivity branch, check `rules.handoverOnInactivity && hasAttemptBudget(input)`
  **before** `rerunOnInactivity`. It returns `DirectorResolution(kind: .handover(.inactivity(stepId: <violation stepId>,
  idleMs: <violation idle ms, or task.guardPolicy.inactivity?.stallTimeoutMs ?? 0>)), rule: "inactivity-handover",
  reason: violation summary, causedBy: [evidenceId])`. Everything else is unchanged.
  If `GuardViolation` has no idle-ms field, use the stall timeout and note that in the progress log.
- `LoopNotificationDispatcher.dispatchHandover(workflow: WorkflowDefinition, payload: HandoverNotificationPayload,
  workflowDirectory: String, workingDirectory: String) async -> [String]`. It returns `[]` unless
  `workflow.loop?.notifications` has channels and `on` contains `"handover"`. Encode the payload like
  `dispatchIfDeclared` (sorted keys, ISO-8601) and reuse the private `dispatch(channel:…outcome: .handover…)`.
  `HandoverNotificationPayload` (in this file): `{outcome: "handover", workflowId, sessionId, taskId, handoverId,
  reasonKind, questionText?, briefHead (first 2048 bytes of the brief, cut on a UTF-8 boundary), locators: [String]
  (HandoverSinkRef.serialized)}`.
- If the `on` values are validated against a hard-coded list (not `LoopOutcome.allCases`) somewhere outside
  writePaths, stop and record an ownership request. Do not edit that file silently.

## Tests

`DeterministicDirectorHandoverTests`: inactivity + `handoverOnInactivity` → `.handover(.inactivity)` with rule
`inactivity-handover`; flag false → today's `inactivity-rerun`/`inactivity-stop`; budget exhausted → the budget
rule wins as today.
`LoopNotificationHandoverTests` (injected transport and command runner, as the existing dispatcher tests do):
`on: ["handover"]` → one webhook post with the payload fields and a brief head of ≤ 2048 bytes; `on: ["accepted"]` → nothing;
a command channel receives the JSON on stdin.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-11-director-notify/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-11-director-notify/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicDirectorHandoverTests|DeterministicDirectorTests|LoopNotificationHandoverTests|LoopNotification" > tmp/work-handover/wh-11-director-notify/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-11-director-notify/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count.

## Done criteria

- [x] The rule and the dispatcher entry point are implemented; the tests pass; the progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-11-director-notify.md`. Archived to `impl-plans/completed/`.
