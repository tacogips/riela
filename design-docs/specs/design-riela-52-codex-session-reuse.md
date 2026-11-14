# Riela 52 Codex Session Reuse And Authentication Readiness

## Scope

- Workflow mode: `issue-resolution`
- Issue: [riela#52](https://github.com/tacogips/riela/issues/52)
- Provider scope: the `codex-agent` workflow adapter only

The workflow runner already carries `WorkflowStepSessionPolicy` to
`AdapterExecutionInput`, but the Codex adapter always starts `codex exec
--json`, discards the emitted Codex thread id, and repeats `codex --version`
plus `codex login status` for every step. A single cached
`CodexAgentAdapter` is also shared by concurrent fanout branches, so an
unscoped mutable "last thread" would allow one branch to resume another.

This design makes reuse explicit, branch-safe, and fail-open to a fresh Codex
thread when requested history cannot be resolved. It does not keep one Codex
OS process alive between workflow steps; reuse means starting `codex exec
resume` against a known Codex thread.

## Boundaries And Reference Behavior

Codex-specific command construction, JSONL interpretation, thread state, and
authentication readiness remain inside `Sources/CodexAgent`. `RielaCore`
supplies provider-neutral execution identity: the root workflow-run id, the
current workflow-session id, and the current workflow step id. Fanout children
inherit the root run id but retain the distinct workflow-session ids already
created by `DeterministicWorkflowRunner+Fanout.swift`.

The local Riela sources are authoritative for this change:

- `Sources/CodexAgent/CodexAgentAdapter.swift`
- `Sources/CodexAgent/CodexAgentProcess.swift`
- `Sources/CodexAgent/CodexProcessManager.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/AdapterContracts.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`
- `Sources/RielaCore/WorkflowValidation.swift`
- `Sources/RielaCore/WorkflowRawValidation.swift`
- `Sources/RielaAdapters/LocalAgentProcess.swift`
- `Sources/RielaAdapters/DispatchingNodeAdapter.swift`
- `Sources/RielaCLI/WorkflowResolution.swift`
- `Sources/RielaCLI/WorkflowResolution+SharedNodeRefs.swift`
- `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`
- `Sources/RielaCLI/WorkflowStagedVerification.swift`
- `Sources/RielaCLI/WorkflowCatalogCommands.swift`
- `Sources/RielaCLI/WorkflowRunCommand.swift`
- `Sources/RielaServer/WorkflowServingController.swift`

No separate Codex-agent reference repository was established during intake.
The existing `CodexProcessCommandBuilder.buildExecArguments`,
`buildResumeArguments`, and `CodexProcessManager` session-id extraction
semantics are the reference behavior to reuse.

Cursor CLI behavior is unchanged. Cursor command selection, session parsing,
and authentication remain isolated in `Sources/CursorCLIAgent`; this design
does not copy Codex JSONL fields, argv ordering, or readiness state into the
Cursor adapter.

### Implementation responsibility map

The implementation seams are intentionally explicit so session identity,
JSONL observation, cleanup, and validation are not accidentally collapsed
into the command builder:

| Reference | Design responsibility |
| --- | --- |
| `Sources/CodexAgent/CodexAgentAdapter.swift` | Own the concurrency-safe Codex run-state object used by the value-typed adapter; coordinate keyed readiness, resolve thread state, select fresh versus resume execution, and promote a captured id only after successful process completion. |
| `Sources/CodexAgent/CodexAgentProcess.swift` | Remain the sole owner of Codex fresh/resume argv construction and piped-prompt argument validation. |
| `Sources/CodexAgent/CodexProcessManager.swift` | Supply the existing Codex JSONL session-id extraction semantics that the workflow path must reuse or centralize rather than reimplement inconsistently. |
| `Sources/RielaCore/WorkflowModel.swift` | Define the authored and normalized `WorkflowStepSessionPolicy` values (`new`, `reuse`, and `inheritFromStepId`). |
| `Sources/RielaCore/AdapterContracts.swift` | Add provider-neutral, typed execution metadata for `workflowRunId`, `workflowSessionId`, and `stepId`; add the exact nonthrowing async `NodeAdapter.workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async` requirement with a default no-op; and add separately rendered `freshPromptText` and `resumedPromptText`. Keep identity separate from business data, let existing adapters consume the fresh form, and let an adapter that actually resolves a resume select the resumed form. |
| `Sources/RielaCore/DeterministicWorkflowRunner.swift` | Derive the root run identity, attach current-session/current-step metadata to every adapter attempt, propagate inherited run context into recursive calls, preserve the run body's original `Result`, invoke and await cleanup exactly once from the top-level lifecycle owner, restore the original result or error after cleanup, and call bundle-aware validation with the resolved node payload map. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift` | Render the session-start plus ordinary prompt as the fresh form and the ordinary prompt alone as the resumed form before adapter execution; do not decide fresh versus resume here. |
| `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift` | Copy the root run context to each branch while preserving the independently resolved branch workflow-session identity, join descendants before root cleanup, and prove branch completion cannot evict sibling state. |
| `Sources/RielaCore/WorkflowValidation.swift` | Preserve `validate(_ workflow:)` and add `validate(_ workflow:nodePayloads:)`. The bundle-aware overload validates the effective step-or-node policy after node files, shared references, and patches are resolved, including that `inheritFromStepId` is allowed only for `reuse` and names a step in the same workflow. |
| `Sources/RielaCore/WorkflowRawValidation.swift` | Enforce authored `workflow.steps[].sessionPolicy` object shape, enum, non-empty-string, cross-field, and target-step rules before decoding can normalize invalid intent away. It does not claim to inspect separate node files. |
| `Sources/RielaAdapters/LocalAgentProcess.swift` | Expose raw stdout observation to the Codex adapter without consuming lines or changing existing streaming, backend-event classification, redaction, normalization, termination, or cancellation behavior. |
| `Sources/RielaAdapters/DispatchingNodeAdapter.swift` | Forward typed execution metadata unchanged and implement the async lifecycle requirement by awaiting `workflowRunDidEnd` on each already-loaded provider adapter. It must not load unused providers for cleanup or implement Codex-specific storage or parsing. |
| `Sources/RielaCLI/WorkflowResolution.swift` and `Sources/RielaCLI/WorkflowResolution+SharedNodeRefs.swift` | Keep raw authored-workflow validation at each decode boundary, hydrate node payloads, and materialize shared references. The resolver returns the payload map used by the bundle-aware callers below; raw validation alone does not claim node-policy coverage. |
| `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`, `Sources/RielaCLI/WorkflowStagedVerification.swift`, and `Sources/RielaCLI/WorkflowCatalogCommands.swift` | Replace every workflow-only validation of a resolved bundle with bundle-aware validation, after any command-local node patch. Inspect must add bundle-aware diagnostics even though it currently only summarizes a resolved bundle. |
| `Sources/RielaCLI/WorkflowRunCommand.swift` | For temporary payloads, construct the node-id payload map before bundle-aware validation. All local run modes pass their final instance-patched payload map to the runtime validator. |
| `Sources/RielaServer/WorkflowServingController.swift` | For a direct-directory selection, resolve/hydrate the complete bundle, apply any node patch, and invoke bundle-aware validation before accepting the served workflow. Scoped/package selections remain deferred to the runtime resolver, whose runtime validation is bundle-aware. |

The Codex state owner must be a single concurrency-safe reference shared by
the command-selection and post-process observation paths. Its indexes remain
keyed by `workflowRunId` and `workflowSessionId`; the value semantics of
`CodexAgentAdapter` must not create independent snapshots or permit a
process-global "latest thread" fallback.

## Execution Identity And State

`workflowRunId` is a runtime-only identifier derived by the top-level
`DeterministicWorkflowRunner.run` invocation after session entry is resolved.
Its value is the top-level `WorkflowSession.sessionId` created or resumed for
that invocation. A rerun that creates a new top-level session therefore gets a
new run id; resuming the same non-terminal session retains that session id.
The id is not authored in `workflow.json` and is not accepted from node or
prompt input.

The top-level runner stores that value in an immutable run-execution context
on its effective request. Every same-workflow fanout request and live
cross-workflow child request copies the context unchanged before recursively
calling `run`. Ownership is derived, not copied: an invocation that entered
without a context creates it and sets a local `ownsRunLifecycle` flag; an
invocation that entered with a context keeps `ownsRunLifecycle == false`.
Only the former wraps the run body in the awaited outcome-and-cleanup sequence
defined under Authentication Readiness. A recursive run uses the inherited
`workflowRunId`; it must not replace it with the child session id. After each
invocation resolves its own session entry, the runner makes the following
identity available for every adapter attempt:

- `workflowRunId`: the inherited top-level session id, stable across the root
  run and all descendants;
- `workflowSessionId`: that invocation's resolved
  `WorkflowSession.sessionId`, which is the parent id for parent steps and the
  independently created child id for branch steps;
- `stepId`: the workflow step id, not the reusable node payload id.

The identity travels as typed adapter execution metadata alongside
`sessionPolicy`; it is not placed in `arguments`, `mergedVariables`, prompts,
or environment variables. `DispatchingNodeAdapter` forwards it unchanged to
the cached provider adapter. These values must not be inferred from prompt
text, node ids, `fanoutIndex`, or process ids. A branch session id is the
isolation boundary. `fanoutGroupId` and `fanoutIndex` may be retained as
diagnostics but must not be required for correct keying.

Codex thread state is indexed as follows:

| State | Key | Value |
| --- | --- | --- |
| completed step lookup | `(workflowRunId, workflowSessionId, stepId)` | Codex thread id |
| branch-local latest lookup | `(workflowRunId, workflowSessionId)` | Codex thread id plus producing step id |

The shared adapter may contain entries for multiple branches, but an exact
workflow-session match is mandatory. Parent, sibling, cross-workflow, and
later workflow runs cannot resolve one another's entries.

## Command Selection

Command selection is deterministic and occurs before the process starts:

1. A missing `sessionPolicy`, a policy with missing `mode`, or `mode: new`
   always uses `CodexProcessCommandBuilder.buildExecArguments`.
2. `mode: reuse` with a non-empty `inheritFromStepId` performs an exact lookup
   for that step inside the current workflow session. It never substitutes an
   unrelated latest thread when the named step is unresolved.
3. `mode: reuse` without `inheritFromStepId` resolves the branch-local latest
   Codex thread inside the current workflow session.
4. A resolved, non-empty thread id uses
   `CodexProcessCommandBuilder.buildResumeArguments`.
5. An unresolved reuse request falls back to fresh
   `buildExecArguments`; absence of history is not a step failure.

Both fresh and resume commands preserve piped prompt transport and the current
Codex option construction. The adapter validates the final argv using the
existing prompt-transport rules. Explicit `new` is a reset for that execution:
it never resumes, even if an inherited or latest id exists. A valid thread id
emitted by that fresh execution becomes available to later explicit reuse.

### Prompt selection and retries

Fresh/resume resolution must occur before the final prompt is chosen and must
be the same immutable decision used to choose command arguments. The runner's
prompting layer renders two values from one set of variables and one selected
prompt variant:

- `freshPromptText`: non-empty `sessionStartPromptTemplate`, then the ordinary
  `promptTemplate` text;
- `resumedPromptText`: the ordinary `promptTemplate` text only.

`AdapterExecutionInput` carries both rendered values. The Codex adapter first
resolves `fresh`, `fresh-fallback`, or `resume`, then passes `freshPromptText`
to `buildExecArguments` for both fresh outcomes or `resumedPromptText` to
`buildResumeArguments` for resume. The command builder must not independently
repeat the lookup. Existing non-Codex adapters retain their current prompt
behavior by consuming the fresh form unless their own adapter explicitly
implements resume semantics. This keeps Cursor-specific resolution unchanged.

Each output-validation attempt repeats resolution against state committed by
prior successful attempts:

- nil or explicit `new` starts fresh on every retry and includes the
  session-start prompt on every newly created backend thread;
- resolved `reuse` resumes on the initial attempt and every retry, omitting the
  session-start prompt;
- unresolved `reuse` uses fresh plus the session-start prompt initially; if
  that successful attempt emits a thread id but output validation requests a
  retry, the retry resolves that id, resumes, and omits the session-start
  prompt;
- a failed, canceled, or id-less fresh fallback does not create resumable
  state, so a later attempt remains a fresh fallback and includes the
  session-start prompt.

Rendering errors, prompt variants, runtime variables, system prompts, memory
guidance, and prior-review feedback remain owned by
`DeterministicWorkflowRunner+Prompting.swift`; only selection between the two
already rendered user-prompt forms moves behind the Codex session decision.

## JSONL Thread Capture

The workflow adapter observes raw stdout JSONL without removing events needed
by normal response and backend-event processing. The extractor accepts the
same normalized forms used by the existing Codex process/session machinery:

- `thread.started.thread_id`;
- `session_meta.meta.id`;
- `session_meta.session_id`, `session_meta.sessionId`, or
  `session_meta.id`, including those fields inside the event payload.

Empty ids and non-string values are ignored. Repeated copies of the same id
are harmless. Conflicting non-empty ids from one process are treated as
ambiguous metadata: no lookup entry is promoted, and a later reuse request
therefore falls back to fresh execution rather than guessing.

A valid id is promoted after the Codex process exits successfully and before
output-contract normalization. This allows a validation retry to reuse a turn
that Codex successfully completed. A spawn failure, non-zero exit, or
cancellation does not replace prior thread state. Promotion uses the following
deterministic rules:

- a successful fresh execution updates the exact step entry and branch-local
  latest entry only when it emits one unambiguous id;
- a successful resumed execution already has a resolved thread id. If it emits
  that same id, or emits no recognized id, the adapter promotes the resolved id
  to the current step entry and branch-local latest entry;
- if any execution emits conflicting non-empty ids, or a resumed execution
  emits an unambiguous id different from the resolved id, metadata is
  conflicting and the adapter promotes nothing for the current execution.

The id-less resume rule preserves continuity without trusting absent metadata:
the adapter reuses only the id it resolved before launch. It lets a later
`inheritFromStepId` name the successfully completed resumed step. An id-less
fresh execution has no trustworthy id to promote, so existing entries remain
unchanged and later resolution follows the normal exact/latest rules.

Captured ids are runtime routing metadata, not workflow business output. They
must not be inserted into prompts or exposed as credentials. Diagnostic output
may identify the resolution outcome (`fresh`, `resume`, or `fresh-fallback`)
and source step without logging environment secrets.

## Authentication Readiness

Readiness deduplication is separate from Codex thread reuse. Its logical key is
the root `workflowRunId` plus a deterministic fingerprint of the effective
preflight configuration (Codex executable, working directory, and merged
environment). The fingerprint must not expose secret values. This permits one
successful check to serve concurrent fanout branches only when they would run
the same readiness commands in the same context.

The per-key state machine is:

- absent: start `codex --version`, then `codex login status`;
- checking: concurrent callers await the same in-flight check;
- ready: subsequent callers skip both subprocesses;
- failure or cancellation: remove the entry so a later call retries.

Only success is memoized. The existing injectable `checkAuthPreflight` seam
uses the same state machine. `AdapterExecutionError` classification and
redaction remain unchanged. A canceled waiter observes cancellation; it must
not convert the shared check into success or hide a check failure. Cancellation
of the root run cancels in-flight readiness work and clears non-ready state.

Cleanup ownership belongs only to the top-level run-execution context. A
fanout or cross-workflow child may finish, fail, or be canceled, but its
recursive `run` return path must not release any state keyed by the inherited
`workflowRunId`.

The lifecycle contract is an exact provider-neutral addition to `NodeAdapter`:

```swift
public struct WorkflowRunLifecycleContext: Equatable, Sendable {
  public let workflowRunId: String
}

public protocol NodeAdapter: Sendable {
  func execute(
    _ input: AdapterExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput
  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async
}
```

The protocol extension supplies a no-op default. The hook is deliberately
`async` and nonthrowing: cleanup is awaited, while an in-memory cleanup problem
cannot replace a completed run result, an adapter error, or `CancellationError`.
`DispatchingNodeAdapter` implements the requirement as an actor-isolated
method, takes a stable snapshot of its already-loaded provider adapters, and
awaits the same hook on each one. It does not instantiate an unused provider
at run end. `CodexAgentAdapter.workflowRunDidEnd` atomically cancels and awaits
any in-flight readiness task for the id, then removes all readiness and thread
entries for the id; it does not check the caller's cancellation state.

Swift `defer` is not used because it cannot await the actor-isolated hook. Once
the owned root context exists, the top-level path executes the run body into a
local `Result<WorkflowRunResult, Error>`. The body cannot produce that result
until its structured fanout task groups have canceled and joined all children
and every awaited cross-workflow call has returned. The owner then creates one
unstructured cleanup task that does not inherit the canceled state of the run
body, equivalent to
`Task.detached { await adapter.workflowRunDidEnd(context) }`, and awaits its
value. Only after that await does it return the saved success or rethrow the
saved original error. The task handle is not exposed and no timeout races the
cleanup. A validation or session-entry failure before the root context exists
has allocated no keyed adapter state and therefore invokes no hook.

`ownsRunLifecycle` is the exactly-once gate: only an invocation that created
the root context enters this outcome-and-cleanup wrapper; recursive runs never
do. Completion, failure, and cancellation therefore each invoke the hook once
per root run, after descendants join, and await it before the caller observes
the original outcome. A fast branch cannot invalidate readiness needed by a
slower sibling, and the parent can continue after the fanout join with
run-scoped readiness and its own session-scoped thread state intact. No
reference count is needed because recursive runs never own cleanup.

## Validation And Failure Rules

- The effective policy for a step is exactly `step.sessionPolicy ??
  nodePayloads[step.nodeId]?.sessionPolicy`; validation uses the same
  precedence as execution and never merges individual fields from both
  policies.
- `WorkflowValidating.validate(_ workflow:)` remains source-compatible for
  workflow-only callers. A new `validate(_ workflow: WorkflowDefinition,
  nodePayloads: [String: AgentNodePayload])` requirement has a compatibility
  default that delegates to workflow-only validation; `DefaultWorkflowValidator`
  overrides it to validate effective node-file policies. Runtime, CLI, server,
  package/staged verification, and inspect paths that already have a resolved
  payload map must call the bundle-aware overload.
- Workflow-only validation checks every step-authored policy. Bundle-aware
  validation additionally checks a node policy for each step that does not
  override it. A node policy hidden by a step override is not effective for
  that step; a shared node used by any non-overriding step is validated once
  with a node-payload diagnostic path.
- `inheritFromStepId` is meaningful only with `mode: reuse`; raw, typed, and
  bundle-aware validation reject it with `new` or a missing mode rather than
  silently ignoring intent. When present it must be a non-empty string naming
  a step id in the same effective workflow.
- `WorkflowRawValidation` validates policies authored in `workflow.json`.
  Separate node JSON is structurally checked by `AgentNodePayload` decoding,
  then its cross-field and step-reference rules are checked by bundle-aware
  validation after shared-node and patch resolution. `validateAuthoredWorkflowData`
  alone cannot and must not report node-file coverage.

The validation call-site contract is exhaustive for the current source
boundaries:

| Entry point and source | Payload state at validation | Required validator |
| --- | --- | --- |
| Base bundle decode in `WorkflowResolution.swift` | Authored `workflow.json`; node files not yet decoded | Keep `validateAuthoredWorkflowData`; do not claim bundle coverage here. |
| Shared-reference decode in `WorkflowResolution+SharedNodeRefs.swift` | Referenced authored workflow used to locate/materialize a node | Keep `validateAuthoredWorkflowData`; the materialized root bundle is validated by its consuming entry point. |
| `workflow validate` in `WorkflowValidateInspectCommands.swift` | Resolved/hydrated/materialized bundle after optional `--node-patch` | Must call `DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)`. |
| `workflow inspect` in `WorkflowValidateInspectCommands.swift` | Resolved/hydrated/materialized bundle | Must call the bundle-aware overload and surface its diagnostics in structured and text inspection results; invalid effective node policy must not be summarized as ready. |
| Staged verification in `WorkflowStagedVerification.swift` | Staged bundle after full resolution/materialization | Must call the bundle-aware overload before mock-scenario or other required verification. |
| Catalog `status` in `WorkflowCatalogCommands.swift` | One fully resolved catalog bundle | Must call the bundle-aware overload when calculating `valid` and diagnostics. |
| Catalog `list` in `WorkflowCatalogCommands.swift` | Each fully resolved catalog bundle | Must call the bundle-aware overload for every entry; one invalid bundle remains an invalid entry rather than aborting the list. |
| Temporary payload load in `WorkflowRunCommand.swift` | Inline/file workflow plus node payloads mapped from node-file or node-id keys | Must create the node-id map first, then call the bundle-aware overload and reject error diagnostics. A bare temporary workflow calls the same overload with an empty map. |
| Local runtime in `DeterministicWorkflowRunner.swift` | Programmatic or CLI request with final effective/instance-patched `request.nodePayloads` | Must replace the workflow-only call with `validate(request.workflow, nodePayloads: request.nodePayloads)` before building the execution plan. This is the final guard for normal, registry, temporary, auto-improve, mock-scenario, and programmatic runs. |
| Direct-directory server start in `WorkflowServingController.swift` | Complete resolved/hydrated/materialized bundle after the requested node patch | Must call the bundle-aware overload and return `workflow_invalid` or the existing patch-invalid category before listener startup. |
| Deferred scoped/package server start in `WorkflowServingController.swift` | No local payload map is available at selection time | Must not claim bundle validation at selection time; the resolved runtime request must pass the bundle-aware runtime guard above before execution. |

`WorkflowViewer.swift` and `DaemonWorkflowGraphPaneView.swift` remain authored
workflow viewers: their `validateAuthoredWorkflowData` calls have no resolved
node-payload map and are not bundle-validation callers. They continue to show
raw workflow diagnostics, while execution and the command/server bundle
surfaces above remain the authoritative effective-policy gates.

- A named inherited step need not have executed yet at static-validation time;
  runtime non-resolution uses the fresh fallback.
- Lookup never crosses a workflow-session boundary, including fanout siblings.
- JSONL parse failures do not fail an otherwise valid Codex response; they
  disable promotion for that execution and make subsequent reuse fall back.
- Authentication failure and CLI-unavailable errors retain their current
  user-visible categories. Neither is cached.
- No Codex GUI/helper suppression flag is assumed or added by this change.

## Data Flow

1. The top-level runner creates or resumes its workflow session, derives
   `workflowRunId` from that session id, and owns the sole run-ended hook.
   Recursive fanout and cross-workflow requests inherit the same run id while
   resolving their own `workflowSessionId`.
2. Before execution, bundle-aware validation checks the same effective
   step-or-node policy that runtime will use.
3. For each attempt, the runner renders fresh and resumed prompt forms and
   passes them with typed root-run, current-session, and current-step identity
   plus the effective `sessionPolicy`.
4. `CodexAgentAdapter` completes or joins the keyed readiness preflight.
5. The adapter resolves the requested thread using the current session only,
   then selects the matching already rendered prompt form.
6. `CodexAgentCommandBuilder` receives the immutable resolution and selected
   prompt and delegates argv construction to `CodexProcessCommandBuilder`.
7. The local process runner streams JSONL to existing event handling while the
   Codex extractor observes thread metadata.
8. On successful process completion, the adapter promotes an unambiguous
   emitted id, or the already-resolved id for an id-less resume, subject to the
   conflict rules above; ordinary output normalization and workflow publication
   continue unchanged.
9. Child completion never cleans shared run state. After every child has
   returned and the parent reaches a completed, failed, or canceled outcome,
   the top-level run-ended hook removes all entries for `workflowRunId`.

## Rollout And Verification Constraints

The change is backward compatible because nil and explicit `new` remain fresh
exec. It requires no workflow-package migration and no schema-version change.
Verification must cover:

- reuse with an exact or latest prior id selects resume arguments;
- nil, explicit `new`, and unresolved reuse select fresh exec arguments;
- effective-policy validation covers step-authored and node-payload policies,
  step-over-node precedence, invalid `new`/missing-mode inheritance, empty or
  unknown inherited step ids, shared nodes, and programmatic runner requests;
- CLI validation coverage supplies an invalid node-file policy through each
  resolved-bundle surface: `workflow validate`, `workflow inspect`, catalog
  `status`, catalog `list`, and staged verification. Each test asserts the
  effective node diagnostic and the entry point's existing invalid/failure
  representation;
- temporary-workflow coverage exercises both the envelope form with a mapped
  node payload and the bare-workflow form, proving the former rejects an
  invalid effective node policy before execution and the latter still accepts
  valid step-only policy with an empty payload map;
- runtime coverage constructs `DeterministicWorkflowRunRequest` directly with
  an invalid node-level policy and proves bundle-aware validation rejects it
  before any adapter call; a CLI run with an instance node patch proves the
  final patched payload, not the base bundle, is validated;
- server coverage starts a direct-directory workflow with an invalid node-file
  policy, repeats with a patch that makes the effective policy invalid, and
  proves listener startup is rejected; a scoped/package selection test proves
  selection remains deferred and its later runtime request is rejected by the
  same runtime guard;
- prompt tests prove session-start inclusion for fresh and fresh-fallback,
  omission for resumed turns, and retry behavior for explicit new, resolved
  reuse, promoted fresh-fallback, and failed/id-less fresh-fallback attempts;
- session ids from supported JSONL variants propagate, including
  `inheritFromStepId` targeting and ambiguous-id fail-safe behavior;
- a successful resumed step that emits no id promotes its resolved id under the
  current step, so a later `inheritFromStepId` targeting that id-less resumed
  step resumes the same thread; a conflicting emitted id promotes nothing;
- sibling fanout workflow sessions cannot resolve one another's ids;
- one branch can finish while a sibling remains active without evicting the
  sibling's readiness or thread state;
- after all branches join, the parent can execute another Codex step using the
  same cached run readiness and only its parent-session thread history;
- completed, failed, and canceled top-level runs each invoke cleanup exactly
  once and only return/rethrow after the async hook finishes, while recursive
  branch runs invoke it zero times;
- lifecycle tests use a suspending cleanup spy to prove the saved success,
  provider error, and `CancellationError` are not observable until cleanup is
  released, and that cleanup cannot replace any of those original outcomes;
- readiness success is single-flight and cached only within the same keyed run
  context, while failure retries and cancellation remains observable;
- focused `CodexAgentTests` and `AgentAdapterTests`, relevant RielaCore/RielaCLI
  tests, full `swift test` when feasible, and `swiftlint --strict` for every
  changed Swift file pass.

All scratch evidence belongs under repository-root `tmp/`. The pre-existing
RielaApp web-server/UI, RielaCLI, release-script, and package-resolution
worktree changes are outside this issue and must remain untouched and unstaged.

## Risks

- Missing execution identity would make step inheritance or branch isolation
  impossible; runtime plumbing must fail closed rather than use node id or a
  process-global latest thread.
- A readiness cache without configuration identity could reuse authentication
  across different `CODEX_HOME`, executable, or environment contexts.
- Actor reentrancy could launch duplicate concurrent preflights unless
  `checking` is represented as shared in-flight work.
- Overwriting state from failed or conflicting JSONL could route later work to
  the wrong Codex thread.
- Resume argv ordering must remain owned by
  `CodexProcessCommandBuilder.buildResumeArguments`.

## Implementation Result

Implemented on 2026-07-17 in `issue-resolution` mode. The final code follows
the accepted design without a Codex GUI-suppression flag or schema-version
change:

- `AdapterExecutionInput` now carries typed run/session/step identity plus
  separately rendered fresh and resumed prompts, and `NodeAdapter` has an
  awaited run-ended lifecycle hook.
- the Codex adapter owns actor-isolated per-run/per-workflow-session thread
  indexes and configuration-fingerprinted authentication readiness state;
  successful preflight is single-flight, while failures and cancellation are
  not cached;
- Codex JSONL thread ids are observed non-destructively, centralized with the
  existing process-session code, and promoted only after successful process
  completion under the accepted ambiguity and resume-conflict rules;
- root run identity is inherited by fanout and cross-workflow children while
  each child retains its distinct workflow-session id; only the top-level run
  performs cleanup;
- raw and effective session-policy validation is enforced by the runtime,
  resolved CLI surfaces, and the direct-directory server path.

Focused session reuse, fanout isolation, authentication retry/cache,
validation, prompt, identity, and lifecycle tests were added under
`Tests/AgentAdapterTests` and `Tests/RielaCoreTests`. Exact verification and
the unrelated full-suite exceptions are recorded in the completed
implementation plan.
