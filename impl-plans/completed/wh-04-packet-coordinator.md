# wh-04: Packet builder, brief, redaction, handover coordinator, task adoption

```json
{
  "planId": "wh-04-packet-coordinator",
  "planPath": "impl-plans/active/wh-04-packet-coordinator.md",
  "wave": "W2",
  "dependsOn": ["wh-01-contracts"],
  "writePaths": [
    "Sources/RielaWork/HandoverPacketBuilder.swift",
    "Sources/RielaWork/HandoverBriefRenderer.swift",
    "Sources/RielaWork/HandoverRedaction.swift",
    "Sources/RielaWork/HandoverCoordinator.swift",
    "Sources/RielaWork/TaskAdoption.swift",
    "Sources/RielaWork/WorkStore+Adoption.swift",
    "Tests/RielaWorkTests/HandoverPacketBuilderTests.swift",
    "Tests/RielaWorkTests/HandoverCoordinatorTests.swift",
    "Tests/RielaWorkTests/TaskAdoptionTests.swift",
    "Tests/RielaWorkTests/Fixtures/handover-brief-golden.md",
    "impl-plans/progress/wh-04-packet-coordinator.md"
  ],
  "sharedPaths": [],
  "progressLog": "impl-plans/progress/wh-04-packet-coordinator.md"
}
```

## Intent and context

This plan turns durable records into a deterministic, bounded, redacted, digest-sealed packet and
seals it in the documented order. It also adopts a plain session into a task. Design: §3.2, §5 (order), §7,
§8 (store ref), §10.5, §14 (redaction), §21 R17 and R19. The seal transaction itself is wh-01's
`WorkStore.sealHandoverRecords`. This plan calls it.

Non-goals: sink implementations (wh-09), git (wh-07), the deliverable collector (wh-08), CLI, and reservation.

## Execution rules

Follow the umbrella common execution contract (hashes and intents in `tmp/work-handover/wh-04-packet-coordinator/`,
writePaths only, arm64 logs, no git state changes, own progress log).

## Deliverables

### Builder — pinned API

```swift
public struct HandoverPacketBuilderInput: Sendable {
  public var handoverId: HandoverID; public var task: WorkTask; public var attempt: Attempt
  public var reason: HandoverReason; public var resumeStepId: String
  public var snapshot: WorkflowRuntimePersistenceSnapshot; public var workflow: WorkflowDefinition
  public var workflowRef: HandoverWorkflowRef; public var deliverables: [DeliverableRef]
  public var variables: JSONObject      // the run's variables as passed by the caller (wh-14)
  public var progressNote: String?; public var hostId: String; public var producer: EvidenceProducer
  public var redaction: HandoverRedactionRules; public var now: Date
}
public struct HandoverPacketBuilder: Sendable {
  public init(store: WorkStore)
  public func build(_ input: HandoverPacketBuilderInput) throws -> HandoverPacket   // sealed (digest set), sinks = []
}
```

Rules:
- `progress.acceptedSteps`: the snapshot's executions with `acceptedOutput != nil` and status `completed`, in
  order. `acceptedOutput` is canonical-size-checked. Above 32 KiB it becomes
  `{"truncated": true, "bytes": N}`. `responseExcerpt` is the last ≤ 4 KiB of `streamedResponseText`, cut on a
  UTF-8 character boundary. `backend` is the execution's backend raw value.
- `remainingSteps`: a breadth-first walk from `resumeStepId` over `workflow.steps[].transitions` targets.
  It visits in declaration order, has no duplicates, and includes `resumeStepId` first.
- `latestGateResults`: from the latest attempt outcome or gate evidence (`store.listEvidence(taskId:, kind: .gate)`).
  `openFindings` = `store.listFindings(taskId:, status: .open)` (use the existing status name).
  `evidenceSummary` = counts per `EvidenceKind.rawValue`, sorted.
- `remainingBudget`: attempts used = `store.listAttempts(taskId:).count`. Tokens and wall clock come from `.cost`
  evidence, with the same accounting `requireExecutionAdmissionBudget` uses (read it; do not edit it).
  Max values come from `task.guardPolicy.budget`.
- `history`: the executions of `acceptedSteps` (full `WorkflowStepExecution`, stripped as preserved history strips:
  backend, backendSessionId, backendWorkingDirectory, usage and live backend events set to nil or empty, as
  `DeterministicWorkflowRunner+History.swift:preservedHistory` and `RuntimeHistoryImport` produce). `messages` =
  every `snapshot.workflowMessages` entry whose `sourceStepExecutionId` is one of those executions.
  `compatibilityDigests[stepId]` = the `workflowDigest` string inside `inputSnapshot["_rielaHistoryContract"]` when
  it is present (informational only in this feature). If the canonical size is above 2 MiB, set `executions = []`,
  `messages = []` and `truncated = true`.
- `variables`: `input.variables` minus the keys `handover` and `rielaTask`, which are regenerated at takeover, then redacted.
  If the canonical size is above 256 KiB, use `{"truncated": true}`.
- `contract`: `resumeStepId`, `task.completion`, the verification requirements and `task.guardPolicy`.
- `brief` = `HandoverBriefRenderer.render(packet)`, clipped to 64 KiB with a final line `…(brief truncated)`.
- Final: `packet.sealed()`. If the canonical size is above 4 MiB, throw `WorkStoreError("handover packet exceeds 4 MiB")`.

### Redaction — `HandoverRedactionRules {secretKeyNames: Set<String>, boundValues: [String: String] /* value → env name */}`

`static func apply(_ value: JSONValue, rules:) -> JSONValue`. Any object key in `secretKeyNames` gets the value
`"<redacted:KEY>"`. Any string equal to a bound value becomes `"<redacted:ENV_NAME>"`. The redaction is recursive and
is applied to `variables`, `acceptedOutput`, message payloads and `progressNote`. Empty bound values are ignored.

### Brief — fixed template (no model call)

The sections, in order, are: `# Handover <handoverId>`; task and intent titles; **Why** (reason in one sentence);
**Question** or **Presence required** (text, options, instructions); **Accepted** (one line per step:
`- <stepId> (<executionId>)`); **Remaining** (comma-separated step ids); **Deliverables** (for repository
deliverables: `git fetch <remote> <branch>` and `git checkout <branch>`; for documents: `store/instance: ids`;
for localOnly: `path (not transferable)`); **Open findings**; **Budget remaining**; **Agent note**
(`progressNote` verbatim). Output is deterministic, with no dates other than `createdAt`.

### Coordinator — pinned API

```swift
public struct HandoverSealRequest: Sendable {
  public var builderInput: HandoverPacketBuilderInput          // deliverables filled by the coordinator
  public var publisher: (any DeliverablePublisher)?; public var ownerAlive: Bool
  public var sinks: [any HandoverSink]; public var decisionId: DecisionID; public var decisionProducer: DecisionProducer
  public var predecessorOutcome: AttemptOutcome; public var expectedTaskVersion: Int
}
public struct HandoverCoordinator: Sendable {
  public init(store: WorkStore, builder: HandoverPacketBuilder)
  public func seal(_ request: HandoverSealRequest) async throws -> HandoverPacket   // returned packet carries sinks
}
```

The order is fixed (design §5): (1) `publisher?.publish(...)`, whose results are appended to the input deliverables;
(2) `builder.build`; (3) `store.sealHandoverRecords` with `Decision(kind: .handover(reason), producer, causedBy: [])`
and `Evidence(kind: .handover, payload {handoverId, digest, reasonKind})`; (4) a `.store` ref
`HandoverSinkRef(kind: .store, locator: "<hostId>/<taskId>/<handoverId>", digest, writtenAt: now)`, followed by each sink
written **in order** with `bytes = JSONCanonical.encode(packet)` and `brief`. A sink error becomes
`Evidence(kind: .publication, payload {sink, error})` and never fails the seal. (5) `store.recordSinkRefs(all refs)`.

### Adoption — `TaskAdoption` + `WorkStore+Adoption.swift`

`public struct TaskAdoption { public init(store: WorkStore); public func adopt(session: WorkflowSession, workflow: WorkflowReference, workingDirectory: String, repositoryRoot: String?, principal: String, existingTaskId: TaskID? = nil, now: Date) throws -> AdoptionResult }`
(`AdoptionResult {intent: Intent?, task, attempt}`). With `existingTaskId` (QA Q6 `--task`), no intent or task is created.
The task must exist, be non-terminal, and have no live attempt. Its plan must reference the same workflow id. The terminal attempt is added to it,
and its state is set to `.running` (version+1). It refuses `session.status == .completed`. The CLI checks the execution
lock for running sessions. `WorkStore.adoptSession(intent:task:attempt:evidence:)` inserts everything in one
transaction: `Intent(origin: .cli …)` (use the existing `WorkOrigin` case for CLI), and `WorkTask` with `plan: .workflow(ref)`,
`context: .repository(...)` when `repositoryRoot` is non-nil (use the existing `ContextBinding` repository case),
`state: .running` and default policies. It also inserts `Attempt(entry: .start, state: .terminal, sessionId: session.sessionId)`
without a launch or lease, and `Evidence(kind: .contextSnapshot, payload {"adoptedFromSession": id})`.
Deterministic ids: `task-adopted-<sessionId>` etc. Adopting the same session twice → throw "already adopted".

## Pitfalls

- Determinism: never iterate a `Dictionary` to build arrays without sorting. Never put `Date()` inside
  the builder; use `input.now`. Dates inside the packet round-trip at millisecond precision (R17). Build the
  packet, canonicalize and hash in one place (`sealed()`).
- Do not re-sign after writing sinks. `sinks` is excluded from the digest.
- The builder is read-only. Only the coordinator writes, and only through the store APIs.

## Tests

`HandoverPacketBuilderTests` (temp WorkStore, synthetic snapshot built in the test):
- two builds from identical inputs → byte-identical canonical encodings and digests
- a golden brief equals `Fixtures/handover-brief-golden.md`
- a 40 KiB accepted output → truncated marker; a 3 MiB history → `truncated: true`, empty executions
- redaction of a bound secret value in variables and a message payload; a key in `secretKeyNames`
- remaining steps for a branching graph; history includes only the accepted prefix and its messages
- a packet above 4 MiB → throws

`HandoverCoordinatorTests`: a fake publisher and sinks record the call order (publish → store row → sinks);
a failing sink → publication evidence, the seal still returns, and the store row sinks = [store, the successful one];
a version conflict → nothing persisted and no sink called; after the seal, the task is waiting and the predecessor is reconciled.

`TaskAdoptionTests`: adopt a suspended session → rows exist and evidence is present; a completed session is refused; a second adoption is refused;
`existingTaskId` for a matching idle task → the attempt is added and no intent is created; a mismatched workflow or a task with a live attempt → refused.

## Verification

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-04-packet-coordinator/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-04-packet-coordinator/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverPacketBuilderTests|HandoverCoordinatorTests|TaskAdoptionTests|WorkStoreHandoverRecordsTests" > tmp/work-handover/wh-04-packet-coordinator/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-04-packet-coordinator/focused.log'
git diff --check
```

Both must end with exit=0, and all new tests must pass with a non-zero count.

## Done criteria

- [x] The builder, brief, redaction, coordinator and adoption are implemented to the pinned APIs
- [x] The determinism, bounds, order and failure tests pass
- [x] The progress log is complete

**Closure (2026-10-01, Step 8)**: accepted; implemented in `d043cbad` (waves 1-2), acceptance recorded in `7182232d`. Evidence: `impl-plans/progress/wh-04-packet-coordinator.md`. Archived to `impl-plans/completed/`.
