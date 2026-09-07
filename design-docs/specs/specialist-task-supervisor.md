# Specialist task supervisor

Status: accepted with low findings by independent Step 3 review (`comm-000007`);
author acceptance is recorded in `comm-000006`. The two documentation findings
are corrected in the Step 4 plan handoff. Workflow mode: `issue-resolution`. Issue:
`local-request:specialist-task-supervisor`. Intake: `comm-000002`, from
`step1-issue-intake`, execution `codex-design-and-implement-review-loop-session-1`.
Implementation plan handoff: `impl-plans/active/specialist-task-supervisor.md`.
There is one design and one implementation plan; no feature planning fanout.

## 1. Outcome and scope

A chat request is durably accepted, classified by configured specialists, and
assigned to one authorized owner. The owner announces the assignment, selects
an authorized registered workflow, validates its callable input, and queues one
child execution. A supervisor process drives execution and projects verified
updates to chat and Wrike while later chat turns can query persisted status.
Closing a chat turn does not terminate task ownership, execution, or delivery.

Ship an additive `riela specialist serve` path, with real chat, classifier,
registry, runner, SQLite, and tracker composition. Tests replace LLM/network
boundaries, not orchestration. Keep ordinary workflow calls and existing event
listeners compatible. No acceptance criterion below is deferred. A new node
kind, a GUI, embeddings, and additional provider-specific chat integrations
beyond the initial Matrix adapter are outside this slice. The reusable chat
boundary must permit existing Telegram/Discord/Slack clients to be added later.
Matrix is selected because its send transaction ID supports stable retry keys.

During this work do not commit, push, send external messages, create external
tasks, or make live Wrike writes. Production adapters are implemented and tested
with stub transports; their existence is not evidence of live provider success.

## 2. Verified baseline and references

Local source inspected at HEAD `c3282b18ed5926cd8ee7b9cb2a5998dbd025f604` with
user-owned dirty changes present. These are source observations, not build or
runtime verification results:

| Boundary | Existing source and behavior | Required integration |
| --- | --- | --- |
| Registry | `Sources/RielaWorkflowRegistry/WorkflowRegistryCatalog.swift` loads authored/mutable bundles and validates packages when listing. `WorkflowRegistryService.swift` resolves origin and precedence. | Separate compact metadata listing from full bundle loading; preserve scope and origin semantics. |
| Callable contract | `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`, `buildCallableInspection`, selects `managerStepId ?? entryStepId` and its node input/output. `Sources/RielaCore/WorkflowNodeContracts.swift` has `NodeInputContract.jsonSchema`. | Extract/reuse this selection rule and validate the exact initial payload before reservation and execution. |
| Child execution | `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift` awaits `run(calleeRequest)` and carries parent/root lineage, with a depth limit of eight. `Sources/RielaCLI/WorkflowCalleeResolution.swift` resolves using caller context and scoped fallbacks. | Durable asynchronous launch through this runner family, with an exact pinned resolver and reserved session identity. |
| Live chat | `Sources/RielaCLI/EventLiveServe.swift` and `EventLiveServe+Matrix.swift`, `+Discord.swift`, `+Slack.swift` await workflow completion before reply delivery. Matrix currently generates a fresh UUID transaction ID. | Dedicated serve path with durable intake, separate workers, and stable outbox IDs. |
| Wrike | `Sources/RielaCLI/ProductionNodeAdapter+WrikeGatewayAddons.swift` implements read/write/admin tiers through gateway capability enforcement. | Reuse tier boundaries; extract injectable transport composition for durable mapping and reconciliation. |
| Persistence/recovery | `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` supports snapshot/message transactions, lineage, and schema migration. `Sources/RielaCLI/WorkflowRunLivePersistence.swift` persists live snapshots; `DeterministicWorkflowRunner+Recovery.swift` supports resume/rerun. | Mandatory durable reservation before effects, fail-closed persistence, and recovery coordinated with supervision records. |
| Concurrency | `Sources/RielaCLI/WorkflowRunCommand+LoopOperations.swift` has advisory pending loop leases. `Sources/RielaSQLite/SQLiteDatabase.swift` defaults transactions to `BEGIN IMMEDIATE`. | Cross-connection task/capacity atomicity and distinct child execution exclusion; advisory leases alone are insufficient. |
| GraphQL | `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` exposes registry, sessionProgress, and control mutations, but no executeWorkflow mutation. `Sources/RielaCLI/WorkflowCommands.swift` contains the remote executeWorkflow client request. | Use local production runner composition, not an assumed server execution API. |

`riela/start-workflow` occurs in `examples/default-superviser/workflow.json`,
not in the inspected Sources implementation. The existing
`ProductionNodeAdapter+WorkflowTaskAddon.swift` generates/registers a workflow
and awaits execution; it does not satisfy selection of an existing workflow or
durable asynchronous supervision. Reuse existing progress, cancellation,
fanout, memory/KV, and lineage facilities where applicable; do not describe
those capabilities as wholly missing.

No local reference checkout was found at `../../codex-agent`,
`../../hermes-agent`, `../../openclaw`, `../hermes-agent`, or `../openclaw`, nor
by targeted reference-file search under `/Users/taco/gits`. Upstream sources
were fetched read-only and pinned on 2026-09-06:

| Reference | Evidence and adaptation |
| --- | --- |
| [Hermes skills_tool.py, 089bb32886c8c18f7fa20182c7bf8826d6935ac5](https://github.com/NousResearch/hermes-agent/blob/089bb32886c8c18f7fa20182c7bf8826d6935ac5/tools/skills_tool.py) | `skills_list` returns bounded name/description/category; `skill_view` loads selected content. Adopt progressive disclosure, without importing skill bodies into workflow cards. |
| [Hermes delegate_tool.py, same revision](https://github.com/NousResearch/hermes-agent/blob/089bb32886c8c18f7fa20182c7bf8826d6935ac5/tools/delegate_tool.py) | Dedicated child DB handles preserve profile lineage and survive parent-handle closure; depth-derived capability limits and background dispatch inform isolation. Riela additionally requires durable launch reservations. |
| [OpenClaw current SQLite registry, 1421c216407515ad29061f67e99c50c68f57f1f3](https://github.com/openclaw/openclaw/blob/1421c216407515ad29061f67e99c50c68f57f1f3/src/agents/subagents/registry/subagent-registry.store.sqlite.ts) | Stores normalized canonical state with indexed run/child/controller/requester identity and distinct execution/delivery status. Adopt correlated state and transactional projection. |
| [OpenClaw restart coordinator, same revision](https://github.com/openclaw/openclaw/blob/1421c216407515ad29061f67e99c50c68f57f1f3/src/agents/subagents/registry/subagent-registry-restart-recovery-coordinator.ts) | Recovery checks the current generation and tracks launch reservation/acceptance/consumption. Adopt fencing and explicit startup phases. |
| [OpenClaw subagents documentation, same revision](https://github.com/openclaw/openclaw/blob/1421c216407515ad29061f67e99c50c68f57f1f3/docs/tools/subagents.md) | Spawn returns an accepted run/child receipt before completion; thread binding and policy ceilings inform acknowledgment and identity boundaries. |

The supplied OpenClaw path `src/agents/subagent-registry.store.ts` returns 404
at that current revision. Its historical implementation was also inspected at
`de8c90457776c94262bc86a73f7ebd0f2a07e323`; it used versioned persistence and
normalization of requesterOrigin/controllerSessionKey/childSessionKey/spawnMode.
Use the current SQLite implementation above as the design reference. These are
conceptual adaptations, not copied code. `codexAgentReferences: []` and
`cursorCliBehaviorMapping: []`; no Codex-agent or Cursor-specific parity applies.

## 3. Lifecycle architecture and node decision

| Option | Appropriate use | Decision |
| --- | --- | --- |
| Ordinary operation nodes | Deterministic validation, lookups, and bounded connector operations | Reuse existing behavior; lifecycle service owns durable writes. |
| Agent decision nodes | Advisory specialist classification and selected input preparation | Use existing production agent adapter with bounded structured output and no tools that can write or dispatch. |
| Existing workflow-call | Composition whose caller waits for a child | Preserve synchronous semantics; do not use it in the chat request path. |
| Async workflow-call | Returning a durable task/child receipt | Implement as service/CLI lifecycle operations backed by reservations, not a new authored node kind. |
| Durable wait/subscription | Monitoring persisted child events and retrying delivery | Implement persisted cursors plus polling in serve; no suspended chat turn or in-memory-only waiter. |

Responsibilities stay in existing modules where dependencies permit:
`RielaCore` owns typed lifecycle/store and runtime reservation contracts;
`RielaWorkflowRegistry` owns short catalog and selected snapshots;
`RielaCLI` owns process composition, production adapters, and CLI parsing.
`RielaSQLite` is reused without overlapping its user-owned edits. Add SwiftPM
dependencies only where necessary and additively. New files separate storage,
state transitions, runtime dispatch, adapters, and commands; do not extend
already oversized Swift files with another large responsibility.

Data flow:

1. Trusted chat adapter validates an inbound event and commits inbox/request
   receipt and next source cursor before acknowledging it. Task creation waits
   for the routing decision; a status request never creates a business task.
2. Status/cancel routes authenticate and read/update task state immediately.
   New work enters a persisted classification round outside the chat handler.
3. Each configured specialist sees its own policy and compact catalog cards;
   the coordinator settles routing before ownership. Only a new-work outcome
   creates the correlated task and permits an atomic owner selection.
4. Claim commit creates the ownership chat outbox event and tracker projection.
   Input preparation loads only the selected full contract; clarification can
   keep the owner while waiting for the requester to supply missing values.
5. Successful validation creates a durable dispatch record and prepared child
   session. A separate executor runs the existing runner from that identity.
6. Monitoring projects committed child events into task updates and outbox
   entries. Delivery workers send independently. Status reads the store and
   reports the latest observation time and any stale or uncertain state.

## 4. Compact discovery and immutable selection

Add optional authored `shortSummary`, `tags`, and `domain` metadata with
backward-compatible decoding. A card contains only workflow ID/name,
shortSummary (maximum 240 Unicode scalars), at most eight tags (32 scalars
each), optional domain (64 scalars), origin ID, scope/source kind, activation,
and revision. It contains no filesystem path, prompt, full description,
contract, node payload, environment, or free-form validation diagnostic.
Normalize whitespace deterministically; reject invalid authored metadata.
Legacy fallback is the whitespace-normalized top-level description truncated
to 240 scalars, or `Workflow <workflowId>` if empty. Never derive it from node
prompts. Treat card text as untrusted data, never as classifier instructions.

List all accessible origins with stable pagination; no query/top-K is required.
Optional query ranks only ID/name/summary/tags/domain, with stable origin/ID
tie-breaking. Filtering cannot silently hide the rest of the registry.
Maintain existing resolution precedence: project workflow, user immutable
workflow, project package, user package, user mutable workflow. Preserve explicit
origin selection and direct-root context; identity collisions remain separate
cards. Access policy filters before cards reach an LLM. Inactive workflows may
be listed with their state but cannot be executed.

Use a compact registry index, refreshed by registry/package mutation and an
explicit `specialist catalog refresh`. Serve readiness refreshes missing or
stale index entries before accepting new work. Listing reads only compact
metadata and index entries; it must not call today's full-bundle `list`/`fetch`
path or semantically scan every prompt. Index refresh is a distinct integrity
operation: hash opaque bundle files without loading their prompt/contracts into
discovery objects or LLM context. Legacy workflows are indexed with the same
fallback; no legacy workflow is silently omitted. A direct filesystem edit
invalidates the index using file inventory metadata; selection always verifies
content hashes even if size/mtime were preserved. Stale cards cannot execute.

Revision is a SHA-256 digest of the canonical manifest of normalized relative
paths and byte digests for workflow.json and its complete executable bundle
dependency closure, including shared node refs, prompt files, and declared
script/config assets. Do not confuse definition-only revision or package
version with this execution revision. Reject traversal, symlink escapes,
missing dependencies, and unsupported dynamic dependency references. External
executables/providers remain runtime dependencies and cannot be claimed pinned
by a bundle digest; their authorized configuration is separately snapshotted.

Selected resolution takes `(workflowId, originId, revision)` and an authenticated
policy context. It loads only that bundle, checks the entire indexed manifest,
validates the workflow and effective capabilities, then copies the dependency
closure into a runtime-owned immutable snapshot. Copy and hash from protected
descriptors; detect source change during capture. Publish the snapshot before
the DB references it. A crash can leave an unreferenced snapshot, never a queued
task pointing to an unpublished one. Store the manifest and digest with the
dispatch record. The worker rehashes it and never resolves a bare name again.
Origin/revision remain identical from card to contract to execution. Drift
returns `revision_changed` and requires fresh selection, not automatic repinning.

Revalidate current actor permission, workflow activation, and effective policy
before queued work starts. Revocation blocks startup; do not silently replace
the selected workflow. Nested workflow calls use an authorized pinned resolver;
resolve and persist the selected callee at each call boundary, inherit the
parent permission ceiling and depth limit, and prohibit name-based fallback
outside that policy. Each nested call also uses the durable invocation and
parent-result delivery contract in section 6; a pinned resolver alone does not
make a nested launch recoverable. Listing a workflow does not grant execution
permission.

Callable input is the existing manager-or-entry node contract, selected by the
same helper used by inspect. The runner enters that callable step explicitly
for this path. Validate the complete business payload against its JSON schema,
including required keys, types, bounds, enums, nested objects/arrays, and
additional-property rules. Reuse the existing schema validator where supported;
unsupported schema keywords/references must fail closed rather than imply
validation. Reserve runtime-owned keys separately and reject caller attempts
to supply them. Run this validation both before enqueue and immediately before
first node execution against the identical snapshot and canonical payload.
Legacy absent schema means an object contract plus size/depth/reserved-key
checks, explicitly reported as `schema_unspecified`; no fabricated schema.

## 5. Specialist decisions, identity, and atomic ownership

Operator configuration declares specialist IDs, business domain descriptions,
model/backend, deterministic priority, positive capacity, accessible origins,
execution capability ceilings, and allowed chat/tracker mappings. Agent output
cannot edit these values. Each specialist returns one typed result:
`claim`, `decline`, `clarification`, or `status`, with a bounded reason and,
for claim, an exact card identity. Identity is supplied by the invoked adapter,
not a `specialistId` asserted in model output.

### Request routing before ownership

Persist a request-level route independently of task lifecycle. Explicit CLI
operations and chat `/status [taskId]` or `/cancel <taskId>` commands go directly
to authenticated control handling and never enter ownership classification.
For ordinary prose, a bounded read-only intent pass using the production agent
adapter returns `status`, `new_work`, or `routing_clarification`; it has its own
reserved concurrency lane and sees only the message and authorized task
identifiers, not full workflow contracts. Natural-language status goes directly
to the same status resolver. Ambiguous or timed-out intent returns a routing
clarification; it cannot default to creating work. Cancellation requires the
explicit command, not model-inferred authority. The classifier prompt documents
these command forms and routing outcomes.

New-work candidates proceed to the specialist round, still keyed by request ID
with no task/owner/slot allocated. Specialist `status` remains an advisory
correction of the initial intent decision. Settle the following table over
validated decisions at the recorded deadline, before any claim transaction:

| Specialist decisions | Final route and allowed effects |
| --- | --- |
| At least one status, no claims | `status`: resolve the requester's explicit reference or authorized thread context. Declines/clarifications cannot convert it to new work. |
| Both status and claim | `routing_clarification`: ask whether the requester wants progress or new work. Do not choose a claim by priority. |
| No status, at least one claim | `new_work`: create one task and apply the ownership/capacity rules below. |
| No status/claim, at least one clarification | `new_work`: create one unowned needs_clarification task for the business-input question. |
| Only declines, or unavailable decisions without a valid outcome | `new_work`: create one unclaimed task and record incomplete coverage when applicable. |

Explicit control routes are final and bypass this table. An invalid classifier
result is unavailable, never authorization. A sealed round cannot be changed by
a late result; persist its deadline, accepted decision set, and route. A routing
clarification reply uses a new source event linked to the original request and
expected request version; only its settled new-work route may create the unique
task. Task uniqueness is enforced by originating request ID across these replies.

For a status route, ignore model-invented task identifiers: only an explicit
reference in the request or the authorized thread resolver may select a task.
Zero or unauthorized matches produce the same not-found response; one returns
persisted status; multiple return an authorized disambiguation list. No failed
lookup falls back to new work. Status and routing clarification may write only
request/audit receipts and a chat-response outbox event, never task creation,
ownership/capacity changes, tracker creation/update, or workflow dispatch.
An accepted response is persisted and replayed on source/request retry; a fresh
status event obtains a fresh observation. These rules apply in every completion
order and before any specialist's claimed expertise is considered.

### New-work settlement and ownership

Ship an authored classifier prompt that asks whether the request belongs to
the specialist's business domain, requires those structured outcomes, treats
chat/card text as quoted data, and prohibits tool execution, permission claims,
invented progress/ETA, and full-contract requests for unselected candidates.
An owner input-preparation prompt may see the selected contract only. Persist
request/round ID, policy/catalog revision, per-specialist output, validation result,
deadline, and final decision. Bound retries/time and record timeout/error as
unavailable. Restart reuses accepted decisions and resumes only missing ones.

Settle on completion of the round or its recorded deadline, never on whichever
network result arrives first. Apply the routing table first; the following
rules run only for a settled new-work route. Eligible claims are ordered by configured
priority then specialist ID. With multiple claims select the first with
capacity and record `multi_owner_resolved`, all candidates, and the reason.
With no claims, choose `needs_clarification` if any valid clarification exists,
else `unclaimed`; incomplete classifier coverage remains explicit in the
receipt. If all eligible owners are full, return `capacity_wait` and retry the
persisted candidate order on release. Late decisions cannot displace an owner.

`BEGIN IMMEDIATE` atomically checks task state/version, selected identity,
policy, capacity reservations, and owner absence; writes the owner, reserves a
slot, increments version, and inserts one ownership outbox event. Unique task
ownership and slot constraints arbitrate across independent connections and
processes. Declining or losing specialists cannot mutate a claimed task.
Capacity counts claimed, clarification-with-owner, queued, running,
cancel-requested, and recovery-required tasks; configurable clarification TTL
releases only tasks with no child, through an explicit transition. Terminal
transition releases capacity once. Monitor lease expiry never releases capacity
or changes business ownership. Explicit reassignment keeps the child identity
and requires authorized control plus an atomic new capacity reservation.

All calls carry a trusted principal binding: profile/tenant, adapter account,
chat/room, thread, actor, and specialist where applicable. CLI uses an explicit
operator principal with local-state access, not a model-provided actor flag.
Provider envelopes bind remote actor IDs; request JSON cannot impersonate them.
Requester and configured delegates can inspect/control a task; specialists may
act only as its current owner. Never reveal an unauthorized task's existence.
Reference-free status resolves only within authorized thread context: zero
matches gives not-found, one gives its status, multiple return authorized task
IDs and ask for selection. Explicit task IDs still undergo the same checks.

Unique inbox key is `(profile, adapterAccount, room, providerEventId)`; request
idempotency is `(principalScope, operation, requestId)`. Store canonical request
hash and original response. Identical retry replays that response; changed
payload under the same key is `idempotency_conflict`. A clarification reply is
a new source event linked to the same task, with expected task version; it
does not create a second task or dispatch. Dedup tombstones outlive payload
retention and the maximum provider replay window.

## 6. Storage, execution, and recovery

Use versioned additive supervisor tables in the same canonical runtime SQLite
database as child snapshots; reuse the supplied-connection persistence APIs.
No migration drops existing data. Refuse unknown future schemas. Keep task
payloads/snapshots in profile-private storage; credentials stay in configured
secret providers and never in events, prompts, outbox bodies, or command lines.

| Record | Required durable fields/invariants |
| --- | --- |
| Task | ID, requester identity/ACL, chat/thread/source/request correlation, owner, policy revision, typed lifecycle, version, last observed progress/time, error, cancellation request/confirmation, timestamps |
| Classification/claim | Request/round and specialist IDs, input hash, ordered decisions, sealed route/deadline, optional task ID until new-work settlement, ownership/capacity slot, assignment generation |
| Dispatch | Unique task ID and dispatch ID, child session ID, exact origin/revision/snapshot, validated input/hash, authorized effective configuration, prepared/started/terminal evidence |
| Nested invocation | Unique invocation key, root dispatch ID, parent session/source execution/transition/branch identity, callee target and pinned origin/revision, handoff hash, reserved child ID, resume destination, phase, execution generation, terminal result/hash and parent-delivery key |
| Child | Prepared runtime snapshot, parent/root session correlation, task ID, runtime generation, durable node start/result records and progress cursor |
| Lease | Role, holder ID, monotonic generation, acquired/expiry times; compare-and-swap token on every privileged write |
| Update | Unique `(taskId, sequence)` and source child-event ID, typed factual change and timestamp; no fabricated percentage/ETA |
| Inbox/request | Provider cursor, stable event/request key, canonical hash, processing state, route/version, nullable task link and accepted response |
| Outbox/delivery | Stable event ID, task sequence or request-response identity, nullable task link for status/routing replies, destination/account/mapping revision, immutable payload/hash, state, attempts, next attempt, lease generation, remote receipt and uncertain-delivery evidence |

Request lifecycle: `received -> classifying -> status | routing_clarification |
new_work` (explicit control requests bypass classification). Only settled
`new_work` creates a task. Initial task state: `unclaimed | needs_clarification |
capacity_wait | claimed`; `claimed -> needs_clarification | queued | failed`;
`queued -> running | cancel_requested | recovery_required | failed`;
`running -> succeeded | failed | cancel_requested | recovery_required`.
Cancellation before reservation can confirm `cancelled` atomically. After
reservation, record `cancel_requested`; only runtime confirmation yields
`cancelled`. Completion may legitimately win the race and yield `succeeded`.
An ambiguous stop remains `recovery_required` with the cancellation request
retained. Terminal state is immutable except explicit administrative repair
with an audit record. Delivery status is orthogonal to execution status.

The enqueue transaction reserves the unique dispatch ID and child session ID,
saves the prepared runtime session and input, and marks the task queued. This
requires a real additive runtime reservation/prepared-session API: the existing
runner allocates sessions inside `resolveSessionEntry` and a best-effort
session-start event callback cannot close the startup crash window. The
supervised path must refuse to execute if reservation or mandatory persistence
fails; ordinary CLI persistence behavior remains compatible. Request routing
states precede this task lifecycle; status-only requests have no task row.

### Nested invocation reservation and parent delivery

The existing runner publishes a parent step before calling
`dispatchCrossWorkflowCallee`, which currently allocates a fresh child and then
appends the result to the parent. Supervised execution must close both gaps
through the same durable runtime composition, without changing the authored
synchronous workflow-call semantics. Do not reuse that path unchanged.

Runtime-derived invocation identity is the tuple `(rootDispatchId,
parentSessionId, sourceStepExecutionId, transitionOrdinal, branchId)`; a
non-branch call uses a fixed empty branch ID. Ordinal is the transition's stable
position in the pinned parent definition, never its display label. Store a
unique invocation ID for that tuple. A replay with changed target, entry/resume
step, handoff hash, or pinned identity fails as a conflict. A later legitimate
loop iteration has a distinct source execution ID; recovery must reuse the
recorded execution ID instead of minting another one.

1. Commit parent step output/publication, an invocation intent containing the
   target and canonical handoff, and the parent's waiting-invocation checkpoint
   atomically. Do not publish a recoverable completed parent step without its
   intent, and do not release the parent resume step yet. Other supervised
   child-producing transitions, including fanout branches, use the same
   identity rule and durable join barrier with distinct branch IDs.
2. Resolve and snapshot that selected callee under section 4, validate the
   actual target entry-step contract and permission ceiling, then atomically
   bind the immutable snapshot/input and reserve its child session on the
   invocation. Phases are `intent`, `prepared`, `running`, `terminal`, and
   `delivered`; validation failure records a terminal failure without execution.
   A crash before binding may repeat resolution because no child can run;
   after binding, origin/revision and child identity cannot change on recovery.
3. Run only the reserved child under the root execution exclusion and a
   per-invocation fenced execution gate. Nested calls can await completion in
   the worker process; they never block serve's chat/status lane. A new monitor
   cannot acquire execution authority from an expired monitor lease. Reopen
   looks up the invocation and session, not a bare workflow name.
4. Persist the child terminal result before attempting parent delivery. Use
   `(invocationId, terminalGeneration, resumeStepId)` as a unique internal
   delivery key. One DB transaction appends the parent workflow message,
   marks the invocation delivered, and advances the parent checkpoint (or
   records the branch result and satisfies its join barrier). Repeated
   delivery returns the already-recorded receipt; a changed result hash fails.
   Failure/cancellation follows existing caller failure semantics through an
   equally idempotent terminal record, never a fabricated success message.

Recovery first reconciles pending invocations before advancing the parent.
Intent-only resumes preparation, prepared-only starts the reserved child,
running attaches or enters effect reconciliation, and terminal-undelivered
replays only internal delivery. Delivered invocations never rerun the child or
parent producer step. Parent resume/join work must use durable node-start/result
boundaries too; repeated recovery cannot advance it twice. An unresolved nested
effect blocks automatic parent resume, root terminal projection, and capacity
release. Cancellation propagates durably to all reserved descendants; root
cancelled confirmation requires their confirmed stops or terminal outcomes.
Loss of a worker lock alone does not prove external subprocess effects stopped.

An invocation intent without its matching parent publication, a missing
prepared child, or a conflicting completion receipt is corruption/recovery
required, not permission to allocate a replacement session. Step 4 must plan
the publication/store/runner changes and crash tests together; top-level
reservation tests alone do not establish this contract.

Serve starts bounded child worker processes through the trusted Riela executable
and an internal `specialist execute --dispatch-id` operation. Payload and
credentials are loaded through the authorized store, not shell interpolation.
Each worker holds a kernel-backed per-dispatch exclusive lock for its complete
execution and uses the reserved session, never `run` with a fresh identity.
The dispatch transition from prepared to started is committed under that lock
before any adapter effect. Duplicate launch attempts attach to the recorded
child or exit without running nodes. PID alone is not liveness evidence.
The supervisor's monitor lease is distinct from this execution lock; expiry
does not revoke a live worker's identity or authorize a replacement execution.
If a worker stalls, request cancellation and retain capacity until its death
and effect state are known. Local state must reside on a filesystem with
supported SQLite/lock semantics; multi-host shared storage is not supported.

Supervised execution must durably record node-start and result/publication
boundaries before advancing. Persistence failure halts further adapter calls.
Arbitrary existing workflow nodes may perform effects outside the outbox;
never replay an interrupted node merely because its result was not saved.
Child subprocess hooks/outputs cannot grant permissions, change destination,
forge terminal progress, or alter reservations. Execution uses the intersection
of operator, requester, specialist, and workflow capabilities. Unsupported
capability enforcement causes preflight rejection, not an unrestricted fallback.

| Crash boundary/evidence | Reconciliation behavior |
| --- | --- |
| Inbox committed, classifier not complete | Resume missing decisions from the persisted round. Do not make another task. |
| Owner committed, no dispatch | Retry clarification/input preparation; ownership announcement already has a stable outbox key. |
| Prepared dispatch/session, worker not started | Start the same reserved dispatch after lock acquisition; no new session. |
| Worker running, serve restarted or lease expired | Observe the existing session and execution lock; reacquire monitoring only. |
| Started record, execution lock free, no node-start record | Resume the prepared session under a new fenced execution generation. |
| Node started, no conclusive result | Mark recovery_required; reconcile provider receipt if supported. No automatic replay of uncertain effects. |
| Durable safe checkpoint, prior worker proven gone | Resume the same session only when no in-flight effect is unresolved; do not rerun completed nodes. |
| Parent publication committed with nested intent, child not prepared | Resume that intent and reserve one child; never rerun the parent producer step. |
| Nested child reserved, crash before launch | Start the same invocation/session after execution exclusion; duplicate reservation returns the original identity. |
| Nested child terminal, parent message absent | Deliver the persisted result under the unique invocation delivery key; do not run the child again. |
| Parent message/checkpoint committed, delivery acknowledgment lost | Return the existing delivery receipt and resume from the committed checkpoint without duplicate messages or join arrivals. |
| Child terminal, task projection absent | Project terminal snapshot with unique source-event key and release capacity once. |
| Outbox send recorded in progress, no receipt | Enter delivery reconciliation; do not assume failure and blindly repeat creation. |

The runnable control surface includes `specialist reconcile` to report these
states and accept scoped operator evidence for a confirmed remote receipt,
confirmed no-effect retry, or terminal failure. Evidence resolution has a
request ID and expected version; it never launches a new child implicitly.
Unreconciled work stays visible in status/list and continues to reserve capacity.
Manual reconciliation is a supported uncertain-effect outcome, not a silent
loss, an automatic exactly-once guarantee, or permission to repeat effects.

## 7. Chat, tracker, and outbox boundaries

Serve has independent bounded intake, classification, execution, monitoring,
and delivery lanes with separate DB connections and no network calls inside
write transactions. A dedicated status/cancel lane bypasses specialist
classification and child capacity; the bounded prose-intent pass has separately
reserved capacity as defined in section 5. Routing ambiguity produces a chat
clarification without creating work. Polling commits a page's accepted events before advancing its
cursor; duplicate pages replay receipts. Backpressure returns a typed retryable
response without losing accepted events. Shutdown stops intake, drains small
transactions, and leaves durable queued/running work recoverable. In-memory
Tasks may schedule work but are never its source of truth.

Matrix production intake verifies the configured homeserver/account, binds
sender/room/thread/event ID from the provider envelope, and ignores own/bot
messages unless explicitly configured. Reuse/extract existing Matrix HTTP
client behavior with transport injection. Ownership announcements say who
owns task `<id>` and whether it is queued or needs input. Status shows the last
observed child step/state and timestamp, including stale/uncertain warnings.
Use the persisted outbox event ID as Matrix transaction ID, including retries.
Transport response parsing must return remote receipt/error classification.
Chat replies must not contain raw workflow prompts, secrets, or unbounded output.

Provide a reusable tracker boundary for create-or-link task, map lifecycle
status, append bounded update, and find/reconcile by correlation key. The Wrike
adapter uses the existing gateway reader/writer capability tiers with an
injectable production transport. Never require admin/delete capability.
Trusted configuration maps folder/project, workflow status IDs, title/body
templates, assignee mapping, and a correlation custom field. Validate mapping
readiness before enabling the adapter; raw LLM text cannot select a folder,
credential, assignee, mutation, or endpoint. Support a supplied authorized
existing Wrike task ID as well as create-on-claim. Persist the remote task ID.

Authored mapping: claimed/queued -> configured active status with owner and
local task ID; running -> active with verified step; needs_clarification ->
configured pending status; succeeded -> configured completed; failed ->
configured failure status; cancel_requested -> active plus cancellation-request
comment; cancelled -> configured cancelled. Wrike status IDs are configuration,
not assumed universal constants. Projection failure never rewrites child state.

Each state transition and its outbox events commit together. Stable event ID is
derived from task ID, sequence, destination identity, and operation. For replies
without a task, derive it from accepted request ID, response revision,
destination identity, and operation. Payload
and mapping version are immutable for that event. Delivery uses per-destination
sequence ordering so an old active update cannot overwrite a terminal update;
chat and tracker queues are independent. New status replies have a responsive
lane and may report a pending ownership/tracker delivery. Within a task, create
must resolve before tracker updates requiring its remote ID.

Classify outcomes as delivered, definitely-not-sent retryable, permanent-failure,
or uncertain. Persist capped exponential backoff and bounded jitter (injectable
clock/randomness), honor bounded Retry-After, and retain failed records with
operator retry. Expired delivery leases become uncertain if a send began;
fencing rejects stale local acknowledgments but cannot cancel a remote request.

Matrix can replay its stable transaction ID. Wrike creation/comment delivery
uses a persisted correlation marker and reader lookup before retry. After a
timeout, a found matching receipt resolves success; conflicting/multiple
matches require reconciliation. A negative or eventually consistent lookup
alone does not prove that a write was never accepted. If the provider cannot
establish absence or idempotency, suspend automatic retry as uncertain. Absolute
status-setting may be retried only with ordering and receipt safeguards.
Never claim exactly-once remote effects; guarantee local deduplication and
explicit, recoverable uncertainty. Tests must cover response loss after the
stub server accepted a mutation.

## 8. Runnable surface, rollout, and verification

Required additive commands (to be implemented, not existing command claims):

```text
riela specialist catalog refresh --config <path> --output json
riela specialist catalog list --config <path> [--query <text>] [--limit <n>] [--cursor <cursor>] --output json
riela specialist serve --config <path> --state-root <path>
riela specialist submit --config <path> --state-root <path> --request-id <id> --input-file <path> --output json
riela specialist status --config <path> --state-root <path> --task-id <id> --output json
riela specialist cancel --config <path> --state-root <path> --task-id <id> --request-id <id> --output json
riela specialist reconcile --config <path> --state-root <path> [--task-id <id>] --output json
riela specialist smoke --state-root tmp/specialist-supervisor/smoke --output json
```

The smoke command must exercise the command parser, production service
composition, registry lookup, schema validation, SQLite, real child runner,
outbox, and reopen/reconciliation with stub LLM/Matrix/Wrike transports. It
uses an existing registered fixture workflow with a controllable long-running
node, asserts an ownership receipt and status response before releasing that
node, then asserts terminal chat/tracker projection. Stub mode fails closed if
any live transport or real credential is selected. Document configuration,
classifier prompt, mapping, startup, stop/restart, task lookup, and uncertain
delivery repair in `examples/specialist-task-supervisor/README.md` and refresh
the affected command docs. Installation of a daemon is not part of verification.

Deterministic integration tests must use two independent SQLite connections
and, where process exclusion matters, real subprocesses. Use barriers/fake
clocks rather than timing sleeps; failpoints surround actual durable commits
and sends. Do not replace the component whose invariant is being tested.

| Acceptance signal | Required assertion/test gate |
| --- | --- |
| Short-only discovery | All project/user/package/mutable origins, same-name precedence, pagination, legacy fallback, bounded fields; reader spy proves list does not load prompts/contracts; secret canaries absent from list and classifier input. |
| Multiple specialists | Every decision, no owner, multiple claims in reversed completion orders, capacity exhaustion/release, round timeout/restart, same-task and last-slot races across DB connections. |
| Status routing (SELF-02) | Explicit and prose status, status-only rounds, status plus decline/clarification, status plus claim in every completion order, unknown/unauthorized/ambiguous references, timeout and replay. Assert zero new task/owner/slot/tracker/dispatch records for status or routing clarification, while one deduplicated chat response is delivered. |
| Identity and dedup | Wrong requester/owner, cross-thread/account/profile access, ambiguous status, forged specialist/actor, source replay, changed request hash, clarification replay, policy revocation and nested permission escalation. |
| Real asynchronous dispatch | Existing registered workflow executes once; schema-invalid/unsupported input does not enqueue; selected-only contract loading; origin and prompt/shared-node/script revision drift rejected; immutable snapshot tampering fails. |
| Durable recovery | Failpoints before/after inbox, claim, reservation, worker start, node start/result, task terminal projection; serving-process restart during live worker does not restart it; dead worker recovery retains child identity and refuses uncertain-node replay. |
| Nested invocation recovery (SELF-01) | Crash before/after atomic parent publication plus intent, after child reservation before launch, after child completion before parent delivery, and after message/checkpoint commit before acknowledgment. Reopen twice and race two connections; assert one child identity, one execution of a stub effect, one parent message/resume or branch join arrival. Cover changed-payload conflicts, distinct loop iterations/branches, nested cancellation, and uncertain effects blocking parent progress. |
| Fencing and cancellation | Expired/stale monitor and outbox generations cannot write; execution lock prevents duplicate workers; cancel-before-start, cancel-versus-completion and unknown cancellation stay truthful. |
| External boundaries | Authored Matrix/Wrike mappings, stable event IDs, 429/backoff, permanent error, response loss after acceptance, eventual-consistency negative lookup, conflicting receipts, ordered updates and no live writes. |
| Responsive status | Hold child and tracker transport on barriers; multiple authorized status queries and a new chat event complete before release, including during classification saturation. |
| Usable entrypoint | CLI smoke uses real orchestration and child execution; store reopen and subprocess restart preserve receipts and do not duplicate task/child/effects. |

Required implementation verification commands, using planned focused test class
names within existing targets (Step 4 must preserve these names or update the
commands to actual tests):

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'SpecialistCatalogTests|SpecialistSupervisorStoreTests|SpecialistSupervisorIntegrationTests|SpecialistSupervisorRecoveryTests|SpecialistTransportTests|SpecialistSupervisorCommandTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela specialist smoke --state-root tmp/specialist-supervisor/smoke --output json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
```

Run focused tests that actually select cases and record counts, commands, exit
codes, and logs under `tmp/specialist-supervisor`. If unrelated dirty changes
break a gate, retain exact diagnostics and isolate relevant verification
without reverting/editing that work or calling a partial run a full pass.
Current Step 2 validation is source/reference inspection and `git diff --check`
only; build, tests, lint, smoke, and live-provider validation have not run.

Retain independent design, plan, test-integrity, implementation, and adversarial
review gates. Correct every high/medium finding before advancement. The latest
feedback is `comm-000007` from `step3-design-review`: `step3_accepted`,
`accepted_with_low_findings`, `needs_revision: false`. It carries author
acceptance from `comm-000006`. Step 5 plan review remains pending.

| Finding | Severity | Design resolution | Review status |
| --- | --- | --- | --- |
| SELF-01 | high | Sections 4/6 define nested invocation identity, atomic parent publication/intent, child reservation, recovery and unique transactional parent delivery; section 8 adds crash/race assertions. | Author accepted in comm-000006; independently accepted in comm-000007; implementation and crash tests remain mandatory. |
| SELF-02 | medium | Sections 3/5/7 separate request routing from task creation, define status/mixed-decision precedence and authorized resolution, and permit only request/chat reply effects; section 8 asserts absence of task/tracker/dispatch effects. | Author accepted in comm-000006; independently accepted in comm-000007; implementation and routing tests remain mandatory. |
| STEP3-DOC-01 | low | Section 6 now separates request classification from initial task state. | Corrected during Step 4 documentation update; not a new independent review. |
| STEP3-DOC-02 | low | Header and this table now record comm-000006 author acceptance and comm-000007 independent acceptance. | Corrected during Step 4 documentation update; Step 5 remains pending. |

Author checks cover all eight acceptance signals, explicit failure states,
review gates, and source-backed capability corrections. This handoff updates
the design and implementation plan; the new behavior and tests remain implementation
requirements, not executed verification evidence.
No unresolved user decision is required; if later discovery forces a product
choice, record it under `design-docs/user-qa/` before requesting an answer.

Preserve all initial dirty files, including Package.swift/Package.resolved,
README.md, SQLite sources/tests, trio examples, and monja/shared-session-store
documents. Use apply_patch and work in this checkout; no worktree changes.
This design-only change does not affect package digests. Implementation must
refresh affected `riela-package.json` digests after workflow, prompt, script,
or packaged skill edits. Keep scratch evidence in `tmp/specialist-supervisor`;
do not remove the running workflow's artifacts during a step handoff.

## 9. Review risks and intentional divergences

- Durable reservation, node persistence, and child locks cross existing runtime
  boundaries; they must ship together. A detached Task or callback-only session
  correlation is not an acceptable implementation substitution.
- Index refresh may cost time for large registries; it is outside compact list
  responses and must expose readiness/progress rather than stall chat status.
  Exact revision covers declared dependencies, not arbitrary external code.
- Arbitrary workflow effects and Wrike creation lack universal exactly-once
  semantics. Conservative recovery can require operator evidence and retain
  capacity; status must make this visible.
- Matrix is the first real chat adapter; other chat providers are deferred,
  while responsive chat, real dispatch, Wrike projection, and restart handling
  are mandatory for this slice.
- Hermes/OpenClaw concepts inform progressive disclosure and session
  attribution. Riela keeps registered workflows, existing capability tiers,
  explicit local lifecycle operations, and stricter uncertain-effect handling;
  it does not clone their agent tool vocabulary or Cursor behavior.
- This artifact records accepted design scope; production functionality,
  implementation tests, and live provider behavior remain unverified.
