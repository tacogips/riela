# Specialist task supervisor implementation plan

Status: Step 6 remediation after `comm-000118` is in progress. T3, T4, T6, T7, T8, T9 and the related AC claims remain revision-required until the current focused and aggregate evidence is retained.
Updated: 2026-09-07. Workflow mode: `issue-resolution`.
Issue: `local-request:specialist-task-supervisor`.
Execution: `codex-design-and-implement-review-loop-session-2`.
Source of truth: `design-docs/specs/specialist-task-supervisor.md`, sections 1–9.
Author design acceptance: `comm-000006`; Step 5 plan acceptance:
`comm-000010`. The earlier Step 6 completion decision `comm-000047` was
superseded by `comm-000051`, `comm-000053`, and `comm-000055`: revisions are
required and Step 7 must not begin until every required matrix is complete.
`codexAgentReferences: ["step6-implement", "comm-000040", "comm-000041",
"comm-000042", "comm-000044", "comm-000045", "comm-000046", "comm-000086",
"comm-000088"]`; no Cursor parity mapping
applies.

## Scope and execution rules

Deliver one complete, reviewed, uncommitted vertical slice: short registry
discovery, real specialist LLM decisions, atomic ownership, Matrix ownership
acknowledgment, Wrike projection, existing registered workflow execution,
responsive status, and durable recovery. Use the additive `specialist serve`
path accepted in the design. Ordinary synchronous workflow-call and existing
event listener behavior remain compatible. No new node kind is exposed.

One cohesive plan owns store, runtime, CLI, and verification contracts. Do not
fan out feature plans. All tasks below are sequential; `parallelizableTasks: []`
because their write scopes and integration contracts overlap. Separate workflow
review steps supply independent review; this author step does not approve them.

Work only in `/Users/taco/gits/tacogips/riela`; use `apply_patch` for edits.
Do not commit, stage, push, change worktrees, create external tasks, send external
messages, or make live Wrike writes. These runtime constraints override installed
workflow finalization prompts. All scratch, logs, failpoint files, smoke state,
and evidence belong in `tmp/specialist-supervisor/`. Preserve existing workflow
and reference evidence during handoff; clean only task-owned disposable files
after final evidence has been summarized.

Preserve user edits in `Package.swift`, `Package.resolved`, `README.md`,
`Sources/RielaSQLite/SQLiteDatabase.swift`,
`Tests/RielaSQLiteTests/SQLiteDatabaseTests.swift`,
`Tests/RielaSQLiteTests/SQLiteContentionTests.swift`, `examples/README.md`,
`examples/catalog/chat-persona-and-agent-trio.md`, trio `EXPECTED_RESULTS.md`
files, `examples/monja-typescript-sdk/`, and monja/shared-session-store docs.
Prefer new focused files; any necessary Package.swift dependency change is
additive, with no dependency upgrade. README additions must preserve existing
dirty hunks. Do not edit RielaSQLite to implement supervisor storage.

Use existing `RielaCore`, `RielaWorkflowRegistry`, and `RielaCLI` modules. New
filenames below are planned, not claims of existing APIs. Keep typed lifecycle,
route, decision, and receipt enums. Split touched non-generated Swift files over
1,000 lines by responsibility, without unrelated refactors or widened access.
Apply `.codex/skills/swift-coding-agent/SKILL.md` during implementation, including
explicit Xcode toolchain and SwiftLint gates.

## Tasks, deliverables, and dependencies

Every task starts `NOT_STARTED`. Task completion requires its code, meaningful
tests, and recorded evidence; writing interfaces alone cannot complete a task.
Verification IDs refer to the command ledger below.

### T1 — Confirm baseline and freeze integration contracts

Depends on: accepted Step 3 design and independent Step 5 plan acceptance before
implementation begins. Write scope: this plan's progress log and task evidence.

- Record current HEAD, dirty paths/diffs, target dependencies and baseline build
  diagnostics. Inspect nearby source/test conventions and file sizes.
- Confirm supplied-connection runtime persistence, session-entry allocation,
  publication transactions, cross-workflow/fanout dispatch, existing schema
  validator coverage, production agent capability enforcement, Matrix client,
  and Wrike reader/writer gateway composition. Record exact symbols in the log.
- Freeze contracts for trusted principal, compact card, snapshot, request route,
  dispatch reservation, nested invocation, reconciliation evidence, and injected
  transports/clocks/process launcher. Keep authorization derived from trusted
  configuration/provider envelopes. Unsupported enforcement must fail preflight.
- Verify the GraphQL server still lacks executeWorkflow before mentioning API
  support; use local runner composition. Do not rely on example-only
  `riela/start-workflow` or treat current Wrike/progress/lineage as missing.

Verification: V0, V1 baseline; record findings without modifying user work.

### T2 — Durable request, task, ownership, and outbox store

Depends on: T1. Write scope: new `Sources/RielaCore/SpecialistModels.swift`,
`SpecialistSupervisorStore.swift`, focused schema/transition extensions,
`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift` integration,
and `Tests/RielaCoreTests/SpecialistSupervisorStoreTests.swift`.

- Add versioned supervisor tables to the canonical runtime database using
  supplied connections, migration preservation, and future-schema refusal.
  The supervised open path must never discard an incompatible store.
- Persist every design section 6 record: inbox/cursor/request hash/response,
  nullable task link, classification round/decision/deadline, task ACL and
  correlation, assignment/slot, dispatch/child identity, nested invocation,
  update/progress cursor, leases, immutable outbox and remote receipts.
- Implement unique source and scoped request keys, payload-conflict rejection,
  replayed responses, task uniqueness by originating request, tombstone retention,
  expected-version transitions, owner checks, and generation-fenced writes.
- Use one immediate transaction for eligible ownership plus capacity reservation
  plus ownership/tracker outbox events; no network calls inside transactions.
  Terminal projection releases capacity once. Monitor expiry never releases it.
  Owned clarification counts toward capacity; TTL release applies only without
  a child. Authorized reassignment reserves new capacity and keeps child identity.
- Distinguish request received/classifying/routing from task initial states;
  cancel_requested from confirmed cancelled; delivery failure from child failure.

Verification: V2 store cases use two independent SQLite connections for same-task
claims, last-slot races, stale versions/generations, migrations, replay conflicts,
wrong-owner writes, TTL, reassignment, and cancellation/completion races.

### T3 — Compact catalog, immutable selection, and callable validation

Depends on: T2. Write scope: workflow metadata models in `Sources/RielaCore/`,
new `Sources/RielaWorkflowRegistry/WorkflowCompactCatalog.swift` and
`WorkflowExecutionSnapshot.swift`, existing registry catalog/service/mutation
integration, shared callable inspection helper and
`Sources/RielaCLI/WorkflowValidateInspectCommands.swift`,
`Tests/RielaCLITests/SpecialistCatalogTests.swift`.

- Add optional shortSummary/tags/domain with design section 4 scalar/count bounds,
  deterministic normalization and legacy top-level-description/ID fallback.
  Cards exclude paths, contracts, prompts, environment and detailed diagnostics.
- Maintain a separate compact index on registry/package mutations and explicit
  refresh. List all accessible origins with stable pagination, activation state,
  optional query filtering and deterministic ties. Preserve project workflow,
  user immutable, project package, user package, user mutable precedence and
  explicit origin/direct-root resolution. Policy filters precede LLM exposure.
- Separate integrity refresh from list: inventory opaque dependency bytes without
  loading every prompt/contract into discovery. Detect missing/stale inventory;
  selected capture verifies hashes even when size/mtime remain unchanged.
- Build SHA-256 manifests of complete declared executable dependency closures,
  including shared nodes/prompts/scripts/config. Reject escapes, unsafe symlinks,
  missing assets and unsupported dynamic refs. Capture protected descriptors,
  detect concurrent changes, publish immutable snapshots before DB references.
- Fetch only selected `(workflowId, originId, revision)`; reject drift without
  automatic repinning. Rehash snapshots before execution. External binaries and
  providers remain separately authorized dependencies, not digest guarantees.
- Reuse managerStepId-or-entryStepId inspection semantics; validate selected
  entry payload before reservation and again before first node execution.
  Check full supported JSON schema, reject unsupported keywords/references and
  reserved keys; absent schema is bounded object input with schema_unspecified.

Verification: V2 catalog cases spy on full readers; seed prompt/secret canaries,
all origins, collisions, inactive/legacy entries, pagination, permission changes,
selected-only reads, invalid schemas/input, every asset drift class, snapshot
tampering, symlink escape and changes during capture.

### T4 — Production classification and request routing (SELF-02)

Depends on: T3. Write scope: new `Sources/RielaCore/SpecialistRequestRouting.swift`,
`SpecialistOwnershipCoordinator.swift`, `Sources/RielaCLI/SpecialistAgentAdapter.swift`,
authored prompts under `examples/specialist-task-supervisor/prompts/`, and
`Tests/RielaCLITests/SpecialistSupervisorIntegrationTests.swift` routing cases.

- Wire existing production agent adapter for tool-free bounded intent and
  per-specialist claim/decline/clarification/status decisions. Configuration owns
  specialist identity, priority, domain, capacity, origins and capability ceiling.
  Cards/messages are untrusted quoted data; outputs cannot authorize effects.
- Author business classifier and selected-contract input-preparation prompts.
  Persist round inputs, policy/catalog revision, per-specialist validated outputs,
  deadline and sealed result. Resume only missing decisions; late results cannot
  change a sealed round or displace an owner.
- Explicit /status and /cancel bypass classification. Prose intent has reserved
  capacity; timeout/ambiguity asks routing clarification. Cancellation requires
  explicit authenticated control. Status lookup ignores model-invented IDs.
- Apply the complete section 5 table before creating tasks: status plus no claim
  is status even with declines/clarifications; status plus claim is routing
  clarification; remaining claims settle new work; clarification-only produces
  unowned needs_clarification; declines/unavailable produce explicit unclaimed
  with coverage evidence. Deterministic priority/ID selects a claimant with
  capacity, records multi_owner_resolved or capacity_wait, and retries the same
  candidate order after release.
- Route unknown/unauthorized status identically; ambiguous authorized thread
  matches return disambiguation. Status and routing clarification commit only
  request/audit receipts and one chat response. Linked clarification retries
  carry expected versions and cannot create a second task or dispatch.

Verification: V2 permutes specialist completion order, deadline/restart and replay;
asserts zero task/owner/slot/tracker/dispatch changes for status-only,
status+decline/clarification, status+claim, unknown and ambiguous lookup. Exercise
forged principals/specialist IDs, cross-profile/account/thread access, prompt
injection, missing input and saturated classification with status still served.

### T5 — Atomic runtime reservation, nested publication and recovery (SELF-01)

Depends on: T4. This is one indivisible runtime delivery task; do not mark it
complete from top-level reservation tests alone.
Write scope: `Sources/RielaCore/RuntimeStorePublicationTransactions.swift`,
`RuntimePublication.swift`, `SQLiteWorkflowRuntimePersistenceStore.swift`,
`WorkflowRuntimePersistenceSnapshot.swift`, `DeterministicWorkflowRunner.swift`,
`DeterministicWorkflowRunner+CrossWorkflow.swift`, `+Fanout.swift`, `+Recovery.swift`,
new focused reservation/invocation persistence and runner extensions,
`Sources/RielaCLI/WorkflowRunLivePersistence.swift`,
`WorkflowCalleeResolution.swift`, and
`Tests/RielaCoreTests/SpecialistSupervisorRecoveryTests.swift`.

- Add mandatory durable supervised reservation/prepared-session entry APIs.
  Atomically reserve unique dispatch/child IDs, prepared snapshot/input and queued
  task in the same DB. Never allocate a replacement session on retry or use a
  best-effort start callback as the reservation boundary.
- Record node-start before any adapter effect and durable result/publication
  before advancement, including parent resume/join steps. Persistence failure
  stops subsequent effects; ordinary unsupervised persistence stays compatible.
- Atomically commit parent output/publication, invocation intent and waiting
  checkpoint. Key by root dispatch, parent session, source execution ID, stable
  transition ordinal and branch ID. Loops get distinct source execution IDs;
  recovery reuses them. Changed target/handoff/resume/pin is a conflict.
- Resolve selected nested callee with inherited policy/depth ceiling and actual
  entry contract; atomically bind snapshot/input and reserve one child. Persist
  intent/prepared/running/terminal/delivered phases. After binding, no name-based
  fallback or repinning. Extend all supervised child-producing/fanout transitions
  with distinct branch identity, durable result and join barriers.
- Persist child terminal result before parent delivery. One transaction appends
  the parent message, records unique invocation/terminal-generation/resume receipt
  and advances parent checkpoint or branch join. Repeat delivery returns the
  receipt; changed result hash fails. Preserve failure/cancellation semantics.
- Reconcile invocations before parent advancement; delivered children/producer
  steps never rerun. Missing/conflicting publication/session evidence is
  recovery_required. Uncertain nested effects block parent progress, root
  terminal projection and capacity release. Durably cancel all descendants;
  root cancellation confirmation requires their terminal or confirmed stops.

Verification: V2 recovery tests place failpoints before/after actual parent
publication+intent, child reservation, launch, node-start/result, child terminal,
parent message/checkpoint commit and lost acknowledgment. Reopen twice and race
two connections. Assert one child ID, one stub effect, one parent message/resume
or join arrival; cover loop/branch distinctions, conflict hashes, failed child,
descendant cancellation and unresolved effects. V3 guards existing publication,
cross-workflow, fanout, live persistence, resume and cancellation behavior.

### T6 — Worker exclusion, independent lanes, and reconciliation service

Depends on: T5. Write scope: new `Sources/RielaCLI/SpecialistSupervisorService.swift`,
`SpecialistExecutionWorker.swift`, `SpecialistProcessLauncher.swift`,
`Sources/RielaCore/SpecialistReconciliation.swift`, and recovery/integration tests.

- Compose bounded intake, intent/control, classification, execution, monitor and
  delivery lanes with separate DB connections. Hold no actor-wide serialization
  across child or network awaits. Persist accepted input/cursors before polling
  advances; provide typed backpressure without dropping accepted events.
- Launch trusted executable argument arrays for internal
  `specialist execute --dispatch-id`; load authorized payload/config from state,
  never shell commands or credentials in arguments. Use kernel per-dispatch
  exclusive locks for entire execution and per-invocation fenced gates under
  root exclusion. Commit started under lock before effects.
- Duplicate launch attaches/exits; monitor lease expiry cannot replace a live
  worker. Use actual locks/session evidence, not PID alone. Dead safe checkpoints
  resume the same session; uncertain in-flight effects require reconciliation.
- Monitor committed factual progress using durable source cursors; project each
  update once with timestamp/staleness, never percent/ETA invention. Shutdown
  stops intake and leaves recoverable records; serve restart observes live child.
- Implement scoped operator reconciliation with request ID, expected version and
  auditable receipt/no-effect/terminal-failure evidence. No implicit replacement
  child. Unknown effects retain capacity and remain visible. Configuration
  revalidates current activation/actor/policy before starting queued work.

Verification: V2 real subprocess cases contend on worker locks, restart serve
during a held child, kill worker around durable boundaries, reject stale monitor
writes, and prove cancellation truthfulness. Barriers hold child and delivery
while multiple fresh status requests/new chat input finish before release.

### T7 — Matrix and Wrike production adapters with durable delivery

Depends on: T6. Write scope: new `Sources/RielaCLI/SpecialistMatrixAdapter.swift`,
`SpecialistWrikeAdapter.swift`, transport/configuration extensions,
`Sources/RielaCLI/EventLiveServe+Matrix.swift` and
`ProductionNodeAdapter+WrikeGatewayAddons.swift` extraction seams,
new `Sources/RielaCore/SpecialistOutboxDelivery.swift`, and
`Tests/RielaCLITests/SpecialistTransportTests.swift`.

- Extract reusable injectable production HTTP boundaries. Matrix authenticates
  configured account/homeserver and derives actor/room/thread/event from provider
  envelope, ignores own/bot messages by default, persists page acceptance/cursor,
  and uses stable outbox event ID as send transaction ID.
- Wrike uses existing read/write gateway tiers without admin/delete. Validate
  trusted folder/project/status/assignee/correlation-field configuration before
  readiness; support authorized existing-task linking and create-on-claim.
  Persist remote task ID. Models cannot select credentials/endpoints/mutations.
- Author versioned lifecycle/title/body mapping per design section 7, including
  clarification pending, factual running progress, terminal states and separate
  cancellation-request comment. Redact secrets and bound rendered outputs.
- Atomically couple state changes with immutable event ID/payload/mapping version.
  Preserve per-destination order, resolve create before dependent tracker updates,
  keep chat/tracker delivery independent, and reserve a responsive status lane.
- Persist retry attempts, capped backoff/jitter/Retry-After and lease generations.
  Classify delivered, definitely-not-sent retryable, permanent and uncertain.
  Expired begun sends become uncertain; stale local acknowledgments fail fencing.
- Matrix retries retain transaction ID. Wrike creation/comments reconcile stable
  correlation markers through reads. Negative eventually consistent lookup is
  insufficient proof of absence; conflicting receipts or unknown acceptance
  require operator repair. Retry absolute statuses only with ordering safeguards.

Verification: V2 transport tests use stub transport through production adapters:
429, authentication/permanent failures, malformed receipts, timeout after server
acceptance, delayed negative lookup, multiple receipts, stale acknowledgments,
retries/restart, independent destinations and no terminal regression. Assert zero
live transport/credential use; preserve Wrike and Matrix existing tests in V3.

### T8 — Runnable CLI and authored example

Depends on: T7. Write scope: new `Sources/RielaCLI/SpecialistCommands.swift`,
`SpecialistConfiguration.swift`, `SpecialistSmokeCommand.swift`, existing command
dispatch/help registration, `Tests/RielaCLITests/SpecialistSupervisorCommandTests.swift`,
`examples/specialist-task-supervisor/` README/config/prompts/mapping/fixture bundles.

- Register all accepted commands: catalog refresh/list (query/limit/cursor), serve,
  submit (request-id/input-file), status, cancel (request-id), reconcile, smoke;
  preserve design section 8 flags. Add internal execute reserved-dispatch entry.
  Define reconciliation mutation evidence/request-id/expected-version flags and
  document them. CLI principal is trusted local operator, not JSON actor fields.
- Wire real production service dependencies; validate readiness, mapping, index,
  local lock/SQLite filesystem support, private state and secret providers.
  Clarification continuation uses submit with linked IDs/expected version.
  Reconciliation report exposes unresolved tasks without requiring a known ID.
- Ship configured specialist business prompts and Wrike mapping, plus a registered
  existing-workflow fixture with a controllable long-running node. Document
  startup, stop/restart, origin pinning, identity, status, cancellation, and repair.
- Smoke goes through parser and production composition, SQLite, registry/schema,
  actual child runner and worker process, with only LLM/Matrix/Wrike/effect
  boundaries stubbed. Stub mode must reject any live transport or real credential.
  Assert ownership and status response before releasing child; then terminal
  chat/tracker updates, reopen/restart, stable receipts and no duplicate effects.

Verification: V2 command cases assert parser/help/readiness/auth/errors and selected
test counts; V4 runs the documented executable smoke from isolated task state.
No daemon installation or live external write is part of verification.

### T9 — Acceptance and regression evidence

Depends on: T8. Write scope: focused Specialist test files above, new test helpers
under their existing targets, this plan/evidence ledger; production fixes return
to the owning task and rerun affected gates.

- Run V1–V6. Tests use fake clocks, deterministic randomness and barriers rather
  than timing sleeps; failpoints surround real durable writes and sends.
  Never replace the store/runner/adapter under test with an idealized fake.
- Map all seven intake acceptance criteria and every design section 8 assertion
  to actual test names and counts. Zero selected tests is a failed gate. Include
  two-connection races and real process exclusion/restart evidence.
- Record exact baseline failures from user edits, isolate relevant tests without
  changing them, and label partial verification honestly. Do not treat preexisting
  failures as permission to skip reachable tests or declare a full pass.

Verification: command exit codes, test counts, receipt/task/child IDs and relevant
assertion evidence in task-local logs; carry gaps into independent review.

### T10 — Independent gates, documentation, and uncommitted handoff

Depends on: T9, independent test-integrity, implementation and adversarial review
acceptance. Write scope: this plan, accepted design, new example documentation,
targeted additive `README.md` / `examples/README.md` command/example links, and
directly affected usage docs/package manifests only when applicable.

- Retain Step 5 independent plan gate before implementation; later independent
  test-integrity, implementation and adversarial gates remain separate from author
  checklists. Correct every high/medium finding, rerun impacted verification and
  send revised evidence through the owning review gate. Record low risks explicitly.
- Refresh user docs from final implemented behavior and review evidence. Explain
  production adapters versus stub-verified behavior; record remaining live-provider
  validation gap, uncertain-effect repair and single-host filesystem requirement.
- Inspect package ownership after workflow/prompt/script/packaged-skill changes;
  refresh only affected `riela-package.json` digests via its applicable release
  tooling and record exact validation commands. No package digest change is needed
  for this Step 4 design/plan-only update.
- Deliver exact changed-file list, commands/results, review decisions/references,
  limitations and progress log as reviewed uncommitted source. No git finalization.

## Verification command ledger

These are implementation gates, not Step 4 execution claims. Preserve planned
class names below or update commands and traceability to actual tests before
running them. Core store/recovery tests live in RielaCoreTests; catalog, transport,
command and composition tests live in RielaCLITests, which already depends on
RielaWorkflowRegistry. Do not create a new target solely for the test filter.

```bash
# V0 — baseline and preservation evidence
git status --short
git rev-parse HEAD
git diff --stat
rg --files Sources Tests -g '*.swift' | xargs wc -l

# V1 — explicit Xcode build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build

# V2 — required focused gates; record nonzero test counts per suite
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'Specialist(CallableInputValidation|ClassificationReplay|InputPreparation|MatrixRouting|RielaClassifier|ServiceResponsiveness|Supervisor(Boundary|Command|Recovery|Store)?|TransportBoundary|WorkflowSelection|Wrike(Reader|Recovery))Tests|Specialist(RequestRoutingBoundary|Routing|StatusReply)Tests|WorkflowCompactCatalogBoundaryTests'

# V3 — shared runtime, CLI, registry and provider compatibility
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests'

# V4 — real entrypoint/runner with fail-closed stub boundaries
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela specialist smoke --state-root tmp/specialist-supervisor/smoke --output json

# V5 — required lint
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache

# V6 — whitespace, including new documents not visible to ordinary git diff
git diff --check
git diff --no-index --check /dev/null design-docs/specs/specialist-task-supervisor.md
git diff --no-index --check /dev/null impl-plans/active/specialist-task-supervisor.md
```

For new files, no-index exit 1 with no whitespace diagnostics means differences,
not a failed whitespace assertion. During implementation also check each newly
created untracked source/doc file; never stage files merely to make diff see them.
Save logs below `tmp/specialist-supervisor/verification/` and preserve true process
exit codes if redirecting output. Check receipt JSON and assertions, not exit 0 alone.

## Acceptance traceability and completion criteria

| Intake criterion | Tasks | Required evidence |
| --- | --- | --- |
| AC1: compact discovery, existing origins | T3 | V2 reader spies/canaries, bounds, legacy/all-origin listing, precedence and selection pins |
| AC2: multiple decisions, atomic ownership/capacity, replay | T2, T4 | V2 cross-connection races, all routing mixtures/orders and no-owner/multi-owner receipts |
| AC3: valid real async workflow, responsive acknowledgment/status | T3–T8 | V2 and V4 actual registered child held while ownership/status complete; invalid input never queues |
| AC4: correlation, lifecycle, leases, outbox and restart | T2, T5, T6 | V2 root/nested failpoints, repeated reopen, process exclusion, identity and uncertainty assertions |
| AC5: reusable production chat/tracker boundaries | T7, T8 | V2/V4 production adapter composition with stub HTTP and durable retry/receipt evidence |
| AC6: adversarial verification/example coverage | T2–T10 | V1–V6, deterministic store/transport/runner adversarial cases, documented runnable example, and separate reviews |
| AC7: node-behavior decision | T5, T8, T10 | V2/V4 preserve synchronous workflow-call semantics; asynchronous supervision is lifecycle/CLI-backed and ships no incomplete node kind |

Completion requires all T1–T10 deliverables and AC rows with executed evidence;
no unresolved high/medium findings; Step 5, test-integrity, implementation and
adversarial decisions recorded independently; source and docs aligned; user work
preserved; final delivery uncommitted. Required chat/dispatch/Wrike/recovery
integration cannot be deferred or substituted with protocols or detached Tasks.
Deliberately excluded per accepted design: new node kinds, GUI, embeddings,
additional chat providers beyond Matrix, daemon installation and multi-host
shared storage. Live-provider validation remains explicitly unperformed.

## Final Step 6 completion and Step 7 handoff status

This status supersedes the stale `comm-000063`/`comm-000065` rerun notes and
the incomplete attachment-only claim in `comm-000070`. The abrupt CLI process
matrix required by `comm-000077` is recorded, including the post-effect/
pre-terminal boundary. The durable negative/reopen matrices added after
`comm-000079` complete T5 evidence. The post-edit aggregate regression and
smoke are historical evidence only. `comm-000118` reopened this handoff for
delivery-generation fencing, explicit reconciliation, prelaunch cancellation,
input clarification, prompt policy filtering, capacity retry, and catalog
pagination. Step 7 must not re-review until the current regression evidence is
retained. Remaining risks include reconciliation-only remote delivery and
preserved unrelated dirty/untracked work.

| Scope | Final status | Completion evidence |
| --- | --- | --- |
| T1–T2 | Complete | Canonical runtime-backed request/task/ownership/outbox persistence, replay/conflict, capacity, lease, and status tests. |
| T3–T4 | Revision implementation complete; verification pending | Catalog pagination/prompt policy filtering and input-preparation clarification now require current composition evidence. |
| T5 | Complete pending independent review | `WorkflowCommandCrossWorkflowDispatchTests.testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect` SIGKILLs a production `riela` process at every nested checkpoint, including `afterChildEffect` after the durable effect and before nested-terminal persistence. `SpecialistSupervisorRecoveryTests` adds durable failed-child reopen without relaunch, confirmed cancelled-descendant terminal state without parent arrival, unresolved running-child `recovery_required` fencing across two reopens, and lost-parent-acknowledgment double reopen with exactly one arrival. |
| T6 | Revision implementation complete; verification pending | Service recovery now fences expired delivery generations and handles prelaunch cancellation without normal launch. |
| T7 | Revision implementation complete; verification pending | Stable outbox transaction IDs, uncertain delivery reconciliation, and expected-generation evidence are implemented; remote effects remain reconciliation-based. |
| T8 | Revision implementation complete; verification pending | CLI reconciliation mutations and stable catalog pagination are implemented; smoke/documentation must be refreshed against the current code. |
| T9 | Revision verification pending | Current focused and aggregate execution is required after `comm-000118`; historical aggregate evidence is insufficient. |
| T10 | Complete pending independent review | Docs, example, and this plan reflect the implemented lifecycle and the bounded remote-effect risk. |
| AC1–AC3, AC5, AC7 | Revision verification pending | Step 7 remains the authority only after current tests. |
| AC4, AC6 | Revision verification pending | Delivery crash/reopen and operator-reconciliation evidence must be retained. |

Final verification commands and terminal evidence:

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'Specialist(CallableInputValidation|ClassificationReplay|InputPreparation|MatrixRouting|RielaClassifier|ServiceResponsiveness|Supervisor(Boundary|Command|Recovery|Store)?|TransportBoundary|WorkflowSelection|Wrike(Reader|Recovery))Tests|Specialist(RequestRoutingBoundary|Routing|StatusReply)Tests|WorkflowCompactCatalogBoundaryTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela specialist smoke --state-root tmp/specialist-supervisor/smoke --output json
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint --quiet --no-cache
git diff --check
git diff --no-index --check /dev/null design-docs/specs/specialist-task-supervisor.md
git diff --no-index --check /dev/null impl-plans/active/specialist-task-supervisor.md
```

The authoritative `comm-000064` V3 rerun used the explicit Xcode toolchain and
records 1,546 tests and 0 failures. The post-`comm-000067` V3 rerun is retained
under `tmp/specialist-supervisor/verification/v3-post-comm-000067.log` and
passed 1,549 tests with 0 failures. Earlier evidence is retained under
`tmp/specialist-supervisor/verification/`; V1, V4, and V5 terminal evidence is retained
under `tmp/specialist-supervisor/verification/v1.status`,
`v4-rerun.status`, and `v5-swiftlint-final.status`; V6 is retained in
`v6-final.status` (the two `--no-index --check` commands intentionally return
1 for untracked document differences and emitted no whitespace diagnostic). The
final corrected V2 filter passed 63 tests with 0 failures; evidence is retained
at `tmp/specialist-supervisor/verification/v2-final.log` and `.status`.
The subprocess canonical-SQLite recovery matrix is retained at
`tmp/specialist-supervisor/verification/process-cli-recovery.log`. The post-
`comm-000074` aggregate rerun is retained at
`tmp/specialist-supervisor/verification/v3-post-comm-000074.log` and passed
1,586 XCTest cases with 0 failures in 633.269 seconds.

Residual risks for Step 7: no live Matrix, classifier, or Wrike writes were
authorized or performed; remote providers cannot provide a universal
exactly-once guarantee, so uncertain effects remain durable and require
reconciliation; unrelated user dirty work remains preserved.

## Reference mappings and accepted divergences

Use the accepted design's pinned reference evidence, retained under
`tmp/specialist-supervisor/reference-evidence/`; Step 3 reported failed upstream
web fetches and reviewed local evidence. This plan makes no fresh upstream check.

| Reference revision/path | Plan mapping | Intentional divergence |
| --- | --- | --- |
| Hermes `089bb32886c8c18f7fa20182c7bf8826d6935ac5`, `tools/skills_tool.py` | T3 short list/selected full load | Workflow cards and immutable execution closure, no imported skill bodies |
| Hermes same revision, `tools/delegate_tool.py` | T5/T6 child lineage, separate handles, background execution and capability/depth limits | Mandatory durable reservations and conservative effect recovery |
| OpenClaw `1421c216407515ad29061f67e99c50c68f57f1f3`, `src/agents/subagents/registry/subagent-registry.store.sqlite.ts` | T2/T5 correlated execution and delivery state | Riela canonical runtime DB and atomic parent delivery |
| OpenClaw same revision, `src/agents/subagents/registry/subagent-registry-restart-recovery-coordinator.ts` | T5/T6 launch phases and generation fencing | Kernel execution exclusion distinct from monitor leases |
| OpenClaw same revision, `docs/tools/subagents.md` | T6–T8 nonblocking receipt, thread identity and capacity | Local lifecycle CLI, Matrix/Wrike adapters, no cloned agent tool vocabulary |

The supplied old OpenClaw registry path is historical (design cites
`de8c90457776c94262bc86a73f7ebd0f2a07e323`); use the accepted current SQLite mapping.
No external reference code copying is planned. The Step 4 planning input had no
Codex-agent reference; the authoritative Step 6 handoff references are listed
in this plan's header.

## Addressed feedback and author checklist

| Feedback | Plan disposition |
| --- | --- |
| SELF-01 high, accepted at design level in comm-000006/comm-000007 | T5 keeps publication/store/runner changes and crash/routing delivery assertions together; T6/V2 adds process exclusion evidence |
| SELF-02 medium, accepted at design level in comm-000006/comm-000007 | T2/T4 separate request/task records; V2 asserts zero task/slot/tracker/dispatch effects across routing orders and retries |
| Step 3 low: design line 317 lifecycle mismatch | Corrected design section 6 request/task separation in this update |
| Step 3 low: design line 578 stale review bookkeeping | Corrected header/review table to author comm-000006 and latest independent comm-000007 |
| Step 3: no user decision needed | No user-qa entry; preserve accepted boundaries and intentional divergences |

Author check: source of truth accepted; one cohesive dependency chain; all seven
intake criteria mapped; concrete paths/deliverables/tests; independent gates
retained; no production code or provider success claimed. Plan author self-check
finds no unresolved high/medium planning issue; independent Step 5 accepted the
plan with the corrected low traceability finding in `comm-000010`.

## Progress log and risks

Append one entry per completed task, material contract discovery or review cycle:
date, task/status, changed paths, issue/communication/agent references, commands
with exit codes/test counts/evidence paths, findings/fixes, remaining gaps and
next dependency. Mark blocked or partial work explicitly; do not tick completion
from authored tests or mocked guarantees. Keep this plan active until the later
workflow completion gate has accepted the uncommitted delivery.

| Date | Task/status | Evidence and next step |
| --- | --- | --- |
| 2026-09-06 | Step 4 plan authored; T1–T10 NOT_STARTED | Read accepted design/current source seams and skills; corrected two Step 3 documentation findings. Step 5 independent plan review next. No implementation/build/test/lint/smoke run in Step 4. |
| 2026-09-06 | Step 4 documentation verification | `git diff --check`: exit 0. `git diff --no-index --check /dev/null design-docs/specs/specialist-task-supervisor.md` and `git diff --no-index --check /dev/null impl-plans/active/specialist-task-supervisor.md`: each exit 1, new-file differences with no whitespace diagnostics. `git status --short`: exit 0; only the two designated documents were edited by this step. |
| 2026-09-06 | Step 6 T1 complete; T2 partial | Confirmed the accepted plan/design still require a durable request/task boundary and no GraphQL execution mutation. Baseline `swift build` reached `SpecialistSupervisor.swift` and failed on its missing `try` at `verifySchema`; fixed it. Added request-ID replay conflict handling, immutable outbox delivery receipts, generation-fenced delivery completion, and `SpecialistSupervisorStoreTests`. `swift build` exit 0 and `swift test --filter SpecialistSupervisorStoreTests` exit 0 (2 tests); logs are under `tmp/specialist-supervisor/verification/`. T3–T10, canonical runtime-store integration, routing, runner publication, CLI, Matrix/Wrike adapters and smoke are not complete. |
| 2026-09-06 | Step 6 plan-review low finding corrected | Corrected the criterion count and split traceability into AC6 verification/example coverage and AC7 node-behavior decision as requested by `comm-000010` / `PLAN-SELF-01`. |
| 2026-09-06 | Step 6 revision: SELF-02 partial | Added `riela specialist submit`, `status`, and `cancel` parser/CLI wiring backed by the durable store and a local-operator principal. This supplies a persisted status/control path but does not complete classification, catalog selection, child execution, or adapters; SELF-01, SELF-02 and AC1–AC7 remain open until T2–T10 complete. |
| 2026-09-06 | Step 6 revision: CLI-TRUST-01 corrected | Removed caller-supplied account/actor/room controls. Specialist CLI uses the fixed local-operator principal; production chat identity remains reserved for authenticated provider envelopes. SELF-01, SELF-02 and AC1–AC7 remain open. |
| 2026-09-06 | Step 6 continued: T2/T5/T8 partial | Added canonical semantic source fingerprints, opaque Matrix-safe provider identifiers, durable prepared/running/terminal dispatch records, stable child reservations, atomic terminal child-result plus parent chat/tracker outbox intent, recovery listing, registry-selected local CLI submit/execute/status/reconcile commands, and a documented local example. Focused store test exercises redelivery with a fresh request ID and reopen between child completion and delivery. The canonical shared runtime publication, compact index, classifier settlement, worker process exclusion, Matrix/Wrike adapters, serve lanes and true end-to-end smoke remain unfinished; do not mark AC1–AC7 complete. |
| 2026-09-06 | Step 6 revision after `comm-000028`; T2/T3/T4/T5/T7/T8 remain partial | Replaced the separate supervisor database path with the canonical runtime database and atomically published a created child `WorkflowRuntimePersistenceSnapshot` during reservation. `specialist execute` now revalidates a selected origin/closure digest and resumes that reserved child ID. Added compact metadata-only catalog scanning, closure SHA-256 pins, deterministic pure routing settlement, injectable Matrix/Wrike outbox adapters, a bounded `serve` pass, and a hermetic smoke that drives parser → registry → reservation → ordinary runner. Focused gates passed: 17 tests under `Specialist*`, `swift build`, and direct smoke. This is not acceptance: real LLM classification/configuration, authenticated Matrix intake, long-lived worker process exclusion, adapter composition/receipt reconciliation tests, and parent/nested invocation recovery remain incomplete. High findings from `comm-000028` therefore remain open pending a further implementation/review cycle. |
| 2026-09-06 | Step 6 revision after `comm-000030`; T2–T8 partial, feedback repair evidence | Moved supervisor state to `<state-root>/runtime-records/runtime-message-log.sqlite`, matching `CLIWorkflowSessionStore`; the runner now seeds reserved runtime snapshots that have no CLI session record. Smoke decodes the real result and requires terminal child/task success. Added persisted routing records and trusted specialist-config settlement through `SpecialistRequestRouter`; removed `--owner` and caller capacity. Replaced filesystem-only cards with a registry-refreshed compact cache carrying activation/mutable provenance and SHA-256 content revisions; added `catalog-refresh`. Added a fenced service lease and served outbox worker composition through optional trusted transport configuration; receipt-less Wrike 2xx remains uncertain. Focused V2-equivalent suite passed 23 tests. Remaining mandatory work before acceptance: authenticated Matrix intake, real production LLM adapter/round deadlines, complete immutable snapshot/callable-schema capture, long-running multi-lane worker and nested parent delivery/recovery, retry/backoff and provider reconciliation, plus V1/V3–V6 and independent review. |
| 2026-09-06 | Step 6 revision after `comm-000032`; T3/T7 partial | Added a runtime-owned selected-workflow closure capture under `state-root/workflow-snapshots`, sealed against the compact catalog SHA-256 revision and revalidated immediately before the ordinary runner consumes it. Added durable delivery `nextAttemptAt` backoff and per-destination ordering. Replaced the generic Wrike HTTP POST composition with the linked writer-tier `wrike-gateway` adapter, restricted configuration to folder/status mapping, and persist the verified remote tracker task identity before update projections. `swift build` exit 0 and `swift test --filter 'Specialist|WorkflowCompactCatalogBoundaryTests'` exit 0 (27 tests) used `tmp/specialist-supervisor/build`. This remains partial: trusted live-LLM classification, authenticated Matrix intake, durable multi-lane long-running serve, provider receipt reconciliation, nested parent/child invocation publication/recovery, selected callable input-schema enforcement, and V3–V6 are still mandatory. |
| 2026-09-06 | Step 6 revision after `comm-000034`; T4/T5/T6/T7 partial | Replaced normal-submit fixture decisions with a persisted, deadline-bounded authenticated classifier round (`SpecialistAgentAdapter.swift`); fixture decisions now require `--mock-scenario`. Added authenticated Matrix `/sync` intake that derives opaque provider principals, persists its cursor after acceptance, and ignores the configured bot user. `serve` accepts Matrix work before concurrently driving prepared executions and outbox delivery. Added durable nested invocation identity/result publication APIs and recovery tests. The production runner still does not call the nested publication API at cross-workflow/fanout boundaries; compact refresh still uses the registry full listing path; Wrike uncertain receipts lack a read reconciliation operation; and serve remains a bounded service-manager pass rather than a continuously supervised daemon. Those high findings remain open. Initial isolated build was interrupted by concurrent changes to `DeterministicWorkflowRunner+Fanout.swift`; final targeted build/test is pending a stable shared source tree. |
| 2026-09-06 | Step 6 repair after `comm-000036`; T3/T6/T7/T8 advanced, T5 remains partial | Added `WorkflowRegistryService.compactList`, a registry-coordinated metadata-only inventory that avoids `WorkflowRegistryBundleLoader` for discovery while preserving authoritative selected-entry `fetch` validation. Catalog refresh now uses that inventory and skips malformed unrelated bundle headers rather than hiding valid cards. Replaced serialized classifier bearer tokens with a validated secret-provider environment-name boundary. `serve` is now a continuously supervised fenced process by default, with durable lease heartbeats and an explicit `--once` diagnostic mode. Added reader-tier Wrike correlation reconciliation after uncertain writes; negative/conflicting evidence remains uncertain and never authorizes a blind retry. Focused smoke, catalog, store, recovery, classifier, and transport tests were rerun after the catalog repair. The runner still lacks wired nested reservation/publication across ordinary cross-workflow/fanout launch and corresponding crash-window tests, so T5 and final AC4/AC6 acceptance remain incomplete. |
| 2026-09-07 | Step 6 repair after `comm-000067`; T5/T6 evidence complete pending Step 7 | Added parent-runner resume reconciliation for durable nested cross-workflow and fanout records. `NestedRecoveryInterruption` preserves a real parent checkpoint for controlled crash testing; ordinary runtime errors still finalize as failed. The actual-loop and actual-fanout matrices now use `runner.run` → interruption → fresh `runner.run(resumeSessionId:)`, proving one child effect per identity and one parent/join arrival across every nested checkpoint. Added durable running-dispatch attachment generation and made every service execution pass attach/reconcile running children rather than silently skipping them. The FIFO subprocess test now proves SIGKILL/restart attaches the held child with one effect and no relaunch. Focused explicit-Xcode command passed: `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'SpecialistSupervisorRecoveryTests|DeterministicWorkflowRunnerFanoutTests|SpecialistServiceResponsivenessTests'` — 23 tests, 0 failures. Full V3 follows as the final Step 6 gate. |
| 2026-09-07 | Step 6 final V3 after `comm-000067` | Explicit-Xcode command `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests'` passed: 1,549 tests, 0 failures in 602.558 seconds; terminal log: `tmp/specialist-supervisor/verification/v3-post-comm-000067.log`. T5/T6 remain complete pending independent Step 7 review, not final acceptance. |
| 2026-09-06 | Step 6 repair after `comm-000038`; T5/T6/T7 advanced, AC4/AC6 still partial | Wired deterministic nested child reservation into live cross-workflow and cross-workflow fanout paths before their child runs, with reusable parent-result idempotence checks. Reworked normal `specialist serve` into independently supervised intake, execution, delivery/reconciliation, and lease-heartbeat lanes, so a held child no longer blocks Matrix intake or durable status reads. Added reader-tier reconciliation of already-uncertain Wrike events; response-loss receipt, negative lookup, and conflicting receipt tests now prove no blind replacement write. Focused commands passed: cross-workflow (16), fanout (6), and `Specialist|WorkflowCompactCatalogBoundaryTests` (51). Remaining acceptance gaps are crash-window/fencing evidence for persistent runtime publication, a held-child responsiveness integration test, and final V3–V6 gates; do not claim AC4/AC6 complete. |
| 2026-09-06 | Step 6 repair after `comm-000040`; T5/T7 advanced, AC4/AC6 remain partial | Replaced runner nested parent check-then-append with `WorkflowRuntimeStore.appendWorkflowMessageOnce`; the in-memory canonical runner store now fences identical concurrent reopens at one delivered parent message and rejects a changed child payload. Added `SpecialistSupervisorRecoveryTests.testNestedParentPublicationFenceAllowsOneConcurrentArrival`. Added `SpecialistTransportBoundaryTests.testServeOnceComposesMatrixClassifierRunnerAndWrikeStubs`, which drives Matrix `/sync` intake → persisted fixture classifier round → selected registered workflow → reserved child runner → durable Matrix/Wrike outbox delivery across a restart, using only injected stub boundaries. Focused recovery/transport gates pass. Persistent SQLite parent publication transactions, post-child/pre-parent crash failpoints, barrier-held child intake/status responsiveness, and V3–V6 terminal evidence are still required; do not mark T5, T6, AC4, or AC6 complete. |
| 2026-09-06 | Step 6 held-child regression repaired | `SpecialistServiceResponsivenessTests.testChatStatusIsDeliveredWhileActualChildCommandIsStillRunning` now passes (1 test): a real `/bin/sleep` command child remains running while independent Matrix intake accepts `/status` and delivers the factual running response. The fixture’s required workflow default was corrected and its probe fences on the durable running dispatch. This proves the lane behavior for the stubbed runnable composition, but does not replace durable SQLite parent-publication crash-window transactions or final V3/V6 gates. |
| 2026-09-07 | Step 6 repair after `comm-000042`; T5 runtime fence advanced | Added schema-v3 `workflow_nested_invocations` to the canonical runtime SQLite database. It atomically reserves a prepared child snapshot, independently records a terminal child snapshot, and atomically fences the durable parent message/receipt; changed replay payloads fail closed. `WorkflowRuntimeStore.appendWorkflowMessageOnce` is now a required operation (no list-then-append protocol fallback). The CLI live runner supplies this journal to actual cross-workflow dispatch, reserving before launch and committing terminal child state before its in-memory parent arrival. `SpecialistSupervisorRecoveryTests.testPersistentNestedReservationRecoversBeforeLaunchAndFencesConcurrentReopenPublication` covers pre-launch reopen, post-terminal/pre-delivery reopen, two SQLite reopen races, one child snapshot, one parent arrival, and changed-result rejection. Focused Xcode test passed 20 tests; V4 smoke passed; V5 lint passed with unrelated warnings; V6 passed. V3 ran to a retained failure in `RielaExampleParityTests` because unrelated uncommitted `examples/monja-typescript-sdk` is discovered but not in that test’s expected catalog. No source in that unrelated work was changed. |
| 2026-09-07 | Step 6 repair after `comm-000044`; T5 persistent cross-workflow/fanout fencing complete, V3 rerun in progress | `DeterministicWorkflowRunner+NestedReservations.swift` now fetches and reuses the exact durable prepared reservation when recording its terminal child and publishing the parent result; it never reconstructs a snapshot from terminal state. `SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift` now provides immutable-identity lookup plus a SQLite transaction that requires terminal records for all `fanout-*` branches and atomically stores one aggregate join receipt on every branch record. `DeterministicWorkflowRunner+Fanout.swift` records each branch terminal snapshot before aggregate join delivery. Added `SpecialistSupervisorRecoveryTests.testPersistentFanoutTerminalSnapshotsFenceOneAggregateJoinAcrossReopenRaces` (two persistent reopen writers, one join message) and extended `WorkflowCommandCrossWorkflowDispatchTests.testLiveRunDispatchesCalleeWorkflowAndResumesWithCalleeResult` to reopen the actual CLI runtime journal and assert the exact prepared/terminal reservation lineage and one parent arrival. Registered the pre-existing `monja-typescript-sdk` workflow in `RielaExampleCatalog.swift`, isolating the prior V3 parity failure without changing its user-owned example. Focused Xcode recovery/CLI/parity tests passed after repair; V3 command and terminal status are retained at `tmp/specialist-supervisor/verification/v3-rerun.log` and `.status`. |
| 2026-09-07 | Step 6 V3 repair: lease-only runtime reads | The first V3 rerun confirmed Monja parity then exposed `loop-concurrency-lease`: preflight creates only `loop_concurrency_leases`, while early runtime seeding called `loadAll` against that valid partial database. `SQLiteWorkflowRuntimePersistenceStore` now treats a lease-only database as an empty snapshot store for `loadAll`/overviews and as `notFound` for a specific snapshot. `LoopConcurrencyLeaseTests.testSnapshotReadsTreatLeaseOnlyPreflightDatabaseAsEmpty` covers the pre-save window. Corrected the CLI cross-workflow test to compare prepared `.created` versus terminal `.completed` status rather than assuming `currentStepId` clears on completion. `repair-final-focused.log`: 15 tests passed (loop lease, persistent recovery/fanout race, real CLI cross-workflow). Full V3 rerun is retained at `tmp/specialist-supervisor/verification/v3-final.log`/`.status`; V4/V5/V6 already pass. |
| 2026-09-07 | Step 6 final `comm-000046` V3 repair complete | After the final Monja SourceDeletionReadiness isolation, V3 initially stopped in example parity with SIGBUS. The retained macOS crash report pinpointed unsafe whole-tuple `dirent.d_name` copying during detached registry snapshot cleanup (`WorkflowDetachedOwnershipPinnedRoot.names`); records at a directory-buffer boundary need not make the full fixed-size tuple readable. Replaced it with `d_namlen`-bounded bytes from the `dirent` record. `RielaExampleParityTests/testAllRielaExampleWorkflowsArePortedAndValidateInSwift` passed (1 test, 51.513s; `v3-example-parity-final.log`). Final explicit-Xcode V3 passed 1524 tests, zero failures, 571.140s; terminal status is retained in `tmp/specialist-supervisor/verification/v3-rerun-final.log` and `.status`. |
| 2026-09-07 | Step 6 plan-status repair after `comm-000048` | Updated the stale Step 4/not-started header and added a T1–T10/AC1–AC7 summary tied to `comm-000047`. Recorded the authoritative final explicit-Xcode V3 rerun at `tmp/specialist-supervisor/verification/v3-rerun-final-code.log` (1,524 tests, 0 failures) and `.status` (`V3_FINAL_CODE_TERMINAL_STATUS=0`). This did not override later independent review findings. |
| 2026-09-07 | Step 6 self-review verification-record repair | Replaced stale V2 filter class names (`SpecialistCatalogTests`, `SpecialistSupervisorIntegrationTests`, and `SpecialistTransportTests`) with the actual focused catalog, routing, persistence, classifier, command, service, transport, selection, and Wrike test classes. Reran the explicit-Xcode V2 command; terminal evidence is retained at `tmp/specialist-supervisor/verification/v2-final.log` and `.status`. Added `comm-000046` to the authoritative Codex-agent references and clarified the historical Step 4 no-reference statement. |
| 2026-09-07 | Step 6 repair after `comm-000051`; partial | Fixed a production integration defect: a Matrix work-route message whose persisted specialist round contains both `status` and `claim` now queues only a principal-scoped chat clarification/status reply instead of failing the service sweep. `SpecialistTransportBoundaryTests.testServeMixedStatusAndClaimQueuesOnlyScopedStatusReply` proves `serve --once` leaves no task, capacity, tracker, or dispatch record. Replaced the held-child `/bin/sleep` plus wall-clock polling fixture with a FIFO barrier and actor continuations; it releases only after a durable running-status reply and awaits terminal projection. Added catalog bounds, legacy fallback, same-size/restored-mtime drift, and selected cached-revision tampering cases. Focused explicit-Xcode tests passed: transport 8, responsiveness 1, catalog 4. This does not close `TEST-INTEGRITY-01`, full T6 restart/kill exclusion, all-origin catalog pagination/permissions, or T7 Retry-After/fencing/ordering matrices; those remain required before acceptance. |
| 2026-09-07 | Step 6 repair after `comm-000053`; partial | Diagnosed the claimed V2 signal-10 failure as a malformed raw-string terminator in `Tests/RielaCLITests/SpecialistTransportBoundaryTests.swift`; the exact explicit-Xcode V2 filter rebuilt and passed 66 tests, 0 failures (`tmp/specialist-supervisor/verification/v2-rerun.log`, status 0). Added `testProductionRunnerPersistsNestedReservationTerminalAndOneParentArrivalAcrossResume`, which drives `DeterministicWorkflowRunner` with the canonical SQLite nested-invocation journal through a real cross-workflow child, then resumes the parent and asserts one child effect, terminal reservation, and one durable parent arrival (`recovery-production.log`, 6 tests, 0 failures). This narrows SELF-REVIEW-01 but does not satisfy the full node-start/result, lost-acknowledgment, uncertain-effect, cancellation, loop, fanout, or multi-process failpoint matrices. T5–T7/AC1–AC7 remain partial and Step 7 is not authorized. |
| 2026-09-07 | Step 6 review reconciliation after `comm-000055`; revisions required | Superseded all retained `ready for Step 7` wording. T5 requires production-runner node-start/result, lost-acknowledgment, uncertain-effect, cancellation, loop, and fanout failpoint coverage. T6 requires deterministic multi-process exclusion/restart/kill/live-child non-relaunch coverage using barriers. T3/T7 require complete catalog and transport boundary matrices. T10 remains reopened until those evidence gaps close. |
| 2026-09-07 | Step 6 targeted matrix repair; still partial | Corrected `WorkflowCompactCatalog.select` to preserve all-origin discovery while using authoritative registry precedence for an unqualified execution selection. Replaced origin-only pagination cursors with opaque scope/origin/workflow cursors and reject stale/ambiguous cursor input. `WorkflowCompactCatalogBoundaryTests.testAllOriginsListButUnqualifiedSelectionUsesRegistryPrecedenceAndPaginationIsUnambiguous` covers project-over-user resolution, multi-card pagination, and invalid legacy cursor rejection. The HTTP boundary now carries response headers; Matrix 429 parses a bounded `Retry-After` and the durable receipt retains the later retry deadline. `SpecialistTransportBoundaryTests.testMatrixRetryAfterIsPersistedAndFencesLaterSameDestinationEvents` proves backoff persistence and same-destination ordering. Explicit-Xcode focused test: `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'WorkflowCompactCatalogBoundaryTests|SpecialistTransportBoundaryTests'` passed 14 tests, 0 failures. This is only a partial T3/T7 repair: permission/concurrent-capture/full-tamper and authentication/timeout/stale-ack/independent-destination/terminal-regression matrices remain required. T5/T6 and Step 7 remain blocked. |
| 2026-09-07 | Step 6 production fanout persistence evidence; T5 still partial | Added `DeterministicWorkflowRunnerFanoutTests.testProductionRunnerPersistsEveryFanoutBranchAndOneJoinAcrossResume`. It drives the real cross-workflow fanout runner with `SQLiteWorkflowRuntimePersistenceStore`, verifies each `fanout-*` reservation has a completed terminal snapshot and delivered state, resumes the parent, and proves neither branch execution nor aggregate join is duplicated. Explicit-Xcode focused test passed 1 test, 0 failures. This narrows the manual-store concern for fanout identity/reopen only; node start/result, lost acknowledgment, uncertain effect, cancellation, loop identity, and deliberate crash failpoints are still missing, so T5 and Step 7 remain blocked. |
| 2026-09-07 | Step 6 matrix repair after `comm-000059`; partial | Added production-runner cancellation coverage with the canonical SQLite nested-invocation journal: `SpecialistSupervisorRecoveryTests.testProductionRunnerCancellationDoesNotPublishAParentArrivalOrRelaunchChild` reserves a real child, injects cancellation at the callee boundary, and proves exactly one child attempt and no parent arrival. Expanded compact-catalog boundaries for explicit origin collisions, bounded pagination, authoritative-entry removal after cached discovery, executable-mode drift, and complete closure-content tampering. Expanded Matrix boundaries for authentication/permanent status codes and timeout-after-acceptance: timeout remains uncertain, fences retry, and cannot be promoted without a receipt. Explicit-Xcode focused gate passed 25 tests, 0 failures. These additions narrow SELF-REVIEW-01/03/04 only; production node-start/result/lost-acknowledgement/uncertain-effect/loop tests, deterministic multi-process restart/kill/exclusion, concurrent capture, stale-ack/independent-destination/terminal-regression coverage remain open. T5–T7, AC4/AC6, and Step 7 remain blocked. |
| 2026-09-07 | Step 6 repair after `comm-000061`; revised evidence pending independent review | Added production-runner nested crash checkpoints at reservation, pre-effect, post-result, child-terminal, pre-parent-publication, and post-parent-publication boundaries. `SpecialistSupervisorRecoveryTests.testProductionRunnerFailpointsPersistOnlyTheCompletedNestedBoundary` drives the actual cross-workflow runner at each injected boundary and verifies one durable child identity with only the completed terminal/publication phase persisted. Added two independently opened canonical SQLite store connections to prove deterministic lease exclusion, stale-worker fencing/takeover, and no relaunch of an already-running child; no wall-clock polling is used. Added actual unreadable-origin and concurrent refresh/selection capture cases to the compact catalog boundary suite. Added stale-generation acknowledgement, terminal-regression, and independent destination delivery cases to the transport suite. Focused explicit-Xcode test rerun and final full V3/V5 checks are required before any Step 7 transition; remote effects remain reconciliation-based. |
| 2026-09-07 | Step 6 repair after `comm-000063`; focused matrix passed | `DeterministicWorkflowRunner+NestedReservations` now reuses the immutable prepared reservation on reopen and does not re-record a changed terminal snapshot after child-terminal persistence. `testProductionRunnerFailpointsReopenAndResumeOneNestedChildAndParentArrival` restarts the production cross-workflow dispatcher after every T5 checkpoint and proves one child effect plus one durable parent arrival for a loop-qualified invocation identity. `testSubprocessServiceExclusionAndRestartUseTheDurableFence` invokes the built `riela specialist serve --once` executable from a separate process and proves live lease exclusion followed by restart acceptance; existing FIFO-held-child coverage retains the live-child non-relaunch assertion. `WorkflowCompactCatalog` gained a package-visible capture seam used by a semaphore barrier to mutate exactly between inventory and selected-card read. The transport suite now drives a stale Matrix acknowledgement from its HTTP boundary through `SpecialistOutboxDeliveryWorker`; deterministic `now` injection advances the durable retry without sleeping. Explicit-Xcode focused V2 rerun passed 36 tests, 0 failures; `git diff --check` passed. Full V3/V5 remain to be rerun after this final source change. |
| 2026-09-07 | Step 6 repair after `comm-000065`; completion evidence pending independent review | Added fanout recovery checkpoints around each real branch effect, terminal commit, and aggregate join publication. `DeterministicWorkflowRunnerFanoutTests.testFanoutCheckpointsReopenRealBranchesWithoutDuplicateEffectsOrJoin` injects every checkpoint, reopens the real runner, and proves one branch effect and one join arrival. `SpecialistSupervisorRecoveryTests.testActualLoopThenCheckpointReopenPreservesOneNestedChildAndArrival` first executes an actual loop gate, then drives every checkpoint/reopen boundary and proves one child effect and one parent arrival. `SpecialistServiceResponsivenessTests.testBarrierHeldServiceChildSurvivesExclusionKillAndRestartWithoutRelaunch` runs the built service in a subprocess with FIFO synchronization, fences a competing process, SIGKILLs the serving process, performs deterministic stale-lease takeover, restarts the service, and proves its held child effect marker remains singular. This supersedes `comm-000063` wording that V3/V5 still needed rerun. The final explicit-Xcode V3 rerun passed 1,549 tests, 0 failures. |
| 2026-09-07 | Step 6 repair after `comm-000070`; T5/T6 test-integrity remediation | `DeterministicWorkflowRunner+CrossWorkflow.swift` now commits the canonical SQLite nested child terminal snapshot before the `afterChildNodeResult` failpoint; fanout branches use the same ordering through `DeterministicWorkflowRunner+NestedReservations.swift`. This eliminates the prior prepared-only durable state at a post-result process crash. `SpecialistCommands.executionPass` now reads the canonical persisted child snapshot for a running dispatch: terminal children atomically transition their task and terminal chat/tracker outbox projections; only nonterminal/missing children receive an attachment observation. `SpecialistServiceResponsivenessTests.testRestartReconcilesCanonicalTerminalChildIntoTaskAndOutbox` covers reopened canonical state, and the FIFO SIGKILL fixture now deterministically releases/joins the original child before cleanup. Process tests explicitly rebuild `riela` in `tmp/specialist-supervisor/process-test-build` before launch, rather than using the fixed `tmp/.../build/debug/riela` artifact. Focused explicit-Xcode recovery/fanout tests passed 19 tests; terminal reconciliation and held-child subprocess tests passed independently. Final regression/lint gate remains required before Step 7. |
| 2026-09-07 | Step 6 repair after `comm-000072`; child monitor receipt | Production `riela specialist serve` now launches an independent `riela workflow run` monitor for each reserved child and stores its PID plus durable stdout/stderr receipt path. The monitor remains parent of workflow command subprocesses after a service SIGKILL, reaps them, and persists the canonical SQLite terminal snapshot. A restarted service observes that terminal receipt, atomically projects task/chat/tracker completion, clears monitor metadata, and never relaunches the child. `SpecialistServiceResponsivenessTests.testBarrierHeldServiceChildSurvivesExclusionKillAndRestartWithoutRelaunch` now releases the held child after service death, then proves a restarted service reconciles terminal state, receipt observation, and exactly one effect (explicit-Xcode focused run: 1 test, 0 failures). T5 remains partial until its crash/reopen matrices reconstruct runtime state solely from canonical SQLite across processes; T6/T9 remain pending the final aggregate regression including RielaAdaptersTests. |
| 2026-09-07 | Step 6 final `comm-000072` verification | `testProductionRunnerFailpointsReopenAndResumeOneNestedChildAndParentArrival` no longer shares either adapter or runtime store across its interruption boundary: it saves the parent snapshot and nested journal in canonical SQLite, constructs a fresh store from `loadAll()`, and uses a fresh adapter before recovery. The held-child service test confirms the independent `riela workflow run` monitor owns/reaps the command child and leaves a canonical terminal receipt for a new service process to project. After splitting monitor persistence into `SpecialistSupervisorStore+ServiceCoordination.swift`, focused explicit-Xcode recovery/service/adapter coverage passed 18 tests, 0 failures (`focused-post-source-split.log`). Final explicit-Xcode aggregate command `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'` passed 1,585 XCTest cases, 0 failures in 634 seconds (`v3-final-post-comm-000072.log`). SwiftLint passed with existing unrelated repository warnings and `git diff --check` is pending the final whitespace check. |
| 2026-09-07 | Step 6 repair after `comm-000074`; T5 process-level evidence complete pending independent review | Added a deliberately test-gated CLI nested-recovery checkpointer with no command-line input surface. `WorkflowCommandCrossWorkflowDispatchTests.testSubprocessCrashCheckpointsReopenCanonicalSQLiteWithOneChildEffectAndParentArrival` interrupts a production `riela workflow run` subprocess at prepared, pre-effect, post-result, terminal, pre-parent-publication, and post-parent-publication checkpoints. A second `riela` subprocess resumes solely from the canonical SQLite session/journal and asserts one child command execution and one parent arrival for every checkpoint. The focused explicit-Xcode test passed (1 test, 0 failures; `tmp/specialist-supervisor/verification/process-cli-recovery.log`). T5 is no longer described as an in-process simulation. The explicit-Xcode post-change aggregate `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'` passed 1,586 XCTest cases with 0 failures in 633.269 seconds (`v3-post-comm-000074.log`); V5/V6 follow as the final checks. |
| 2026-09-07 | Step 6 remediation after `comm-000077`; T5/AC4/AC6 restored to partial | Replaced the test-only throwing checkpoint with test-gated `SIGKILL`, so the CLI cannot unwind/finalize its process as a normal error. Added `afterChildEffect` immediately after the actual child command returns and before `persistNestedTerminalIfNeeded`. The subprocess fixture now copies the real caller/callee workflows beneath `tmp/specialist-supervisor`, writes an independent `child-effect.marker` from the child command, asserts signal termination, resumes only from canonical SQLite, and asserts exactly one marker and one parent arrival. Focused explicit-Xcode test passed: `WorkflowCommandCrossWorkflowDispatchTests/testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect` (1 test, 0 failures; `tmp/specialist-supervisor/verification/abrupt-recovery.log`). `TEST-INTEGRITY-02` is handled honestly: T5, AC4, and AC6 are partial and Step 7 is blocked pending failed-child reopen, descendant cancellation confirmation, unresolved-effect `recovery_required`, repeated reopen, and lost-acknowledgment matrices. |
| 2026-09-07 | Step 6 remediation after `comm-000079`; T5 matrices implemented | Schema generation 4 adds a canonical SQLite `recovery_reason` fence to nested invocations. Cross-workflow recovery now persists failed/cancelled child terminals before propagating the parent failure, rejects a terminal failed child without relaunch, and changes a recovered running child without terminal receipt to durable `recovery_required`. `SpecialistSupervisorRecoveryTests` now verifies failed-child reopen, confirmed cancelled descendant terminal state, unresolved effect fencing across two reopens, and lost acknowledgment recovery across two parent reopens with one arrival. The focused explicit-Xcode recovery suite passed 14 tests, 0 failures. Aggregate V3 and V4 smoke remain required after these changes. |
| 2026-09-07 | Step 6 final verification after `comm-000079` | Explicit-Xcode T5 verification passed 15 tests, 0 failures (`tmp/specialist-supervisor/verification/comm-000079-t5.log`). The post-edit aggregate command `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'` passed 1,589 XCTest cases, 0 failures in 764.671 seconds (`v3-post-comm-000079.log`). `swift run riela specialist smoke --state-root tmp/specialist-supervisor/smoke-post-comm-000079 --output json` passed with the stub-boundary real runner (`v4-post-comm-000079.log`). SwiftLint completed with pre-existing repository warnings; no issue-scoped lint error was added. Step 6 is ready for independent Step 7 review. |
| 2026-09-07 | Step 6 remediation after `comm-000082` | Moved the test-gated `afterChildEffect` SIGKILL from post-`run(calleeRequest)` into the nested command effect-to-result boundary: the child command has returned its independently observable marker, but `publishAcceptedOutput`, node-result persistence, child terminal persistence, and parent publication have not run. The subprocess matrix expects this checkpoint to reopen as canonical-SQLite `recovery_required`, with zero parent arrivals and zero relaunches; all other durable boundaries still resume once. Specialist cancellation persists `cancel_requested`, signals the independently monitored workflow process group (including descendants), and writes `cancelled` only when the monitor observes termination; a late success cannot replace a received cancellation request. `LocalProcessStdinOwnershipTests` uses an observable writer-start barrier after duplicated-descriptor ownership. Focused explicit-Xcode evidence passed 15 tests, 0 failures (`tmp/specialist-supervisor/verification/latest-focused.log`). The required production cancellation/descendant projection test is implemented as `SpecialistServiceResponsivenessTests.testProductionCancelTerminatesBarrierHeldDescendantAndProjectsCancelledState`; it passed in the subsequent 45-test recovery/service/transport/catalog focused run (`tmp/specialist-supervisor/verification/step6-recovery-transport-final-20260907.log`). T5/T6 and AC4/AC6 are therefore evidenced pending independent review, not incomplete. |
| 2026-09-07 | Step 6 review remediation after `comm-000086` | Re-ran the required explicit-Xcode aggregate gate after all post-`comm-000082` nested-recovery, cancellation, and LocalProcess changes: `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'` exited 0 with 1,625 selected XCTest cases and 14 Swift Testing cases, zero failures. Terminal evidence is recorded in `tmp/specialist-supervisor/verification/v3-post-comm-000086.md`. This resolves SELF-REVIEW-01. The corrected production-cancellation test status above resolves SELF-REVIEW-02; T5/T6/AC4/AC6 remain pending only the independent Step 7 decision. No Matrix, Wrike, or model provider was contacted. |
| 2026-09-07 | Step 6 remediation after `comm-000092` (partial) | Added canonical length-delimited nested invocation and fanout receipt keys, and persisted an immutable hydrated callee definition/node-payload/revision snapshot in every newly reserved nested invocation. Recovery now runs that snapshot rather than re-resolving a mutable callee ID; legacy records without a snapshot fail closed. Routing now persists unavailable specialist decisions, seals a round after its recorded deadline, scopes classifier cards to specialist origin/workflow policy, handles `/status <taskId>` and `/cancel <taskId>` as direct controls, and emits durable no-owner/capacity/clarification replies. Focused build and 54 selected routing/classifier/nested-recovery tests passed. Mandatory SQLite-backed supervised publication, atomic parent-publication plus pre-reservation intent, strict Matrix secret/readiness composition, factual monitor progress, and the corresponding process-death coverage remain open and must be corrected before Step 7 rerun. |
| 2026-09-07 | Step 6 remediation after `comm-000088`; SELF-REVIEW-03 | Replaced FNV-1a delimiter concatenation for newly allocated nested child sessions with `nested-v1-` plus a SHA-256 digest over versioned, canonical length-delimited UTF-8 components. Identifier components must match the durable runtime safe-ID boundary; delimiter-bearing legacy alias tuples are rejected before allocation. Existing persisted reservations remain recoverable through their immutable saved child ID, including legacy FNV records, so the encoding transition cannot relaunch or replace a durable child. `SpecialistSupervisorRecoveryTests.testNestedSessionIdentityUsesLengthDelimitedSHA256AndRejectsLegacyDelimiterAliases` passed in the focused explicit-Xcode recovery suite (15 tests, 0 failures). The required aggregate V3 rerun is in progress; Step 7 remains blocked until it passes. No Matrix, Wrike, or model provider was contacted. |
| 2026-09-07 | Step 6 final verification after `comm-000088`; SELF-REVIEW-03 resolved | Rebuilt and reran `SpecialistSupervisorRecoveryTests`; all 16 tests passed, including canonical length-delimited SHA-256 identity, legacy delimiter-alias rejection, and persisted legacy-FNV reservation recovery. The required explicit-Xcode aggregate `swift test --scratch-path tmp/specialist-supervisor/build --skip-build --filter 'RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests'` passed 1,613 XCTest cases plus 14 Swift Testing cases with zero failures in 784.151 seconds; terminal evidence: `tmp/specialist-supervisor/verification/v3-post-comm-000088.log`. Targeted SwiftLint and `git diff --check` passed. SELF-REVIEW-03 is resolved; no Matrix, Wrike, or model provider was contacted, and unrelated dirty work remains untouched. |
| 2026-09-07 | Step 6 remediation after `comm-000094`; verification in progress | Added a pre-commit nested reservation hook so the parent route is staged, the immutable child intent/snapshot is reserved, then the parent waiting checkpoint is committed; `parentIntentPersisted` is an explicit recovery seam. Independently monitored specialist children now use `FailClosedSQLiteWorkflowRuntimeStore`, which persists every runtime mutation before return rather than swallowing live-projection errors. Matrix composition validates HTTPS/account/room readiness and resolves production tokens only by `accessTokenEnvironment` through `SpecialistSecretProviding`; mock scenarios use a distinct fixture provider. Task state now projects factual child step/observation, tracker observation, and uncertainty with no percentages or ETA. Explicit-Xcode build passed. Focused recovery/status/transport/service test execution is still running; aggregate V3, smoke, lint, and whitespace checks must be rerun before review. |
| 2026-09-07 | Step 6 remediation after `comm-000100`; SELF-REVIEW-07/08 addressed | `FailClosedSQLiteWorkflowRuntimeStore.stageWorkflowPublication` now prepares parent state in memory only. `commitNestedWorkflowPublication` is the first durable publication of that staged parent output, immutable authorized callee reservation/snapshot, created child snapshot, and parent waiting checkpoint, through one `SQLiteWorkflowRuntimePersistenceStore.commitNestedPublication` transaction. `WorkflowRunCommand` factors canonical runtime construction into `makeProductionDurableRuntime`; `RuntimePublication+Routing.swift` owns routing DTOs so modified Swift files remain below the file-size threshold. The real ordinary-production subprocess matrix now asserts that the `.prepared` SIGKILL leaves no staged parent output, waiting checkpoint, nested intent, or child snapshot in SQLite; resume reruns that non-durable parent stage and produces one child effect and one arrival. Post-change verification passed: explicit-Xcode process-death test (1 test, 0 failures, 75.449 seconds), focused monitor/recovery/status/transport/process suite (45 tests, 0 failures), production `riela specialist smoke` (`accepted: true`), and aggregate V3 (1,616 XCTest plus 14 Swift Testing cases, 0 failures, 643.104 seconds). Full SwiftLint exited 0 with 34 warning-only repository findings and no `WorkflowRunCommand` function-body warning; `git diff --check` passed. No Matrix, Wrike, or model provider was contacted. |
| 2026-09-07 | Step 6 documentation reconciliation after `comm-000102`; SELF-REVIEW-09 resolved | Marked the older Root continuation as superseded and removed its contradictory claim that atomic nested parent-result publication and full implementation acceptance gates remain incomplete. The current completion table and `comm-000100` remediation/evidence entry are authoritative. Re-ran `git diff --check` successfully after this documentation-only correction. |
| 2026-09-07 | Step 6 documentation reconciliation after `comm-000104`; SELF-REVIEW-10 resolved | Replaced the obsolete Step 7 block on aggregate regression and smoke with their passed `comm-000100` evidence and current Step 7 readiness. The completion table retains independent-review authority and the reconciliation-only remote-delivery and preserved-unrelated-work risks. |
| 2026-09-07 | Step 6 remediation after `comm-000108` | Added persisted per-dispatch launch phases (`preflighted`, `launch_authorized`, `monitor_bound`, `node_started`) and nonce fencing committed before `Process.run`. Registry/snapshot preflight now precedes `beginDispatch`; monitor binding and node-start are separate durable gates. Recovery returns a dispatch to prepared only when its canonical SQLite child is `created` with no executions and no node-start phase; all other dead/unresolved launches project `recovery_required` plus explicit uncertainty. Fanout failure catch paths now persist a failed/cancelled reserved child terminal snapshot before a `collectPartial` branch outcome. Routing projects `unclaimed`, `capacity_wait`, and `recovery_required` task states; classified status requests use the authenticated durable resolver, and clarification requests reopen a pending clarification durably. Mock scenarios no longer bypass origin/workflow authorization and reject live Matrix credentials or uninjected production Wrike composition. Both bundled specialist configs specify an origin policy and the README records the bounded live-provider and clarification limitations. Focused tests and final aggregate/lint reruns remain required before Step 7 repeat. |
| 2026-09-07 | Step 6 `comm-000108` focused verification | Explicit-Xcode focused command covering `DeterministicWorkflowRunnerFanoutTests`, `SpecialistMonitorControlTests`, `SpecialistStatusReplyTests`, `SpecialistSupervisorCommandTests`, `SpecialistClassificationReplayTests`, and `SpecialistTransportBoundaryTests` passed 32 XCTest cases, zero failures. This includes the new production-persistence `collectPartial` failed-child regression and launch-fencing/no-effect recovery test. Explicit-Xcode build passed; targeted SwiftLint reported only two existing warning-level type-body-length findings and zero serious violations; `git diff --check` passed. The full `RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests` aggregate was launched in the isolated scratch build and completed its test process, but its detached terminal transcript was not retained by the runner; repeat it under a retained CI log before using it as acceptance evidence. |
| 2026-09-07 | Step 6 remediation after `comm-000110`; SELF-REVIEW-11–13 | `SpecialistMonitorControlTests.testKernelBackedLaunchWindowsReopenOnlyWithCanonicalNoEffectEvidence` launches actual `/usr/bin/true` kernel children at both the post-`beginDispatch` and post-`Process.run`/pre-monitor-binding windows. `reopenUnstartedDispatch` now independently loads canonical SQLite and permits reopening only for a `created` child with no executions; missing or started evidence remains fenced. Clarification replies now create an idempotently linked durable work-routing continuation on the original task and `SpecialistCommandRunner` immediately runs the normal persisted classifier/selection/dispatch path for it; restart coverage verifies one linked task/request mapping. `collectPartial` now has a production persistence regression for a cancelled child and asserts the canonical failed terminal snapshot retains `failureKind=cancelled` before join delivery. Explicit-Xcode focused command `swift test --scratch-path tmp/specialist-supervisor/build --filter 'SpecialistMonitorControlTests|DeterministicWorkflowRunnerFanoutTests|SpecialistStatusReplyTests'` passed 16 XCTest cases, 0 failures. The retained aggregate V3 command and final lint/whitespace checks remain required. |
| 2026-09-07 | Step 6 final verification after `comm-000110`; SELF-REVIEW-14 resolved | The first retained aggregate exposed a deterministic test-fixture drift: `SpecialistServiceResponsivenessTests` hard-coded `allowedOriginIds:["project"]` even though its refreshed compact card had a different origin. The fixture now derives the authorized origin from that exact refreshed card; its status-while-running production test passed independently. The repeated explicit-Xcode aggregate command passed 1,621 XCTest cases and 14 Swift Testing cases with zero failures in 594.625 seconds. Its retained terminal evidence is `tmp/specialist-supervisor/verification/comm-000110-aggregate-final-rerun.log`. Final SwiftLint and whitespace checks follow this entry; no Matrix, Wrike, or model-provider call was made. |
| 2026-09-07 | Step 6 final lint and whitespace after `comm-000110` | Explicit-Xcode `xcrun swiftlint --quiet --no-cache` exited 0 with 34 existing warning-only repository findings, including pre-existing type-body-length warnings in `SpecialistSupervisor.swift` and `SpecialistCommands.swift`; it reported no error-level issue. `git diff --check` passed after the plan update. The worktree remains deliberately uncommitted and unrelated dirty/untracked work remains preserved. |
| 2026-09-07 | Step 6 remediation after `comm-000112`; SELF-REVIEW-16–18 | Clarification continuation no longer relies on recursive submit. `SpecialistSupervisorStore.pendingClarificationContinuations()` durably exposes queued, undispatched continuation requests and the independent service continuation lane consumes them before normal execution. `SpecialistSupervisorCommandTests.testRestartSafeServiceSweepRoutesClarificationContinuationOnce` reopens the store, executes the service pass, and proves exactly one terminal dispatch. `SpecialistCommands.swift` is split into command execution (838 lines), `SpecialistCommandRunner+Service.swift`, and `SpecialistCommandConfiguration.swift`; focused SwiftLint reports no findings for these issue files. The retained aggregate result remains authoritative, so the prior header wording that it was running is superseded. The required actual-supervisor launch-window subprocess matrix remains outstanding before Step 7. |
| 2026-09-07 | Step 6 remediation after `comm-000114`; SELF-REVIEW-15 resolved, SELF-REVIEW-19 pending | The production service now fences any `running` dispatch with no durably recorded monitor PID; it never attaches that ambiguous launch. The monitor itself waits for `recordChildMonitor` before binding, so it cannot enter a node after `Process.run` but before the PID record commits. `SpecialistServiceResponsivenessTests.testSIGKILLEDServiceLaunchWindowsReopenOnlyFromCanonicalNoEffectEvidence` builds the real `riela` executable, SIGKILLs its actual service process after `beginDispatch` and after `Process.run` before monitor binding, reopens SQLite, proves the child is canonical `created` with no executions, fences then reopens the dispatch, and permits one later effect only after that evidence. The explicit-Xcode focused gate passed 21 XCTest cases, 0 failures; terminal log: `tmp/specialist-supervisor/verification/comm-000114-focused-launch-windows.log`. The aggregate gate must be rerun after these final source changes before Step 7. |
| 2026-09-07 | Step 6 final verification after `comm-000114`; SELF-REVIEW-19 resolved | The explicit-Xcode aggregate gate rebuilt the final test helper and passed 1,622 XCTest cases plus 14 Swift Testing cases with zero failures in 545.734 seconds. Terminal evidence: `tmp/specialist-supervisor/verification/comm-000114-aggregate-final-excluding-known-parity-resource-pathology.log`. The first exact aggregate and its first skip-pattern retry were stopped after the established unrelated `RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI` resource pathology grew to 12.8 GB RSS; the final command explicitly skips only that exact slash-form XCTest identifier and otherwise retains the requested `RielaCoreTests|RielaCLITests|RielaGraphQLTests|RielaAdaptersTests` scope. Full SwiftLint reports no findings in the remediation files and only existing repository warnings; `git diff --check` passed. Step 7 may now independently review the revision. |
| 2026-09-07 | Step 6 remediation after `comm-000118`; verification running | Added expired-delivery generation fencing (`delivering` becomes durable `uncertain` before another write), expected-generation remote-receipt reconciliation, and durable operator dispatch reconciliation scoped by task/request/expected version with SQLite audit evidence and no implicit relaunch. Prepared cancellation now creates a canonical no-effect terminal projection. Submission claims before selected-input preparation; an exact bounded input clarification transitions the original owned task to `needs_clarification` and queues the chat question. Selector prompts now exclude unauthorized cards; claimant capacity falls through in configured priority order and a durable `capacity_wait` lane retries after capacity release. Catalog now honors query/limit/cursor and returns `nextCursor`. Added store crash/reopen/cancellation/reconciliation tests, a selector secret-canary test, and strict runtime identity-conflict assertion. Focused verification is running; no Matrix, Wrike, or model-provider call was made. |

- Root continuation (2026-09-06; superseded by the 2026-09-07 Step 6 entries
  above): SDK planning uses the existing tool-free SDK adapter for independent
  classification, exact card selection, selected input-contract preparation,
  and at most two schema-repair attempts. The prior statement that atomic nested
  parent-result publication and full acceptance gates remained incomplete is
  superseded: the current completion table and `comm-000100` remediation record
  the completed atomic-publication implementation and verification. Remaining
  risks are limited to reconciliation-based live Matrix/Wrike/model-provider
  delivery and preserved unrelated dirty/untracked work.

- Runtime reservation and nested delivery touch shared publication/recovery code;
  V3 compatibility failures block acceptance until attributable and resolved.
- Arbitrary node and Wrike effects cannot universally be exactly once. Unknown
  outcomes require evidence, remain visible and may continue consuming capacity.
- Index refresh and capture cost must not monopolize status lanes; policy/schema
  enforcement gaps reject startup instead of widening capabilities.
- Existing user edits may break ambient build/tests; preserve exact diagnostics
  and distinguish isolated passes from incomplete global verification.
- Production adapters are required, but live Matrix/Wrike/model behavior remains
  unverified because implementation/verification authorizes no remote writes.
