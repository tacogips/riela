# wh-01: Shared contracts — types, enum cases, schema, seal transaction

```json
{
  "planId": "wh-01-contracts",
  "planPath": "impl-plans/active/wh-01-contracts.md",
  "wave": "W1",
  "dependsOn": [],
  "writePaths": [
    "Sources/RielaCore/HandoverContracts.swift",
    "Sources/RielaCore/JSONCanonical.swift",
    "Sources/RielaCore/RuntimeSession.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/WorkflowRunEvent.swift",
    "Sources/RielaCore/LoopOutcomeNotification.swift",
    "Sources/RielaCore/BackendCapability.swift",
    "Sources/RielaCore/DistributedWorkerModels.swift",
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaCore/WorkflowNodeContracts.swift",
    "Sources/RielaCore/WorkflowValidation.swift",
    "Sources/RielaWork/WorkHandover.swift",
    "Sources/RielaWork/HandoverProtocols.swift",
    "Sources/RielaWork/WorkModels.swift",
    "Sources/RielaWork/WorkDecision.swift",
    "Sources/RielaWork/WorkEvidence.swift",
    "Sources/RielaWork/WorkStore+Schema.swift",
    "Sources/RielaWork/WorkStore+Handovers.swift",
    "Tests/RielaCoreTests/HandoverContractsTests.swift",
    "Tests/RielaCoreTests/JSONCanonicalTests.swift",
    "Tests/RielaWorkTests/WorkHandoverModelsTests.swift",
    "Tests/RielaWorkTests/WorkStoreHandoverRecordsTests.swift",
    "Tests/RielaWorkTests/WorkModelsCodableTests.swift",
    "Tests/RielaCLITests/DistributedWorkerConfigurationTests.swift",
    "Tests/RielaCoreTests/AgentNodeOutputContractValidationTests.swift",
    "impl-plans/progress/wh-01-contracts.md"
  ],
  "sharedPaths": [
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCore/RuntimeStore.swift",
    "Sources/RielaCore/SessionObservability.swift",
    "Sources/RielaCore/LoopSessionOverview.swift",
    "Sources/RielaCore/RuntimeMessageInputResolver.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift",
    "Sources/RielaCLI/SpecialistCommands.swift",
    "Sources/RielaCLI/WorkflowRunLivePersistence.swift",
    "Sources/RielaCLI/TaskDispatch.swift",
    "Sources/RielaWork/WorkStore+Reservation.swift",
    "Sources/RielaWork/DecisionApplier.swift",
    "Tests/RielaWorkTests/Fixtures"
  ],
  "sharedPathNotes": [
    {"path": "Sources/RielaCLI/RielaCommand.swift", "intendedEdit": "Add only `case suspended = 5` (doc comment: run or resume ended suspended for a handover) to CLIExitCode. Do not touch TaskCommandKind or SessionCommand."},
    {"path": "Sources/RielaCore/RuntimeStore.swift", "intendedEdit": "Only the exhaustive-switch arms the compiler requires for the new status cases. wh-02 owns behavior later."},
    {"path": "Sources/RielaCore/SessionObservability.swift", "intendedEdit": "Only exhaustive-switch arms: `suspended` is non-terminal and not active, and renders as \"suspended\"."},
    {"path": "Sources/RielaCore/LoopSessionOverview.swift", "intendedEdit": "Only exhaustive-switch arms for `suspended`."},
    {"path": "Sources/RielaCore/RuntimeMessageInputResolver.swift", "intendedEdit": "Only exhaustive-switch arms for step status `suspended` (treated like `failed`: not an accepted producer)."},
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner+Events.swift", "intendedEdit": "Only exhaustive-switch arms for the new `.handover` run event. Emission is wh-02."},
    {"path": "Sources/RielaCLI/SpecialistCommands.swift", "intendedEdit": "Only exhaustive-switch arms for `suspended`."},
    {"path": "Sources/RielaCLI/WorkflowRunLivePersistence.swift", "intendedEdit": "Committed at bb33bbf0: only the exhaustive-switch arm adding `.handover` to the persisted run-event list."},
    {"path": "Sources/RielaCLI/TaskDispatch.swift", "intendedEdit": "Committed at bb33bbf0: only a placeholder `.takeover` entry arm that throws WorkStoreError. wh-14 (writePath owner) replaces it with packet resume-step resolution."},
    {"path": "Sources/RielaWork/WorkStore+Reservation.swift", "intendedEdit": "Committed at bb33bbf0: only a placeholder `.takeover` arm in `decisionKind(for:)` returning `.resume`. wh-03 (writePath owner) replaces it with `.takeover(handoverId:, placement:)`."},
    {"path": "Sources/RielaWork/DecisionApplier.swift", "intendedEdit": "Only exhaustive-switch arms for the new DecisionKind cases, each throwing WorkStoreError(\"decision kind '<kind>' is applied by the handover store APIs\"). wh-03 replaces them."},
    {"path": "Tests/RielaWorkTests/Fixtures", "intendedEdit": "Update JSON fixtures that encode DeterministicDirectorRules, WorkTask or lease rows so they carry the new required keys (`handoverOnInactivity`, `fence`)."}
  ],
  "progressLog": "impl-plans/progress/wh-01-contracts.md"
}
```

## Intent and context

This plan pins every data shape that the wave-2 plans share, so those plans compile
side by side. It is data, Codable, schema and one store transaction only. It adds no runner,
dispatch or CLI behavior. Design: §4, §11, §13, §21 R1, R3, R14, R15, R17 and R19.
No GitHub issue and no codex-agent reference apply. Branch: `feat/work-handover-and-takeover`.

Non-goals: suspend behavior (wh-02), reservation and lease logic (wh-03), the builder (wh-04),
SDL or catalog rows (wh-20), and `TaskCommandKind` cases (wh-15). Do not add
`SessionBackendActivityVerdict.awaitingUser` (dropped).

## Execution rules (umbrella "Common execution contract")

Fresh-read before each edit. Record pre/post SHA-256 and intent snapshots under
`tmp/work-handover/wh-01-contracts/<attempt>/`. Edit only writePaths, plus sharedPaths for
their stated edit. Run swift commands with `arch -arm64 /bin/zsh -lc '…'` and complete
logs. Do not stage, commit or reset. Log progress only in `impl-plans/progress/wh-01-contracts.md`.
**Exhaustive-switch rule (pre-authorized, this plan only):** when `swift build`
fails *only* because a `switch` over one of the changed enums is no longer
exhaustive, you may add the minimal arm in that file even if it is not listed. Semantics:
session `suspended` is non-terminal and not running. It renders as `suspended`.
It is never grouped with `completed` or `failed`. Record every such file and
line in the progress log.

## Deliverables

### A. `Sources/RielaCore/HandoverContracts.swift` (new)

Write the enums with associated values using a `kind` discriminator exactly like
`WaitReason` (`Sources/RielaWork/WorkDecision.swift:60`). Use a private `Kind` mirror and
strict decoding. Unknown kinds throw `DecodingError.dataCorrupted`.

- `HostTrait: String, Codable, CaseIterable, Sendable, Comparable`: `userReachable, interactive, tccApproved, hardwareKey, gui`.
- `HandoverOption {id, label, description?}`; `HandoverQuestion {id, text, options: [HandoverOption], answerSchema: JSONObject?, defaultAnswer: JSONObject?, impact: String?}`.
- `PresenceRequirement {traits: [HostTrait], instructions: String}`. The init **and** `init(from:)` normalize `traits` to sorted-unique. Arrays, never `Set`, keep the digest stable (R17).
- `SuspendReasonKind: String`: `userInputRequired, userPresenceRequired, operatorMove`.
- `SuspendProducer`: `stepExecution(String) | runtime | human(principal: String)`.
- `SuspendRecord {reasonKind, stepId, stepExecutionId?, question?, presence?, progressNote?, suspendedAt: Date, producer}`.
- `HandoverEnvelope {reason: SuspendReasonKind, question?, presence?, progressNote?, resumeStepId?}`, plus
  `static let reservedKey = "handover"` and
  `static func parse(_ value: JSONValue, source: String) throws -> HandoverEnvelope`. Rules:
  the value must be an object. Only the keys `reason, question, presence, progressNote, resumeStepId` are allowed.
  `reason` ∈ {userInputRequired, userPresenceRequired} (`operatorMove` is rejected here).
  userInputRequired requires `question` with non-empty `id` and `text`. userPresenceRequired
  requires `presence` with ≥1 trait. `progressNote` must be ≤ 8192 UTF-8 bytes. `resumeStepId` must be
  non-empty if present. Every violation throws `AdapterExecutionError(.invalidOutput, "<source>.handover…")`
  (the same error type `normalizeOutputContractEnvelope` throws, `AdapterContracts.swift:354`).
- `HandoverSinkKind: String`: `store, kaiba, gitRef, file, command`.
- `HandoverSinkConfig {kind, kaibaInstanceId?, notebookId?, remote?, path?, command: [String]?}`.
- `HandoverSinkRef {kind, locator, digest, writtenAt}`, plus `var serialized: String` =
  `"<kind>:<locator>#sha256:<digest>"` and `static func parse(_ s: String) throws -> (kind, locator, digest)`.
  Split on the first `:` and the **last** `#sha256:`. The digest must be 64 lowercase hex characters.
- `HandoverHistoryBundle {executions: [WorkflowStepExecution], messages: [WorkflowMessageRecord], compatibilityDigests: [String: String], truncated: Bool}`.
- `WorkflowHandoverDeclaration {sinks: [HandoverSinkConfig]}` (workflow.json top-level `handover`).
- `WorkflowDeliverableProjection {store: String, instanceField: String?, idFields: [String]}`.

### B. `Sources/RielaCore/JSONCanonical.swift` (new) — R17

`public enum JSONCanonical { static func encode<T: Encodable>(_ v: T) throws -> Data; static func sha256Hex(_ d: Data) -> String }`.
Encode with a `JSONEncoder` whose `dateEncodingStrategy` is a custom **UTC ISO-8601 with
milliseconds, rounded to the nearest ms** (`(t*1000).rounded()`; never `floor`, because floating
error makes floor non-idempotent). Decode the result to `JSONValue` and serialize with a
custom writer. Object keys are sorted by UTF-8 bytes, there is no whitespace, strings use minimal
RFC 8259 escaping, `.integer` values are printed verbatim, and `.number(d)` uses `d.description`.
NaN and infinity throw. Add a matching `JSONCanonical.decoder()` that parses the same date format.
Use `Crypto` SHA256, as `WorkStore+Reservation.swift:launchTokenDigest` does.

### C. Session model — `RuntimeSession.swift`, `SQLiteWorkflowRuntimePersistenceStore.swift`

- Add `suspended` to `WorkflowSessionStatus` (after `running`) and to `WorkflowStepExecutionStatus`.
- Add `WorkflowSessionFailureKind.stalled` ("stalled") and `.leaseLost` ("leaseLost").
- `WorkflowSession.suspend: SuspendRecord?`. If `WorkflowSession` has explicit CodingKeys or a custom
  decoder, add the key there and decode it as optional.
- `schemaGeneration = 9`. Add one comment sentence ("Generation 9 adds the suspended status, the
  handover tables and lease fencing"). Register **no** migration.

### D. Events, outcomes, capabilities, workflow model

- `WorkflowRunEventType.handover = "handover"`; `WorkflowRunEvent.handover(SessionEnvelope, HandoverEventPayload)`;
  `HandoverEventPayload {reasonKind: SuspendReasonKind, resumeStepId: String, questionId: String?, questionText: String?}`.
  Extend the flat initializer and the encode/decode exactly as `silenceWarning` is handled in the same file.
- `LoopOutcome.handover`. `LoopOutcomeClassifier` never returns it (the dispatcher uses it explicitly).
- `HostCapabilitySnapshot.traits: [HostTrait]` and `DistributedWorkerRegistration.traits: [HostTrait]`.
  Both inits take `traits: [HostTrait] = []` and normalize to sorted-unique. Decoding is synthesized and strict.
- `WorkflowDefinition.handover: WorkflowHandoverDeclaration?` (optional key).
- `NodeOutputContract.deliverables: WorkflowDeliverableProjection?` (optional key; R15).

### E. `WorkflowValidation.swift`

1. Error: a node whose `output.jsonSchema.properties` contains `handover` →
   message `"output.jsonSchema must not declare the reserved 'handover' key"`.
2. Add `"riela/git-publish-branch"` to the git add-on list at the producer walk (`:255`).
3. Warning (severity `.warning`) when any registry node's add-on name has the prefix `riela/memory-` or
   `riela/kv-` and no registry node's add-on has the prefix `kaiba/`. Message: `"riela memory/KV state is
   cwd-local and becomes a localOnly deliverable on handover; add a kaiba mirror step"`.
   Pitfall: this is a **warning**. Run the example validation tests to prove no example gains an
   error.

### F. RielaWork models — `WorkHandover.swift` (new), `WorkModels.swift`, `WorkDecision.swift`, `WorkEvidence.swift`

`WorkHandover.swift`:
`HandoverID` (like `TaskID`/`AttemptID` in `WorkIdentifiers.swift`, with `generate()`);
`HandoverReason` (`userInputRequired(HandoverQuestion) | userPresenceRequired(PresenceRequirement) | ownerLost(OwnerLossEvidence) | inactivity(stepId: String, idleMs: Int) | operatorMove(reason: String)`; kind strings = case names);
`OwnerLossEvidence {attemptId, lastHeartbeatAt: Date?, expiredAt, fence: Int, forcedBy: DecisionProducer}`;
`HandoverWorkflowRef {workflowId, scope: String?, workflowDefinitionDir: String?, entryStepId, resumeStepId}`;
`BudgetSnapshot {attemptsUsed, maxAttempts?, tokensUsed, maxTotalTokens?, wallClockMsUsed, maxWallClockMs?}`;
`HandoverStepSummary {stepId, stepExecutionId, status: WorkflowStepExecutionStatus, acceptedOutput: JSONObject?, responseExcerpt: String?, backend: String?}`;
`HandoverProgress {acceptedSteps, remainingSteps: [String], latestGateResults: [LoopGateResult], openFindings: [Finding], evidenceSummary: [String: Int] (EvidenceKind raw → count), remainingBudget: BudgetSnapshot}`;
`PublicationState` (`published | checkpointFailed(reason: String) | unpublished(lastKnown: String?)`);
`RepositoryDeliverable {root, remote, branch, baseRevision, headCommit: String?, state, dirtyPaths: [String]}`;
`DocumentDeliverable {store, instance: String?, ids: [String], producedByStepIds: [String]}`;
`ArtifactFileRef {path, sha256, bytes: Int}`; `ArtifactBundleRef {files, location: HandoverSinkRef}`;
`LocalOnlyDeliverable {kind: String /* memory | kv | file */, path: String, bytes: Int?}`;
`DeliverableRef` (`repository | document | artifactBundle | localOnly`);
`HandoverContinuationContract {resumeStepId, completion: CompletionContract, verification: [VerificationRequirement], guardPolicy: GuardPolicy}` (no `answer`, R19; use the existing type names from `WorkModels.swift`. If `VerificationRequirement` is named differently, use the existing type that `CompletionContract` references and note it);
`HandoverAnswer {questionId, payload: JSONObject, answeredBy: DecisionProducer, answeredAt}`;
`HandoverPacket` exactly as design §4 (`version = 1`), plus
`func canonicalDigest() throws -> String` (canonical encoding of a copy with `sinks = []`, `digest = ""`) and
`func sealed() throws -> HandoverPacket` (sets `digest`);
`TakeoverPlacement {hostId, requiredTraits: [HostTrait], backend: NodeExecutionBackend?, model: String?}`;
`TakeoverLineage {fromAttemptId, handoverId, hops: Int}`;
`AttemptLease {attemptId, taskId, sessionId, tokenDigest, fence, heartbeatAt, expiresAt, hostId}`;
`LeasePolicy {ttlMs = 300_000, heartbeatMs = 15_000}`;
`CheckpointPolicy` (`none | stepBoundary | everyMs(Int)`);
`PublicationPolicy {remote = "origin", branchTemplate = "riela/task/{taskId}/g{generation}", branchAllowlist = "riela/task/*", allowCreateBranch = true}`;
`HandoverPolicy {onWaitSignal = true, checkpoint = .stepBoundary, sinks: [HandoverSinkConfig] = [], publish = PublicationPolicy()}`;
`HandoverBounds` (static constants: acceptedOutput 32_768, responseExcerpt 4_096, history 2_097_152, variables 262_144, brief 65_536, packet 4_194_304, progressNote 8_192, artifactFiles 16, artifactBytes 524_288);
`TaskHandoverSummary {taskId, handoverId, reasonKind: String, requiredTraits: [HostTrait], needsAnswer: Bool, questionText: String?, createdAt}`;
`HandoverRequestRecord {requestId, taskId, attemptId, reason: String, immediate: Bool, target: String?, sinks: [HandoverSinkKind], requestedAt, consumedAt: Date?}`.

Existing files:
- `AttemptEntry.takeover(fromAttemptId: AttemptID, handoverId: HandoverID)`. Add to the `Kind` mirror, CodingKeys (`fromAttemptId`, `handoverId`), encode and decode.
- `DecisionKind.handover(HandoverReason)`, `.answer(HandoverAnswer)`, `.takeover(handoverId: HandoverID, placement: TakeoverPlacement)`.
- `WaitReason.handover(HandoverID)`.
- `EvidenceKind`: `handover, handoverAnswer, publication, leaseFence`.
- `GuardPolicy.lease: LeasePolicy?` and `.handover: HandoverPolicy?` (optional, like `inactivity`; use-sites apply `?? .init()`).
- `DeterministicDirectorRules.handoverOnInactivity: Bool` (init default `false`; synthesized Codable, so required → update fixtures).
- `WorkTask.fence: Int` (init default `0`, required key, added to the custom CodingKeys/decoder at `WorkModels.swift:386` if one exists).
- `Attempt.takeoverLineage: TakeoverLineage?` and `Attempt.supersededByFence: Int?` (optional).

### G. `Sources/RielaWork/HandoverProtocols.swift` (new) — signatures pinned for wave 2

```swift
public protocol HandoverSink: Sendable {
  var kind: HandoverSinkKind { get }
  func write(_ packet: HandoverPacket, bytes: Data, brief: String) async throws -> HandoverSinkRef
  func read(_ ref: HandoverSinkRef) async throws -> Data
}
public protocol WorkspaceHandoverRuntime: Sendable {
  func ensureBranch(root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?,
                    isolation: RepositoryIsolation, template: String) async throws -> IsolationRef
  func checkpoint(_ isolation: IsolationRef, message: String, trailer: String, paths: [String]?) async throws -> String?  // commit sha, nil = nothing to commit
  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool, branchAllowlist: String) async throws -> PublishedBranch
  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool, attempt: AttemptID) async throws -> IsolationRef
  func dirtyPaths(_ isolation: IsolationRef) async throws -> [String]
}
public struct PublishedBranch: Codable, Equatable, Sendable { remote, branch, sha: String; created: Bool }
public protocol DeliverablePublisher: Sendable {
  func publish(task: WorkTask, attempt: Attempt, snapshot: WorkflowRuntimePersistenceSnapshot, ownerAlive: Bool) async -> [DeliverableRef]  // never throws; failures become states
}
```

### H. Schema and store CRUD — `WorkStore+Schema.swift`, `WorkStore+Handovers.swift` (new)

- `work_handovers(handover_id TEXT PRIMARY KEY, task_id TEXT NOT NULL, from_attempt_id TEXT NOT NULL, successor_attempt_id TEXT, reason_kind TEXT GENERATED ALWAYS AS (json_extract(record,'$.reason.kind')) STORED, digest TEXT NOT NULL, record BLOB NOT NULL CHECK (json_valid(record, 8)), created_at TEXT NOT NULL)` plus the index `(task_id, created_at)`.
  Follow the jsonb/`json(record)` storage and read idiom of `work_attempts` in the same file.
- `work_handover_requests(request_id TEXT PRIMARY KEY, task_id, attempt_id, record BLOB, requested_at, consumed_at TEXT)`, plus a unique partial index on `attempt_id WHERE consumed_at IS NULL`.
- `work_leases`: add `heartbeat_at TEXT NOT NULL, expires_at TEXT NOT NULL, fence INTEGER NOT NULL DEFAULT 1, host_id TEXT NOT NULL`.
  **Pitfall:** `reserveAttempt` (wh-03's file) still inserts without these columns until wh-03 lands, so
  add SQL defaults for `heartbeat_at`/`expires_at` (`DEFAULT ''`) and `host_id` (`DEFAULT 'local'`).
  wh-03 writes real values. State this in a comment.
- `work_tasks`: a generated `fence` column from `$.fence`.
- Append both new tables to `tableNames`.
- CRUD in `WorkStore+Handovers.swift`: `saveHandover(_:)`, `loadHandover(id:)`, `latestHandover(taskId:)`,
  `listHandovers(taskId:)` (ordered by `created_at`, then id), `attachSuccessor(handoverId:attemptId:)`
  (idempotent for the same attempt; throws for a different one), `recordSinkRefs(handoverId:refs:)`
  (updates only `record.sinks`; the digest is unchanged), and `tasksAwaitingHandover(traits: [HostTrait]?) -> [TaskHandoverSummary]`
  (latest handover per task with no successor; `needsAnswer` = reason is userInputRequired and there is no `.answer` decision
  for it; if `traits` is non-nil, keep only rows whose required traits ⊆ `traits`).
  The record stores **canonical bytes** (`JSONCanonical.encode`). Load with `JSONCanonical.decoder()`.
- `sealHandoverRecords(packet: HandoverPacket, decision: Decision, evidence: [Evidence], predecessorOutcome: AttemptOutcome, expectedTaskVersion: Int, now: Date) throws -> WorkTask`
  runs as **one transaction**. It checks the task version, inserts the packet row, inserts the decision
  (`kind .handover`) and the evidence rows, and sets the predecessor attempt (`packet.fromAttemptId`) to `.reconciled`
  with `predecessorOutcome` if it is not reconciled yet. It deletes that attempt's `work_leases` row and
  sets the task to `.waiting` with version+1. Reuse the internal helpers `insertDecision`, `insertEvidence`,
  `updateTask`, `replaceAttempt` and `requiredAttempt` from `WorkStore+Reservation.swift` / `WorkStore+Decisions.swift`. Call them;
  do not edit those files.

## Pitfalls

- Never encode a `Set` inside packet types. Dictionary keys are sorted by the canonical writer.
- Keep the existing `init` signatures source-compatible by adding new parameters with defaults at the end.
  Other plans construct these types.
- Do not create shims that accept old JSON. Update the fixtures instead (`grep -rn "rerunOnInactivity" Tests`).
- `LoopOutcome` is `CaseIterable`. Check where the notification `on` values are validated. If that check uses
  `allCases`, `handover` is accepted automatically. If it is a hard-coded list outside writePaths, record it for wh-11.

## Tests (new files)

- `HandoverContractsTests`: every envelope rule → accept or specific error; trait normalization
  (`[interactive, userReachable, interactive]` → `[interactive, userReachable]`); `SuspendRecord` and
  `WorkflowSession` round-trip with `suspend`; `"suspended"` decodes; an unknown status fails; sink-ref
  `serialized`/`parse` round-trip, where a bad digest or a missing `#sha256:` throws; a locator that contains `#` and `:` parses.
- `JSONCanonicalTests`: two dictionaries with different insertion order give identical bytes; a date with sub-ms precision
  gives `encode(decode(encode(x))) == encode(x)`; `0.1`, `1e21` and `-0.5` are stable; NaN throws; sha256 of a known input.
- `WorkHandoverModelsTests`: round-trip every new case of `AttemptEntry`, `DecisionKind`, `WaitReason`,
  `EvidenceKind` and `HandoverReason` (5) and `PublicationState`; an unknown `kind` fails; `HandoverPacket.sealed()` is
  stable when `sinks` changes.
- `WorkStoreHandoverRecordsTests` (SQLite temp root, pattern of `WorkStoreTests`): the tables exist;
  save/load gives byte-equal canonical records; list order; `attachSuccessor` idempotency and conflict;
  `recordSinkRefs` keeps the digest; `sealHandoverRecords` effects (task waiting, version+1, attempt reconciled,
  lease row gone, decision and evidence present); a version conflict → nothing written; `tasksAwaitingHandover`
  trait filter and `needsAnswer`.

## Verification (record each log and `exit=`)

```
arch -arm64 /bin/zsh -lc 'swift build > tmp/work-handover/wh-01-contracts/build.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/build.log'
arch -arm64 /bin/zsh -lc 'swift test --filter "HandoverContractsTests|JSONCanonicalTests|WorkHandoverModelsTests|WorkStoreHandoverRecordsTests|WorkModelsCodableTests|WorkStoreTests|WorkStoreReservationTests|DeterministicDirectorTests|RuntimeStoreTests|WorkflowValidation" > tmp/work-handover/wh-01-contracts/focused.log 2>&1; echo "exit=$?" >> tmp/work-handover/wh-01-contracts/focused.log'
git diff --check
```

The build must end with exit=0. The focused tests must end with exit=0 and a non-zero executed count, with every new test listed as passed.
Any pre-existing failure in these filters must appear in the wh-00 baseline list. Otherwise it is a
regression to fix.

## Done criteria

- [ ] Every type and case above exists, with its Codable round-trip covered by a test
- [ ] Generation 9, the new tables and the lease columns are in place; `tableNames` is updated
- [ ] `sealHandoverRecords` is atomic and tested
- [ ] The build is green; the focused suite is green; the exhaustive-switch edits are listed in the progress log
- [ ] The progress log is complete, with hashes and log paths
