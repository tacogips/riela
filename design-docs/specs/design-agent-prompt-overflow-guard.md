# Agent Prompt Overflow Guard

Status: design for opus-luna-design-and-implement-review-loop session-475
(branch `feat/agent-prompt-overflow-guard`, base `3f921eb4`).

## Problem

In opus-luna-design-and-implement-review-loop 0.1.8, session-471
(2026-10-22), the `implementation-wave-outcome` Opus step received about
8 MB of input. The provider answered `Prompt is too long (~1.25M tokens)`.
The session failed with `failureKind: adapterFailure`, and
`riela session resume --retry-failed-step` resent the same input, so the
only recovery was manual surgery. Three causes were confirmed in the source:

1. **Unbounded fanout observations.** `WorkflowFanoutChangeEvidence.reduce()`
   (`Sources/RielaCore/WorkflowFanoutChangeEvidence.swift`) emits one
   observation per (branch, capture record, drifted path). Each node boundary
   adds a capture record. Long continuations that write many `tmp/` logs
   multiply into thousands of near-identical entries in
   `join.changeEvidence.observations`.
2. **The step input is sent several times.** No adapter delivers
   `AdapterExecutionInput.mergedVariables` or `arguments` to a provider.
   `AgentGatewayNodeAdapter` sends only `systemPromptText` (as the vendor
   system prompt) and the fresh or resumed `promptText`. The duplication is
   inside the single runtime-variables block that `composedPrompts` appends to
   `systemPromptText` (`runtimeVariablesPrompt`,
   `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`).
   `runtimeVariables` is `requestVariables` merged with `resolvedInputPayload`,
   and `DefaultWorkflowMessageInputResolver` builds that payload as:
   - every message's payload keys flattened to the top level, plus
   - `_rielaInput.messages[i].payload`, the same values again per message, plus
   - `_rielaInput.latest.payload`, the last message's payload a third time.

   A single-message step therefore carries its upstream payload three times in
   one system prompt. Step 2 of session-475 shows this: `acceptanceSignals`
   appears at the top level, in `_rielaInput.latest.payload`, and in
   `_rielaInput.messages[0].payload`. Prompt templates render from the
   unmodified `variables` and are not a duplication source unless an author
   explicitly interpolates a value.
3. **No size check, and generic failure classification.** Nothing measures the
   composed request before invocation. Provider overflow is recorded as
   `adapterFailure`, with no structured signal an operator or router can act on.

## Scope

In scope:

- Bounded, aggregated `changeEvidence.observations`, with the full list kept
  in an artifact.
- Single-copy rendering of the runtime-variables block.
- A deterministic pre-invocation size guard that spills values to artifacts.
- Classification of `promptTooLarge` for both guard failures and provider
  overflow replies.
- Configuration, documentation and focused tests.

Out of scope:

- New retry or failure-transition routes for failed agent steps.
- Token-accurate counting per model.
- Compaction of node-authored `payload.variables`, memory guidance or output
  contracts.
- Changes to drift-detection semantics.
- GraphQL schema changes. `failureKind` is already a free-form `String` in
  `Sources/RielaGraphQL/GraphQLContracts.swift`, so SDL regeneration is not
  required.

## Part A: bounded fanout change-evidence observations

### Aggregation

`reduce()` still compares every capture record with the stable final tree,
exactly as today. The same comparison produces the same drift set and the same
`reduceFailures`. Only the reporting changes.

- Raw drift findings are aggregated by the key
  `(branchId, selection, path)`.
- Each aggregated observation contains:
  - `branchId`, `selection`, `path`;
  - `reason`: the reason from the earliest record, kept for compatibility
    with existing consumers and tests;
  - `reasons`: the distinct reasons in first-seen order;
  - `occurrences`: an integer count of records that flagged the key;
  - `firstStepId` and `lastStepId`;
  - `firstSnapshotPath` and `lastSnapshotPath`.
- Inline order is deterministic: `branchId` ascending, then `selection`
  ascending, then `path` ascending. Records are already iterated in that
  branch order and appended in capture order.

### Cap and join fields

- Inline limit: `fanout.changeTracking.observationInlineLimit`.
  - Optional non-negative integer.
  - Default `200`, maximum `10000`.
  - Raw validation rejects other values at
    `...fanout.changeTracking.observationInlineLimit`. This needs its own
    integer check: the existing `changeTracking` field loop in
    `WorkflowRawValidation.swift` requires every listed field to be a JSON
    Pointer.
  - The setting is a new optional field on `WorkflowFanoutChangeTracking`.
- `changeEvidence.observations` holds the first `inlineLimit` aggregated
  observations in that order.
- New join fields:
  - `observationCount`: the total number of aggregated observations.
  - `observationOccurrenceCount`: the total number of raw findings.
  - `inlineObservationCount`.
  - `observationsTruncated`: `observationCount > inlineObservationCount`.
  - `observationsPath`: the absolute path of the full list.
  - `observationCountsByBranch`: `{branchId: {total, inline}}` for every
    branch with drift. This is bounded by the branch count, so truncation
    never hides which branches drifted.
- `limits` gains `observationInline`.
- `hasDrift` becomes `observationCount > 0`, computed from the total and never
  from the inline subset. `requiresSemanticReview`, `observationBoundary`,
  `complete`, `captureFailures`, `reduceFailures` and `artifactPaths` keep
  their current meaning and shape.

### Full-list artifact

- `reduce()` writes `observations.json` into the fanout evidence directory
  that already holds the capture snapshots referenced by `artifactPaths`
  (`<fanoutWorkspaceRoot>/tmp/riela-fanout/<generated-id>/observations.json`).
  This is the existing per-fanout runtime artifact area, so the full list
  lives beside the snapshots it was derived from.
- The file holds the complete aggregated list, with no cap. Each entry also
  carries `occurrenceDetails: [{stepId, snapshotPath, reason}]` in record
  order, so no information from the old per-record list is lost.
- The file is created with `O_CREAT | O_EXCL` and mode `0600`, like the
  snapshot files. It is written even when there is no drift.
- If the write fails, the failure is appended to `reduceFailures` (phase
  `reduce`, path `observations.json`) and `complete` becomes `false`. The
  inline observations are still delivered and the list is never silently
  dropped.

### Consumers

- Assertions in `WorkflowFanoutMapReduceTests` and
  `FanoutArtifactEvidenceRunnerTests` that look for a specific `reason` keep
  working when the earliest record carries that reason. Otherwise they are
  updated to check `reasons`.
- No example `EXPECTED_RESULTS.md` reads `changeEvidence.observations`. A grep
  of `examples/` finds only an unrelated prose match in
  `monja-project-task-orchestrator`.

## Part B: single-copy runtime-variables block

`runtimeVariablesPrompt` renders a deduplicated view of `runtimeVariables`.
The template variables are unchanged: `{{_rielaInput.latest.payload.x}}`,
`{{runtimeVariables.workflowInput.x}}` and top-level keys render exactly as
before, because templates read the original `variables`.

### Deduplication rules

The rules are deterministic and lossless:

1. **Message payload members.** In `_rielaInput.messages[i].payload`, a member
   whose value is byte-identical (compact JSON) to `runtimeVariables[key]` is
   omitted. The payload object gains `"$rielaElidedKeys": [sorted keys]`,
   meaning "the value equals top-level `runtimeVariables.<key>`". Members
   overridden by a later message differ from the top-level value, so they stay
   inline.
2. **Latest message.** `_rielaInput.latest` is always the record of the last
   message. Its `payload` is replaced by
   `{"$rielaSameAs": "/_rielaInput/messages/<lastIndex>/payload"}`. The other
   metadata fields stay.
3. Nothing else is altered: request variables, `workflowInput`,
   `communicationIds`, `sourceStepIds` and so on.

The block header keeps the sentence "Use this JSON as the authoritative
runtimeVariables object". It adds one sentence that explains `$rielaElidedKeys`
and `$rielaSameAs`, so the agent still has every value it had before. Existing
prompts that tell the agent to use that JSON keep working.

### Test

A test builds a single-message input with a unique 100 KB marker string and
the default fallback prompt. It asserts that the marker occurs exactly once
across `systemPromptText + promptText`. It also asserts that templates
referencing `{{_rielaInput.latest.payload.k}}` and
`{{runtimeVariables.workflowInput.k}}` still render their values.

## Part C: pre-invocation prompt-size guard and spill

### Where it runs

The guard runs on the controller in `executePayloadNodeAndRecordMemory`, after
`composedPromptsWithFinalizationEvidence` and before `AdapterExecutionInput` is
built. It therefore covers every agent step with a backend. Stdio nodes,
output projections and add-on nodes do not compose agent prompts and are not
guarded.

### Budget

- Precedence: node payload `promptMaxBytes`, then workflow
  `defaults.agentPromptMaxBytes`, then the built-in default `400000`.
- Both settings are optional positive integers and raw validation rejects
  other values.
- Measured size:
  `utf8(systemPromptText) + max(utf8(freshPromptText), utf8(resumedPromptText))`.
  This is exactly the text riela sends.
- The default is about 100k–160k tokens for JSON-heavy text. That leaves
  headroom for vendor system prompts and tools on 200k-context models while
  failing safely far below the session-471 shape. Backend-added prompts and
  images are not measured; the documented headroom covers them.

### Spill algorithm

The algorithm is deterministic, with no clocks or UUIDs:

1. If the measured size is within budget, nothing changes and no evidence is
   recorded.
2. **Candidates** are the values in the Part B deduplicated runtime-variables
   view at any depth below a top-level key: object members and array
   elements. Each candidate's compact JSON size must be at least `4096` bytes,
   a fixed constant. Each candidate is identified by its JSON Pointer in that
   view.
3. Repeat while over budget, with `excess = measured - budget`:
   - Choose the **smallest** candidate whose size is at least `excess`.
     Ties are broken by pointer, ascending by bytes.
   - If no single candidate covers the excess, choose the **largest**
     candidate. Ties are again broken by pointer, ascending.
   - Candidates inside an already-spilled subtree are skipped.
   - Replace the chosen value with a stub.
   - Re-render the view and recompose both prompts with the same templates.
     Variables are rebuilt from the compacted request variables and resolved
     payload.
   - Re-measure.
4. A stub replaces the value at its view pointer and at every location the
   view elided as a duplicate:
   - For a top-level-key pointer, the byte-identical copies inside
     `_rielaInput.messages[*].payload` and `_rielaInput.latest.payload`.
   - For a pointer under `/_rielaInput/messages/<lastIndex>/payload` (a value
     kept inline because a later key overrode it, or one that differs from the
     top level), the matching location under `_rielaInput.latest.payload`.
     Part B elides `latest.payload` entirely as `$rielaSameAs`.

   Templates that interpolate the spilled value, including
   `{{_rielaInput.latest.payload.*}}`, therefore render the stub, not the
   original.
5. If no candidates remain while still over budget, the step fails before any
   backend call (see Part D).

### Stub and file

- Stub shape:
  `{"$rielaSpilled": true, "pointer": "/k/...", "path": "<absolute path>", "bytes": N, "sha256": "<hex>", "preview": "<first 256 characters of the compact JSON>"}`.
- File: `<resolvedBackendWorkingDirectory>/tmp/riela-prompt-spill/<sessionId>/<stepId>/<sha256>.json`.
  It contains the exact compact JSON bytes that were hashed.
  - The working directory is the agent's own directory, so the agent can read
    the file. When a node has no backend, the same fallback as
    `resolvedBackendWorkingDirectory` applies: `fanoutWorkspaceRoot`, then the
    process working directory.
  - The name is content-addressed, so a resume or retry of the same step
    reuses an existing file whose bytes verify. A mismatching existing file
    fails the guard with `policy_blocked`.
  - Files are created `0600` under a `0700` directory.
  - Spilled values are never dropped.
- Steps with `placement` run on another worker, where the controller's files
  are not visible. These steps are measured but never spilled: over budget
  means an immediate `promptTooLarge` failure.

### Evidence

- When the guard spills or rejects, the step execution's `inputSnapshot` gains
  `promptCompaction`:
  - `budgetBytes`, `measuredBytes`, `finalBytes`;
  - `outcome`: `spilled` or `overBudget`;
  - `spills: [{pointer, path, bytes, sha256}]` in spill order.
- `inputSnapshot.mergedVariables` stays the original, uncompacted object.
  Rerun-boundary matching in `DeterministicWorkflowRunner+History.swift`
  compares `_rielaInput` there and must not change. The recorded
  `systemPromptText` and `promptText` are the compacted text that was sent.

## Part D: `promptTooLarge` failure classification

- `WorkflowSessionFailureKind.promptTooLarge` (raw value `promptTooLarge`) is
  added to the existing extensible struct. It needs no decoding change.
- `AdapterExecutionErrorCode` stays closed and unchanged. Adding a case would
  alter a persisted closed enum used by external adapters.
- `AdapterExecutionError` gains an optional `failureKind:
  WorkflowSessionFailureKind?` hint that defaults to `nil`. The type is not
  `Codable`, so this is source-compatible.
- **Guard rejection.** The guard does not throw from
  `executePayloadNodeAndRecordMemory`. A throw there, like
  `validateAgentNodePayload`, records no step execution. Instead, the guard
  outcome (`overBudget` plus its `promptCompaction` evidence) is passed into
  `executeAndPublish`. After `recordStepStartedExecution`, which carries the
  evidence in `inputSnapshot`, `executeAndPublish` publishes
  `AdapterExecutionError(.invalidInput, "agent prompt exceeds budget: measured=<n> budget=<b> after <k> spill(s)", failureKind: .promptTooLarge)`
  through `publishAdapterFailure` without calling `executePlacedAdapter`.
- **Provider overflow.** A pure classifier maps an adapter failure to a failure
  kind:
  1. Use the explicit `failureKind` hint when present.
  2. Otherwise, when the code is `provider_error` or `invalid_input` and the
     lowercased message contains one of the fixed phrases below, return
     `promptTooLarge`:
     - `prompt is too long` (Anthropic and Claude Code);
     - `context_length_exceeded` (OpenAI and Codex);
     - `maximum context length` (OpenAI);
     - `request_too_large` (Anthropic HTTP 413).
  3. Otherwise return `adapterFailure`.
- **Producers.** All three sites that map an `AdapterExecutionError` to
  `.adapterFailure` call the classifier:
  - `Sources/RielaCore/RuntimePublication.swift:348` and `:368`
    (step-failure publication, normal and advisory);
  - `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:120`
    (session failure kind for a thrown adapter error with code
    `provider_error`, `invalid_input`, `invalid_output` or
    `template_resolution_failed`).

  The step record and the session record therefore both carry
  `promptTooLarge`, and the session digest in
  `Sources/RielaCore/SessionObservability.swift` shows it unchanged.
  Unrelated provider errors stay `adapterFailure`.

### Consumers of `failureKind`

`promptTooLarge` is a refinement of `adapterFailure`. Every existing gate that
grants recovery to `adapterFailure` grants it to `promptTooLarge` too, so no
recovery path is lost. No new retry or failure-transition route is added.

`grep -rn '\.adapterFailure' Sources` finds these gates, and each is amended
to accept `.promptTooLarge`:

| Gate | Current check | Behavior for `promptTooLarge` |
| --- | --- | --- |
| `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift:63` (`retryableFailureKind`) | `.adapterFailure \|\| .policyBlocked` | Eligible for `riela session resume <id> --retry-failed-step`. The retry recomposes prompts with the current workflow definition, so the guard re-runs with the current `promptMaxBytes`/`agentPromptMaxBytes` and spills or fails deterministically. The validation message names `adapter-failed, prompt-too-large or policy-blocked`. |
| `Sources/RielaCLI/SessionCommands.swift:1001` (`nonBudgetFailureResumeMessage` retry guidance) | `.adapterFailure \|\| .policyBlocked` | Prints the same `--retry-failed-step` guidance. |
| `Sources/RielaWork/DeterministicDirector.swift:101` (`rerunnable`) | `.adapterFailure && rerunOnAdapterFailure` | Rerunnable under `rerunOnAdapterFailure`, as before the reclassification. There is no new director rule or setting. |
| `Sources/RielaWork/TaskGuardCoordinator.swift:111` (attempt-budget violation) | `.adapterFailure && rerunOnAdapterFailure` | Counted like `adapterFailure`, so the attempt budget still bounds overflow reruns. |

The `failureKind` raw-value string reaches GraphQL and the CLI unchanged; no
consumer there branches on the value. These four files are part of the Part D
implementation surface.

## Configuration summary

| Setting | Level | Default | Valid values |
| --- | --- | --- | --- |
| `fanout.changeTracking.observationInlineLimit` | fanout / step | 200 | 0...10000 |
| `defaults.agentPromptMaxBytes` | workflow | 400000 | positive integer |
| `promptMaxBytes` | agent node payload | inherits | positive integer |

The spill minimum value size (4096 bytes) and the preview length (256
characters) are fixed constants and are not configurable.

## Documentation

- A README section, "Agent prompt size limits", near "Session Observability",
  covers:
  - the three settings and their defaults;
  - the dedup markers;
  - the stub format and spill location;
  - `promptCompaction` evidence;
  - `failureKind: promptTooLarge`;
  - the new `changeEvidence` count, truncation and `observationsPath` fields.
- `design-fanout-dependency-waves-and-change-evidence.md` gets a short
  amendment pointing to Part A, because its join-field list changes.

## Verification

- `arch -arm64 /bin/zsh -lc 'swift build'`
- Focused tests:
  `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowFanoutMapReduceTests|FanoutArtifactEvidenceRunnerTests|<new prompt-composition / prompt-guard / failure-classification / promptTooLarge recovery suites>|DeterministicDirectorTests|WorkGuardDispatcherTests"' 2>&1 | tee tmp/prompt-overflow/swift-test.log`
  They cover:
  - **Part A.** Several branches, each with multiple capture records and
    thousands of drifted paths. The test asserts:
    - aggregation counts and first/last step;
    - the inline cap and `observationsTruncated`;
    - the `observationsPath` content (the full list);
    - `observationCountsByBranch`;
    - serialized `changeEvidence` under a fixed byte bound (for example 256 KB
      with the default cap);
    - `hasDrift`, `complete`, `reduceFailures` and `captureFailures` unchanged.

    A capped-to-zero case still has `hasDrift == true`.
  - **Part B.** Exactly-once marker and template rendering (see Part B).
  - **Part C.**
    - Under budget: prompts byte-identical to the no-guard result, and no
      `promptCompaction`.
    - Spill: stub fields, file bytes and sha256, deterministic selection
      across two identical runs, evidence recorded, and the adapter invoked
      with compacted text.
    - Still over budget: a failed execution with `failureKind ==
      promptTooLarge` and the scenario adapter never invoked.
  - **Part D.** Classifier table, covering the four phrases with
    `provider_error`, an unrelated `provider_error`, and the explicit hint.
    Step and session records carry `promptTooLarge`, including through the
    `Cancellation.swift` thrown-error path.
  - **Recovery preservation.**
    - A runner test: a session that failed with `promptTooLarge` (guard
      rejection) is accepted by resume with `retryFailedStep`. After the
      budget is raised in the workflow definition, the retried step succeeds,
      and its `promptCompaction` shows `spilled`, or is absent when within
      budget.
    - A `SessionCommands` resume-message test: the message for a
      `promptTooLarge` session includes the `--retry-failed-step` guidance.
    - A `DeterministicDirector` test: a failed attempt with
      `failureKind == promptTooLarge` and `rerunOnAdapterFailure: true`
      resolves to `.rerun`. With `rerunOnAdapterFailure: false` it does not.
    - A `TaskGuardCoordinator` test: an exhausted attempt budget with a
      `promptTooLarge` attempt records the attempts-budget violation.
- A runner-level test runs a fanout with `changeTracking` into an agent join
  step with a small `promptMaxBytes`, using the scenario adapter. It shows
  spill evidence and a succeeded step. The same shape is exercised as a
  mock-scenario CLI run with its fixture and logs under `tmp/prompt-overflow/`
  only. No committed example is added.
- Lint:
  `arch -arm64 /bin/zsh -lc "git diff --name-only -z 3f921eb46e0a099b0d849adb62b8fb7ca69eb9af HEAD -- '*.swift' | xargs -0 swiftlint lint --strict"`

## Rollout constraints

- Changes are commit-local only (`gitPush: false`).
- Every agent step's system prompt changes shape because of Part B dedup. This
  is the intended single-copy behavior. Agents that read the JSON keep full
  information through the markers.
- Workflows with prompts above 400 KB start spilling. The spill is lossless:
  the agent can read the file. Authors can raise the limit per node or per
  workflow.

## Open questions (non-blocking; defaults chosen)

- Whether a per-backend default should replace the single 400000-byte default
  once context sizes per vendor are cataloged. Not needed for the accepted
  scope.
- Whether `promptTooLarge` should later get a failure-transition or retry
  route. Explicitly not requested here.
