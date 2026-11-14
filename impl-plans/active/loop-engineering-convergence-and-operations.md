# Default Loop Guardrails And Terminal Preservation Implementation Plan

**Status**: Implemented; Step 7 comm-000054 revision verified; final full-suite rerun pending
**Workflow Mode**: issue-resolution
**Feature Fanout**: false — one feature, one work package
**Issue Reference**: No GitHub issue supplied
**Design Reference**: `design-docs/specs/design-loop-engineering-convergence-and-operations.md` S9/S9a
**Prior Plan**: `impl-plans/completed/loop-engineering-convergence-and-operations.md` (historical LB1-LB4 implementation; do not reopen)
**Created**: 2026-07-22
**Last Updated**: 2026-07-23

## Accepted Design And Review

- Source of truth: `design-docs/specs/design-loop-engineering-convergence-and-operations.md`, especially S9a, Compatibility and Migration, LB1, and Risks.
- Step 3 decision: `accepted-for-implementation-planning`; no high, mid, or low findings.
- Reviewed path: `design-docs/specs/design-loop-engineering-convergence-and-operations.md`.
- Codex-agent references: none supplied. There is no reference-repository or Cursor-adapter traceability work in this package.
- User QA: none required for S9a. The accepted design fixes the defaults, flag name, policy states, terminal-corridor rules, and propagation behavior.

## Scope

### Included

- Resolve each run into exactly one convergence-policy state: `declared`, `authored-inactive`, `disabled`, or `default`.
- Add `LoopConvergenceDeclaration.enabled`, defaulting to `true`, with declaration-level opt-out validation.
- For workflows with no `workflow.loop` object, synthesize `maxGateVisits: 4` and `maxRepeatedFindingRounds: 2` unless the request disables the default guard.
- Use existing step loop annotations and the shared gate payload parser to enforce defaults through the existing convergence tracker/evaluator path.
- Preserve existing `loop_stall` fields and add declared/default provenance; graceful default violations emit `accept-with-residual-risks`.
- Discover an unambiguous terminal corridor, route a default-policy violation into it, and carry a `loopGuardOutcome` marker to final root output.
- Reserve at least three terminal steps, or the full corridor length when longer, without raising or weakening the hard `maxSteps` limit.
- Add `riela workflow run --disable-default-loop-guard` as typed request context.
- Propagate request-level `maxSteps`, `maxLoopIterations`, and default-guard opt-out to live cross-workflow child sessions without copying or replacing child-authored loop declarations.
- Add an explicit `maxGateVisits: 4`, `maxRepeatedFindingRounds: 2`, `onStall: "fail"` convergence policy to `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`.
- Add focused tests and refresh CLI/help, loop-engineering documentation, implementation-plan progress evidence, and any package digests affected by committed workflow/skill changes.

### Excluded

- LB2-LB6 baseline, regression, concurrency, notification, trend, flakiness, and retrospective roadmap work.
- Changes to authored enabled convergence semantics, authored loop budgets, existing hard `maxSteps` enforcement, mock-scenario semantics, or failure-kind values.
- Default convergence for a workflow that already has a `workflow.loop` object but no `loop.convergence`; that state is `authored-inactive` for backward compatibility.
- Semantic/fuzzy finding matching, cross-session convergence, automatic recovery, distributed aggregate child budgets, or inference across ambiguous terminal paths.
- Unrelated refactors, main-branch work, push behavior outside the workflow's existing commit/push contract, or changes in another worktree.

## Task Breakdown

| Task | Deliverables | Primary write scope | Dependencies | Parallelizable |
| --- | --- | --- | --- | --- |
| S9A-1 Effective-policy model and validation | Optional `enabled` decoding/defaults; four-state resolver with constants 4/2; raw and typed validation; policy-state/provenance tests | `Sources/RielaCore/LoopEngineeringModels.swift`, `Sources/RielaCore/WorkflowLoopValidation.swift`, `Tests/RielaCoreTests/LoopEngineeringModelsTests.swift`, `Tests/RielaCoreTests/WorkflowLoopValidationTests.swift`, `Tests/RielaCoreTests/WorkflowLoopMetadataCodableTests.swift` | Existing authored convergence contract | Yes, with S9A-2; scopes are disjoint |
| S9A-2 Request context and CLI opt-out | Request and CLI option fields; parser/help wiring; local, auto-improve, fanout, and remote GraphQL propagation; parser/help/transport tests | `Sources/RielaCore/DeterministicWorkflowRunner.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`, `Sources/RielaCLI/RielaCommand.swift`, `Sources/RielaCLI/ParsedWorkflowOptions.swift`, `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`, `Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift`, `Sources/RielaCLI/WorkflowCommands.swift`, `Tests/RielaCLITests/CommandParsingTests.swift`, `Tests/RielaCLITests/WorkflowRunHelpTests.swift`, `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`, `Tests/RielaCLITests/WorkflowCommandAutoImproveTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift` | Existing `maxSteps` run and remote transport paths | Yes, with S9A-1; scopes are disjoint |
| S9A-3 Default enforcement and structured provenance | Route `declared` and `default` through one tracker/evaluator path; annotation-based default gate discovery; retain stall fields; add optional policy source and default action; prove authored states are unchanged | `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Sources/RielaCore/WorkflowRunEvent.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift` | S9A-1, S9A-2 | No; owns shared loop-policy/event integration |
| S9A-4 Terminal-corridor selection and graceful routing | Pure deterministic corridor selector; publisher-owned single-pass transition selection with explicit no-selection completion disposition; selected-transition staging across every executable publication path; persisted gate evaluation with intended-status-aware skipped-gate parsing; atomic effective-route commit; idempotent pending-publication recovery; fail when no corridor | New `Sources/RielaCore/LoopTerminalCorridor.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Sources/RielaCore/DeterministicWorkflowRunner.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`, `Sources/RielaCore/LoopFindingFingerprint.swift`, `Sources/RielaCore/RuntimePublication.swift`, `Sources/RielaCore/RuntimeSession.swift`, `Sources/RielaCore/RuntimeStore.swift`, new `Tests/RielaCoreTests/LoopTerminalCorridorTests.swift`, `Tests/RielaCoreTests/RuntimePublicationTests.swift`, `Tests/RielaCoreTests/RuntimeSessionTests.swift`, `Tests/RielaCoreTests/RuntimeStoreTests.swift`, `Tests/RielaCoreTests/RuntimeStoreSeedSessionTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift` | S9A-3 | No; shares runner, store, publication, parser, and loop-policy flow with S9A-3/S9A-5 |
| S9A-5 Reserved terminal-step accounting | Pre-dispatch reservation plus an atomic pending-step redirect; supersede displaced delivered input, append corridor input, and update session routing consistently; prove snapshot/resume behavior | `Sources/RielaCore/DeterministicWorkflowRunner.swift`, `Sources/RielaCore/LoopTerminalCorridor.swift`, `Sources/RielaCore/RuntimeStore.swift`, `Tests/RielaCoreTests/RuntimeStoreTests.swift`, `Tests/RielaCoreTests/RuntimeStoreSeedSessionTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerBudgetTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerLoopPolicyTests.swift` | S9A-4 | No; same runner and corridor flow as S9A-4 |
| S9A-6 Cross-workflow request propagation | Child request inherits `maxSteps`, `maxLoopIterations`, and opt-out alongside `defaultTimeoutMs`; child declaration remains authoritative; nested amplification is documented | `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift` | S9A-2 | Yes after S9A-2 and while S9A-3 begins; write scopes are disjoint |
| S9A-7 First-party fixture, docs, and integrity | Explicit fixture convergence policy with bounds 4/2 and `onStall: "fail"`; CLI/help and loop-engineering text; README/skill relevance review; workflow validation and exact-value inspection evidence; required package digest refresh if a changed packaged file is covered by `riela-package.json` | `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`, `design-docs/specs/design-loop-engineering-convergence-and-operations.md`, `Sources/RielaCLI/ParsedWorkflowOptions.swift`, `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` only if behavior is user-facing there, `riela-package.json` only when its digest scope changes | S9A-1-S9A-6 behavior stable | No final parallel claim; documentation and digests must reflect the integrated result |
| S9A-8 Integrated verification and handoff | Build, focused suites, fixture validation, help inspection, diff hygiene, progress log, residual-risk record | Tests and this plan's Progress Log; fixes stay within the owning task's scope | S9A-1-S9A-7 | No; final integration gate |

## Task Details

### S9A-1 Effective-Policy Model And Validation

**Deliverables**:

- `LoopConvergenceDeclaration.enabled` is optional on the wire and resolves to `true` when absent, preserving existing authored declarations and snapshots.
- Validation accepts `enabled: false` with both bounds omitted; rejects any bound or non-default `onStall` combined with disablement.
- A request-local resolver distinguishes all four accepted states without mutating `WorkflowDefinition`.
- The synthesized declaration is centralized and immutable for the run: visit cap 4, repeated-identical-finding rounds 2.
- Tests cover old JSON without `enabled`, enabled authored policy, authored-inactive loop metadata, declaration disablement, CLI/request disablement of only an absent-loop default, and invalid contradictory declarations.

**Completion evidence**:

- Focused model and validation suites pass.
- No authored convergence bound or `onStall` value is default-merged or changed.

### S9A-2 Request Context And CLI Opt-Out

**Deliverables**:

- Add a Boolean default-guard opt-out to `DeterministicWorkflowRunRequest` and `WorkflowRunOptions`, defaulting to false.
- Add the Boolean option to `ParsedWorkflowOptions`, map it through `RielaArgumentParser+WorkflowAndMemory`, and place it beside `--max-steps` in usage/help.
- Thread the field through the local initial request, `WorkflowRunCommand+AutoImprove` request reconstruction, and `DeterministicWorkflowRunner+Fanout` branch requests. Recovery continues to receive the same request value; it must not reset the flag.
- Support `--endpoint` consistently with sibling run limits: add `disableDefaultLoopGuard` to `WorkflowRemoteRunRequest`, set it in `WorkflowRunCommand.runRemote`, and serialize it as `ExecuteWorkflowInput.disableDefaultLoopGuard` in `WorkflowCommands.remoteRunInputObject`.
- The remote `executeWorkflow` service must reconstruct the same Boolean on its `DeterministicWorkflowRunRequest`. This repository contains the client contract but no in-repository `executeWorkflow` schema/controller implementation; do not invent a second server adapter here. Treat support for the additive input field as an external GraphQL endpoint compatibility dependency and prove the repository side with captured request/input tests.
- Tests assert omitted/default false, explicit true, help visibility, local request propagation, auto-improve/fanout preservation, remote request serialization, and no effect on explicit enabled or authored-inactive policies.

**Completion evidence**:

- CLI parser/help tests pin the exact flag.
- Local, auto-improve, and fanout runs reach the core request with the selected value.
- `WorkflowCommandInspectionTests` captures a remote mutation whose input contains `disableDefaultLoopGuard: true`; omission retains the server default.

### S9A-3 Default Enforcement And Structured Provenance

**Deliverables**:

- Replace `workflow.loop != nil` entry guards only where S9a requires the effective state; retain authored policy/budget checks elsewhere.
- Default gate discovery uses only `step.loop.gateId` or `step.loop.role == "gate"`; role-only identity falls back to step id.
- Reconstruct visits from persisted accepted gate executions through `LoopGatePayloadParser`; do not add a second payload parser or a second finding identity.
- Emit the existing `loop_stall` shape with gate id, violation kind, visits, repeated rounds, and bounded fingerprints plus optional `loopStallPolicySource` (`declared` or `default`).
- Explicit `warn` continues and explicit `fail` fails exactly as before. Default violations proceed to S9A-4 disposition.
- Do not project synthesized/default sessions into authored `LoopConvergenceEvidence`.

**Completion evidence**:

- Tests independently trigger the fifth gate visit and the second consecutive identical rejected/needs-work finding set.
- Events identify the stable gate, counts, fingerprints, violation kind, action, and provenance.
- Tests prove declared, authored-inactive, disabled-by-declaration, and disabled-by-CLI behavior.

### S9A-4 Terminal Corridor And Graceful Routing

**Deliverables**:

- Implement the accepted graph contract as a pure selector over validated workflow structure plus already-persisted branch choice.
- Own the pure graph model and selector in new `Sources/RielaCore/LoopTerminalCorridor.swift`; keep request policy resolution in `DeterministicWorkflowRunner+LoopPolicy.swift`.
- Select only a unique terminal suffix leading to a root-output-producing transitionless sink; stop backward extension at gates, branches, fanout/cross-workflow boundaries, or multiple incoming edges.
- Treat distinct sinks/suffixes and unresolved terminal outcomes as ambiguous; return no corridor rather than guessing.
- Define `WorkflowPrePersistenceRoutingDecider` and `WorkflowPrePersistenceRoutingDecision` in `RuntimePublication.swift`. The decider receives the already-selected ordinary transitions plus the reloaded staged session/execution and returns one of original publication, replacement corridor publication, or accepted-output-without-route followed by hard failure; it does not reevaluate transition predicates.
- Thread the optional decider through every publication-request construction path that can execute a step: file/inline, stdio, agent retry, native add-on, and input-filter skip paths in `DeterministicWorkflowRunner.swift`, `DeterministicWorkflowRunner+Addons.swift`, and `DeterministicWorkflowRunner+InputFilters.swift`. Install it only for an annotated gate in the `default` effective-policy state; all other requests retain the existing single-phase publication path.
- Make `RuntimePublication.swift` the sole owner of transition-predicate evaluation after candidate validation. Add a `WorkflowPublicationTransitionSelectionMode` to `WorkflowPublicationRequest`: ordinary paths use `rejectMultiple` and input-filter skip uses `firstMatch`, preserving the current ordered first-match skip behavior without preselecting a transition.
- Add `WorkflowPublicationNoSelectionDisposition` to `WorkflowPublicationRequest`. Ordinary paths default to `publishPayloadAsRoot`; input-filter skip uses `completeRootWithoutOutput`. Explicit transitionless sinks still use the existing `publishesRootOutput` request flag. This replaces the input-filter caller's current `selectedTransitions.isEmpty` computation without changing its matched or unmatched behavior.
- Remove `multiplePublishableTransitionFailure` and its runner/add-on calls from `DeterministicWorkflowRunner+Prompting.swift`, `DeterministicWorkflowRunner.swift`, and `DeterministicWorkflowRunner+Addons.swift`. Remove `transitionAfterSkippedInputFilter` from `DeterministicWorkflowRunner+InputFilters.swift` and pass the full authored transition list plus `firstMatch` mode to the publisher.
- After validation, `RuntimePublication.swift` evaluates each needed predicate at most once in authored order, producing the immutable ordinary selection. In `rejectMultiple` mode, more than one publishable direct transition fails the recorded execution with the existing `.invalidOutput` diagnostic and outward failure semantics; `firstMatch` stops after the first match. Unsupported-transition validation runs against this selection. No runner helper, decider, commit, or recovery path reevaluates predicates.
- Give `InMemoryWorkflowOutputPublisher` a narrow injected predicate-evaluator closure with `WorkflowBranchEvaluator` as the default so tests can count calls and fail on unexpected recovery-time evaluation without changing production semantics. The guarded path then builds unchanged accepted-output metadata before any outgoing message is appended.
- After ordinary selection, derive `ordinaryPublishesRootOutput` and `ordinaryCompletesRootWithoutOutput`: a nonempty selection sets both false; an empty selection honors explicit `publishesRootOutput` first, then the request's no-selection disposition. Input-filter `completeRootWithoutOutput` produces nil root output and terminal completion only when its ordinary selection is empty.
- Add optional `WorkflowPendingRoutePublication` metadata to `WorkflowStepExecution` in `RuntimeSession.swift`, decoding an absent value as nil. Persist the already-selected ordinary `WorkflowStepTransition` values, the derived ordinary root-output/completes-root flags, the no-selection disposition, and the intended successful status needed to finish publication without rerunning transition predicates. Add `stageWorkflowPublication`, `commitWorkflowPublication`, and `abortWorkflowPublication` inputs/results to `WorkflowRuntimeStore` in `RuntimeStore.swift`; update `InMemoryWorkflowRuntimeStore` and the `StaticWorkflowRuntimeStore` test double.
- `stageWorkflowPublication` persists the accepted output, adapter metadata/usage, intended successful execution status, and `pendingRoutePublication` metadata on the execution, while leaving the execution in its pre-commit status, leaving session status/current step unchanged, appending no message, and deferring review-finding/root-completion projection.
- Add a nonmutating intended-status input to `LoopGatePayloadParser.result(from:)` in `LoopFindingFingerprint.swift`. Existing callers default to the execution's persisted status. During staged evaluation, only the current execution is parsed with `pendingRoutePublication.intendedSuccessfulStatus`; prior executions use their committed status. This makes a payload-less input-filter gate visible as `.skipped` without prematurely completing the execution. Reload the staged session and evaluate the parser/tracker/evaluator from its persisted accepted gate observation, execution id, intended status, and stored selected transitions.
- When there is no default violation, the effective selection is the already-selected ordinary transitions. When a violation has a unique corridor, replace the selected loop-back with exactly one corridor-entry transition and attach `loopGuardOutcome` only to its routed payload. When no corridor exists, select no outgoing route and retain the hard-failure disposition. The original accepted gate output is never rewritten.
- Derive `publishesRootOutput`, `completesRootWithoutOutput`, `nextStepId`, cross-workflow/fanout directives, and message inputs only after the decision. An unchanged empty ordinary selection reuses its staged derived completion flags; any effective corridor selection clears both completion flags; accepted-output-without-route followed by hard failure also clears both. `commitWorkflowPublication` atomically appends only effective messages, performs only the effective root-completion projection, clears `pendingRoutePublication`, applies the staged terminal execution status, and persists the identical effective session `currentStepId`.
- Key stage and commit idempotency by session/execution id. Extend `RuntimePublication.swift`'s existing-execution lookup to reuse a matching pending publication before recording a new execution. A repeated stage with identical accepted metadata and selected-transition metadata returns the existing staged record; a repeated commit returns the previously committed messages rather than duplicating them. A stale execution, mismatched payload/selection, or partial-message request fails without mutation. An unexpected decider/commit error invokes `abortWorkflowPublication`, clears the staged output/metadata, and records the execution failure without publishing a route.
- Before terminal reservation or `visitedSteps` accounting, `DeterministicWorkflowRunner.swift` detects persisted `pendingRoutePublication` metadata at the session's current step. Resume from its stored payload/`when`, selected transitions, flags, and intended status; pass that persisted intended status to the parser for the current execution, rerun only the persisted-evidence decision, and invoke the idempotent commit without rerunning the adapter, reevaluating transition predicates, creating an execution, or consuming another step slot. A snapshot taken after commit resumes from the already-persisted effective current step.
- A no-corridor default violation commits the accepted execution with no outgoing message and clears the pending flag; the runner then emits the structured stall event and marks the session failed. Thus both recoverable and hard-failure paths contain no stale loop-back message.
- Keep declared-policy enforcement on its existing post-publication path so explicit `warn`, `fail`, and authored routing semantics remain byte-for-byte compatible. Do not run a second post-publication convergence evaluation for `default` state.
- Carry the marker unchanged through the corridor and merge it where `DeterministicWorkflowRunner.swift` currently updates `rootOutput`, without rewriting the original gate decision or findings.
- Use `loopNotConverging` only when a default violation cannot route; do not add a new failure-kind or convergence-violation enum case.

**Completion evidence**:

- `LoopTerminalCorridorTests.swift` covers a linear suffix, branches converging on one suffix, no output sink, distinct sinks, and fanout/cross-workflow ambiguity.
- `RuntimeSessionTests.swift` proves legacy execution JSON decodes without pending-route metadata and round-trips the staged selected transitions/flags. `RuntimeStoreTests.swift` proves stage/commit/abort atomicity, deferred projections, idempotent retry, and rejection without partial mutation.
- `RuntimePublicationTests.swift` uses the injected counting evaluator to prove ordinary `rejectMultiple` and input-filter `firstMatch` semantics, preservation of the existing multiple-direct-transition `.invalidOutput` failure, one predicate evaluation per examined transition, zero decider/commit/recovery reevaluation, persisted selected transitions, and matched/unmatched no-selection disposition. It asserts unmatched filtered publication completes without root output, while a matched filter routes and does not complete the root.
- `RuntimeStoreSeedSessionTests.swift` proves staged-publication snapshots resume with persisted intended status, selected transitions, no-selection disposition, and derived completion flags, while committed snapshots do not republish. `DeterministicWorkflowRunnerLoopPolicyTests.swift` covers standard, native-add-on, and input-filter gate paths with the counting evaluator; proves recovery avoids predicate evaluation, adapter redispatch, and extra visit accounting; verifies matched, unmatched, corridor-rerouted, and resumed filtered steps retain exact root-output/completion behavior; and covers final-root-output merge, graceful completion, hard failure without a corridor, add-on effective routing, and a payload-less skipped annotated gate whose staged intended status counts the visit, can trigger `maxGateVisits`, commits as skipped, and leaves no stale loop-back message.

### S9A-5 Reserved Terminal Steps

**Deliverables**:

- Apply reservation in `DeterministicWorkflowRunner.swift` at the top of the `while let stepId = currentStepId` loop, before `visitedSteps` increments and the existing `maxSteps` check, using the effective policy from `DeterministicWorkflowRunner+LoopPolicy.swift` and the shared selector from `LoopTerminalCorridor.swift`.
- In `default` state with a corridor, reserve `max(3, corridor length)` within the caller's unchanged `maxSteps` total.
- Allow steps already in the corridor to consume reserved capacity; redirect a non-terminal dispatch that would invade the reserve to the corridor entry.
- Before redirecting, resolve the pending step input through `DefaultWorkflowMessageInputResolver`. Use only its currently `delivered` messages as `displacedCommunicationIds`; preserve their deterministic merged effective payload but remove `_rielaInput`, which the corridor step will reconstruct.
- Add `WorkflowPendingStepRedirectInput`/`WorkflowPendingStepRedirectResult` and `redirectPendingWorkflowStep` to `WorkflowRuntimeStore` in `RuntimeStore.swift`. The operation must atomically verify the session's expected `currentStepId`, mark the identified delivered messages `superseded`, append exactly one delivered direct corridor-entry message, set the session `currentStepId` to the corridor entry, update its timestamp, and return the updated session and replacement message. Update `InMemoryWorkflowRuntimeStore` and the `StaticWorkflowRuntimeStore` test double explicitly.
- Build the replacement message from the deterministic latest displaced message's source step/execution/transition metadata and the resolved payload, plus the separate `terminal-step-reserve` `loopGuardOutcome` marker with `policySource: "step-budget"`, budget, visited count, reserved count, and residual risk. Preserve artifact references from all displaced messages without duplicates.
- After a successful atomic redirect, replace the runner-local session/current step with the returned values and continue the loop without dispatching or incrementing the displaced non-terminal step. The next iteration dispatches and counts the corridor entry normally.
- Rely on the existing input resolver rule that excludes `superseded` messages. Because both superseded and replacement records are part of the persisted runtime snapshot, seed/resume must resolve only the corridor-entry message and retain its marker.
- Do not emit `loop_stall` or fabricate gate/fingerprint fields for reservation-only activation.
- Preserve existing `maxStepsExceeded` when the corridor cannot fit, is absent/ambiguous, or the request is declared, authored-inactive, or disabled.

**Completion evidence**:

- `RuntimeStoreTests.swift` proves the redirect is atomic, rejects a stale expected step or foreign message id without mutation, supersedes only the selected delivered messages, appends one replacement message, and updates session routing consistently.
- `DeterministicWorkflowRunnerBudgetTests.swift` covers three-step and longer corridors, activation outside a gate, already-in-corridor execution, too-small budget, ambiguous corridor, reservation absence in every non-default state, and suppression of the displaced adapter dispatch.
- `RuntimeStoreSeedSessionTests.swift` and `DeterministicWorkflowRunnerLoopPolicyTests.swift` prove snapshot/resume excludes the superseded route, retains the corridor marker/current step, merges the marker into final root output, and emits no reservation-only `loop_stall` event.

### S9A-6 Cross-Workflow Propagation

**Deliverables**:

- Copy parent request-level `maxSteps`, `maxLoopIterations`, and default opt-out into each live callee request beside `defaultTimeoutMs`.
- Preserve per-session semantics: do not subtract the parent's visited count and do not copy parent-authored `loop.budget` or `loop.convergence` declarations.
- Audit fanout and other request-copy construction for consistency, but do not expand scope beyond preserving the same request context where those copies already exist.

**Completion evidence**:

- Cross-workflow tests capture the child request/result behavior for all inherited fields.
- A child-authored convergence/budget declaration remains authoritative.
- Dispatch depth remains capped at the existing value.

### S9A-7 Fixture, Documentation, And Integrity

**Deliverables**:

- Add exactly `"convergence": {"maxGateVisits": 4, "maxRepeatedFindingRounds": 2, "onStall": "fail"}` under `loop` in `.riela/workflows/codex-design-and-implement-review-loop/workflow.json`. Writing `onStall: "fail"` explicitly preserves the authored-policy hard-failure behavior and prevents the fixture from acquiring the synthesized default policy's graceful terminal action.
- Update CLI help and affected loop-engineering documentation with defaults 4/2, reserve 3, four policy states, limited opt-out scope, graceful routing, and per-child `maxSteps` semantics.
- Review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`; update only directly affected user-facing guidance.
- Refresh `riela-package.json` checksum/integrity digests only if the changed workflow, prompt, script, or skill belongs to that package's digest set, following repository rules.
- Keep the historical completed LB1-LB4 plan unchanged; this active S9a plan is the progress authority for the new work package.

**Completion evidence**:

- Updated workflow validates, and direct JSON inspection proves its authored convergence policy is exactly 4 visits, 2 repeated rounds, and `onStall: "fail"`.
- Help output contains the new flag and retains `--max-steps` guidance.
- Digest verification, if applicable, passes with no unexplained manifest changes.

## Dependencies And Ordering

1. S9A-1 and S9A-2 may proceed in parallel because their listed write scopes are disjoint.
2. S9A-3 requires the effective-policy resolver and request context.
3. S9A-6 requires S9A-2 only and may proceed while S9A-3 runs because it owns separate cross-workflow source and test files.
4. S9A-4 follows S9A-3 so it can consume the default violation and provenance contract.
5. S9A-5 follows S9A-4 and reuses the same corridor selector.
6. S9A-7 follows stable integrated behavior; S9A-8 runs last.

The remote GraphQL `executeWorkflow` endpoint is an external compatibility dependency: its `ExecuteWorkflowInput` schema and request reconstruction must accept `disableDefaultLoopGuard`. The repository-side deliverable is the additive `WorkflowRemoteRunRequest` and serialized input contract; remote deployment coordination is not a reason to silently drop the flag.

Do not mark additional tasks parallel without first confirming their actual write scopes are disjoint. In particular, S9A-3, S9A-4, and S9A-5 all affect runner control flow and must be serialized.

## Verification

Run from the repository root on `feat/loop-guardrail-defaults` and record command, exit status, test count when available, and any skipped or unrelated failure in the Progress Log.

### Static And Focused

```bash
git diff --check
jq -e '.loop.convergence == {"maxGateVisits": 4, "maxRepeatedFindingRounds": 2, "onStall": "fail"}' .riela/workflows/codex-design-and-implement-review-loop/workflow.json
swift test --filter LoopEngineeringModelsTests
swift test --filter WorkflowLoopValidationTests
swift test --filter WorkflowLoopMetadataCodableTests
swift test --filter LoopConvergenceTrackerTests
swift test --filter RuntimePublicationTests
swift test --filter RuntimeSessionTests
swift test --filter RuntimeStoreTests
swift test --filter RuntimeStoreSeedSessionTests
swift test --filter DeterministicWorkflowRunnerLoopPolicyTests
swift test --filter DeterministicWorkflowRunnerBudgetTests
swift test --filter LoopTerminalCorridorTests
swift test --filter DeterministicWorkflowRunnerCrossWorkflowDispatchTests
swift test --filter DeterministicWorkflowRunnerFanoutTests
swift test --filter CommandParsingTests
swift test --filter WorkflowRunHelpTests
swift test --filter WorkflowCommandInspectionTests
swift test --filter WorkflowCommandAutoImproveTests
```

### Build, Lint, Workflow, And Help

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build
direnv exec . .build/arm64-apple-macosx/debug/riela workflow validate codex-design-and-implement-review-loop
direnv exec . .build/arm64-apple-macosx/debug/riela workflow run --help
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet
```

If project-scope resolution does not discover the checked-in fixture, use `--workflow-definition-dir .riela/workflows` and record the exact replacement.

### Integrated Regression

```bash
swift test
git diff --check
git status --short
git diff --name-only
git branch --show-current
```

Known unrelated local flakes may be classified only with command output showing they match the intake's named cases: `DaemonWorkflowNodePatchTests` event-source restart or agent-VM interleaved submit. New loop, budget, cross-workflow, CLI, fixture, or model failures are blocking.

## Risks And Mitigations

- Ambiguous or absent terminal corridors retain deterministic failure; selector tests cover every accepted ambiguity boundary.
- Staged publication is limited to annotated default-policy gates; tolerant decoding, persisted selected-transition metadata, idempotent stage/commit, atomic abort, and resume tests prevent the additive state from changing authored or legacy sessions.
- Transition selection and no-selection completion derivation move into the publisher; explicit `rejectMultiple`/`firstMatch` and `publishPayloadAsRoot`/`completeRootWithoutOutput` modes plus standard, add-on, and input-filter counting tests preserve existing failure, ordered-skip, root-output, and completion behavior while preventing duplicate evaluation.
- Terminal reservation can end undeclared revision work earlier; the hard `maxSteps` total remains unchanged and the final output records activation.
- Reservation rewrites pending routing atomically; stale-step and foreign-message guards prevent partial or cross-session mutation, while snapshot/resume tests pin marker survival.
- Per-child session limits can amplify aggregate nested work; the existing dispatch-depth cap remains authoritative and no parent-authored loop budget is copied.
- A remote GraphQL endpoint may not yet accept the additive opt-out field; captured request tests prevent client-side omission, and endpoint compatibility must be recorded before claiming remote verification.

## Completion Criteria

- [x] One work package completes all S9A-1-S9A-8 tasks; `has_feature_fanout` remains false.
- [x] An absent-loop workflow enforces default cap 4 and repeated-finding rounds 2 through existing tracker/evaluator machinery.
- [x] Both default violations emit the structured stall fields and default provenance.
- [x] A unique terminal corridor completes with an `accept-with-residual-risks` marker across file/inline, stdio, agent-retry, native add-on, and input-filter publication paths; RuntimePublication is the sole predicate evaluator, ordinary multiple-direct and input-filter first-match semantics remain unchanged, matched/unmatched filtered steps retain exact root-output/completion behavior, the persisted ordinary selection narrows distinct authored sinks when it resolves a terminal corridor, payload-less skipped gates are counted without prematurely finalizing their execution, and the atomic commit stores only the effective message and matching session `currentStepId`.
- [x] Terminal reservation protects at least three steps or the full longer corridor while never increasing `maxSteps`; its atomic redirect supersedes the displaced delivered route, suppresses that dispatch, and both reservation and convergence residual-risk markers survive snapshot/resume into final root output.
- [x] Authored enabled, authored-inactive, declaration-disabled, and CLI-disabled states retain the accepted distinct behavior.
- [x] `--disable-default-loop-guard` is typed, documented, tested, and limited to synthesized defaults.
- [x] Local, auto-improve, fanout, and remote GraphQL request paths preserve the opt-out; captured remote input includes `disableDefaultLoopGuard` and never silently drops it.
- [x] Parent request-level `maxSteps`, `maxLoopIterations`, and opt-out reach child sessions without overwriting child declarations.
- [x] The first-party workflow carries exactly `maxGateVisits: 4`, `maxRepeatedFindingRounds: 2`, and `onStall: "fail"`; direct JSON inspection and workflow validation pass.
- [ ] `swift build`, focused affected suites, full `swift test`, workflow validation, help inspection, and lint complete with recorded evidence or a precisely classified unrelated known flake.
- [x] No unrelated files, mock-scenario adapter semantic changes, new failure-kind values, or weakened authored budget/step enforcement are introduced; mock-scenario runs exercise the same synthesized defaults as live runs, and only the explicit declaration or CLI flag opts out.
- [x] Documentation is refreshed, relevant package digests are current, and this plan's Progress Log records completed tasks, changed files, verification, deviations, residual risks, and final review decisions.

## Progress Log Expectations

For every implementation session append a dated entry containing:

- tasks completed, in progress, and blocked;
- exact changed file paths grouped by task;
- design deviations and their review status, or `none`;
- exact verification commands, exit codes, test counts, and failure classification;
- review findings and dispositions;
- residual risks, especially terminal-corridor ambiguity and aggregate nested child work;
- remote GraphQL endpoint compatibility status for the additive `ExecuteWorkflowInput.disableDefaultLoopGuard` field;
- whether workflow/skill edits required `riela-package.json` digest refresh;
- whether completion criteria changed, with the authorizing review reference.

Do not check a task or completion box until implementation and its required verification evidence both exist. Do not move this plan to `completed/` until every criterion is checked or an accepted deferral names its owner and trigger.

## Progress Log

### Session: 2026-07-22 Step 4 Implementation-Plan Creation

- Tasks completed: Created the active S9a implementation plan from the Step 3 accepted design and review decision.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: None; Step 3 reported no findings or feedback.
- Verification: Plan structure and diff hygiene checks recorded in the Step 4 handoff.
- Residual risks: Ambiguous terminal corridors retain hard failure; reservation may end undeclared revision work earlier; per-child limits can amplify aggregate nested work.

### Session: 2026-07-22 Step 4 Self-Review Revision

- Tasks completed: Revised S9A-2 to define local, auto-improve, fanout, and remote GraphQL propagation; named the external server compatibility boundary. Named `LoopTerminalCorridor.swift`, `DeterministicWorkflowRunner.swift`, `DeterministicWorkflowRunner+LoopPolicy.swift`, and `RuntimePublication.swift` integration seams plus exact test files for S9A-4/S9A-5.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: Both mid-severity plan-only findings from `comm-000019` are addressed; no design revision was required.
- Verification: Plan-content, source-path, dependency, and diff-hygiene checks recorded in the revised Step 4 handoff.
- Residual risks: The external GraphQL endpoint must accept the additive input field; ambiguous terminal corridors and aggregate child amplification remain accepted risks.

### Session: 2026-07-22 Step 4 Persistence-Ordering Revision

- Tasks completed: Replaced the post-publication default-routing override with an asynchronous pre-persistence decision in `RuntimePublication.swift`; specified the atomic `WorkflowRuntimeStore` pending-step redirect used by terminal reservation.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: Both mid-severity plan-only findings from `comm-000021` are addressed. The plan now persists only the effective convergence transition, atomically supersedes displaced reservation input, keeps session and runner routing consistent, suppresses displaced dispatch, and verifies snapshot/resume marker survival. No design revision was required.
- Verification: Source seams, protocol conformers, input-resolution lifecycle behavior, plan content, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: The additive publication hook and atomic store operation require focused compatibility tests; accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 4 Persisted-Evidence Revision

- Tasks completed: Reordered S9A-4 around ordinary transition selection, persisted accepted-gate staging, persisted-evidence evaluation, and atomic effective-route commit. Added optional tolerant pending-publication metadata that stores the selected transitions and completion flags for idempotent stage/commit/abort and resume behavior.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: Both mid-severity plan-only findings from `comm-000023` are addressed. The decider consumes already-selected transitions, the current gate is persisted before tracker evaluation, all downstream routing artifacts derive from the effective selection, and failure/recovery cannot duplicate adapter work or messages.
- Verification: Accepted persisted-evidence wording, existing transition/publication order, all request-construction paths, runtime-store conformers, legacy Codable coverage, plan content, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: The additive staged-publication state requires careful idempotency and snapshot coverage; accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 5 Add-On Publication-Path Revision

- Tasks completed: Added `DeterministicWorkflowRunner+Addons.swift` to S9A-4's write scope and exhaustive publication-decider wiring; added focused add-on-backed annotated-gate coverage to S9A-4 evidence and the completion criteria.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: The mid-severity plan-only finding from `comm-000026` is addressed. Native add-on output can no longer be omitted from the default-policy staging and effective-route contract, and the plan requires a regression test proving persisted evidence, terminal rerouting, and absence of a stale loop-back message. No design revision was required.
- Verification: Add-on publication-path coverage, required plan sections, accepted S9a terminology, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: The additive staged-publication state still requires careful idempotency and snapshot coverage; accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 4 Skipped-Gate Staged-Status Revision

- Tasks completed: Defined intended-status-aware parsing for the current staged execution without prematurely changing its persisted execution status; added skipped annotated-gate cap, commit-status, recovery, and stale-route regression coverage.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: The mid-severity plan-only finding from `comm-000028` is addressed. The staged and recovery paths now pass the persisted `pendingRoutePublication.intendedSuccessfulStatus` only for the current execution, while committed history continues to use stored execution status. A payload-less input-filter gate therefore remains visible to the shared parser and tracker before atomic commit. No design revision was required.
- Verification: Intended-status data flow, skipped-gate parser behavior, regression coverage, required plan sections, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: The additive staged-publication state still requires careful idempotency and snapshot coverage; accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 4 Single-Pass Transition-Selection Revision

- Tasks completed: Consolidated planned predicate evaluation in `RuntimePublication.swift`; added explicit `rejectMultiple` and input-filter `firstMatch` modes; removed planned runner/add-on multi-transition scans and input-filter preselection; added counting-evaluator coverage for standard, native-add-on, input-filter, staged-decider, and recovery paths.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: The mid-severity plan-only finding from `comm-000030` is addressed. `DeterministicWorkflowRunner+Prompting.swift` is now explicit write scope, RuntimePublication owns the only predicate pass after validation, existing multiple-direct `.invalidOutput` and ordered input-filter first-match behavior are preserved, and persisted selections are reused without reevaluation. No design revision was required.
- Verification: Sole-evaluator wording, removed helper/preselection contracts, standard/add-on/input-filter counting tests, recovery reuse, required plan sections, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: Transition-selection consolidation requires precise compatibility tests; staged-publication idempotency, accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 4 No-Selection Completion Revision

- Tasks completed: Added an explicit publisher no-selection disposition; specified post-selection derivation and persistence of ordinary root-output/completes-root flags; defined effective-selection recomputation for unchanged, corridor-rerouted, and hard-failure dispositions; added matched, unmatched, staged, and resumed input-filter coverage.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: The mid-severity plan-only finding from `comm-000032` is addressed. Input-filter skip now requests `completeRootWithoutOutput`, ordinary paths retain `publishPayloadAsRoot`, and RuntimePublication derives completion only after selection so removing caller preselection does not turn skipped payloads into root output. No design revision was required.
- Verification: No-selection disposition, derived/staged/effective completion flags, matched/unmatched and recovery tests, required plan sections, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: Transition-selection and completion consolidation require precise compatibility tests; staged-publication idempotency, accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 4 Fixture-Policy Revision

- Tasks completed: Pinned the first-party workflow's authored convergence policy to `maxGateVisits: 4`, `maxRepeatedFindingRounds: 2`, and explicit `onStall: "fail"`; added direct JSON inspection alongside workflow validation.
- Tasks in progress: None; implementation has not started.
- Blockers: None.
- Changed files: `impl-plans/active/loop-engineering-convergence-and-operations.md`.
- Addressed feedback: The mid-severity plan-only finding from `comm-000034` is addressed. S9A-7 now fixes every material fixture-policy value, explains why authored `fail` is explicit, and requires exact-value evidence. No design revision was required.
- Verification: Exact fixture-policy wording, inspection command, completion criterion, required plan sections, and diff hygiene are recorded in the revised Step 4 handoff.
- Residual risks: Transition-selection and completion consolidation require precise compatibility tests; staged-publication idempotency, accepted corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 6 Implementation And Verification

- Tasks completed: Implemented S9A-1 through S9A-8 as one work package: four-state effective convergence policy, tolerant declaration opt-out, default 4/2 guard with provenance, staged single-pass publication, deterministic terminal corridors, residual-risk routing, three-step terminal reservation, request/CLI/GraphQL/fanout/cross-workflow propagation, first-party fixture policy, compatibility fixes, tests, and documentation.
- Tasks in progress: None.
- Blockers: None in the feature scope. The external GraphQL `ExecuteWorkflowInput` endpoint still owns deployment compatibility for the additive `disableDefaultLoopGuard` field.
- Changed files by task: S9A-1/S9A-3 changed `Sources/RielaCore/LoopEngineeringModels.swift`, `Sources/RielaCore/WorkflowLoopValidation.swift`, `Sources/RielaCore/WorkflowRunEvent.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, and `Sources/RielaCore/LoopFindingFingerprint.swift`; S9A-2/S9A-6 changed `Sources/RielaCore/DeterministicWorkflowRunner.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift`, `Sources/RielaCLI/ParsedWorkflowOptions.swift`, `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`, `Sources/RielaCLI/RielaCLIApplication.swift`, `Sources/RielaCLI/RielaCommand.swift`, `Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift`, and `Sources/RielaCLI/WorkflowCommands.swift`; S9A-4/S9A-5 added `Sources/RielaCore/LoopTerminalCorridor.swift`, `Sources/RielaCore/RuntimeMessageInputResolver.swift`, and `Sources/RielaCore/RuntimeStorePublicationTransactions.swift`, and changed `Sources/RielaCore/RuntimePublication.swift`, `Sources/RielaCore/RuntimeSession.swift`, `Sources/RielaCore/RuntimeStore.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift`, and `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`; tests changed `Tests/RielaCoreTests/DefaultLoopGuardTests.swift`, `Tests/RielaCoreTests/RuntimePublicationTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`, `Tests/RielaCLITests/CommandParsingTests.swift`, `Tests/RielaCLITests/WorkflowRunHelpTests.swift`, `Tests/RielaCLITests/WorkflowCommandInspectionTests.swift`, and `Tests/RielaCLITests/WorkflowCommandScenarioTests.swift`; S9A-7 changed `.riela/workflows/codex-design-and-implement-review-loop/workflow.json` and `design-docs/specs/design-loop-engineering-convergence-and-operations.md`.
- Design deviations: The initial implementation automatically disabled synthesized defaults for mock-scenario local runs. This deviation was rejected by the Step 6 test-integrity gate and is superseded by the revision below; mock-scenario runs now exercise production-equivalent default routing.
- Addressed feedback: Step 5 low finding fixed by changing the design's closing Implementation Plan paragraph to identify this active S9a plan and the completed historical LB1-LB4 plan accurately.
- Verification: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` passed; the affected Core/CLI filter executed 159 tests with zero failures; the 50 feature-related regressions identified by the first full run passed after compatibility fixes; two remote transport/serialized-input tests passed; `riela workflow validate codex-design-and-implement-review-loop --workflow-definition-dir .riela/workflows` returned `valid: true`; direct `jq -e` fixture inspection passed; CLI help inspection showed `--max-steps`, `--disable-default-loop-guard`, defaults 4/2, and reserve 3; `git diff --check` passed; SwiftLint exited zero with only five pre-existing warnings in unrelated files.
- Full-suite evidence: The first arm64 XCTest run executed 2,151 tests with 4 skipped and surfaced 23 assertions. Fourteen feature-attributable assertions were fixed and all corresponding 50 tests then passed. The remaining full-run failures were the intake-named `DaemonWorkflowNodePatchTests.testRuntimeRestartsWorkflowWhenEventSourceExits` event-source-restart flake plus two unrelated `SourceDeletionReadinessTests` repository-state gates (pre-existing TypeScript files and a model fixture). A second full run advanced through all modified workflow/runner tests with no feature failure, then terminated in an unrelated `RielaNoteUI` image-prefetch `NSException`.
- README/skill/package review: `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` do not expose this option surface and required no change. No `riela-package.json` exists in this worktree, so no digest refresh applies.
- Residual risks: Ambiguous or absent terminal corridors retain deterministic hard failure; reservation may end undeclared revision work earlier; per-child limits can amplify aggregate nested work; persisted staged-publication metadata depends on tolerant consumers; external GraphQL servers must accept the additive field.

### Session: 2026-07-22 Step 6 Self-Review Revision

- Tasks completed: Addressed all three mid-severity findings from `comm-000039`. Generic `WorkflowRuntimeStore` staged-publication defaults now fail closed instead of performing a non-atomic message-then-session update; `StaticWorkflowRuntimeStore` explicitly rejects unsupported transactions; committed retries validate the persisted route, payload, session destination, lifecycle, and completion flags before returning idempotent success.
- Test coverage completed: Added `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift` for pending-publication snapshot/resume without adapter or predicate replay, native-add-on default routing, payload-less input-filter skipped-gate cap handling, first-match predicate counts, commit/abort atomicity, stale redirect rejection, ambiguous corridors, long-corridor reservation, insufficient budgets, CLI opt-out, and declared-policy reservation exclusion. Extended `Tests/RielaCoreTests/DefaultLoopGuardTests.swift` with fail-closed default-store and mismatched committed-retry checks.
- Tasks in progress: None.
- Blockers: None in the feature scope.
- Changed files: `Sources/RielaCore/RuntimeStorePublicationTransactions.swift`, `Tests/RielaCoreTests/RuntimeStoreTests.swift`, `Tests/RielaCoreTests/DefaultLoopGuardTests.swift`, new `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift`, and this active plan.
- Addressed feedback: `comm-000039` findings at former lines 133 and 219 are resolved by fail-closed generic transactions and strict retry matching. The S9A-4/S9A-5 verification gap is resolved by focused path, recovery, atomicity, and reservation-edge regressions; completion criteria remain checked only after those tests pass.
- Verification: `swift test --filter DefaultLoopGuardRecoveryTests` passed 7 tests with zero failures; direct XCTest execution of the 18 accepted affected Core/CLI suites passed 167 tests with zero failures; `swift build`, workflow validation, exact fixture inspection, CLI help inspection, SwiftLint, `git diff --check`, file-size review, and branch verification passed. The complete 2,000-plus-test XCTest bundle was rerun and reached the unrelated Riela example parity suites without a feature failure before the 300-second command limit terminated it; the earlier Step 6 full-run baseline classification remains unchanged.
- Residual risks: Ambiguous or absent terminal corridors retain deterministic hard failure; reservation can end undeclared revision work earlier while preserving `maxSteps`; external GraphQL endpoints must accept the additive opt-out field; nested per-child limits can amplify aggregate work.

### Session: 2026-07-22 Step 6 Test-Integrity Revision

- Tasks completed: Addressed TI-001 through TI-005 from `comm-000042`. Removed the implicit mock-scenario opt-out; mock-backed CLI runs now exercise the same synthesized default guard as live runs. Restored multi-message atomic failure coverage, strengthened structured event and terminal-marker assertions, added declaration opt-out end-to-end coverage, and added focused local CLI, auto-improve rerun, and fanout inheritance regressions.
- Changed files: `Sources/RielaCLI/WorkflowRunCommand.swift`, `Sources/RielaCLI/RielaCLIApplication.swift`, `Sources/RielaCLI/WorkflowRunCommand+AutoImprove.swift`, `Tests/RielaCLITests/WorkflowCommandScenarioTests.swift`, `Tests/RielaCLITests/WorkflowCommandAutoImproveTests.swift`, `Tests/RielaCoreTests/DefaultLoopGuardTests.swift`, `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift`, `Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift`, and this active plan.
- Test-integrity dispositions: TI-001 resolved by deleting `options.mockScenarioPath != nil` from the request opt-out and adding a two-run mock scenario proving default enforcement and explicit CLI opt-out. TI-002 resolved with a two-message commit whose second append is rejected while messages and staged routing remain unchanged. TI-003 resolved by asserting gate id, violation kind, visits, repeated rounds, fingerprints, policy source, action, decision, and residual risks. TI-004 resolved with declaration-disabled execution, auto-improve rerun request, fanout branch, and local CLI regressions. TI-005 resolved by recording the complete executable 143-test filter below.
- Verification: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DefaultLoopGuardTests` passed 12 tests; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/arch -arm64 /usr/bin/xcrun xctest -XCTest 'RielaCoreTests.DefaultLoopGuardTests,RielaCoreTests.DefaultLoopGuardRecoveryTests,RielaCoreTests.RuntimePublicationTests,RielaCoreTests.DeterministicWorkflowRunnerFanoutTests,RielaCLITests.WorkflowCommandTests/testAutoImproveRerunPreservesDefaultGuardOptOut,RielaCLITests.WorkflowCommandTests/testMockScenarioUsesDefaultGuardUnlessCLIExplicitlyOptsOut,RielaCLITests.WorkflowCommandTests/testScenarioSequenceSkipsUnusedRetrySlotsForRepeatedStepExecutions' .build/arm64-apple-macosx/debug/rielaPackageTests.xctest` passed 44 tests; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter 'DefaultLoopGuardTests|DefaultLoopGuardRecoveryTests|RuntimePublicationTests|RuntimeStoreTests|DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerCrossWorkflowDispatchTests|WorkflowRunnerLoopPolicyTests|LoopConvergenceTrackerTests|LoopEngineeringModelsTests|WorkflowLoopValidationTests|CommandParsingTests|WorkflowRunHelpTests|testAutoImproveRerunPreservesDefaultGuardOptOut|testMockScenarioUsesDefaultGuardUnlessCLIExplicitlyOptsOut|testScenarioSequenceSkipsUnusedRetrySlotsForRepeatedStepExecutions'` passed 143 tests with zero failures; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` passed; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet` passed with five unrelated pre-existing warnings; workflow validation, CLI help inspection, `git diff --check`, TypeScript change detection, file-size review, and branch verification passed.
- TypeScript: `git diff --name-only -- '*.ts' '*.tsx'` returned no paths, so TypeScript post-modification checks are not applicable.
- Residual risks: The complete repository suite was not rerun in this revision; prior full-suite evidence and its unrelated timeout/failure classifications remain recorded above. Accepted terminal-corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-22 Step 7 Max-Steps Regression Revision

- Tasks completed: Addressed the mid-severity finding from `comm-000046`. Terminal reservation now requires the configured `maxSteps` total to fit the effective reserve `max(3, corridor length)`, rather than only the corridor length. An undersized initial budget therefore retains `maxStepsExceeded` instead of bypassing work and reporting terminal success.
- Changed files: `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift`, and this active plan.
- Test coverage completed: Added `testReservationRemainsAbsentWhenInitialBudgetIsBelowReserveFloor`; restored the existing `WorkflowCommandTests.testWorkflowRunJSONLFailureIncludesBufferedProgressRecords` contract for `recent-change-quality-loop --max-steps 1`.
- Tasks in progress: None.
- Blockers: None in the feature scope.
- Verification: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DefaultLoopGuardRecoveryTests` passed 8 tests; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter testWorkflowRunJSONLFailureIncludesBufferedProgressRecords` passed 1 test; the explicit affected Core/CLI filter including that regression passed 145 tests; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` passed; SwiftLint passed with five unrelated pre-existing warnings; `git diff --check`, changed-file size review, and branch verification passed.
- TypeScript: No TypeScript files changed in this revision; TypeScript post-modification checks are not applicable.
- Residual risks: The full repository suite still contains the previously classified unrelated daemon restart and source-deletion readiness failures. Accepted terminal-corridor ambiguity, external GraphQL compatibility, and aggregate child amplification risks remain.

### Session: 2026-07-23 Step 7 Branch, Recovery, And Fingerprint Revision

- Tasks completed: Addressed every finding from `comm-000050`. Default-violation routing now tries the persisted ordinary transition selection before the authored graph fallback, resume entry rehydrates a persisted `loopGuardOutcome` from current-step input, and both event and terminal-marker fingerprint arrays use the same eight-item bound.
- Changed files: `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`, `Tests/RielaCoreTests/DefaultLoopGuardTests.swift`, `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift`, and this active plan.
- Test coverage completed: Added a fifth-visit gate regression whose selected accepted branch and unselected replan branch have distinct terminal sinks; added convergence-redirect and reservation-redirect interruption/resume regressions; added a twelve-finding regression that pins both structured-event and root-output arrays to eight fingerprints.
- Tasks in progress: None.
- Blockers: None in the feature scope.
- Verification: `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter DefaultLoopGuardTests` passed 14 tests; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --skip-build --filter DefaultLoopGuardRecoveryTests` passed 10 tests; the explicit affected Core/CLI filter reported 149 tests with zero failures before the SwiftPM wrapper exceeded its 180-second process limit; `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` completed successfully; SwiftLint reported only the five unrelated pre-existing warnings before the wrapper timeout; workflow validation returned `valid: true` with no diagnostics; exact fixture-policy inspection returned true; `git diff --check`, branch verification, TypeScript change detection, and changed-file size review passed.
- TypeScript: `git diff --name-only -- '*.ts' '*.tsx'` returned no paths, so TypeScript post-modification checks are not applicable.
- Residual risks: The full repository suite was not rerun for this revision. Previously classified unrelated daemon-restart and source-deletion readiness failures remain; external GraphQL endpoint compatibility and aggregate child-work amplification remain deployment risks.

### Session: 2026-07-23 Step 7 Dispatch-Boundary Revision

- Tasks completed: Addressed every finding from `comm-000054`. Terminal-corridor discovery now fails closed when the runtime-selected or statically reachable path contains a fanout or cross-workflow boundary; a selected nonlocal transition cannot fall back to the authored graph and choose a local sink. The stale-redirect test now asserts the exact `WorkflowRuntimeStoreError` case and reason.
- Changed files: `Sources/RielaCore/LoopTerminalCorridor.swift`, `Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift`, `Tests/RielaCoreTests/DefaultLoopGuardRecoveryTests.swift`, and this active plan.
- Test coverage completed: Added convergence-routing regressions for selected cross-workflow and fanout transitions beside a local terminal path, plus terminal-reservation regressions for mixed local/cross-workflow and local/fanout exits. Both behaviors retain deterministic hard failure/no redirect at dispatch boundaries.
- Design deviations: None. The revision implements the accepted S9a rule that fanout and cross-workflow boundaries make a terminal corridor ambiguous.
- Addressed feedback: The mid finding at `Sources/RielaCore/LoopTerminalCorridor.swift:65` is resolved by explicit reachable-boundary detection and selected-transition fallback suppression. The low test finding is resolved by typed error matching. The full-suite completion criterion is intentionally unchecked because the complete repository suite was not rerun after this revision.
- Verification: Direct XCTest execution of `DefaultLoopGuardTests` and `DefaultLoopGuardRecoveryTests` passed 26 tests with zero failures. The explicit affected Core/CLI SwiftPM filter passed 151 tests with zero failures. `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build` reported `Build complete!`; the wrapper remained open until its timeout. SwiftLint reported no errors and only five unrelated pre-existing warnings before its wrapper timeout. Final diff hygiene, branch, TypeScript-change detection, and changed-file size checks are recorded in the Step 6 handoff.
- TypeScript: No TypeScript files changed in this revision; TypeScript post-modification checks are not applicable.
- Residual risks: The complete repository suite remains pending and the completion criterion stays unchecked. External GraphQL endpoint compatibility and aggregate child-work amplification remain deployment risks; intentionally ambiguous or absent terminal corridors retain deterministic hard failure.

## Related Plans

- Historical baseline: `impl-plans/completed/loop-engineering-convergence-and-operations.md`.
- Design lineage: `design-docs/specs/design-loop-engineering-first-line-tool.md`, `design-docs/specs/design-loop-engineering-first-line-tool-detail.md`, and `design-docs/specs/design-loop-engineering-application-gap-closure.md`.
