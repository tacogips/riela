# Work Runtime P1: Dispatcher integration and plan contract

**Status**: Step 5 review pending; implementation not certified.
**Workflow mode**: issue-resolution
**Issue reference**: workflow-input:Complete Work Runtime P1 using the accepted dispatcher, guard, and director design
**Design reference**: `design-docs/specs/design-work-runtime-consolidation.md`, §17.1–17.5 and the sections identified below.
**Review source**: `comm-000004`, `step3-design-review`, `accepted_for_step4_implementation_planning`; no findings or revision request.
**Codex-agent references**: `riela-manager`, `step1-issue-intake`, `step2-design-doc-update`, `step3-design-review`, `step4-impl-plan-create`; downstream installed-package implementation/review executions must record their actual IDs.
**Updated**: 2026-09-21

```json
{
  "planId": "p1-dispatch",
  "planPath": "impl-plans/active/work-runtime-p1-dispatcher-guard-director.md",
  "dependsOn": [
    "p1-reservation",
    "p1-lifecycle",
    "p1-capabilities"
  ],
  "writePaths": [
    "Sources/RielaWork/TaskDispatcher*.swift",
    "Sources/RielaWork/AgentDirector*.swift",
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaCLI/TaskCommands.swift",
    "Sources/RielaCLI/TaskCommandModels.swift",
    "Sources/RielaCLI/TaskDispatch*.swift",
    "Sources/RielaCLI/RielaCommand.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/WorkflowRunCommand*.swift",
    "Sources/RielaCLI/WorkflowRun*.swift",
    "Sources/RielaCLI/*Supervis*.swift",
    "Sources/RielaCore/*AutoImprove*.swift",
    "Sources/RielaAdapters/SupervisedScenarioNodeAdapter.swift",
    "Sources/RielaCLI/RielaWebWorkflowRuntime.swift",
    "Sources/RielaCLI/WebWorkflowRequest*.swift",
    "Tests/RielaCLITests/TaskCommandMutationTests.swift",
    "Tests/RielaWorkTests/TaskDispatcherTests.swift",
    "Tests/RielaCLITests/TaskDispatcherIntegrationTests.swift",
    "Tests/RielaCLITests/TaskRuntimeExampleTests.swift",
    "Tests/RielaCLITests/*AutoImprove*.swift",
    "Tests/RielaCLITests/*Supervis*.swift",
    "examples/auto-improve/**",
    "examples/default-superviser/**",
    "examples/supervised-mock-retry/**",
    "examples/task-repair-loop/**",
    "examples/task-agent-director/**",
    "impl-plans/progress/p1-dispatch.md"
  ],
  "sharedPaths": [
    "Sources/RielaWork/TaskGuardCoordinator.swift",
    "Sources/RielaWork/WorkStore+Decisions.swift",
    "Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift",
    "Sources/RielaCLI/WorkflowRunCommand*.swift",
    "examples/task-repair-loop/**",
    "examples/task-agent-director/**"
  ],
  "progressLog": "impl-plans/progress/p1-dispatch.md",
  "taskIds": [
    "P1-6",
    "P1-7"
  ],
  "verificationCommands": [
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch",
    "/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'",
    "git diff --check"
  ]
}
```


## Authority and boundaries

The accepted source is §17.1–17.5 of the design, with §5a for capabilities and
§5–7 for domain rules. Step 3 accepted this revision in `comm-000004`, with
`needs_revision: false`, no high/mid findings and no user question. Earlier
comm-000005/comm-000007 and progress claims belong to the stopped workflow;
they are historical input, not acceptance or verification of this revision.
No Step 5 feedback was supplied for this turn.

Execution is already owned by the installed user-scope package
`/Users/taco/.riela/packages/codex-design-and-implement-review-loop/` and
`codex-design-and-implement-review-loop-session-1`. Continue its native
implementation/review lifecycle; do not start another workflow, invoke the
project-scope workflow, or manually spawn replacement implementation agents.
Canonical node edits are deliverables only. Preserve P0; defer P2 loop fold,
P3 routines/specialists/events/task serve, P4 repository isolation/provider
rewrite, P5 GraphQL task/host APIs and UI, P6 improvement and P7 ceilings.
Plain workflow run remains task-free. No extra task-management commands or
migration/compatibility adapter for removed auto-improve state is required.
Do not modify Monja-owned or separate Tauri worktrees; do not push or integrate
without separate authorization.

No external Codex-reference repository was supplied; the accepted design
records ../../codex-agent absent. There is no external parity claim. Cursor
invocation/auth/heartbeat/probes remain behind
`Sources/RielaAdapters/AgentGatewayNodeAdapter.swift` or adapter helpers;
backend choice does not translate prompts or promise behavioral equivalence.

## Decomposition and dependency waves

| Wave | planId | planPath | dependsOn | Tasks |
| --- | --- | --- | --- | --- |
| 1 | p1-sandbox | impl-plans/active/work-runtime-p1-sandbox.md | [] | P1-0 |
| 1 | p1-reservation | impl-plans/active/work-runtime-p1-reservation.md | [] | P1-1 |
| 2 | p1-lifecycle | impl-plans/active/work-runtime-p1-guard-director.md | p1-reservation | P1-2, P1-3 |
| 2 | p1-capabilities | impl-plans/active/work-runtime-p1-capabilities.md | p1-reservation | P1-4, P1-5 |
| 3 | p1-dispatch | impl-plans/active/work-runtime-p1-dispatcher-guard-director.md | p1-reservation, p1-lifecycle, p1-capabilities | P1-6, P1-7 |
| 4 | p1-finalize | impl-plans/active/work-runtime-p1-finalization.md | all five predecessors | P1-8 |

One Step 4 author owns all six plans. Step 5 must independently accept them.
The accepted design and ALL six plans must be committed, with exact paths and
commit hash recorded, before the installed workflow starts native fanout.
Commit preparation is a serial workflow gate after Step 5, not a Step 4 commit
or permission to stage unrelated stopped-workflow code. No worktrees, private
implementation branches or concurrent Git mutations. The runtime schedules
only accepted dependency IDs; failed branches remain pending. A canonical
sandbox branch failure does not authorize project-scope execution.

## Shared directory and edit integrity contract

The lists in each JSON block are ownership scopes. Globs cover only the named
P1 responsibility, not unrelated files matched by a broad suffix. Materialize
exact paths before editing. New helper/test files must stay within the listed
responsibility patterns. Shared paths have one writer per wave; any additional
intersection or missing shared contract is queued for serial integration,
recorded in the owner's log, and assigned before dependent editing resumes.
Do not opportunistically change Package.swift from a parallel branch: the
reservation owner audits retained module/test dependencies; later changes are
serial integration/finalization work. Lockfile generation, shared indexes,
global plan archiving, digest refresh and broad formatting are serial-only.
Avoid broad formatting entirely unless required for touched code.

For EVERY edit, including deletion and each retry:

1. Fresh-read the current file and relevant predecessor contract. Record a
   pre-edit SHA-256 (or explicit absent sentinel) and immutable intent snapshot
   under `tmp/work-runtime-p1/<planId>/intents/<sequence>/`. The snapshot records
   accepted requirement, exact paths, expected semantic delta, original bytes
   or content reference, and expected preserved behaviors. Never replace an
   earlier snapshot; store corrections in a new sequence.
2. Recheck the hash immediately before writing. On drift, stop that write,
   reread/rebase the intended patch and capture a new intent; do not overwrite
   from stale buffers. After writing, record post-edit SHA-256, exact diff and
   tests. Hashing cannot prevent a race after the check; native runtime-owned
   change evidence and the post-join semantic review remain mandatory.
3. Each worker updates ONLY its `progressLog`: task status, intent paths,
   changed-file paths/pre/post hashes, predecessor versions, behavior,
   verification command/start/end/final exit/complete log path/test count,
   findings and residual risks. Workers do not edit shared checkboxes, indexes
   or another worker's log. Create the named progress log when work starts.
4. At every join, aggregate native changeTracking evidence plus intent/hash
   records. Compare current hashes and behavior with EVERY accepted branch,
   detecting missing, overwritten and unexplained changes even if compilation
   passes. A later intentional shared-path edit must explicitly preserve the
   predecessor contract and rerun its relevant tests.
5. One serial repair owner restores accepted intent with fresh reads; an
   independent combined-tree reviewer then verifies the repaired tree and its
   evidence. Repeat focused gates for affected code and the final aggregate
   gate. No implementation branch declares the combined tree accepted alone.

Inventory and classify existing dirty/untracked changes before implementation.
`tmp/work-runtime-p1/step4/before-hashes.json` records this planning turn's
baseline; implementation must take a fresh one. Retain correct in-scope work,
repair incorrect work with evidence, and preserve unrelated changes. Never
reset/clean the tree or stage all files. Plans remain unchecked until serial
finalization can cite current behavioral evidence and accepted review.

All scratch scripts, Swift build caches, logs and fixtures live under
`tmp/work-runtime-p1/`. Parallel builds use the plan-specific scratch paths in
commands; any command writing a shared build/cache is serialized. Run shell
commands in the foreground, retain yielded handles and poll through terminal
exit. An incomplete log, timeout, missing suite or unpolled process cannot pass.
Retain referenced evidence through review/handoff; remove only unreferenced
scratch once the task is done.

## Intended changes and acceptance (§17.2–17.5)

- [ ] **P1-6a** Compose TaskDispatcher with canonical stored plan/definition and
  runtime store resolution. Resolve selected entry, dependencies and placement
  before reservation. Missing plan/entry/dependency or invalid policy errors;
  unmet dependencies/capacity records its wait without attempt/session/lease.
  Atomically reserve and authorize, then run EXACT reserved session ID through
  the existing runner. Project terminal evidence before guard/completion and
  apply decisions through the shared applier. Refresh real dispatch placement
  once before reservation and use the chosen per-node backend/host in execution.
- [ ] **P1-6b** Ship task run <task-id> [--dry-run] with attempt/session IDs or
  wait reason. Dry-run follows identical resolution but opens state read-only:
  no create, migration, generation reset, checkpoint, host-cache, task, attempt,
  session, decision, lease or evidence writes. Missing/incompatible stores are
  diagnostics; fresh probes remain in memory. Prove byte AND row equivalence
  including work_hosts, SQLite sidecars and host profile configuration; an
  absent store stays absent and corrupt profile config is not quarantined.
- [ ] **P1-6c** task decide requires exactly one --accept, --reject <reason>,
  --rerun [step], --cancel plus --principal, --expected-version, --decision-id.
  Human principal is audit identity under existing local access, not new remote
  authentication. Validate action combinations and stable replay; call the
  applier, never direct row mutation. Ctrl-C uses this same durable cancellation
  path; terminal acknowledgment precedes fence release. Cover interruption
  during authorization, running, acknowledgment and pending rerun consumption.
  Existing authenticated remote manager paths keep their protections.
- [ ] **P1-6d** Wire one bounded optional agent-director child through ordinary
  workflow execution. Reconcile work attempt before entry: .director reservation;
  retain judged work TaskView, record child session/cost/attempt exactly once.
  Validate allowed P1 decision kinds and apply through the same causal/version/
  completion/budget checks. Invalid/forbidden/failed/budget-blocked output records
  evidence and needs human decision. No recursive director repair, replan,
  proposals or specialist classifier. Finish planner-variable host snapshot
  wiring through dispatcher workflow input variables using capability contracts.
- [ ] **P1-7a** FIRST establish replacement dispatcher behavioral tests for
  auto-improve inactivity, bounded retry, gate/failure recovery, cancellation
  and replay. Record passing exit/log before deleting the old implementation.
  THEN remove WorkflowRunCommand+AutoImprove.swift, WorkflowAutoImprovePolicy,
  WorkflowMutationMode, SupervisedScenarioNodeAdapter, supervision state/result,
  remote input.autoImprove/input.nestedSuperviser and removed flags. Discover
  exact references with rg; changes outside scoped files are serialized and
  assigned to this integration owner before edit. Preserve specialist/event
  supervisor dispatch, existing loop/routine behavior and plain workflow runs.
- [ ] **P1-7b** Replace examples/auto-improve, examples/default-superviser and
  examples/supervised-mock-retry with examples/task-repair-loop and
  examples/task-agent-director, each with mock-scenario.json and
  EXPECTED_RESULTS.md. TaskRuntimeExampleTests must drive real task lifecycle
  using deterministic fixtures: acceptance, gate recovery, guard stop, capacity
  wait; allowed director output, child accounting and invalid-output escalation.
  Workflow-only mock runs supplement these tests; they do not prove dispatch.

Deliverables: dispatcher/CLI composition, bounded director child, both example
bundles, removal of obsolete implementation and equivalent regressions. Keep
CLI addition and auto-improve removal in the same delivery cut; no publication
between them. Test real reserved-session execution, dependency/version races,
guard persistence failure, cancellation acknowledgment loss, replay crashes,
last-attempt completion, dry-run effects, and task-free plain workflow run.

## Common lint and validation contract

swift build is the Swift compile/typecheck gate. Swift edits follow the local
Swift skill: keep touched code responsibility-based, avoid speculative
abstraction, and split touched non-generated files over 1000 lines by actual
responsibility without unrelated cleanup. Include necessary extracted paths in
serial ownership records. Do not weaken tests or lint to accept retained WIP.

Before edits, each worker captures repository lint baseline. After edits,
materialize exact existing changed/new Swift paths from its intent records in
`tmp/work-runtime-p1/<planId>/changed-swift-files.nul`; do not rely on git diff
alone because it omits untracked files and predecessor commits. Replace the
literal PLAN_ID below with its stable planId and record the expanded command.

```bash
xargs -0 env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint lint --strict --quiet --no-cache < tmp/work-runtime-p1/PLAN_ID/changed-swift-files.nul
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/arch -arm64 /usr/bin/xcrun swiftlint --quiet --no-cache
```

Skip xargs only for an explicitly empty Swift write set; strict touched-file
lint gates acceptance. Repository-wide output is a recorded baseline check:
fail new diagnostics attributable to this work, report existing unrelated ones,
and do not broaden edits to clear them. If a tool is unavailable, record a
blocked gate and environment error, not success. Run required focused tests,
then the full finalization gate once on the joined tree; repeat only after
new changes/failures. No web code is planned, so browser E2E is not a P1 gate.

## Overall completion and progress

P1-0 through P1-8 must all satisfy their named plan criteria, complete logs and
positive behavioral test counts; P0 remains green and P2-P7 deferred. Atomic
reservation, guard causality, durable cancellation, replay, placement, doctor,
host-aware validation/usage, dry-run and both task examples must be proved.
Docs/help/surface catalog, applicable digests and serial indexes must agree
with the delivered behavior. The installed workflow's test-integrity,
adversarial and combined-tree reviews must have no unresolved high/mid
finding. Step 4/5 planning acceptance is not implementation completion.
Finalization alone updates shared checkboxes/indexes and archives all six plans
when downstream review gates permit; otherwise leave them active and pending.

Planning progress, 2026-09-21: decomposed the accepted comm-000004 design into
six plans. No implementation task was marked complete. Author verification is
recorded at tmp/work-runtime-p1/step4/author-self-check.json and
verification-evidence.json. Worker logs are created only when implementation
begins and remain owned by their respective planIds.

## Verification and completion

Run these commands in the foreground and record final exit status and complete
log paths in the plan-owned progress log. Named new suites below are required
deliverables, not claims that they already exist. Zero selected tests is a
failed gate; record the discovered test names and positive executed counts.

```bash
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build --scratch-path tmp/work-runtime-p1/build/p1-dispatch
/usr/bin/arch -arm64 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --scratch-path tmp/work-runtime-p1/build/p1-dispatch --filter 'TaskCommandMutationTests|TaskDispatcherTests|TaskDispatcherIntegrationTests|TaskRuntimeExampleTests'
git diff --check
```

Also run the changed-file strict SwiftLint gate defined in the root plan for
this plan's actual Swift write set, including new untracked files. Retain P0
assertions affected by these changes. Each unchecked task below requires its
specified acceptance assertions, passing build/typecheck, focused tests and
lint, complete evidence, and independent review with no unresolved high/mid
finding. Passing this plan alone does not close P1. Report blocked commands
explicitly; never substitute source-text assertions for behavioral tests.
