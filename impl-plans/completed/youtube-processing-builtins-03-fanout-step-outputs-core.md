# ypb-03: fanout `includeStepOutputs` in RielaCore

```json
{
  "planId": "ypb-03-fanout-step-outputs-core",
  "planPath": "impl-plans/active/youtube-processing-builtins-03-fanout-step-outputs-core.md",
  "dependsOn": [],
  "wave": "W1",
  "writePaths": [
    "Sources/RielaCore/WorkflowModel.swift",
    "Sources/RielaCore/RuntimePublication.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift",
    "Sources/RielaCore/WorkflowValidation.swift",
    "Sources/RielaCore/WorkflowRawValidation.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift",
    "Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutResumeTests.swift",
    "impl-plans/progress/ypb-03-fanout-step-outputs-core.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §B.
Baseline: `design-bounded-fanout-join-workflow-execution.md` and its
2026-10-30 amendment.

Today a fanout join records only each branch's final output. In
`DeterministicWorkflowRunner+Fanout.swift`, `runFanoutBranch` returns
`.success(index:item:output: result.rootOutput ?? [:], sessionId:)`. ART needs
the outputs of earlier steps inside the branch, such as a speech-to-text
transcript. `result.session.executions` (`[WorkflowStepExecution]`, each with
`acceptedOutput?.payload`) already holds them durably for both same-workflow
and `toWorkflowId` branches.

## Contracts pinned for later plans

ypb-07 (CLI validation and example) relies on the field shape and the join
record shape below.

- `WorkflowStepFanout` gets a field:
  `public var includeStepOutputs: [String]?`.
  - Add it as the LAST init parameter: `includeStepOutputs: [String]? = nil`.
  - The synthesized Codable must keep omitting the key when the value is nil.
    Do not write a custom encoder.
- `WorkflowFanoutDispatchDirective` (`RuntimePublication.swift:190`) gets a
  field `public var includeStepOutputs: [String]?`, also as the LAST init
  parameter with default `nil`.
- A completed branch record gains `"stepOutputs": {<stepId>: <acceptedPayload object>}`
  only when `directive.includeStepOutputs != nil`.

## Non-goals

- No persistence schema change and no change to `SQLiteWorkflowRuntimePersistenceStore*`.
- No change to failed or cancelled branch records.
- No CLI changes. Callee-step validation and the example belong to ypb-07.
- No docs changes. `docs/workflows/json-data-processing.md` belongs to ypb-07.
- Do not touch `Sources/RielaCore/WorkflowNodeValidation.swift`.

## File-level changes

### `WorkflowModel.swift`

Add the field and the init parameter, as pinned above.

### `RuntimePublication.swift`

- Add the directive field.
- `liveFanoutDispatchDirective(...)` (around line 1077) passes
  `includeStepOutputs: fanout.includeStepOutputs`.

### `DeterministicWorkflowRunner+NestedReservations.swift`

Pass `includeStepOutputs: fanout.includeStepOutputs` at both directive
constructions:

- the zero-selected rebuild, around line 143;
- the pending-resume rebuild, around line 204.

If a site is missed, resumed joins diverge from the durable receipt.

### `DeterministicWorkflowRunner+Fanout.swift`

- Add a private helper:
  `fanoutStepOutputs(_ stepIds: [String], session: WorkflowSession) -> JSONObject`.
  For each id it takes the payload of the last element of `session.executions`
  with that `stepId` and a non-nil `acceptedOutput`. Imported executions are
  included. It omits ids with no such execution and never writes `null`.
- `FanoutBranchOutcome.success` gains an optional parameter
  `stepOutputs: JSONObject? = nil`. The record gets the `"stepOutputs"` key only
  when that value is non-nil, which happens whenever the directive field is
  non-nil, even if the result is `{}`.
- In `runFanoutBranch`, success path: when `directive.includeStepOutputs` is
  set, compute the helper from `result.session`.
- In `dispatchFanout`, after building `orderedBranches` and before any
  failure-policy throw or `appendFanoutJoinMessage`, enforce the bound:
  - When `includeStepOutputs` is set, sum the compact `JSONEncoder` byte sizes
    of every `stepOutputs` value, branch by branch in order and step by step in
    the authored order.
  - When the running total first exceeds `8_000_000`, throw
    `DeterministicWorkflowRunnerError.fanoutDispatchFailed(groupId:reason:)`
    with the reason
    `"includeStepOutputs exceeded 8000000 bytes at branch <index> step '<stepId>'"`.

### `WorkflowRawValidation.swift`, `validateFanout`

When `fanout["includeStepOutputs"]` is present, it must be a non-empty
`[String]` with non-empty, unique elements. Otherwise report an error at
`\(path).includeStepOutputs`.

### `WorkflowValidation.swift`

- `validateTypedFanout`: apply the same shape rule on the typed value.
- `DefaultWorkflowValidator.validate`, beside the existing `joinStepId` check
  (around line 175): for transitions with `toWorkflowId == nil` and a non-nil
  `includeStepOutputs`, each id must be in `stepIds` and must not equal
  `fanout.joinStepId`.
  - Error path:
    `workflow.steps.<stepId>.transitions[<transitionIndex>].fanout.includeStepOutputs[<j>]`.
  - Messages: `must reference workflow.steps[] entry '<id>'` and
    `must not name the join step '<joinStepId>'; local branches stop before the join`.
  - Skip this check for `toWorkflowId != nil`. ypb-07 validates callee steps.

## Invariants and pitfalls

- Field absent: the join payload, the branch record key sets
  {index, item, status, output, sessionId, branchId}, the message payload and
  the durable receipt are all byte-identical to today. Do not add an empty
  `stepOutputs` in that case.
- Take values only from durable session executions, never from in-memory
  adapter outputs. The resume rebuild must then produce an identical join, so
  `nestedMessage(_:matches:)` in the persistence store still passes.
- Record the outcome order by input index as today. Do not reorder.
- Keep the existing error ordering for fail-fast and collect-all. The size
  bound check is the only new throw, and it comes before them.
- Do not change `WorkflowStepFanout`'s existing init parameter order. Existing
  call sites rely on it.

## Tests (situation → expected)

Add to `DeterministicWorkflowRunnerFanoutTests.swift`, imitating the existing
local-fanout and `contextFrom` tests in that file.

- Same-workflow fanout, branch steps `a → b`, `includeStepOutputs: ["a","b"]`
  → each completed branch record has `stepOutputs.a` and `stepOutputs.b` equal
  to those steps' accepted payloads, and `output` is unchanged.
- A step that executes twice in a branch (loop) → `stepOutputs` holds the
  latest accepted payload.
- `includeStepOutputs: ["a","never-run"]` → `stepOutputs` has `a` only.
- `collect-partial` with one failing branch → the failed record has no
  `stepOutputs`, and the completed record has it.
- Field absent → the branch record key set equals the existing set exactly.
  `JSONEncoder().encode(WorkflowStepFanout(...))` without the field contains no
  `includeStepOutputs` key.
- Accepted payloads totaling more than 8,000,000 bytes → `fanoutDispatchFailed`
  whose reason names the branch index and the step, and no join message is
  appended.
- Validation:
  - an unknown id, the join step id, a duplicate id, `[]` and `[""]` each
    produce an error diagnostic at the indexed path;
  - a `toWorkflowId` fanout with any ids produces no Core error;
  - raw validation rejects `"includeStepOutputs": "a"`.

Add to `DeterministicWorkflowRunnerFanoutResumeTests.swift`, imitating the
existing resume and cross-workflow cases in that file.

- A cross-workflow (`toWorkflowId`) fanout with `includeStepOutputs` naming
  callee steps → `stepOutputs` is populated from the callee child session.
- A resume after a branch-terminal checkpoint (an existing recovery checkpoint
  pattern) with `includeStepOutputs` → the rebuilt join equals the join from an
  uninterrupted run, and no receipt-conflict error occurs.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-03
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-03/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "DeterministicWorkflowRunnerFanoutTests|DeterministicWorkflowRunnerFanoutResumeTests|WorkflowFanoutMapReduceTests|WorkflowFanoutObservationBoundTests|FanoutArtifactEvidenceRunnerTests" > tmp/youtube-processing-builtins/ypb-03/test-fanout.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter PartialFanoutResumeTests > tmp/youtube-processing-builtins/ypb-03/test-cli-fanout.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCore/WorkflowModel.swift Sources/RielaCore/RuntimePublication.swift "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift" "Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift" Sources/RielaCore/WorkflowValidation.swift Sources/RielaCore/WorkflowRawValidation.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutTests.swift Tests/RielaCoreTests/DeterministicWorkflowRunnerFanoutResumeTests.swift > tmp/youtube-processing-builtins/ypb-03/swiftlint.log 2>&1'
grep -c "includeStepOutputs: fanout.includeStepOutputs" Sources/RielaCore/RuntimePublication.swift "Sources/RielaCore/DeterministicWorkflowRunner+NestedReservations.swift"
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build: exit 0.
- both test runs: exit 0 with 0 failures. Existing fanout tests must pass
  unmodified, apart from appended new tests.
- swiftlint: exit 0 with an empty log.
- grep: `RuntimePublication.swift` reports 1 and `NestedReservations` reports 2.

## Working protocol

### Shared-wave build protocol

Sibling plans in the same wave edit Swift sources in this same working
directory at the same time. `swift build` and `swift test` compile the whole
package, so a sibling's half-finished edit can break your build.

- Diagnostics only in non-owned files. When build or test fails and every
  compiler diagnostic points at a file outside this plan's `writePaths` and
  `sharedPaths`:
  - never edit, revert or reformat that file;
  - append a progress-log row with status `blocked-by-sibling`, the file path,
    the first diagnostic line, the log path and the UTC time;
  - wait about 60 seconds, then re-run the same command in the foreground, at
    most 6 times.
- SwiftPM lock. The message `Another instance of SwiftPM is already running
  using '.build'` means lock contention, not failure. Let the command run to
  exit.
- Owned files. A diagnostic in a file this plan owns is always this plan's to
  fix.
- Persistent block. If the block remains after the bounded re-runs:
  - finish all owned-file work;
  - record status `deferred-to-integration`, naming the blocking file and the
    last log path;
  - stop without touching that file.

  Cross-plan breakage is repaired serially after the wave joins, and the
  dispatch manifest's `integrationVerification` is the authoritative full gate.

Before each edit:

1. Read the file fresh.
2. Record the pre/post SHA-256 and the intent in the progress log.
3. If the hash has drifted, re-read the file and re-apply the edit.

Further rules:

- ypb-06 later adds one call to the `DefaultWorkflowValidator.validate`
  `nodeRegistry` loop in `WorkflowValidation.swift`. Keep that loop's structure
  intact.
- Do not run any git write commands.
- Put scratch files only under `tmp/youtube-processing-builtins/ypb-03/`.

## Done criteria

- All tests in the Tests section pass.
- The grep counts match.
- No change under `Sources/RielaCore/SQLite*`. Check with
  `git diff --quiet -- Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+NestedInvocations.swift`,
  which must exit 0.
- The progress log contains the hashes and the verification table.
