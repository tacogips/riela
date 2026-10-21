# Prompt Overflow Guard 01: Contracts, Classification and Single-Copy Rendering

**planId**: `pog-01-contracts`
**Wave**: 1
**dependsOn**: none
**Workflow Mode**: issue-resolution
**Issue Reference**: none (no GitHub issue). Incident:
opus-luna-design-and-implement-review-loop 0.1.8 session-471 (2026-10-22).
Current run: `opus-luna-design-and-implement-review-loop-session-475`.
**Design Reference**: `design-docs/specs/design-agent-prompt-overflow-guard.md`
(accepted by Step 3): Part B, Part D (producers + `AdapterExecutionError`
hint), Configuration summary.
**Branch**: `feat/agent-prompt-overflow-guard`. Do not commit, push, or run
any git write command.
**Progress log**: `impl-plans/progress/pog-01-contracts.md`
**Evidence dir**: `tmp/prompt-overflow/pog-01-contracts/`
**planPath**: `impl-plans/active/prompt-overflow-guard-01-contracts.md`

**writePaths**:

- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/AdapterContracts.swift`
- `Sources/RielaCore/PromptOverflowClassification.swift`
- `Sources/RielaCore/RuntimePublication.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/AgentNodePayload.swift`
- `Sources/RielaCore/WorkflowNodeValidation.swift`
- `Sources/RielaCore/WorkflowFanoutScheduling.swift`
- `Sources/RielaCore/WorkflowRawValidation.swift`
- `Sources/RielaCore/RuntimeVariablesPromptView.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`
- `Tests/RielaCoreTests/PromptOverflowContractsTests.swift`
- `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift`
- `impl-plans/progress/pog-01-contracts.md`
- `tmp/prompt-overflow/pog-01-contracts`

**sharedPaths**: none.

**artifactRoots**: `tmp/prompt-overflow/pog-01-contracts` (logs only).

## Intent and Context

Wave 2 plans run in parallel and must not edit the same files. This plan pins
every shared contract they depend on, so they can start at the same time:

- the new failure kind and the classifier;
- the three configuration fields and their validation;
- the pure deduplicated runtime-variables view, wired into the system prompt.

It also covers the producer side of classification: the three places that
turn an adapter error into `adapterFailure`.

How the code works today (base `3f921eb4`):

- `WorkflowSessionFailureKind`
  (`Sources/RielaCore/RuntimeSession.swift:19`) is an extensible
  `RawRepresentable` struct with static members.
- `AdapterExecutionError` (`Sources/RielaCore/AdapterContracts.swift:12`) is
  an `Error, Equatable, Sendable` struct. It is not `Codable`.
- `RuntimePublication.swift:348` and `:368` hard-code
  `failureKind: .adapterFailure`.
- `DeterministicWorkflowRunner+Cancellation.swift:120` maps the codes
  `.providerError, .invalidInput, .invalidOutput, .templateResolutionFailed`
  to `.adapterFailure`.
- `composedPrompts` (`DeterministicWorkflowRunner+Prompting.swift:104`)
  appends `runtimeVariablesPrompt(variables:)` (lines 154-165), which renders
  `variables["runtimeVariables"]` as compact JSON.
  - `runtimeVariables` is `requestVariables` merged with
    `resolvedInputPayload`.
  - `DefaultWorkflowMessageInputResolver`
    (`Sources/RielaCore/RuntimeMessageInputResolver.swift`) builds that payload
    by flattening each message's payload keys to the top level and adding
    `_rielaInput.messages[i].payload` and `_rielaInput.latest.payload`.
  - With one message, the payload therefore appears three times.
- No adapter sends `mergedVariables` to a provider.
  `AgentGatewayNodeAdapter` sends only `systemPromptText` and `promptText`.
- `WorkflowDefaults` (`WorkflowModel.swift:127`) uses synthesized Codable.
  `AgentNodePayload` (`AgentNodePayload.swift`) has a custom
  `init(from:)` with `CodingKeys` and a synthesized encoder.
  `WorkflowFanoutChangeTracking` (`WorkflowFanoutScheduling.swift:25`) uses
  synthesized Codable.
- Raw validation lives in `WorkflowRawValidation.swift`:
  - the defaults block at lines 33-46;
  - `validateFanout` at line 329. Its `changeTracking` loop at lines 338-351
    requires every listed field to be a JSON Pointer string.

## Non-Goals

- No prompt-size guard, spill or measurement. That is `pog-03`.
- No changes to fanout `reduce`. That is `pog-02`.
- Do not edit the recovery gates (`Recovery.swift`, `SessionCommands.swift`,
  `RielaWork`). That is `pog-04`.
- Do not add an `AdapterExecutionErrorCode` case.
- No GraphQL or SDL change. `failureKind` is already a `String` there.
- Do not change how templates render. Templates still read the original
  `variables`.

## File-Level Changes

### 1. `Sources/RielaCore/RuntimeSession.swift`

- Add `public static let promptTooLarge = WorkflowSessionFailureKind(rawValue: "promptTooLarge")`
  next to `.adapterFailure`. Make no other change.

### 2. `Sources/RielaCore/AdapterContracts.swift`

- Add `public var failureKind: WorkflowSessionFailureKind?` to
  `AdapterExecutionError`.
- Add a trailing init parameter `failureKind: WorkflowSessionFailureKind? = nil`.
  Every existing call site must compile unchanged.

### 3. `Sources/RielaCore/PromptOverflowClassification.swift` (new)

Pin this contract. `pog-04` and the tests use these exact names.

```swift
public func adapterFailureKind(_ error: AdapterExecutionError) -> WorkflowSessionFailureKind
public let promptOverflowMessagePhrases: [String] // ["prompt is too long", "context_length_exceeded", "maximum context length", "request_too_large"]
```

Rules, applied in order:

1. If `error.failureKind` is set, return it.
2. Else, if `error.code` is `.providerError` or `.invalidInput` and
   `error.message.lowercased()` contains any phrase, return `.promptTooLarge`.
3. Else return `.adapterFailure`.

Do not match on `timeout`, `policyBlocked`, `invalidOutput` or
`templateResolutionFailed`. Do not add regexes or fuzzy matching.

### 4. Producer sites

- `Sources/RielaCore/RuntimePublication.swift:348` and `:368`: replace
  `failureKind: .adapterFailure` with
  `failureKind: adapterFailureKind(adapterFailure)`. Leave the rest of each
  block alone.
- `Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift:120`: in
  the `.providerError, .invalidInput, .invalidOutput, .templateResolutionFailed`
  case, return `adapterFailureKind(adapterError)`.
  - The `.policyBlocked` and `.timeout` cases stay unchanged.

### 5. Configuration fields

- `WorkflowDefaults`: add `public var agentPromptMaxBytes: Int?` and a
  defaulted init parameter.
  - The synthesized encoder omits nil, so do not write a custom encoder.
- `AgentNodePayload`: add `public var promptMaxBytes: Int?`.
  - Add a defaulted init parameter at the end of the parameter list, a
    `CodingKeys` case, and `decodeIfPresent` in `init(from:)`.
  - Imitate how `AgentNodePayload.swift` handles `effort` or `sessionPolicy`.
- `WorkflowFanoutChangeTracking`:
  - add `public var observationInlineLimit: Int?` and a defaulted init
    parameter;
  - add `public static let defaultObservationInlineLimit = 200`;
  - add `public static let maximumObservationInlineLimit = 10_000`.
- `Sources/RielaCore/WorkflowNodeValidation.swift`
  (`validateAgentNodePayload`): if `promptMaxBytes` is set and `<= 0`, emit
  error path `"\(path).promptMaxBytes"` with message
  `"must be a positive integer"`.
- `Sources/RielaCore/WorkflowRawValidation.swift`:
  - In the defaults block, call
    `validatePositiveInteger(defaults["agentPromptMaxBytes"], path: "workflow.defaults.agentPromptMaxBytes", ...)`
    when the key is present. Imitate `fanoutConcurrency` at line 41.
  - In `validateFanout`, after the pointer loop, add a separate check for
    `changeTracking.observationInlineLimit`. It must be an integer in
    `0...10000`, and booleans are rejected.
    - Error path: `"\(path).changeTracking.observationInlineLimit"`.
    - Message: `"must be an integer between 0 and 10000"`.
    - Do not add the field to the pointer-validated `optionalFields` array,
      or a valid integer would be reported as "must be a JSON Pointer".
    - For the integer and boolean check, imitate `validatePositiveInteger`
      in `Sources/RielaCore/WorkflowValidationHelpers.swift:54`. Do not
      reuse the private helper in `WorkflowLoopValidation.swift:767`.

### 6. `Sources/RielaCore/RuntimeVariablesPromptView.swift` (new)

Pin these contracts:

```swift
func deduplicatedRuntimeVariablesView(_ runtimeVariables: JSONObject) -> JSONObject
let runtimeVariablesElidedKeysMarker = "$rielaElidedKeys"
let runtimeVariablesSameAsMarker = "$rielaSameAs"
```

Rules (design Part B). The function is pure and deterministic:

- For each `_rielaInput.messages[i].payload`, remove each member whose
  `compactJSONString()` equals that of `runtimeVariables[key]`.
  - If at least one key was removed, add
    `"$rielaElidedKeys": [sorted removed keys]`.
  - Members whose value differs from the top level stay inline.
- If `_rielaInput.latest` exists and `messages` is non-empty, replace
  `latest.payload` with
  `{"$rielaSameAs": "/_rielaInput/messages/<lastIndex>/payload"}`. Keep all
  other `latest` fields.
- If `_rielaInput` is missing or malformed (not an object, `messages` not an
  array, or a message payload not an object), leave that part unchanged.
  Never throw.
- Compare with `JSONValue.compactJSONString()`. It sorts keys, so the result
  is deterministic. Do not use `JSONEncoder` for comparison.

### 7. `Sources/RielaCore/DeterministicWorkflowRunner+Prompting.swift`

- `runtimeVariablesPrompt(variables:)` renders
  `deduplicatedRuntimeVariablesView(runtimeVariables)` instead of the raw
  object.
- Keep the first header sentence exactly as it is:
  "Runtime variables are available under `runtimeVariables`. Use this JSON as
  the authoritative runtimeVariables object:". Existing tests assert it.
- Add one sentence before the JSON:
  "`$rielaElidedKeys` lists message payload keys whose values equal the
  top-level runtimeVariables entry of the same name; `$rielaSameAs` points
  to an identical payload elsewhere in this object."
- Do not change `promptVariables`, `composedPrompts` ordering, or template
  rendering.

## Invariants

- Templates render exactly as before, because they read the original
  `variables`.
- `runtimeVariables` inside `mergedVariables` is unchanged.
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerRuntimeVariablesTests.swift`
  passes without edits.
- Unrelated provider errors still produce `adapterFailure`.
- An encoded `WorkflowDefaults`, `AgentNodePayload` or
  `WorkflowFanoutChangeTracking` with the new fields unset is byte-identical
  to before.

## Tests

### `Tests/RielaCoreTests/PromptOverflowContractsTests.swift` (new)

Classifier:

- `providerError` with "Error: Prompt is too long: 1250000 tokens" →
  `.promptTooLarge`.
- `providerError` with "context_length_exceeded" → `.promptTooLarge`.
- `invalidInput` with "This model's maximum context length is 200000" →
  `.promptTooLarge`.
- `providerError` with "request_too_large" → `.promptTooLarge`.
- `providerError` with "rate limited" → `.adapterFailure`.
- `timeout` with "prompt is too long" → `.adapterFailure`.
- `invalidOutput` with "prompt is too long" → `.adapterFailure`.
- Explicit hint `.promptTooLarge` on `invalidInput` "x" → `.promptTooLarge`.

Runner (imitate `DeterministicWorkflowRunnerFailureStateTests` with an
adapter that throws):

- An adapter throws `AdapterExecutionError(.providerError, "Prompt is too long")`
  → the session status is `.failed`, `session.failureKind == .promptTooLarge`,
  and the failed execution's `failureKind == .promptTooLarge`.
- The same with "boom" → `.adapterFailure`.

Raw validation, via `validateRawAuthoredWorkflow` or the public validation
entry used by existing raw-validation tests:

- `defaults.agentPromptMaxBytes: 0` → an error at
  `workflow.defaults.agentPromptMaxBytes`.
- `defaults.agentPromptMaxBytes: 5000` → no error.
- `changeTracking.observationInlineLimit` of `-1`, `10001`, `true` or `"5"`
  → an error. `0` and `200` → no error.
- `validateAgentNodePayload` with `promptMaxBytes: 0` → an error.
  `promptMaxBytes: nil` → no new error.

Decode:

- A node JSON with `"promptMaxBytes": 1234` decodes to 1234.
- A workflow JSON with `defaults.agentPromptMaxBytes` round-trips.
- A `changeTracking` JSON with `observationInlineLimit` round-trips.

### `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift` (new)

- One message whose payload `{big: <100 KB unique marker>, small: "s"}` equals
  the top level → the view has `messages[0].payload == {"$rielaElidedKeys": ["big", "small"]}`
  and `latest.payload == {"$rielaSameAs": "/_rielaInput/messages/0/payload"}`.
- Two messages where key `k` is overridden by message 2 → `messages[0].payload`
  keeps `k` with message 1's value, and `messages[1].payload` elides `k`.
- `_rielaInput` absent or malformed → the view equals the input.
- Runner exactly-once: imitate
  `RuntimeVariablesPromptingTests.testRequestVariablesAreExposedAsRuntimeVariablesInWorkerPromptContext`
  in `Tests/RielaCoreTests/DeterministicWorkflowRunnerRuntimeVariablesTests.swift`.
  - Use a two-step workflow. Step 1's adapter returns a payload with a 100 KB
    unique marker. Step 2, the captured step, uses the default fallback
    prompt. Use a per-step adapter that returns step 1's static output and
    captures step 2's input. Write it as a small test adapter in this file.
  - Expected: in step 2's input, the marker occurs exactly once in
    `systemPromptText + "\n" + promptText`. Before this change it occurred
    three times; record that baseline count in the progress log if it can be
    observed.
- Templates still render: with `promptTemplate: "{{_rielaInput.latest.payload.small}}|{{runtimeVariables.workflowInput.k}}"`,
  `promptText` equals `"s|<k value>"`.

## Verification

Write all logs to `tmp/prompt-overflow/pog-01-contracts/`.

1. `arch -arm64 /bin/zsh -lc 'swift build' 2>&1 | tee tmp/prompt-overflow/pog-01-contracts/build.log`
   must exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptOverflowContractsTests|RuntimeVariablesPromptViewTests|RuntimeVariablesPromptingTests|DeterministicWorkflowRunnerTests|WorkflowOutputContractPreflightTests"' 2>&1 | tee tmp/prompt-overflow/pog-01-contracts/test.log`
   must exit 0 and show 0 failures.
3. `arch -arm64 /bin/zsh -lc "{ git diff --name-only -z 3f921eb46e0a099b0d849adb62b8fb7ca69eb9af -- '*.swift'; git ls-files --others --exclude-standard -z -- '*.swift'; } | xargs -0 swiftlint lint --strict" 2>&1 | tee tmp/prompt-overflow/pog-01-contracts/lint.log`
   must exit 0.
   - This lints the union of tracked changes and untracked new Swift files.
     Nothing is committed yet, and `git diff <base>` alone never lists
     untracked files.
   - The log must cover the 4 new files:
     - `Sources/RielaCore/PromptOverflowClassification.swift`
     - `Sources/RielaCore/RuntimeVariablesPromptView.swift`
     - `Tests/RielaCoreTests/PromptOverflowContractsTests.swift`
     - `Tests/RielaCoreTests/RuntimeVariablesPromptViewTests.swift`
4. `grep -n 'adapterFailureKind' Sources/RielaCore/RuntimePublication.swift Sources/RielaCore/DeterministicWorkflowRunner+Cancellation.swift`
   must show 3 hits.

## Done Criteria

- All listed files are changed as described, and the new public names exist
  exactly as pinned.
- Verification commands 1-4 pass. Each log path and exit code is recorded in
  the progress log.
- The lint in step 3 covers every new Swift file this plan created.
  Confirm this in the progress log, for example with
  `git ls-files --others --exclude-standard -- '*.swift'` output.
- The progress log records:
  - the pre- and post-edit `shasum -a 256` of every edited file;
  - any deviation, with the reason.

## Overwrite Safety

- Re-read each file immediately before editing it.
- Record the sha256 before and after each edit in the progress log.
- If a file's pre-edit hash differs from your last read, stop editing it and
  record the drift. Edit only your own `writePaths`.
