# DS179-07 Builtin Improvement Node Add-ons and Example

**planId**: `ds179-07-improvement-node`
**Status**: Ready for implementation
**Workflow Mode**: issue-resolution
**Issue Reference**: tacogips/riela#179 section 3, (B) builtin self-improvement node, definitions and prompts only
**Design Reference**: `design-docs/specs/design-workflow-definition-store.md` §1 (one-time runs do not improve), §9 (the whole section), §12 (`WorkflowImprovementNodeTests`); QA Q5 and Q6
**dependsOn**: `ds179-05-graphql-definition-surface` (serial chain 01→02→03→04→05→07→06)
**Branch**: `feat/definition-store-179` (local commits only; `gitPush=false`)
**Progress log**: `impl-plans/progress/ds179-07-improvement-node.md`

## Intent and context

The user wants a builtin improvement node. It reads three inputs:

1. its own workflow's structure from the SQLite store
2. a bounded digest of the latest run's per-node input, output, failure
   and retry data
3. an improvement guideline from its config

It then applies a change with a mandatory reason, only by running the
riela CLI update command from (A) as a subprocess. The actor is the
improvement node, and the evidence is the referenced session and step
execution ids. It never improves its own runs, and one-time runs never
improve. A mock-scenario example must demonstrate it.

The accepted design shape (design §9, QA Q5) is three nodes:

- `riela/improve-workflow-context`: a builtin add-on, deterministic, new
- a proposer: an ordinary agent node written by the workflow author, and
  the only LLM step
- `riela/improve-workflow-apply`: a builtin add-on, deterministic, new

Under mock-scenario only the proposer (and the example's target node) are
mocked. The two builtins run for real, because `ScenarioWorkflowAddonResolver`
falls back to the real resolver when a node id has no scenario response
(`Sources/RielaCLI/ProductionNodeAdapter.swift:261-266`).

Repository facts (verified):

- **Builtin descriptors.** They live in `Sources/RielaAddons/RielaAddons.swift`,
  for example `keyValueStoreAddons` (`:151`) and `routineAddons` (`:173`).
  They are concatenated into `all` (`:240-258`). The
  `RielaBuiltinAddonCatalogTests` requirements are unique names and
  version-1 descriptors.
- **Handler registration.** `BuiltinStatefulAddonRegistry.registrations`
  (`Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift:27`) uses
  `BuiltinAddonHandlerRegistration.family(<Enum>.self) { resolver, input, op, context in ... }`.
  The handler is `async throws`. Imitate `BuiltinRoutineAddon` in
  `Sources/RielaCLI/ProductionNodeAdapter+RoutineAddon.swift` and
  `BuiltinKeyValueAddon` in `Sources/RielaCLI/ProductionNodeAdapter+KeyValueStoreAddon.swift`.
  Copy their version check, `addonVariables(for:)`, and the
  `AdapterExecutionOutput(provider: "riela-builtin-addon", ...)` shape.
- **Resolver.** `BuiltinWorkflowAddonResolver` is at
  `Sources/RielaCLI/ProductionNodeAdapter.swift:351`. Its init is at
  `:380-400`, and it already holds
  `containerProcessRunner: any LocalProcessRunning` (`:378`). The resolver
  is built by `makeProductionAddonResolver` (`:97-134`) and
  `makeScenarioBackedAddonResolver` (`:76-95`). `WorkflowRunCommand` calls
  `makeScenarioBackedAddonResolver` at `Sources/RielaCLI/WorkflowRunCommand.swift:86`,
  and the store root is computed right after it, at `:91`
  (`storeRootForRun`). Resume and rerun build it at
  `Sources/RielaCLI/SessionCommands.swift:447` and `:723`.
- **Upstream outputs.** Add-ons receive every completed execution's
  accepted output in `input.resolvedInputPayload["upstream"]`. Each entry
  has `stepId`, `nodeId`, `executionId` and `output.payload`. They also
  receive `runtime.sessionId` (`Sources/RielaCore/WorkflowAddonResolvedInputPayload.swift:1-31`).
  This data is runtime-owned. Use it to read the context and proposer
  outputs; do not re-bind them through templates.
- **Execution identity.** `input.executionIdentity` carries
  `workflowExecutionId`, `stepExecutionId` and `operationExecutionId`
  (`Sources/RielaCore/WorkflowAddonExecution.swift:247-269`). The doc
  comment says `operationExecutionId` stays stable across resumable
  attempts. It is derived at
  `Sources/RielaCore/DeterministicWorkflowRunner+Addons.swift:44-50`.
- **Session reads.** `CLIWorkflowSessionStore(rootDirectory:).list(workflowName:status:limit:)`
  (`Sources/RielaCLI/CLIWorkflowSessionStore.swift:333`) returns records
  newest first (`updated_at DESC`), with a limit of at most 100. Each
  `PersistedCLIWorkflowSession` has `.session: WorkflowSession`.
  `WorkflowSessionStatus.isTerminal` is at `Sources/RielaCore/RuntimeSession.swift:22`.
  `WorkflowStepExecution` fields are at `RuntimeSession.swift:262-287`.
- **Process API.** `LocalProcessRunning.run(configuration:stdin:deadline:)`
  (`Sources/RielaAdapters/LocalProcess.swift:77`) returns
  `LocalProcessResult{stdout, stderr, terminationStatus}`.
- **Executable lookup order to imitate:**
  `DaemonWorkflowEventServeProcess.resolveExecutablePath`
  (`Sources/RielaAppSupport/DaemonWorkflowEventServeProcess.swift:215-230`).
  Order: configured path, then a `riela` sibling of `Bundle.main.executableURL`,
  then `/usr/bin/env riela`.
- **Earlier plans.** Plan 02 provides `WorkflowDefinitionService.authoredView(workflowName:versionId:)`
  and `WorkflowDefinitionJSONPatch`. Plan 03 sets `bundle.definitionSource`
  (with `storeRoot` for store pins) and `WorkflowRunOptions.executionMode`.
  Plan 04 provides `riela workflow definition update --patch <file>
  --reason ... --expected-version ... --evidence ... --actor ... --actor-kind
  improvementNode --session-store ... --output json`, the pinned JSON
  success shape `{accepted, outcome, versionId, digest, auditId, diff}` and
  the error shape `{accepted:false, error:{code,message}}`.
- **Examples.** Each example is `examples/<name>/` with `workflow.json`,
  `nodes/`, `prompts/`, `mock-scenario.json` (keyed by node id; see
  `examples/routine-task-runner/mock-scenario.json`) and
  `EXPECTED_RESULTS.md`.
  - Labelled transitions use `"label": "<whenKey>"` or `"!(<whenKey>)"`
    (`examples/design-and-implement-review-loop-feature-plan/workflow.json:62-82`).
  - Output-node pattern: `examples/apple-calendar-fetch/workflow.json:37-41`
    with `nodes/node-workflow-output.json`.
  - The catalog is `rielaExampleWorkflowNames()` in
    `Tests/RielaCLITests/RielaExampleCatalog.swift`.
  - `ExampleCatalog.expectedMockScenarioCount = 47` is at
    `Tests/RielaCLITests/RielaExampleParityTests.swift:14`.

## Non-goals

- No memory, cache or kv candidates, no section 4 approval or evaluation,
  and no `workflow self-improve` cleanup (issue sections 4 and 5).
- No new GraphQL fields or `SurfaceCatalog` rows; the add-ons are not
  control-plane operations. No SDL regeneration.
- Do not add the run-scoped context to `WorkflowAddonExecutionInput` (a
  Codable contract that container add-ons see).
- The add-ons must not write `definition_*` rows directly. The only write
  path is the CLI subprocess.
- No `guidelineFile`. Service runs never read workflow files (design §3).
- Do not call an LLM from either builtin.

## Pinned contract

**`Sources/RielaAddons/RielaAddons.swift`.** Add
`public static let workflowImprovementAddons: [RielaAddonDescriptor]`
with `riela/improve-workflow-context` and `riela/improve-workflow-apply`,
both version `"1"`, and append it to `all`.

**`Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift` (new):**

- `enum BuiltinWorkflowImprovementAddon: String, CaseIterable, Sendable { case context = "riela/improve-workflow-context"; case apply = "riela/improve-workflow-apply" }`
- `struct BuiltinDefinitionRunContext: Sendable { var definitionSource: WorkflowDefinitionSource?; var sessionStoreRoot: String; var cliProcessRunner: (any LocalProcessRunning)? }`.
  `cliProcessRunner` nil means `resolver.containerProcessRunner`.
- `extension BuiltinWorkflowAddonResolver { func executeWorkflowImprovementAddon(_ input:, operation:, context:) async throws -> AdapterExecutionOutput }`

**`Sources/RielaCLI/WorkflowImprovementDigest.swift` (new).** Pure
functions with no IO:

- `enum WorkflowImprovementDigest { static func build(session: WorkflowSession, excludedNodeIds: Set<String>, maxStepExecutions: Int, maxFieldChars: Int) -> (digest: JSONValue, evidence: [WorkflowDefinitionEvidenceRef]) }`
- `static func excludedNodeIds(runtimeWorkflow: WorkflowDefinition, extra: [String]) -> Set<String>`.
  It returns the ids of every `nodeRegistry` entry whose `addon?.name` is
  one of the two improve names, plus `extra`.
- `static func touchedExcludedNodes(before: JSONValue, after: JSONValue, excludedNodeIds: Set<String>) -> [String]`.
  It compares authored views by node id (design §9 `targetsImprovementNode`)
  and returns the offending node ids.

**`BuiltinWorkflowAddonResolver`** gains
`var definitionRunContext: BuiltinDefinitionRunContext?` (init default
nil). `makeProductionAddonResolver` and `makeScenarioBackedAddonResolver`
gain a trailing `definitionRunContext: BuiltinDefinitionRunContext? = nil`
that is forwarded.

**`WorkflowRunCommand`** gains an internal test seam,
`var improvementCLIProcessRunnerOverride: (any LocalProcessRunning)?`
(default nil), copied into `BuiltinDefinitionRunContext.cliProcessRunner`.
Imitate the existing `taskNodeAdapterOverride` field.

**Context output payload** (design §9):

```
status: "ok" | "skipped"; reason?: "oneTimeRun" | "noPreviousRun"
workflowName, baseVersionId, baseDigest, definition (authored view),
excludedNodeIds: [String], runDigest: {sessionId, workflowStatus, stepExecutions: [...], omittedCount} | null,
evidence: [{kind, id}], guideline: String
when: { improvable: Bool }
```

**Apply output payload:**

```
status: "applied" | "unchanged" | "rejected" | "skipped" | "noChange"
reason?: "oneTimeRun" | "reasonRequired" | "invalidPatch" | "targetsImprovementNode" | "noEvidence" | "definition_conflict" | "invalid_patch" | "invalid_definition" | "definition_not_registered"
versionId?, auditId?, digest?, cliExitCode?: Int
when: { applied: Bool }
```

## File-level changes

1. **`RielaAddons.swift`.** Add the descriptors (above).
2. **`BuiltinStatefulAddonRegistry.swift`.** Append
   `+ BuiltinAddonHandlerRegistration.family(BuiltinWorkflowImprovementAddon.self) { resolver, input, operation, context in try await resolver.executeWorkflowImprovementAddon(input, operation: operation, context: context) }`.
3. **`ProductionNodeAdapter.swift`.** Add the stored property, the init
   parameter and the two factory parameters (above). Make no other edits.
4. **`WorkflowRunCommand.swift`.**
   - Move the `makeScenarioBackedAddonResolver(` call (`:86`) to just after
     `let storeRoot = storeRootForRun(...)` (`:91`). Pass
     `definitionRunContext: .init(definitionSource: <the definitionSource plan 03 computed>, sessionStoreRoot: storeRoot, cliProcessRunner: improvementCLIProcessRunnerOverride)`.
   - Check that nothing between the old and new positions uses
     `addonResolver`. Record the check in the progress log.
5. **`SessionCommands.swift`.** At `:447` and `:723`, pass
   `definitionRunContext` built from the persisted session's
   `session.definitionSource` and that command's resolved store root.
   Without this, a resumed apply would see a nil context and skip.
6. **`ProductionNodeAdapter+WorkflowImprovementAddon.swift`.** Behaviour:
   - **Version.** It must be nil or `"1"`, else `AdapterExecutionError(.policyBlocked, ...)`,
     as in the kv add-on.
   - **Policy gate (both operations).** If `definitionRunContext?.definitionSource?.kind != .store`,
     or `versionId` or `storeRoot` is nil, return `skipped / oneTimeRun`
     with `when.improvable = false` (context) or `when.applied = false`
     (apply). Open no store, read no session, spawn nothing.
   - **Context:**
     1. Parse config: `guideline` (string, default `""`), `excludeNodeIds`
        (string array), `maxStepExecutions` (default 20, clamp 1-100),
        `maxFieldChars` (default 2000, clamp 100-20000) and
        `maxContextBytes` (default 262144).
     2. Load the pinned authored view:
        `WorkflowDefinitionService(storeRoot: source.storeRoot!, fileResolver: FileSystemWorkflowBundleResolver()).authoredView(workflowName: source.workflowName, versionId: source.versionId)`.
        Load the pinned runtime with `loadPinned` to compute
        `excludedNodeIds`.
     3. Find the previous run:
        `CLIWorkflowSessionStore(rootDirectory: context.sessionStoreRoot).list(workflowName: source.workflowName, limit: 100)`.
        Take the first record where `session.status.isTerminal`,
        `session.definitionSource?.kind == .store`, and
        `session.sessionId != input.executionIdentity?.workflowExecutionId`.
        If there is none: `runDigest = null`, `evidence = []`,
        `reason = noPreviousRun`, `improvable = false`.
     4. Build `digest` and `evidence` with `WorkflowImprovementDigest.build(...)`.
        The evidence order is `session:<id>` first, then one
        `stepExecution:<id>` per digest entry, in output order.
     5. If the canonical encoding of the payload exceeds `maxContextBytes`,
        throw `AdapterExecutionError(.invalidOutput, "context_too_large")`.
   - **Digest (`WorkflowImprovementDigest.build`):**
     - Drop executions whose `nodeId` is excluded.
     - Each entry has `stepId`, `nodeId`, `stepExecutionId`
       (`executionId`), `attempt`, `status`, `failureKind`,
       `failureReason`, `inputSnapshot` (canonical JSON text),
       `acceptedOutput` (canonical JSON text of `acceptedOutput?.payload`)
       and `usage`.
     - Every text field is cut to `maxFieldChars` characters (not bytes),
       with `truncated: true` set on the entry when any field was cut.
     - **Selection** when there are more than `maxStepExecutions`
       entries:
       1. First take the "priority" entries (status failed, or
          `attempt > 1`), newest first.
       2. Then the rest, newest first, until the limit.
       3. `omittedCount` is the number not taken.
     - The final output is sorted by `createdAt`, then `executionId`.
     - Pure and deterministic: the same session gives byte-identical
       canonical output.
   - **Apply:**
     1. Config: `contextStepId` (required string), `proposerStepId`
        (required string), `excludeNodeIds` (string array) and
        `rielaExecutable` (optional absolute path). A missing required key →
        `AdapterExecutionError(.policyBlocked, ...)`.
     2. From `resolvedInputPayload["upstream"]`, take the latest entry
        whose `stepId` is `contextStepId` and the latest whose `stepId` is
        `proposerStepId`. If either is missing →
        `AdapterExecutionError(.invalidInput, ...)`.
     3. Verify that the context step's node uses
        `riela/improve-workflow-context` in the pinned runtime
        (`loadPinned`), so that a forged upstream cannot pose as the
        context. The context payload must have `status == "ok"`;
        otherwise return `skipped` with that payload's reason.
     4. Validate before spawning anything, in this order:
        - `reason`: the proposer payload `reason` is blank after trimming
          → `rejected / reasonRequired`.
        - `patch` is not a JSON array → `rejected / invalidPatch`.
        - An empty array → `noChange`.
        - The context `evidence` is empty → `rejected / noEvidence`.
        - Apply the patch locally to the context `definition` with
          `WorkflowDefinitionJSONPatch.apply`. A failure →
          `rejected / invalidPatch`.
        - `touchedExcludedNodes(before: definition, after: patched, excludedNodeIds: contextExcluded ∪ config.excludeNodeIds ∪ addon-derived)`
          is non-empty → `rejected / targetsImprovementNode`.
     5. Write the patch to
        `FileManager.default.temporaryDirectory/riela-improve-<uuid>.json`
        and delete it in `defer`. `AdapterExecutionContext` exposes no run
        artifact directory, so the process temp directory is used; never
        write into the repository or the workflow directory.
     6. Arguments, exactly:
        `["workflow","definition","update", workflowName, "--patch", <file>, "--reason", reason, "--expected-version", baseVersionId] + evidence.flatMap { ["--evidence", "\($0.kind.rawValue):\($0.id)"] } + ["--actor", "\(workflowName)/\(input.nodeId)@\(workflowExecutionId)/\(operationExecutionId)", "--actor-kind", "improvementNode", "--session-store", storeRoot, "--output", "json"]`.
        Run it through `context.cliProcessRunner ?? containerProcessRunner`.
        With the `/usr/bin/env` fallback, prepend `"riela"` to the
        arguments.
     7. Map the result. Parse stdout as JSON:
        - `accepted == true` → `applied` (outcome `updated`) or `unchanged`,
          with `versionId`, `auditId` and `digest`.
        - `accepted == false` with an `error.code` → `rejected / <code>`.
        - **Exception:** on `definition_conflict`, run `["workflow","definition","history", workflowName, "--limit","1","--session-store", storeRoot, "--output","json"]`.
          If the newest audit's `actor.id` equals this step's actor id,
          return `applied` with that record's `versionId` and `auditId`.
        - Unparseable stdout, or a spawn error →
          `AdapterExecutionError(.providerError, ...)` (the node fails).
     8. Put the result classification in a small pure helper,
        `WorkflowImprovementApplyOutcome.classify(updateStdout:historyStdout:expectedActorId:)`,
        so that it can be unit-tested.
7. **Example `examples/definition-store-self-improvement/` (new):**
   - **`workflow.json`.** `workflowId` is
     `definition-store-self-improvement`, with nodes and steps:
     1. `summarize`: an agent node. `nodes/node-summarize.json` uses
        `promptTemplateFile: prompts/summarize.md`.
     2. `improve-context`: inline addon `riela/improve-workflow-context`
        with config `{guideline: "<short guideline text>", excludeNodeIds: ["improve-propose"], maxStepExecutions: 20}`.
     3. `improve-propose`: an agent node. `nodes/node-improve-propose.json`
        uses `prompts/improve-propose.md`, which renders the context output
        through `{{inbox.latest.output.payload...}}` fields and asks for
        `{patch, reason}`.
     4. `improve-apply`: inline addon `riela/improve-workflow-apply` with
        config `{contextStepId: "improve-context", proposerStepId: "improve-propose", excludeNodeIds: ["improve-propose"]}`.
     5. `workflow-output`: an output node, like apple-calendar-fetch.

     Transitions:
     - summarize → improve-context
     - improve-context → improve-propose (`label: "improvable"`)
     - improve-context → workflow-output (`label: "!(improvable)"`)
     - improve-propose → improve-apply
     - improve-apply → workflow-output
   - **`mock-scenario.json`.** Responses for `summarize` and
     `improve-propose` only. The proposer payload is
     `{"patch":[{"op":"replace","path":"/prompts~1summarize.md","value":"<improved prompt text>\n"}],"reason":"summaries omitted the action items; require an action-item list"}`.
     The add-on nodes must not appear in the scenario.
   - **`EXPECTED_RESULTS.md`.** Under `riela workflow run --mock-scenario`
     (one-time) the session completes, `improve-context` returns
     `skipped/oneTimeRun`, and the route goes to workflow-output. It also
     describes the service-mode flow that the tests check.
   - **`README.md`** (short) only if sibling examples have one; follow
     `examples/routine-task-runner`.
8. **`examples/README.md`.** Add one line for the new example in the
   existing list style.
9. **`Tests/RielaCLITests/RielaExampleCatalog.swift`.** Insert
   `"definition-store-self-improvement"` in sorted position.
10. **`Tests/RielaCLITests/RielaExampleParityTests.swift`.** Set
    `expectedMockScenarioCount` from 47 to 48. Leave
    `expectedNodeMockScenarioCount` unchanged unless
    `workflowUsesNodeRuntime` counts the new example; check it.
11. **`Tests/RielaCLITests/WorkflowImprovementNodeTests.swift` (new).** See
    Tests.

## Invariants

- One-time runs (`executionMode == .oneTime`) never open definition tables
  or spawn the CLI from these add-ons. A one-time run of the example leaves
  zero `definition_*` rows.
- The add-ons write `definition_*` rows only through the CLI subprocess.
  No `WorkflowDefinitionStore.commit` or service write call exists in the
  new files; grep proves it.
- Improve-node executions are never in the digest, and the current session
  is never evidence.
- A run keeps its pin while an apply moves the head.
- Existing builtin add-ons and their dispatch are unchanged.

## Pitfalls

- **Template binding.** Do not take the context output from the LLM's
  proposer payload, and do not bind arrays through `{{...}}` templates.
  Read `upstream`.
- **Version id.** Do not use the head's `currentVersionId` as
  `baseVersionId`. Use the run's pin. The `--expected-version` check
  depends on it.
- **Previous-run filter.** `list` defaults to `limit: 10`. Pass 100. The
  current session may already be persisted as `running`; the `sessionId`
  filter handles it.
- **Executable resolution.** `Bundle.main.executableURL` under XCTest is
  the xctest runner. Tests must inject `improvementCLIProcessRunnerOverride`
  and never depend on a built binary.
- **In-process test runner.** It must call
  `RielaCLIApplication().run(configuration.arguments)` and return
  `LocalProcessResult(stdout:, stderr:, terminationStatus: exitCode)`. Drop
  a leading `"riela"` argument if present.
- **Character truncation.** Truncate by `Character`, not by UTF-16 offset,
  so multibyte text is never split.
- **Moving the resolver construction.** Do not reorder any other
  statements in `WorkflowRunCommand`.
- **Patch pointer.** The mock patch pointer `/prompts~1summarize.md` must
  match the authored key exactly. The node file must reference
  `prompts/summarize.md`, not `./prompts/summarize.md`.

## Tests

`Tests/RielaCLITests/WorkflowImprovementNodeTests.swift`. Copy the example
directory into a temp dir and use a temp `--session-store`. Run the
service mode with
`WorkflowRunCommand(improvementCLIProcessRunnerOverride: InProcessRielaCLIRunner())`,
`WorkflowRunOptions(executionMode: .service(.init(kind: .api, id: "test")), mockScenarioPath: <scenario>, sessionStore: <tmp>, ...)`.
Read rows through `WorkflowDefinitionStore`.

- **Run 1, service.**
  - The head is seeded (1 version, operation `seed`).
  - `improve-context` output: `status == "ok"`,
    `reason == "noPreviousRun"`, `when.improvable == false`.
  - `improve-apply` did not run, and there is exactly 1 version.
- **Run 2, service.**
  - Context `runDigest.sessionId` is run 1's id.
  - The digest contains run 1's `summarize` execution id and no execution
    whose `nodeId` starts with `improve-`.
  - Apply `status == "applied"`.
  - The newest audit has operation `update`, `actor == {improvementNode, "definition-store-self-improvement/improve-apply@<run2Id>/<opId>"}`,
    the mocked reason, and evidence equal to the context evidence
    (`session:<run1>` first).
  - The copied example files are byte-identical (sha256) before and after.
  - Run 2's own pin is still the seed version.
- **Run 3, service.**
  - The pin is the run 2 version.
  - `summarize`'s `inputSnapshot["promptText"]` contains the improved
    prompt text.
- **One-time.** `riela workflow run <copy> --mock-scenario ... --session-store <fresh tmp>`
  through `RielaCLIApplication`.
  - Both add-ons report `skipped/oneTimeRun` (apply not reached).
  - The session completes.
  - All four `definition_*` tables have 0 rows.
  - The in-process runner recorded zero invocations.
- **Recursion guard.** A scenario variant whose proposer patch replaces
  `/prompts~1improve-propose.md` → apply `rejected/targetsImprovementNode`,
  and the version count is unchanged. A variant whose patch removes the
  `improvable` transition into `improve-propose` → same result.
- **Validation.**
  - A proposer reason of `"  "` → `rejected/reasonRequired`, no subprocess.
  - A patch that is not an array → `rejected/invalidPatch`.
  - An empty patch → `noChange`.
- **Conflict.** The head must move *after* run 2 pins its version and
  *before* the apply subprocess's `update` runs.
  - Do not call `updatePrompt` between run 1 and run 2. Run 2 would pin the
    manual version, its `--expected-version` would match the head, and the
    correct outcome would be `applied`.
  - Instead, wrap the injected `InProcessRielaCLIRunner` in a test runner,
    `HeadMovingCLIRunner`. On the first invocation whose arguments start
    with `["workflow","definition","update"]`, it calls
    `WorkflowDefinitionService(storeRoot: <tmp store>, fileResolver: FileSystemWorkflowBundleResolver()).updatePrompt(workflowName: "definition-store-self-improvement", nodeId: "summarize", field: .node(.promptTemplate), text: "MANUAL\n", reason: "manual", expectedVersionId: nil, evidence: [], actor: .init(kind: .cli, id: "manual"))`,
    then delegates the same arguments to the inner runner. All other
    invocations (including the follow-up `history`) are delegated
    unchanged.
  - Run run 1 (seed), then run 2 with `HeadMovingCLIRunner` as
    `improvementCLIProcessRunnerOverride`. Expected:
    - apply returns `status == "rejected"` with
      `reason == "definition_conflict"`
    - the follow-up `history --limit 1` shows the newest audit's actor is
      `{cli, "manual"}`, not the improve actor, so `classify` does not turn
      it into `applied`
    - the version count is exactly 2: the seed plus the manual
      `updatePrompt`, with no `update` version
    - run 2's own `definitionSource.versionId` is still the seed version
  - Do not weaken `--expected-version` (it stays equal to the run's pin)
    or relax this assertion.
  - Alternative (not recommended, because it needs a new seam): move the
    head from a hook on the `improve-propose` mock step.
- **Classification (pure).**
  - `classify` with conflict stdout plus history stdout whose newest
    `actor.id` equals the expected id → `applied` with that version.
  - The same with a different actor id → `rejected/definition_conflict`.

  This covers resume idempotency without relying on runtime resume
  timing, and addresses the Step 3 low finding on `operationExecutionId`
  stability.
- **Digest (pure).** On a synthetic session:
  - 30 executions with `maxStepExecutions` 5 → failed and retried entries
    kept first, `omittedCount == 25`, output sorted by `createdAt`.
  - A 5000-character `failureReason` with `maxFieldChars` 100 → cut to 100
    characters with `truncated == true`.
  - The same input twice → identical canonical output.
- **`touchedExcludedNodes` (pure).**
  - An edit to an excluded node's `nodes[]` entry is detected.
  - An edit to its `steps[]` entry is detected.
  - An edit to an inbound transition is detected.
  - An edit to its prompt file is detected.
  - An index shift caused by removing an unrelated earlier node is not a
    false positive.
- **Example parity.** `RielaExampleParityTests` pass with the new example.

## Verification (each command must exit 0)

Run `mkdir -p tmp/ds179` first.

- `arch -arm64 /bin/zsh -lc 'swift build 2>&1 | tee tmp/ds179/07-build.log'`
- `arch -arm64 /bin/zsh -lc 'swift test --filter WorkflowImprovementNodeTests 2>&1 | tee tmp/ds179/07-test.log'`.
  Record testsRun and failureCount from the `Executed N tests, with M
  failures` line.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "RielaExampleParityTests|RielaBuiltinAddonCatalogTests|KeyValueStoreAddonTests" 2>&1 | tee tmp/ds179/07-regression.log'`.
  Record testsRun and failureCount. A pre-existing failure unrelated to
  the new example is a residual risk with the exact test name.
- `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowDefinitionServiceResolutionTests|WorkflowDefinitionCommandTests" 2>&1 | tee tmp/ds179/07-chain-regression.log'`.
  This shows the moved resolver construction did not break earlier plans.
- `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaAddons/RielaAddons.swift Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift Sources/RielaCLI/WorkflowImprovementDigest.swift Sources/RielaCLI/BuiltinStatefulAddonRegistry.swift Sources/RielaCLI/ProductionNodeAdapter.swift Sources/RielaCLI/WorkflowRunCommand.swift Sources/RielaCLI/SessionCommands.swift Tests/RielaCLITests/WorkflowImprovementNodeTests.swift Tests/RielaCLITests/RielaExampleCatalog.swift Tests/RielaCLITests/RielaExampleParityTests.swift'`
  must print no violations.

## Done criteria

- `grep -n "riela/improve-workflow-context\|riela/improve-workflow-apply" Sources/RielaAddons/RielaAddons.swift`
  shows both names.
- `grep -n "definition-store-self-improvement" Tests/RielaCLITests/RielaExampleCatalog.swift`
  matches, and `grep -n "expectedMockScenarioCount = 48" Tests/RielaCLITests/RielaExampleParityTests.swift`
  matches.
- `grep -nE "\.commit\(|\.update\(workflowName|\.updatePrompt\(" Sources/RielaCLI/ProductionNodeAdapter+WorkflowImprovementAddon.swift`
  returns nothing, so there are no direct store writes.
- `examples/definition-store-self-improvement/mock-scenario.json` has no
  key that starts with `improve-context` or `improve-apply`.
- All verification commands exit 0. The progress log records each
  command's exitStatus, testsRun, failureCount and log path.

## Progress log expectations

Create and update `impl-plans/progress/ds179-07-improvement-node.md`
after each file-level change, with the file, the pre-edit and post-edit
`shasum -a 256`, and the reason. `WorkflowRunCommand.swift`,
`SessionCommands.swift` and `ProductionNodeAdapter.swift` were edited by
earlier plans. Re-read each fresh before editing; if a file differs from
what the earlier plan's log recorded, note the drift and merge instead of
overwriting. Record the "nothing uses `addonResolver` between the old and
new position" check from file change 4.


## Operator amendment 1 (after session-494 blocked wave)

- ds179-01-store-core is accepted and committed in 6337aa24. The definition store API now returns
  `WorkflowDefinitionCurrent` (struct with head/version/document) from `current(workflowName:)`, and
  `WorkflowDefinitionDiffEntry.Op` was renamed to `WorkflowDefinitionDiffEntry.Operation`.
- Known pre-existing failures on main f4fcf68c (not caused by this work; exclude them from gates with
  `--skip` and never treat them as blockers): `DeterministicWorkflowRunnerFailureStateTests.testRetryFailedStepErrorNamesTimeoutForCompletedSession`,
  `HandoverContractsTests.testSessionSuspendAndClosedStatusRoundTrip`, `SessionObservabilityTests.testTransitionalCancelledFailureKindIsTerminal`.
  `DeterministicWorkflowRunnerFanoutTests.testProductionCollectPartialPersistsCancelledChildBeforePublishingJoin` is timing-flaky under
  full-suite load and passes in isolation.
