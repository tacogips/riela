# Prompt Overflow Guard 03: Pre-Invocation Prompt-Size Guard and Spill

**planId**: `pog-03-prompt-guard`
**Wave**: 2
**dependsOn**: `pog-01-contracts`
**Workflow Mode**: issue-resolution
**Issue Reference**: none. Incident: opus-luna 0.1.8 session-471. Current
run: `opus-luna-design-and-implement-review-loop-session-475`.
**Design Reference**: `design-docs/specs/design-agent-prompt-overflow-guard.md`
Part C, plus Part D "Guard rejection".
**Branch**: `feat/agent-prompt-overflow-guard`. Do not run any git write
command.
**Progress log**: `impl-plans/progress/pog-03-prompt-guard.md`
**Evidence dir**: `tmp/prompt-overflow/pog-03-prompt-guard/`
**planPath**: `impl-plans/active/prompt-overflow-guard-03-prompt-guard.md`

**writePaths**:

- `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift`
- `Tests/RielaCoreTests/AgentPromptGuardTests.swift`
- `impl-plans/progress/pog-03-prompt-guard.md`
- `tmp/prompt-overflow/pog-03-prompt-guard`

**sharedPaths**: none.

**artifactRoots**: `tmp/prompt-overflow/pog-03-prompt-guard`.

## Intent and Context

Measure the exact text riela sends to an agent: `systemPromptText` plus the
fresh or resumed `promptText`.

- Within budget: change nothing.
- Over budget: deterministically move large runtime-variable values into
  content-addressed files and replace them with stubs, then recompose.
- Still over budget: fail the step with `failureKind: promptTooLarge` before
  calling the backend.

Available from `pog-01`:

- `deduplicatedRuntimeVariablesView(_:)`;
- the markers `$rielaElidedKeys` and `$rielaSameAs`;
- `AdapterExecutionError(..., failureKind:)`;
- `WorkflowSessionFailureKind.promptTooLarge`;
- `AgentNodePayload.promptMaxBytes` and `WorkflowDefaults.agentPromptMaxBytes`;
- `adapterFailureKind(_:)`, already applied in `RuntimePublication`. A
  published guard rejection therefore records `promptTooLarge` on both the
  step and the session.

How the code works today:

- `executePayloadNodeAndRecordMemory`
  (`Sources/RielaCore/DeterministicWorkflowRunner.swift:563-664`) does the
  following in order:
  1. builds `mergedVariables = promptVariables(...)` (line 613);
  2. calls `prompts = try composedPromptsWithFinalizationEvidence(...)` (line
     620);
  3. validates the payload and resolves `agentEnvironment`;
  4. builds `AdapterExecutionInput` (line 641);
  5. calls `executeAndPublish`.
- `executeAndPublish`
  (`Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift:4`)
  loops over validation attempts. Each attempt calls
  `recordStepStartedExecution(... inputSnapshot: historyInvocationSnapshot(...))`
  and then `executePlacedAdapter`. An `AdapterExecutionError` goes through
  `publishAdapterFailure(...)` (lines 68-76).
- `promptVariables(workflow:step:payload:requestVariables:resolvedInputPayload:)`
  and `composedPromptsWithFinalizationEvidence(workflow:step:payload:variables:session:)`
  are the recomposition entry points. Reuse them as they are.
- `resolvedBackendWorkingDirectory(backend:configuredWorkingDirectory:workspaceRoot:)`
  is defined in `DeterministicWorkflowRunner+ExecutionEvents.swift:19`.
- `JSONValue.compactJSONString()` sorts keys and is deterministic. Use it for
  every byte count and hash. Use `Crypto`'s `SHA256`, as
  `WorkflowFanoutChangeEvidence.swift` imports `Crypto` and uses `fanoutHex`.
  That helper is private, so reimplement the hex formatting locally.

## Non-Goals

- Do not edit `DeterministicWorkflowRunner+Prompting.swift` (owned by
  `pog-01`) or `RuntimePublication.swift`.
- No token counting. No per-backend budgets.
- Do not compact `payload.variables`, memory guidance or output contract
  text.
- No retry or failure-transition routes.
- Do not change `inputSnapshot.mergedVariables`. It must stay the original
  for rerun-boundary matching in `DeterministicWorkflowRunner+History.swift:101`.

## File-Level Changes

### 1. `Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift` (new)

Pin these names. `pog-05` tests rely on them.

```swift
let agentPromptDefaultMaxBytes = 400_000
let agentPromptSpillMinBytes = 4_096
let agentPromptSpillPreviewCharacters = 256
struct AgentPromptGuardOutcome: Sendable { var prompts: ComposedAdapterPrompts; var evidence: JSONObject?; var rejection: AdapterExecutionError? }
extension DeterministicWorkflowRunner {
  func effectiveAgentPromptMaxBytes(workflow: WorkflowDefinition, payload: AgentNodePayload) -> Int
  func guardAgentPrompt(workflow: WorkflowDefinition, step: WorkflowStepRef, payload: AgentNodePayload, request: DeterministicWorkflowRunRequest, session: WorkflowSession, resolvedInputPayload: JSONObject, prompts: ComposedAdapterPrompts) throws -> AgentPromptGuardOutcome
}
```

Key behavior (design Part C):

- **Budget.** Use `payload.promptMaxBytes ?? workflow.defaults.agentPromptMaxBytes ?? 400_000`.
- **Measure.**
  `utf8(systemPromptText ?? "") + max(utf8(promptText), utf8(resumedPromptText))`.
  `promptText` is the fresh text.
- **Within budget.** Return the input prompts unchanged, with
  `evidence = nil` and `rejection = nil`.
- **Candidates.**
  - Build `runtimeVariables` the same way `promptVariables` does:
    `requestVariables` overlaid by `resolvedInputPayload`.
  - Take `view = deduplicatedRuntimeVariablesView(runtimeVariables)` and
    enumerate every value in it except the root. That includes the
    top-level member values and all nested object members and array
    elements.
  - Size each value as its `compactJSONString().utf8.count`. Keep values of
    at least 4096 bytes.
  - Exclude any object containing `"$rielaSpilled"` and everything under it.
  - Exclude marker members (`$rielaElidedKeys`, `$rielaSameAs`).
  - Identify each candidate by its RFC 6901 JSON Pointer, escaping `~` as
    `~0` and `/` as `~1`.
- **Selection loop.** While over budget, set `excess = measured - budget` and
  choose one value:
  - the smallest candidate with `bytes >= excess`, ties broken by pointer
    ascending;
  - if none exists, the largest candidate, ties broken by pointer ascending.

  Spill it, rebuild the view, recompose and re-measure. Candidates are
  re-enumerated each iteration on the compacted view, so already-spilled
  subtrees disappear.
- **Applying a spill.** Map the view pointer back to the sources. The
  compacted copies are `compactedRequestVariables` and
  `compactedResolvedInputPayload`. Replace the value at every location below
  with the same stub:
  1. **Top-level key `K` (pointer `/K/...`, `K != "_rielaInput"`).**
     - If `K` is in `resolvedInputPayload`, replace it there. Also replace
       the same relative path under every
       `_rielaInput.messages[i].payload.K` and under
       `_rielaInput.latest.payload.K` whose value at that path is
       byte-identical to the original.
     - Otherwise replace `requestVariables[K]`.
  2. **Pointer under `/_rielaInput/messages/<i>/payload/...`.** Replace it
     there. If `i` is the last index, also replace the same relative path
     under `_rielaInput.latest.payload`. The view elided `latest.payload`
     as `$rielaSameAs`.
  3. **Any other `/_rielaInput/...` pointer** (rare, metadata). Replace it in
     place.
- **Stub.**
  `{"$rielaSpilled": true, "pointer": <view pointer>, "path": <absolute file path>, "bytes": <n>, "sha256": <hex>, "preview": <first 256 Characters of the compact JSON>}`.
- **File.**
  `<resolvedBackendWorkingDirectory(backend: payload.executionBackend, configuredWorkingDirectory: payload.workingDirectory, workspaceRoot: fanoutWorkspaceRoot) ?? fanoutWorkspaceRoot?.path ?? FileManager.default.currentDirectoryPath>/tmp/riela-prompt-spill/<sessionId>/<step.id>/<sha256>.json`.
  - Create directories with mode 0700 and the file with mode 0600, using
    `O_CREAT|O_EXCL`.
  - If the file already exists, read it. Matching bytes mean reuse.
    Mismatching bytes mean a rejection of
    `AdapterExecutionError(.policyBlocked, "prompt spill file exists with different content: <path>")`.
  - The file content is exactly the hashed compact JSON bytes.
  - Never include timestamps or UUIDs.
- **Recompose.**
  1. Call `promptVariables(workflow:step:payload:requestVariables: compactedRequestVariables, resolvedInputPayload: compactedResolvedInputPayload)`.
  2. Call `composedPromptsWithFinalizationEvidence(workflow:step:payload:variables:session:)`.

  Templates that interpolate a spilled value therefore render the stub JSON.
- **Placement.** If `step.placement != nil`, do not spill. Over budget means
  an immediate rejection.
- **No candidates left while still over budget.** Reject with
  `AdapterExecutionError(.invalidInput, "agent prompt exceeds budget: measured=<n> budget=<b> after <k> spill(s)", failureKind: .promptTooLarge)`.
- **Evidence**, set when spilled or rejected:
  - `budgetBytes`;
  - `measuredBytes`: the initial size;
  - `finalBytes`;
  - `outcome`: `"spilled"` or `"overBudget"`;
  - `spills: [{pointer, path, bytes, sha256}]` in spill order.
- **Filesystem errors** while spilling, other than the mismatch case, become a
  rejection with `AdapterExecutionError(.providerError, "prompt spill failed: <error>")`.
  The guard does not throw for policy outcomes. It returns them as a
  rejection.

### 2. `Sources/RielaCore/DeterministicWorkflowRunner.swift` (`executePayloadNodeAndRecordMemory`)

- After `prompts` is computed (around line 620), call `guardAgentPrompt(...)`
  with `resolvedInput.payload`.
- Build `AdapterExecutionInput` from `outcome.prompts`: `promptText`,
  `freshPromptText`, `resumedPromptText` and `systemPromptText`.
  `mergedVariables` stays the original `mergedVariables`.
- Pass `promptGuard: outcome` into `executeAndPublish`.
- Do not throw the rejection here. A throw at this point records no step
  execution.

### 3. `Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift` (`executeAndPublish`)

- Add the parameter `promptGuard: AgentPromptGuardOutcome? = nil`. Other
  callers keep compiling.
- Inside the attempt loop, take the `historyInvocationSnapshot(...)` result
  and set `snapshot["promptCompaction"] = .object(evidence)` when evidence is
  non-nil. Pass that as `inputSnapshot`.
- After `recordStepStartedExecution`, if `promptGuard?.rejection` is set,
  return
  `try await publishAdapterFailure(rejection, sessionId:, step:, attempt:, backend: basePayload.executionBackend, transitions:)`
  without calling `executePlacedAdapter`.

## Invariants

- Within budget, the adapter receives byte-identical prompts to those
  produced without the guard, and `inputSnapshot` has no `promptCompaction`
  key.
- Spill selection and stub content are deterministic: two identical runs
  produce identical stubs, files and evidence.
- `inputSnapshot.mergedVariables` and `adapterInput.mergedVariables` are
  never compacted.
- A rejection never calls the backend. It records exactly one failed step
  execution, with `failureKind == .promptTooLarge` for budget rejections.

## Tests: `Tests/RielaCoreTests/AgentPromptGuardTests.swift` (new)

Use an input-capturing adapter that counts invocations, as in
`DeterministicWorkflowRunnerRuntimeVariablesTests`. Seed upstream input
through a two-step workflow: a first step whose `StaticAdapter` output
payload holds big strings, then the guarded agent step. Use
`InMemoryWorkflowRuntimeStore`. Set `fanoutWorkspaceRoot` to a scratch
directory under the repository `tmp/`, so spill files land there, and
remove it in teardown.

- Under budget (default 400000, small payload) → the adapter is invoked once,
  the prompts equal a no-guard baseline, and `inputSnapshot["promptCompaction"]`
  is nil.
- Spill: the upstream payload `{huge: 60 KB string, medium: 10 KB string, tiny: "t"}`,
  with node `promptMaxBytes` set so that only spilling `huge` fits.
  - Expected: the adapter is invoked once; `systemPromptText` contains
    `"$rielaSpilled"` and does not contain the 60 KB string.
  - The file exists at the stub path, and its sha256 matches the stub.
  - `promptCompaction.outcome == "spilled"`, `spills.count == 1`,
    `spills[0].pointer == "/huge"`, and `finalBytes <= budgetBytes`.
- Smallest-covering selection: excess of about 12 KB with candidates of
  60 KB and 15 KB → only the 15 KB value is spilled.
- Tie-break: two equal-size candidates `/a` and `/b`, where one spill
  suffices → `/a` is spilled.
- Determinism: run the spill scenario twice with fresh stores and the same
  session id → identical `promptCompaction` and stub JSON.
- Template interpolation:
  `promptTemplate: "{{_rielaInput.latest.payload.huge}}"` → after the spill,
  `promptText` contains `"$rielaSpilled"`, not the original string.
- Still over budget: `promptMaxBytes: 100`, which is smaller than the
  non-spillable workflow text.
  - Expected: the adapter invocation count is 0, `session.status == .failed`,
    and `session.failureKind == .promptTooLarge`.
  - The single execution has `failureKind == .promptTooLarge`,
    `inputSnapshot.promptCompaction.outcome == "overBudget"`, and a failure
    reason containing "agent prompt exceeds budget".
- Placement: a step with `placement` that is over budget → rejected with no
  spill files written. If building a placed step needs worker
  infrastructure, test `guardAgentPrompt` directly instead.
- Budget precedence: node 5000 over workflow 9000 over the default.
  `effectiveAgentPromptMaxBytes` returns 5000, then 9000 when the node value
  is unset, then 400000.
- Existing spill file with different bytes → a rejection containing
  "different content", recorded as a failed step.

## Verification

1. `arch -arm64 /bin/zsh -lc 'swift build' 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/build.log`
   must exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentPromptGuardTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests"' 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/test.log`
   must exit 0 and show 0 failures.
3. `arch -arm64 /bin/zsh -lc "swiftlint lint --strict Sources/RielaCore/DeterministicWorkflowRunner+PromptGuard.swift Sources/RielaCore/DeterministicWorkflowRunner.swift Sources/RielaCore/DeterministicWorkflowRunner+AdapterPublication.swift Tests/RielaCoreTests/AgentPromptGuardTests.swift" 2>&1 | tee tmp/prompt-overflow/pog-03-prompt-guard/lint.log`
   must exit 0.

## Done Criteria

- The guard file exists with the pinned names, the runner wiring is done, and
  all `AgentPromptGuardTests` pass.
- No change to `Prompting.swift` or `RuntimePublication.swift`.
- Logs and exit codes are recorded in the progress log, along with pre- and
  post-edit sha256 values.

## Overwrite Safety

- Re-read each file before editing it, and hash it before and after.
- Stop on unexpected drift.
- Only `pog-03` edits `DeterministicWorkflowRunner.swift` and
  `DeterministicWorkflowRunner+AdapterPublication.swift` in this wave.
