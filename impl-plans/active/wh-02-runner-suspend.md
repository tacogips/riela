# wh-02: Runner suspend, envelope extraction, resume from suspended

```json
{
  "planId": "wh-02-runner-suspend",
  "planPath": "impl-plans/active/wh-02-runner-suspend.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaCore/AdapterContracts.swift",
    "Sources/RielaCore/RuntimeOutputCandidate.swift",
    "Sources/RielaCore/RuntimePublication.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Suspend.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift",
    "Sources/RielaCLI/FailClosedSQLiteWorkflowRuntimeStore.swift",
    "Sources/RielaCLI/SessionObservabilityRendering.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerSuspendTests.swift",
    "Tests/RielaCLITests/SessionResumeSuspendedTests.swift",
    "impl-plans/progress/wh-02-runner-suspend.md"
  ],
  "sharedPaths": [
    "Sources/RielaCore/RuntimeStore.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
    "Sources/RielaCLI/SessionCommands.swift",
    "Sources/RielaCLI/WorkflowRunCommand.swift"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/RuntimeStore.swift", "intendedEdit": "Add `suspendSession(_:)` to the WorkflowRuntimeStore protocol with a throwing default in the existing protocol extension (as importAcceptedHistory does), implement it in InMemoryWorkflowRuntimeStore, and clear `session.suspend` where the store moves a session back to `.running` (around line 489). wh-01 only added switch arms here."},
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift", "intendedEdit": "Add `emitHandoverEvent(...)`, modelled on the existing silence/step event emitters."},
    {"path": "Sources/RielaCLI/SessionCommands.swift", "intendedEdit": "Resume handling for suspended sessions only (question gate, answer message injection, exit code). `session handover` is wh-15."},
    {"path": "Sources/RielaCLI/WorkflowRunCommand.swift", "intendedEdit": "Map runner exit code 5 to CLIExitCode.suspended (line ~307 already uses CLIExitCode(rawValue:)); print the suspend hint in text output. wh-14 later adds task hooks."}
  ],
  "progressLog": "impl-plans/progress/wh-02-runner-suspend.md"
}
```

## Intent and context

A step whose accepted output carries the reserved `handover` envelope must stop the
run cleanly. The session becomes `suspended` with a `SuspendRecord`, the step
execution is `suspended` (or `completed` when it resumes downstream), and a `handover` run
event is emitted. `session resume` continues from the resume step. This is the plain-session half of
design §3.3, §6.1 and §10.5 and of R20–R22. Task sealing is wh-14.

Non-goals: packet building, the Work store, CLI `session handover`, the
`riela/handover-request` add-on (wh-14), and history import (wh-05).

## Execution rules

Follow the umbrella common execution contract: hashes and intent snapshots in
`tmp/work-handover/wh-02-runner-suspend/`, writePaths only, arm64 foreground logs, no git
state changes, and only this plan's progress log.

## Deliverables

1. **Extraction.** Add
   `func extractHandoverEnvelope(_ payload: JSONObject, source: String) throws -> (payload: JSONObject, handover: HandoverEnvelope?)`
   to `RuntimeOutputCandidate.swift`. It removes the `handover` key, then calls `HandoverEnvelope.parse`.
   `RuntimeOutputCandidate` gains `handover: HandoverEnvelope?`. `normalizeRuntimeAdapterOutput`,
   `normalizeRuntimeInlineCandidate` and `DefaultCandidatePathReader.readCandidate` apply it to the
   **normalized** payload, after `normalizeOutputContractEnvelope`.
   **Do not** strip `handover` inside `normalizeOutputContractEnvelope` itself.
   `AgentGatewayNodeAdapter.swift:737` also calls that function, and stripping there would lose the envelope.
   `AdapterContracts.swift` changes only if a shared helper belongs there. Otherwise leave it.
2. **Publication (`RuntimePublication.swift`).** `WorkflowPublicationResult` gains `handover: HandoverEnvelope?`.
   In `publishAcceptedOutput`, when the candidate has an envelope:
   - `resumeStepId` is nil or equal to the declaring step: **do not** validate or publish the business
     payload. Update the step execution to status `.suspended` with no accepted output and no messages,
     and return with `nextStepId = nil` and `handover` set.
   - `resumeStepId` names another step: validate and publish exactly as today. Then require
     `resumeStepId == result.nextStepId`. If it is not, throw `AdapterExecutionError(.invalidOutput,
     "handover.resumeStepId must be the selected next step")` *before* commit, so the normal
     validation-rejection path applies.
3. **Runner (`DeterministicWorkflowRunner.swift`, new `+Suspend.swift`).**
   - `DeterministicWorkflowRunRequest` gains
     `boundaryHandover: (@Sendable (_ nextStepId: String) async -> SuspendRecord?)?` (R22). After each
     accepted publication whose `nextStepId != nil`, call it. A non-nil record suspends the session
     with `stepId = nextStepId` before that step starts.
   - When `publishResult.handover != nil`, build a `SuspendRecord`: `reasonKind` from the envelope,
     `stepId = resumeStepId ?? step.id`, `stepExecutionId = publishResult.stepExecution.executionId`,
     question/presence/progressNote copied, `producer = .stepExecution(executionId)`, and `suspendedAt = now`.
   - `suspendSession(_ record:)` in the new file: call `store.suspendSession`, emit `.handover`, then emit
     `.sessionCompleted` with status `suspended`. Live persistence and JSONL consumers terminate on
     that event, so keep emitting it. Call `finishOwnedWorkflowRun` and return a `WorkflowRunResult`
     with `status .suspended` and `exitCode 5`. Do **not** call `recordTerminalFinalization`, because the session is not terminal.
   - `store.suspendSession(WorkflowSessionSuspendInput {sessionId, record, now})` sets `status = .suspended`,
     `suspend = record`, `currentStepId = record.stepId` and `updatedAt`. Define the input type in `RuntimeStore.swift`.
     `FailClosedSQLiteWorkflowRuntimeStore` forwards it and persists, like `markSessionFailed` (`:103`).
4. **Resume (`+Recovery.swift`).** `resolveResumeEntry` proceeds for `.suspended` and uses
   `currentStepId = existing.suspend?.stepId ?? existing.currentStepId`. The store clears `suspend` when the
   step starts (the RuntimeStore note). A suspended session is never `.terminal`.
5. **CLI.**
   - `WorkflowRunCommand`: exit code 5 → `.suspended`. In text output, print to stderr:
     `session <id> suspended at <stepId>: <question text | presence instructions>`, then
     `hand over: riela session handover <id>`, then
     `answer and resume: riela session resume <id> --variables '{"handover":{"answer":{…}}}'`.
     The structured JSON output is unchanged apart from the status value.
   - `SessionCommands` resume: if `session.suspend?.question != nil` and the parsed `--variables` have no
     `handover.answer`, print the question, its options and the hint, and return `.suspended` **without running**.
     If an answer is supplied, append a `delivered` message `{ "handover": { "answer": <payload> } }`
     to `suspend.stepId` through the runtime store (`appendWorkflowMessage`, `fromStepId = nil`,
     `sourceStepExecutionId = suspend.stepExecutionId ?? "handover-answer"`) before resuming. Keep the
     variable as well. Pitfall: `blocksResume` must stay false for suspended sessions.
   - `SessionObservabilityRendering`: `session status/progress/export` render `suspended` plus
     `resumeStep`, `reason` and `question` in both text and JSON.

## Existing code to imitate

`markSessionFailed` (store API and forwarding); `emitSessionCompletedEvent` and the silence event emission;
`resolveResumeEntry`'s maxStepsExceeded branch; `normalizeRuntimeAdapterOutput`.

## Pitfalls

- The mock `ScenarioNodeAdapter` returns `payload` verbatim, so a mock `payload.handover` must be
  extracted by the runtime normalization path. Test this.
- With the default resume, the declaring step's execution count increases. On resume, the same step
  runs again (executionIndex+1). Do not reuse the suspended execution.
- Never mark the session `failed` on the envelope path. `finalizeInterruptedSessionFailed` must not run,
  because this is not an error path.
- `maxValidationAttempts` retries apply only to malformed envelopes. A valid envelope is not a failure.

## Tests

`DeterministicWorkflowRunnerSuspendTests` (use the fake adapters already used in
`DeterministicWorkflowRunnerFailureStateTests`):
- envelope, default resume → session `suspended`, the step execution `suspended`, no messages published, the `SuspendRecord`
  fields match, exitCode 5, the events end `[…, handover, sessionCompleted(status: suspended)]`
- envelope with a downstream `resumeStepId` equal to the next step → declaring step `completed`, message delivered to
  the resume step, session suspended at the resume step
- downstream `resumeStepId` that is not the selected next step → the invalid-output path; the session does not suspend
- malformed envelope (userInputRequired without a question) → invalid-output path
- enveloped output `{when, payload:{handover:{…}}}` → extracted
- `boundaryHandover` returns a record after step 1 → suspended before step 2; step 2 never started
- resuming a suspended session → runs from `suspend.stepId` to `completed`; `suspend` becomes nil

`SessionResumeSuspendedTests` (CLI; pattern `SessionPreservedHistoryTests`, temp session store under `tmp/`):
- `workflow run --mock-scenario` with an envelope → exit `.suspended`, stderr hint, `session status` shows suspended
- `session resume` without an answer → exit `.suspended`, question printed, no new execution
- `session resume --variables '{"handover":{"answer":{"option":"a"}}}'` → completes; the resumed step's
  `inputSnapshot` contains `handover.answer`

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-02-runner-suspend/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "DeterministicWorkflowRunnerSuspendTests|SessionResumeSuspendedTests|DeterministicWorkflowRunnerFailureStateTests|RuntimeStoreTests|SessionPreservedHistoryTests|SessionObservabilityCommandTests|AgentGatewayNodeAdapterTests" > tmp/work-handover/wh-02-runner-suspend/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-02-runner-suspend/focused.log'
git diff --check
```

Both must end with exit=0, the new tests must pass, and the executed count must be > 0. Any other failure must be in the wh-00 baseline.

## Done criteria

- [ ] Extraction, publication, runner, store, resume and CLI deliverables are implemented
- [ ] Every test above passes; the focused regressions are green or baseline-classified
- [ ] The progress log has hashes, commands and log paths
