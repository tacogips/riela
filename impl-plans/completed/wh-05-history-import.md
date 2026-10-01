# wh-05: History import from suspended sessions and from a packet bundle

```json
{
  "planId": "wh-05-history-import",
  "planPath": "impl-plans/active/wh-05-history-import.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaCore/RuntimeHistoryImport.swift",
    "Tests/RielaCoreTests/RuntimeHistoryImportHandoverTests.swift",
    "impl-plans/progress/wh-05-history-import.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-05-history-import.md"
}
```

## Intent and context

A takeover session imports the predecessor's accepted prefix. Today
`InMemoryWorkflowRuntimeStore.importAcceptedHistory` (`RuntimeHistoryImport.swift:26`) accepts only a `.failed`
source session that lives in the same store. The successor may import from a `suspended` session or
a `failed(.stalled | .cancelled | .leaseLost)` session in the same store, or from a
`HandoverHistoryBundle` carried by a packet when the source is on another host. Design §5, §10.1 step 5, §21 R20.
`docs/preserved-history-recovery.md` defines what an imported execution may carry.

Non-goals: changing `WorkflowRuntimeStore`'s protocol signature, the `FailClosedSQLiteWorkflowRuntimeStore`
wrapper (it forwards the input unchanged), and rerun `--preserve-history` behavior for existing callers.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-05-history-import/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables

- `public enum HistoryImportSource: Sendable { case session; case bundle(HandoverHistoryBundle, handoverId: String) }`.
- `WorkflowHistoryImportInput.source: HistoryImportSource`. The existing init keeps its signature and sets `.session`.
  The Recovery caller (`DeterministicWorkflowRunner+Recovery.swift:118`) must compile unchanged. Add
  `init(sessionId: String, sourceSessionId: String, bundle: HandoverHistoryBundle, handoverId: String)`,
  which copies the bundle's executions and messages.
- `WorkflowImportedExecutionSource.handoverId: String?` (optional Codable key, default nil).
- The `importAcceptedHistory` rules:
  - Always: the target session is `.created`, has no executions or messages, and has a different id from the source.
    Message communication ids are unique.
  - `.session`: the source exists in this store, has the same workflowId, and has status `.failed` (any kind) or `.suspended`.
    Messages must be canonical source evidence (the existing check).
  - `.bundle`: the source session need **not** exist in the store. Refuse `bundle.truncated == true` with
    `messageAppendRejected("history bundle for handover <id> is truncated; read the packet from the controller store")`.
    Every execution has `acceptedOutput != nil` and status `.completed`, and step ids are unique. Every message's
    `sourceStepExecutionId` names a bundle execution. The workflowId of every execution's session is not checked
    (the caller passes the right workflow).
  - Imported executions get `importedFrom = WorkflowImportedExecutionSource(sessionId: sourceSessionId,
    executionId: original, communicationIds: …, handoverId: <bundle id or nil>)`, exactly as the `.session` path builds them today.
  - After import, `session.currentStepId` and `entryStepId` stay equal to the target session's `entryStepId`.
    The status stays `.created`.

## Pitfalls

- Keep the atomicity of the in-memory mutation: validate everything before mutating state (the current
  function's shape).
- Do not relax the `.session` message-canonicality check for session sources. Only bundles skip it.

## Tests (`RuntimeHistoryImportHandoverTests`, in-memory store)

- a suspended source session → import succeeds; `importedFrom.handoverId == nil`
- a failed source with kind `stalled`, `cancelled` or `leaseLost` → succeeds
- a completed source → refused
- bundle happy path → executions imported with `handoverId`, messages remapped, `currentStepId == entryStepId`
- a bundle message that references an unknown execution → refused; a bundle execution without acceptedOutput → refused
- a truncated bundle → refused with a message naming the handover
- an existing preserved-history rerun still works (run the existing suites below)

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-05-history-import/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-05-history-import/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "RuntimeHistoryImport|PreservedHistory|SessionPreservedHistoryTests" > tmp/work-handover/wh-05-history-import/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-05-history-import/focused.log'
git diff --check
```

Both must end with exit=0 and a non-zero count, with the new tests passing.

## Done criteria

- [x] The source enum, bundle init and rules are implemented; the existing API is source-compatible
- [x] All listed tests pass; the preserved-history suites are green or baseline-classified
- [x] The progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-05-history-import.md`. Archived to `impl-plans/completed/`.
