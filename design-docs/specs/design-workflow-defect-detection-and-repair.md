# Workflow defect detection and verified repair

Status: Draft revised after Step 3 review, 2026-09-22. Independent acceptance and implementation pending.

## Intent and evidence

Detect broken routing contracts and unproductive workflow cycles before expensive
agent repetitions. Explain each defect with reproducible evidence and offer a
bounded, verified repair proposal. A generic autonomous workflow rewriter is not
required.

The intake reports `maxStepsExceeded(53)` for the Work Runtime P1 incident: one `dispatch-plans`, 22
`reconcile-implementations`, 22 `integration-review`, plus setup activity. The eight-step remainder is inferred from the reported counts, not independently inspected execution evidence. Failed
workers remained pending while reviewers requested selective redispatch. The
persisted review outputs lacked the redispatch discriminator. This is incident evidence of repeated work, not a reconstructed causal proof; attributing its precise routing requires the captured workflow,
not a subsequently updated installed definition.

Current source facts:

- `WorkflowBranchEvaluation.swift` parses Boolean labels and resolves identifiers
  from `when`, then Boolean payload fields, then false. Constants `true`, `always`,
  `false`, and `never` are reserved. Missing and explicitly false are conflated.
- `RuntimeOutputValidation.swift` validates the payload schema, not a complete
  routing envelope contract.
- `DeterministicWorkflowRunner+LoopPolicy.swift` selects convergence handling by
  step gate metadata. `LoopConvergenceTracker.swift` already tracks gate visits and
  repeated findings. Reuse these mechanisms.
- Intake reports package 0.3.3 has `workflow.loop.convergence` with limits 4/2, but its
  integration-review step is not a declared/annotated gate. The earlier claim
  that convergence metadata was absent came from querying the wrong key, `loops`.

## Scope and ownership

Extend existing validation, publication, and convergence mechanisms. Coordinate
with `design-agent-node-output-contract.md` and its T2/T3 work: that plan owns
general output-schema requirements and bounded output retries; this feature owns
route-specific semantic analysis and progress checks. Coordinate with
`design-loop-engineering-convergence-and-operations.md`: preserve its policy
resolution, explicit disablement, and terminal routing. Future execution-environment typed readiness conditions supply readiness/liveness evidence to the progress check. They are not Boolean route expressions. Any future branch-condition expression support must consume the shared AST rather than introduce another parser.
Work Runtime P1 remains responsible for task orchestration and durable decisions.

Do not add a second scheduler, general SAT service, history store, or automatic
provider-authentication repair. Inspect only authorized source bundles and existing
runtime evidence. Package deployment follows the existing source/digest/install
process; installed immutable bundles are never edited in place.

## D1: One condition representation

Extract the existing tokenizer/parser into a shared parsed Boolean condition with
identifier enumeration and evaluation. Preserve supported expression syntax and
reserved constants. Validation and publication must use this representation.
Distinguish missing, wrong-type, false, and true. Reject malformed expressions
with the step and transition location rather than treating them as false.

For each referenced identifier, validation checks whether the producer contract
guarantees a Boolean routing value. The initial authoring convention is a required
Boolean payload property, validated by the existing output contract; `when`-only values remain valid runtime inputs where the effective producer contract permits them. A required payload property still must be supplied when its schema requires it; `when` cannot satisfy that payload requirement. Valid payload-only routing is supported. Add-on
outputs need catalog-backed route guarantees; absence of such evidence is reported
as unverified rather than inventing an agent schema on an add-on.
When schema combinators prevent a proof, emit an explicit analysis-incomplete
diagnostic. Do not silently treat uncertain guarantees as proven.

At publication, check all referenced routing controls in the effective routing contract before selecting or publishing any outgoing transition, including identifiers in short-circuited expressions. A supplied `when` Boolean and payload Boolean must agree. Reject
missing identifiers, incompatible types, and disagreements with a typed diagnostic.
Use existing bounded validation retries for agent outputs. Exhaustion produces a
terminal validation failure with no downstream enqueue or side effects. Correct
false values and reserved constants remain valid.

## D2: Bounded graph checks

Analyze ordinary exclusive conditional routing only. For at most 12 distinct
Boolean identifiers, enumerate assignments and report overlapping branches or
uncovered assignments where the workflow contract requires exactly one successor.
Include a witness assignment and transition locations. No-successor terminal steps,
fanout, call/resume, and externally dispatched transitions must retain their own
semantics. Derive that classification from current runner contracts before enabling
an error; uncertainty yields a diagnostic, not a fabricated exclusivity rule.
Above the bound, report that coverage was not checked; never report proven safety.

Build reachable strongly connected components for local steps. Report cyclic
components lacking an applicable convergence guard and cycles that bypass all
eligible gates. Check effective policy and step annotations, not just the existence
of `workflow.loop`. Identify possible exits and missing references, but do not claim
that an exit proves termination. Cross-workflow analysis is bounded to resolved,
pinned definitions; unresolved composition is explicitly incomplete. Intentional
long-lived event loops are not automatically classified as defective.

## D3: Progress evidence and convergence

Reuse the runner-owned convergence path and persistence. Add an explicit progress
projection for retry/reconciliation cycles where authoritative evidence exists.
Its stable identity includes accepted/pending branch IDs, terminal branch outcomes,
persisted repair change digests, and verification outcomes relevant to the decision.
Use semantic changes to results, not a new timestamp, execution ID, token count,
reworded finding, or another unchanged test pass as evidence of progress.
Bind projections to root invocation, wave and cycle; distinguish retry attempts for
audit without allowing attempt counters alone to reset a stall.

Compare only completed comparable cycles. A live worker, pending authorized wait,
external event subscription, or unobserved asynchronous result is not a no-progress
cycle. Missing evidence is unknown, never proof that nothing changed. Existing
max-step/max-visit limits continue to bound executions with unknown progress.

For the incident-shaped cycle, two consecutive equal completed projections with
unresolved work trigger the existing stall/terminal policy before another agent
round. Persist the projection/decision atomically with accepted output so resume
cannot erase the counter or double-count the same execution. Report previous and
current evidence references plus the selected policy. Reuse existing snapshots or
their projections; do not add a parallel database. Record format and recovery decisions are specified in D6 below.

Failed-branch redispatch may be derived mechanically only from an authored retry
policy and durable branch state. Authentication failures, unchanged environment
failures, non-idempotent side effects and cancelled work are not universally safe
to replay. When no permitted progress action exists, terminate with the concrete
cause and a repair proposal rather than repeatedly reviewing unchanged work.

## D4: Verified repair proposals

A proposal contains source identity and digest, diagnostic code, affected
file/JSON pointer, before/after change, rationale, semantic assumptions, test
commands and expected evidence. Mark each proposal `verified-equivalent` or
`requires-review`. Automatically apply only a transformation with a proved
unchanged meaning; initially offer canonical formatting of an already-valid
condition as the narrow equivalent case. Never claim this fixes the incident.

Missing required schema declarations, default flags, new convergence limits and
reroutes change accepted behavior and therefore require reviewed proposals.
Do not infer intent from a model explanation alone. Generate an incident-specific
mock with a failing pre-repair assertion and a passing post-repair assertion.
Schema edits alone cannot establish that the producer emits a required value.

Use existing workflow transaction and staged verification facilities for apply:
pin source/digest; reject stale source or path escapes; stage; validate; execute
selected deterministic regression tests; publish atomically or leave source intact.
An immutable package directs the patch to its source checkout and normal package
digest/version/test/publish/install workflow. Repair never commits, pushes, installs,
or executes live provider actions without authorization for those operations.

Diagnostics extend existing `workflow validate` output. Proposal generation is an
explicit option, not a side effect of validation. D5 specifies the proposed CLI surface after inspection of current validation, version restoration and staged verification APIs; these options are planned, not available commands.

## Acceptance evidence

| Scenario | Required result |
| --- | --- |
| Required Boolean exists in payload only | Correct branch accepted |
| Missing discriminator under negation | Rejected before routing, never silently false |
| Conflicting envelope/payload values | Typed validation failure |
| Overlap/gap in ordinary exclusive branch | Witness assignment or explicit incomplete result |
| Fanout and valid terminal output | No false exclusivity error |
| Loop metadata present, cycle bypasses gates | Guard-coverage diagnostic |
| Incident repeats unchanged failed branches | Stall before another unproductive round |
| Active worker or external wait | No no-progress failure from silence |
| Real repair or accepted-plan progress | Appropriate counter reset |
| Resume/replay of a persisted cycle | No lost counter or duplicate counting |
| Ambiguous repair or stale source | Review required or apply rejected, source intact |
| Immutable package | Source repair required; installed content unchanged |

Independent review must verify these cases against runtime semantics. This draft
does not claim implementation, test execution, or independent acceptance.

## Evidence identity and unresolved evidence

This is the single-author design for the complete requested plan set:
`impl-plans/active/workflow-defect-detection-and-repair.md`. Issue reference is
`workflow-input` in `/Users/taco/gits/tacogips/riela`; issue number and URL are null.
Authoritative runtimeVariables identify the current execution as
`codex-design-and-implement-review-loop-session-2`. Mode is `planning-only`.
No intake communication ID was supplied; intake communication ID is null. The
supplied `workflowInput` is the authoritative problem brief for this revision.
Review feedback arrived as `comm-000004`, from `step3-design-review` to
`step2-design-doc-update`, source execution `step3-design-review-attempt-1-exec-1`.
This is a review communication, not an intake communication. Its decision is
`revision_required_for_provenance` (`accepted=false`, `needs_revision=true`).
No Codex-reference input was supplied: `codexAgentReferences=[]`; Cursor CLI
mapping and intentional reference divergences are not applicable. No reference
repository or other worktree needs inspection for this runtime-owned behavior.

Step 2 inspected source at `62bf0ec28b6e0c5013fbd1b3b5d2d2de457d095f`.
The user-scope package currently resolves to version **0.3.5**, at
`/Users/taco/.riela/packages/codex-design-and-implement-review-loop/`.
Its `workflows/codex-design-and-implement-review-loop/workflow.json` has SHA-256
`d589326dc6c9c48bcd2cfcc29c2941ce610ae54e894a406bae79b5445089df78` and includes
integration-review in both step gate annotations and `loop.gates`. This fresh
observation does not replace the intake's version-specific 0.3.3 facts or prove
what the old incident ran. JSON's top-level `loop` represents `workflow.loop` in
the model; `loops` is incorrect. Installed files were read only.

Open evidence questions (not user product decisions):

- The historical session's captured definition, digest, branch ledger and accepted
  outputs are unavailable. Historical replay/causal attribution remains blocked
  until the incident owner supplies those artifacts. No missing flag, gate change,
  or current-package comparison is declared the sole historical cause.
- Work Runtime P1 is not represented by an accepted complete implementation in the
  inspected design. Native fanout evidence can exercise the progress interface now;
  P1 integration depends on its authoritative director/attempt API being available.
- Step 3 review in `comm-000004` identified one mid finding at the prior line 167:
  unsupported intake communication and workflow execution references. This revision
  corrects those references against runtimeVariables and requests renewed review.
  No Step 5 review was supplied; independent acceptance remains pending.

There is no unresolved user decision requiring a `design-docs/user-qa/` document.
These evidence limitations do not prevent a synthetic deterministic regression.

## D1 detail: syntax, guarantees and publication ordering

`WorkflowBranchEvaluator` currently combines parsing and evaluation; it does not
already expose an AST. Extract a single `ParsedWorkflowCondition` representation
with source spans, `identifiers`, and `evaluate(lookup:)`. Its shared parse result
is keyed by captured definition digest and transition pointer within an execution;
validation, type checks, contradictions, assignment enumeration and runtime
selection consume that same representation. This is a value, not another service
or persisted parser cache. Preserve `!`, `&&`, `||`, parentheses, hyphenated names,
case-sensitive reserved constants, and nil-label unconditional semantics. Empty
or structurally malformed expressions fail validation, including trailing `!`,
missing operands and unmatched parentheses; token consumption alone is not proof
of well-formed syntax.

Lookup reports `missing`, `wrongType`, or `boolean(value, source)`. `when` wins when
present; otherwise use a Boolean payload property. Payload-only false is present,
not missing. When both Boolean locations exist, disagreement is a contract error
before lookup is used for routing. This intentionally rejects contradictory output
while preserving precedence for valid output. Unknown values are never coerced to
false in strict publication. Legacy evaluator missing-to-false behavior is recorded
as the defect being removed from this boundary, not promised compatibility for
invalid output. Required payload fields remain subject to their schema even when
`when` contains the identifier. Non-routing payload fields are not new controls.

The initial static guarantee proof supports required top-level Boolean properties
and Boolean `const`/`enum` restrictions. A nullable, optional or non-Boolean property
cannot prove the guarantee. For schema combinations, every possible `anyOf` or
`oneOf` alternative must establish the guarantee; `allOf` constraints are intersected
only where the same bounded proof can establish consistency. Otherwise report
`analysis_incomplete`, with the schema pointer. Do not narrow the truth table using
unproven constraints. Add-on pass-through follows the producer walk owned by
output-contract T2; a guarantee is usable only if forwarding and any overwrite are
known. No agent `output` schema is invented on an add-on. Explicitly guaranteed
`when` controls need not be duplicated into payload solely for routing, but cannot
bypass a required payload-schema contract.

Runtime ordering: normalize envelope → validate output schema → resolve effective
routing controls → reject missing/type/conflict errors → evaluate AST → apply
existing completion/routing policy → persist accepted output and route atomically
→ enqueue. `RuntimePublication.swift:publish` currently invokes `validator.validate`
before `selectedTransitions`; put the new check at that shared boundary, not only
in a CLI adapter or after `WorkflowPrePersistenceRoutingContext` has selected routes.
Use the actual candidate values used by routing; carried policy payload cannot
silently supply or overwrite a producer's required control. Reconciler-generated
controls must be traceable to explicit authorized policy and revalidated.

Return `WorkflowPublicationError.validationRejected` so output-contract T3's
bounded output correction loop receives the failure. T3 owns the default of two
**total attempts** for `output != nil`; explicit authored bounds still apply.
Direct library callers receive that typed rejection without an internal hidden
retry. Side-effecting add-ons are not rerun to correct output. The guarantee is
zero downstream messages, child reservations or finalization on rejection; it does
not claim to undo the producer's already executed tool effects. Test ordinary,
inline, fanout-join, callee-resume and recovered pending-publication paths.

## D2 detail: exact routing and graph boundaries

Current `RuntimePublication.selectedTransitions` supports `rejectMultiple` and
ordered `firstMatch`. Its `completionDisposition` can publish root payload or
complete without output on no match. Thus transitions alone never establish a
must-select-one requirement. Use a shared internal routing-semantics descriptor
from the caller's actual publication contract:

| Contract | Static result |
| --- | --- |
| Exclusive, exactly one required by a proven caller contract | Overlap and no-match errors with witnesses |
| `rejectMultiple`, completion permitted on no match | Overlap error; uncovered assignments describe valid completion, not error |
| Ordered `firstMatch` | No exclusivity error for later matching branches; show selected first branch |
| Fanout item expansion, event dispatch, call/resume | Do not apply ordinary exclusive checks to child/item edges; preserve the parent selection contract |
| No outgoing transitions or valid terminal route | No no-match error |
| Unknown/custom selection or predicate | `analysis_incomplete`, never infer exact-one |

The inspected default sequential contract permits no match; the initial integration
must not invent a new mandatory-route flag merely to activate a no-match error.
An internal exact-one analyzer test must explicitly provide that contract. A future
caller that supplies it must name its evidence. Runtime malformed/missing control
rejection applies independently of this static coverage classification.

Bound each step to 12 identifiers (4,096 assignments), 256 transitions and 4,096
AST nodes total; report the limit name and observed size. Use identifier lexical
order and false-before-true enumeration for stable first witnesses. Contradictory
conditions such as `x && !x` yield an unsatisfiable-route diagnostic; a branch
whose supported constraints admit no assignment is not counted as an exit.
Unsupported expressions cannot turn graph edges into proven impossibilities.

For the resolved local graph, walk from the entry and compute SCCs, including
self-loops. Use all possibly feasible edges, removing only proven-false ones.
Report unreachable defects separately from reachable stall risk. For each reachable
cyclic SCC, remove eligible enforcing gate vertices and compute SCCs again: any
remaining cycle is a concrete gate-bypass witness. Sort vertices/edges for stable
paths. A reachable exit is only a possible exit, never proof of eventual traversal.
An SCC with an exit can still contain an indefinitely repeated subcycle.

Eligibility must reuse `effectiveLoopConvergencePolicy`, `loopGateParser` and the
same runner predicates, not duplicate an approximation:

- A missing loop object enables synthesized 4/2 defaults unless disabled.
- An authored loop without convergence is `authoredInactive`; explicitly disabled
  convergence remains disabled. Neither gets silently replaced with defaults.
- The runner requires `step.loop.gateId` or `role == "gate"` for its convergence
  hook. Gate declaration membership alone is insufficient. Parser acceptance of a
  `loopGate` payload alone does not establish that the hook runs at that step.
- Declared enforcement runs after publication today; default enforcement runs in
  the pre-persistence decision. Findings identify which timing is effective.
  Parseable gate results and finite applicable limits are additional conditions.
  A `warn` action reports risk but is not an enforcing cut in the graph.
- Default terminal reservation and max-steps are global bounds, not evidence that
  the SCC's findings/progress convergence is covered. Preserve finalization checks
  when composing a new progress decision with the existing routing decider.

Cap resolved graph analysis at 10,000 vertices, 50,000 edges and 32 pinned workflow
identities per request. Unresolved, recursive or over-limit cross-workflow edges
are explicit boundaries with `analysis_incomplete`. Local SCC evidence remains
usable. Do not substitute a call-only graph for a callee-return proof or classify
intentional long-lived event loops as stalled because they have no static exit.

## D3 detail: authoritative comparison and retry decisions

Introduce a small `WorkflowCycleProgressProjection` value consumed by the existing
tracker, not another guard engine. The existing native join/accepted-plan/change
records provide its inputs; later P1's director feeds the same value. A model's
claim that work changed is not authoritative input.

Comparison key: root invocation identity + current session identity + captured
workflow digest + stable wave/plan-set identity + SCC identity + selected cycle
boundary step. Choose the SCC's lexicographically first step for a deterministic
local boundary; observe only completed returns to that step with all participating
branch results durably settled. An observed cycle ordinal and publication identity
are deduplication metadata, excluded from the semantic progress hash.

Canonical content includes sorted stable branch IDs and normalized terminal
outcomes, pending/dispatched branch sets, independently accepted plan IDs and plan
content digests, accepted change-content digests, and relevant verification
identity `(check, subjectDigest, outcome, resultDigest)`. Hash normalized structured
evidence rather than raw logs. A repeated pass on the same subject is unchanged;
a newly passed formerly failing check or independently accepted plan is progress.
A changed attempt ID, timestamp, token total, prose or finding wording is not.
Changing failure prose without a changed typed failure/outcome is not progress.

The first complete projection establishes count 1. An equal next complete
projection raises it to 2; a material semantic change resets it to 1. Apply the
effective `maxRepeatedFindingRounds` to this additional comparison (the incident
fixture sets 2). Do not invent a new loop limit or enable a disabled policy.
If the applicable bound is absent, report progress observations without inventing
an enforced threshold. Existing gate visit/finding counters retain their semantics.
For declared `fail`, block the next route before persistence/enqueue; for declared
`warn`, record once and continue. Default policy uses its existing safe terminal
corridor or failure. A stalled component need not contain an annotated gate: this
progress observation occurs at its completed cycle boundary, using the same tracker
and effective policy. This closes the gate-bypass observation gap without silently
adding gates to authored graphs.

A live owned worker, queued accepted dispatch, reserved authorized retry, pending
external event/wait, or unread asynchronous result makes the cycle non-comparable.
If liveness is missing or readiness unknown, the result is unknown, not stalled.
Execution-environment `Ready` conditions supply this exclusion after E6; no second
readiness parser is introduced. Pending work is excluded only while backed by its
owned runtime lifecycle; abandoned/stale work must first be reconciled by its owner.
Existing budgets continue to apply even while this semantic comparison is unknown.

Redispatch is a policy decision over durable failed branch state, not a consequence
of the string “retry” in review prose. Require authored retry eligibility, stable
branch identity, allowed failure class, remaining retry budget and proven replay
safety/idempotency. Recheck them when reserving the attempt with the existing
native dispatcher/P1 authority. Accepted branches are never redispatched. Missing
policy means no derived redispatch. Authentication, unchanged environment,
cancellation and non-idempotent outcomes remain ineligible unless an explicit
supported policy and evidence establish a safe action; no universal retry rule is
added. P1 owns attempt reservation and fencing. Before its availability, the native
workflow must explicitly supply a reviewed retry decision; the detector offers
proposals and a stall result, not a replacement dispatcher.

## D5: Proposal interface and verification trust

Planned interface: extend `workflow validate <id> --output json` with read-only
structured `analysis` results; proposed `--repair-proposals` includes proposals in
that JSON without writing the source. Reuse `workflow self-improve` for explicit
proposal registration/review/apply, adding a proposed `--repair-proposal <path>`
input to its dry-run proposal path. This imports a diagnostic-bound proposal into
the existing history rather than the current fixed self-improvement marker change.
Apply remains the existing `--yes --change-set-id <id> --expected-digest <digest>`
contract after finalization through runtime-owned review evidence. Do not add an
independent repair command, approval file authority, change-set store or journal.
The new proposal options are planned and not available commands today.

`WorkflowSelfImproveVersioning.swift` already loads `WorkflowChangeSetStore`,
`WorkflowRuntimeGateEvidenceStore` and `WorkflowReviewGatePolicy`, verifies review
and source digests, and rejects immutable apply targets. Extend that path with the
mechanical transformation and diagnostic metadata. `WorkflowVersionCommands` owns
restoration and `LoopPromoteCommand` is read-only readiness; neither is patch apply.
Reuse `WorkflowDirectoryTransaction` and `WorkflowStagedVerifier` underneath.
Automatic eligibility never bypasses an existing required review gate; the initial
formatting proof can establish equivalence, while existing authorization and runtime
review prerequisites still apply. If P2 removes self-improve first, expose this
same proposal through its accepted `proposeWorkflowChange` decision, not both APIs.

`WorkflowDefectDiagnostic` carries stable code, severity, check status
(`complete`, `incomplete`, `notApplicable`), source digest, step/transition/file
JSON pointer, bounded witness/evidence and remediation class. Extend existing
validation results additively; `valid=true` means no proven errors, not complete
analysis. Malformed syntax, proven route contract failure and supported overlap
are errors; potential uncovered guards/exits and unknown proofs are diagnostics.
Output order is deterministic by file/pointer/code. Avoid raw payloads and secrets.

`WorkflowRepairProposal` format version 1 includes original bundle identity/digest,
per-file original digest, exact RFC 6901 JSON pointers, expected before-values,
proposed after-values and human-readable before/after diff; rationale; assumptions;
semantic class; required review evidence; and exact verification IDs, commands and
expected outcomes. Include changed-file ownership and dependency digests. The
proposal digest binds all fields; the existing runtime review record must bind that
digest, reviewer identity and decision through the finalized change set. A proposal
saying “approved” is not its own review evidence. `WorkflowRepairProposal` is the
diagnostic input/view of that existing proposal model, not a second durable format.

Proof for the only initial automatic transformation: parse a valid condition,
render its canonical expression, reparse and prove identical normalized AST with
identical identifiers/constants and evaluation semantics. Leave whole files and
unrelated fields alone. No truth substitution, schema-required insertion, gate/limit
addition, reroute or retry policy is automatically equivalent. Uncertain proposals
remain reviewable but unapplied. Reviewed semantic repairs must pair a failing
before-case with passing after-case and all applicable negative cases.

Command strings in a proposal are review text, never automatically shell-executed.
The runner maps allowlisted verification IDs to argument arrays and deterministic
mock adapters; no provider fallback or external-command retry is permitted. Missing
mock responses fail closed. `WorkflowStagedVerifier` currently requires successful
completed mocks and conditionally chooses mocks from loop self-evolution metadata;
repair must explicitly require its selected mocks regardless of that metadata and
support expected typed failures for negative fixtures. Consumed-response counts,
actual terminal disposition, assertions and exit status are required evidence.

Apply pins/checks source identity before staging and again inside the transaction;
reject changed digests, symlinks/escapes, unsupported pointers and changed before-
values. A failed check leaves live bytes intact. Transaction recovery must never
publish an unverified stage after restart. Validation/proposal generation is always
read-only. Only explicitly authorized apply can publish; it does not implicitly
commit, push, install or run live provider actions.

## D6: Persistence, migration and rollout

Persist a versioned, runtime-owned optional `cycleProgress` record in
`WorkflowAcceptedOutputMetadata` (`RuntimeSession.swift`), alongside accepted
output, not inside model-authored payload. It contains projection, comparison key,
comparison count, last comparable publication identity and the policy decision.
Use the existing acceptance/message checkpoint transaction. Extend pending
publication recovery metadata to carry this decision so a crash cannot recompute
it against newer external state. Snapshots project this record from the session;
no new table or parallel progress store is needed.

This is an additive serialized metadata change, **no SQL schema migration** for
this feature: `SQLiteWorkflowRuntimePersistenceStore.swift` persists executions in
`session_json` and the metadata introduces no indexed query field. Missing old metadata is unknown: reconstruct only when captured,
complete authoritative records suffice, otherwise start comparison at the next
complete cycle without claiming historical safety. Unknown record versions block
new semantic enforcement and report incompatible evidence; retain the existing
execution budgets. No fabricated counter reset is permitted for a same-version
resume. An older binary must not resume a session that has opted into this new
record; rollback uses a new run or an explicitly reviewed recovery path. Plan tests
must verify JSON/SQLite round-trip and transaction recovery, not just encode/decode.

Resume/replay preserves session and last counted publication; duplicate acceptance
is idempotent. A rerun/new root gets fresh comparison state and records lineage;
parent counters do not leak into child sessions. Child branches contribute via the
parent's accepted join snapshot, not a global execution list. Concurrent completion
must use the existing store's checkpoint conflict handling and retry with a fresh
snapshot, not commit two counts for the same publication.

Workflow schema syntax needs no new required Boolean flags or loop limits merely
to introduce diagnostics. Requiring controls at publication is a deliberate contract
validation tightening: release notes must show payload-only migration, when-only
contract behavior, missing-control failures and bounded correction. Schema repairs
in packages require human-reviewed source changes. If execution-environment E0's
planned schema-generation replacement lands first, extend that active definition
writer/store instead; its independent migration/discard decision is not owned or
reversed by this feature. Do not implement both stores for compatibility.

Rollout gates: (1) land shared AST and diagnostic-only graph checks, retaining
explicit completeness status; (2) reconcile output-contract T2/T3 and fixture
producers before enabling strict runtime control rejection; (3) enable progress
checks only for complete authoritative records under effective policy, run
crash/resume and negative cases; (4) expose reviewed proposals/staged apply after
transaction and fixture gates pass. Keep deterministic validation available without
network/provider availability. Do not activate incomplete static proofs as errors.

Package follow-up sequence is source checkout → reviewed patch → manifest digest
refresh → validate and deterministic mocks → version/publish → install new immutable
version → verify installed identity. Package 0.3.5 is evidence, not a patch target.
No workflow, prompt, script or skill changed in this planning turn, so repository
`riela-package.json` digests need no refresh now.

## D7: Deterministic fixture and acceptance matrix

Future fixture root: `Tests/RielaCoreTests/Fixtures/workflow-defect-incident/`.
It contains a pinned synthetic `workflow.json`, node schemas, strict mock responses,
branch/accepted-plan/change/verification evidence, expected diagnostic pointers and
`EXPECTED_RESULTS.md`. All are future implementation artifacts, not files created
by this planning turn. Mark provenance `synthetic-incident-shape`; never fabricate
a captured historical digest or assert an exact 53-step replay without artifacts.

Fixture topology: dispatch → native collect-partial join → reconcile → integration
review → either reconcile, explicit selective redispatch, or terminal. Two initial
branches fail. Variant A omits `redispatch_required` while a negated condition uses
it: validation/output rejection occurs with no next route, including correction
exhaustion. Variant B supplies valid controls selecting the reconcile/review cycle,
whose two completed projections retain identical failed branches, no accepted plans,
and unchanged verification/change identities: under declared 4/2 fail policy stop
before the third comparable round. This isolates route-contract failure from guard
coverage and progress failure. A reviewed retry-policy variant dispatches only the
eligible failed branch and advances actual authoritative state. Mock success must
not arrive merely because another agent round elapsed.

| ID | Test owner / case | Expected executable evidence |
| --- | --- | --- |
| A1 | Core branch tests: payload-only/when-only true and false, constants, precedence, nested/hyphenated identifiers | Existing valid behavior preserved; complete AST consumed |
| A2 | Core validation/publication: absent under negation, null/string control, conflicting when, optional/untyped schema | Exact typed error/pointer; bounded two-attempt correction; zero route/message/child publication |
| A3 | Core condition analysis: malformed tokens, missing operands, `x && !x`, overlap and exact-one gap | Parse/unsatisfiable diagnostics or stable Boolean witness |
| A4 | Core graph tests: 13 identifiers, excessive AST/edges, unsupported schema/custom predicate | Explicit incomplete status and reason, never “safe” |
| A5 | Core routing tests: ordinary no-match terminal, firstMatch, fanout items, call/resume | Correct existing completion; no false exclusivity/no-match error |
| A6 | Loop validation tests: unreachable/self SCC, gate-bypass subcycle, exit but repeated route, warn/disabled/authoredInactive and missing gate output | Stable reachable witness; eligibility and enforcement timing reported; no termination claim |
| A7 | Core composition tests: unresolved/recursive/pinned over-limit workflows | Local evidence retained; cross-workflow boundary incomplete |
| A8 | Incident Variant A/B and safe retry variant | Contract rejection separately from completed-cycle stall; bounded rounds; actual state progress for permitted redispatch |
| A9 | Tracker tests: wording/time/token churn vs accepted plan/change/new verification result | Churn does not reset; authoritative semantic change resets |
| A10 | Runner progress tests: active worker, queued result, pending authorized wait, not Ready, cancelled/stale owner | Live/unknown work excluded; abandoned work requires owner reconciliation |
| A11 | Store and runner tests: crash before/after checkpoint, duplicate publication, resume, new root, rerun, concurrent completion | No lost/duplicate count or cross-session contamination; one accepted next route |
| A12 | Retry tests: no policy, auth/environment, non-idempotent failure, exhausted budget, already accepted branch | No inferred replay or external action; explicit reason/policy evidence |
| A13 | CLI proposal tests: formatting equivalence, required flag/limit/reroute, unknown truth | Only proved equivalence automatic; semantic repairs require bound review and before/after tests |
| A14 | CLI transaction tests: stale source, changed dependency, symlink/pointer escape, failed mocks, crash/recovery | Original bytes unchanged on rejection; no unverified recovery promotion |
| A15 | CLI package tests: immutable target, proposed shell text, missing mock response | Source-directed proposal; no installed mutation, shell execution or live fallback |
| A16 | Metadata tests: absent/unknown progress version and serialized store round-trip | Explicit unknown/incompatible disposition; supported resume preserves policy/count |

For every implementation gate record exact command, cwd, fixture/definition digest,
exit status, consumed mock responses, assertions and complete foreground log path.
An intentionally failing runtime scenario passes its test only when the harness
asserts the expected failure kind and zero downstream publication. A process exit
alone, mock manifest, reviewer prose or incomplete log is not passing evidence.

## D8: Implementation ownership and native Riela handoff

The dedicated document is necessary because the issue crosses route parsing,
publication, guard analysis, persisted progress and repair transactions. It extends
existing seams only. No Monja changes, generic agent framework, alternate scheduler,
second parser/store/guard, unrelated cleanup or current runtime edits are authorized.

| Owner | Boundary and dependency |
| --- | --- |
| This feature T1 | Shared condition AST and typed route lookup; owns branch syntax, not template reference parsing |
| Output-contract T2/T3 | T2 producer walk/schema requirement and T3 bounded answer correction; this feature adds semantic guarantees and typed routing rejection after those contracts settle |
| Loop engineering plan | Effective policy, parser, terminal corridor/reservation and opt-outs; feature T3/T4 consumes/extracts shared pure helpers without weakening that plan |
| Work Runtime P1 | Fenced attempts, director decisions and branch authority; feature supplies progress/diagnostic values and consumes native evidence until P1 integration exists |
| Execution-environment E0/E6 | Active definition identity/store and Ready/liveness; never treat readiness records as branch-expression ASTs |
| Package source maintainers | Reviewed producer/route fixes, digests, publish/install; separate follow-up, immutable package read-only |

Step 4 must expand the preserved draft at
`impl-plans/active/workflow-defect-detection-and-repair.md` using the following
complete task contracts. Its pre-existing content/checkboxes remain unimplemented;
none are discarded or marked complete by this design. Reconcile its current
“when mirror” language with D1's explicit precedence/producer-schema distinction.
The existing `impl-plans/README.md` registration remains untouched in Step 2.

| Task / dependency | File-level deliverable and API boundary | Required gate |
| --- | --- | --- |
| T1 / output-contract boundary read | `WorkflowBranchEvaluation.swift`, new `WorkflowConditionAnalysis.swift`; `ParsedWorkflowCondition`, typed lookup, structural errors; existing `WorkflowBranchEvaluationTests.swift` plus focused condition tests | A1, A3, A4; no second parser |
| T2 / T1 and output-contract T2/T3 | `WorkflowValidation.swift`, `WorkflowValidationHelpers.swift`, `WorkflowRawValidation.swift`, `RuntimeOutputValidation.swift`, `RuntimePublication.swift`; `WorkflowDefectDiagnostic` and route-control validation before selection | A2, A5 and all shared publication entry paths; no add-on retry |
| T3 / T1 then T2 shared validation integration | New `WorkflowGraphAnalysis.swift`, `WorkflowLoopValidation.swift`, shared eligibility helper extracted from `DeterministicWorkflowRunner+LoopPolicy.swift`; analysis descriptor and deterministic SCC/cut witnesses | A3–A7; bounds/completeness and effective-policy parity |
| T4 / T2, T3; existing loop policy and native evidence | `LoopConvergenceTracker.swift`, `DeterministicWorkflowRunner+LoopPolicy.swift`, `RuntimePublication+Routing.swift`, `RuntimePublication.swift`, `RuntimeSession.swift`, `WorkflowRuntimePersistenceSnapshot.swift` and `RuntimeStorePublicationTransactions.swift`, `RuntimeStore.swift`, `SQLiteWorkflowRuntimePersistenceStore.swift`; projection/atomic decision, no new store | A8–A12, A16; default/declared/finalization policy composition; SQLite and file snapshot publication/recovery parity |
| T5 / T2–T4 | New focused repair proposal/CLI file; `WorkflowValidateInspectCommands.swift`, `ParsedWorkflowOptions.swift`, existing self-improve command parsing/help, `WorkflowSelfImproveVersioning.swift`, `WorkflowStagedVerification.swift`, existing directory transaction; digest-bound proposal and reviewed apply | A13–A15; reuse transaction recovery, no shell/provider fallback |
| T6 / T1–T5 for final integration | Fixture root in D7, existing Core/CLI suites plus focused new tests; `design-docs/specs/command.md`, `design-docs/specs/architecture.md`, authoring docs, this design and plan progress evidence | All A1–A16; rollout and package-source instructions; scope/checkbox audit |

Dependency-ready wave intent: T1 first; T2 next; T3 next because both wire shared
validation; T4 after T2/T3; T5 after T4; T6 final integrated acceptance. Pure fixture
preparation can precede its final gate only with disjoint owned files. Prefer this
serial dependency graph to overlapping edits in publication/validation. These are
authored dependencies; native Riela, not a dispatch agent, computes the ready set.

The later plan checkpoint must expose one complete plan-set manifest with task IDs,
exact `writePaths`, `sharedPaths`, `dependsOn`, `planPath`, acceptance/verification
contracts and full `reviewContext.sourcePaths` including this design. The plan
creator must resolve options/store helper filenames from that implementation base
before dispatch; no directory-wide allowlist or unresolved file-owner placeholder
is dispatch-ready. If the installed workflow requires one plan item per native
branch, Step 4 must encode the subtask contracts through its supported plan manifest
format or serialize the single plan's internal tasks; it must not fabricate a
second workflow or unsupported subtask scheduler. One requested plan file remains
the complete source of task contracts.

Use only the installed user-scope `codex-design-and-implement-review-loop` for later
orchestration. Native `fanout.dependencies` computes ready branches and excludes
independently accepted plan IDs; native `fanout.changeTracking` records immutable
before/after evidence. Preserve checkpoint commit and complete review context in
every dispatched item. Failed or unreviewed branches stay pending. Shared index
registration belongs to serial reconciliation. Never manually infer completion
from timestamps or spawn another workflow from this owned Step 2 node.

Planned executable verification commands (not run as implementation evidence here):

- `swift test --filter WorkflowBranchEvaluationTests`
- `swift test --filter 'WorkflowConditionAnalysisTests|WorkflowRouteContractTests|WorkflowGraphAnalysisTests'`
- `swift test --filter 'RuntimePublicationTests|RuntimeOutputValidationTests|WorkflowLoopValidationTests'`
- `swift test --filter 'LoopConvergenceTrackerTests|DefaultLoopGuardTests|DefaultLoopGuardRecoveryTests|DeterministicWorkflowRunnerLoopPolicyTests'`
- `swift test --filter 'WorkflowCycleProgressTests|WorkflowDefectIncidentTests|WorkflowRepairProposalTests|WorkflowStagedVerificationTests|WorkflowDirectoryTransaction'`
- `swift test --filter 'RielaCoreTests|RielaCLITests'`
- `swift build`
- `swiftlint lint --quiet --no-cache`
- `git diff --check`

New suite names above are task deliverables; zero selected tests is a failed gate.
Step 4 must add concrete fixture validate/mock commands using the installed CLI's
supported options after fixtures exist, including exact definition root. This
planning turn runs only documentation/source-evidence checks, not Swift tests or
future repair commands. Commit/push of the requested design/plan/narrow index are
authorized for the later workflow finalization stages, not performed in Step 2.

## Author self-check — Step 2

Author decision: `ready_for_design_rereview`, not independent acceptance. The author
checked the complete intake against D1–D8 and A1–A16. No high or mid design finding
remains from this self-check. Corrections made before handoff:

- Corrected the evidence identity against authoritative runtimeVariables: session-2,
  no supplied intake communication ID, and review communication `comm-000004`.
  Preserved Step 3's `revision_required_for_provenance` decision; the correction
  does not assert that independent review has accepted this revision.
- Kept intake's 0.3.3 facts separate from freshly observed 0.3.5 and historical
  uncertainty; removed the inferred setup count as an independently verified fact.
- Defined valid no-match completion/firstMatch/fanout boundaries, and explicit
  bounded incomplete results, rather than assuming all routes require one branch.
- Specified policy/gate hook eligibility, authoritative completed-cycle state,
  persistence/recovery and semantic-counter rules; reused existing mechanisms.
- Distinguished readiness conditions from branch ASTs and preserved when-first,
  payload-Boolean fallback with precise schema and conflict handling.
- Reused existing self-improve review/change-set/transaction authority after source
  inspection; removed an unnecessary separate apply command/review-file authority.

Verification evidence for this documentation turn is under
`tmp/workflow-defect-design/verification.log` with commands and individual terminal
exit statuses. `verify.py` in that directory captures complete outputs, checks
whitespace in the untracked design (which `git diff --check` alone omits), verifies
the plan/index hashes against the saved local baselines, checks tracked/untracked change
scope and confirms every acceptance ID and design section is present. Its final
status must be 0 for this handoff to pass. These mechanical checks supplement the
author's semantic read-through; they do not execute future runtime acceptance tests.
Revision verification is recorded separately in
`tmp/workflow-defect-design/provenance-revision-verification.log`. Its foreground
`verify-provenance-revision.py` check rejects the unsupported old identities, checks
the supplied execution and review lineage, and verifies plan/index preservation
against hashes captured at the start of this revision. Both logs require terminal
exit status 0. Historical causal replay remains unavailable; renewed independent
review and implementation verification remain later workflow gates. The sole edited deliverable in Step 2 is
this design; the existing plan and index are preserved byte-for-byte.
