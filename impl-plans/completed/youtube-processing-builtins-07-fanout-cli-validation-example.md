# ypb-07: includeStepOutputs callee validation, docs and mock-scenario example

```json
{
  "planId": "ypb-07-fanout-cli-validation-example",
  "planPath": "impl-plans/active/youtube-processing-builtins-07-fanout-cli-validation-example.md",
  "dependsOn": ["ypb-03-fanout-step-outputs-core"],
  "wave": "W2",
  "writePaths": [
    "Sources/RielaCLI/WorkflowValidateInspectCommands.swift",
    "Tests/RielaCLITests/FanoutIncludeStepOutputsTests.swift",
    "examples/fanout-include-step-outputs",
    "docs/workflows/json-data-processing.md",
    "impl-plans/progress/ypb-07-fanout-cli-validation-example.md"
  ],
  "sharedPaths": []
}
```

## Intent and context

Design source: `design-docs/specs/design-youtube-processing-builtins.md` §B,
"Validation" (CLI row) and "Docs, tests and example".

ypb-03 delivers the following. Read its progress log first.

- `WorkflowStepFanout.includeStepOutputs: [String]?`.
- Completed branch records carry `stepOutputs`.
- Core validation of same-workflow ids.

For `toWorkflowId` fanouts, ids must name steps of the callee workflow. Only
the CLI can check that, because only the CLI resolves callees.
`crossWorkflowCalleeResolutionDiagnostics` in `WorkflowValidateInspectCommands.swift`
already resolves callees with `FileSystemWorkflowCalleeResolver`. However, it
only iterates `DeterministicWorkflowRunner.crossWorkflowDispatchReferences`,
which requires `resumeStepId`.

## Non-goals

- Do not change RielaCore. If ypb-03's contract is missing, stop and report it.
  Do not reimplement it.
- Do not update the example registry or the mock count. ypb-09 does that.
- Do not modify existing examples.

## File-level changes

### `Sources/RielaCLI/WorkflowValidateInspectCommands.swift`

Add a private function:

```swift
func fanoutIncludeStepOutputsCalleeDiagnostics(workflow: WorkflowDefinition, resolution: WorkflowResolutionOptions, resolver: any WorkflowBundleResolving) async -> [WorkflowValidationDiagnostic]
```

`runtimeCapabilityDiagnostics` appends its result.

What it does:

- Iterate every step and every transition, by index, where
  `transition.toWorkflowId != nil` and `transition.fanout?.includeStepOutputs`
  is non-nil and non-empty.
- Resolve the callee once per workflow id, with a cache, through
  `FileSystemWorkflowCalleeResolver(resolver:baseResolution:).resolveCallee(workflowId:)`.
- If resolution fails, emit no extra diagnostic. The existing passes or the
  host requirement resolution already report unresolved callees. This avoids a
  duplicate.
- For each id that is not in `callee.workflow.steps.map(\.id)`, emit an
  `.error`:
  - path:
    `workflow.steps.<stepId>.transitions[<i>].fanout.includeStepOutputs[<j>]`;
  - message:
    `must reference a step of callee workflow '<workflowId>'; '<id>' does not exist`.

### `docs/workflows/json-data-processing.md`

After the `contextFrom` paragraphs, add a short subsection on
`fanout.includeStepOutputs`. It covers:

- the shape;
- the record example `stepOutputs`;
- the latest-accepted-execution rule;
- that steps which never ran are omitted;
- that failed records are unchanged;
- the same-workflow rule (ids must exist and not be the join);
- the cross-workflow rule (callee steps);
- the 8,000,000-byte bound;
- that omission keeps the join unchanged.

Do not add fenced json blocks that other tests parse. Search the Tests for
`json-data-processing.md` first. If any test parses the blocks, keep the count
valid and record what you did in the progress log.

### `examples/fanout-include-step-outputs/`

Create `workflow.json`, `mock-scenario.json`, `README.md` and
`EXPECTED_RESULTS.md`.

`workflowId` is `fanout-include-step-outputs` and equals the directory name.
All nodes are `riela/json-compose` v1, so the run is deterministic.

1. `source` composes `{"segments": [{"id": "s1"}, {"id": "s2"}]}`. It has a
   same-workflow fanout transition to `transcribe`:
   - `groupId: "segments"`, `itemsFrom: "/segments"`, `itemVariable: "segment"`;
   - `joinStepId: "join"`, `failurePolicy: "fail-fast"`,
     `writeOwnership: {"mode": "read-only"}`;
   - `includeStepOutputs: ["transcribe"]`.
2. `transcribe` composes a `transcript` that references `{{segment.id}}`, then
   transitions to `describe`.
3. `describe` composes a description, then transitions to `join`.
4. `join` composes `{"joined": "{{input.fanoutJoin}}"}`.

`mock-scenario.json` mocks only `source`, using the shape of the existing
examples, so the branch and join steps run for real. If the parity runner
requires a mock entry for every node, mock all of them and make the
`stepOutputs` assertion against the real fanout behavior with a mocked
`transcribe`.

Document the observed join, with `branches[].stepOutputs.transcribe`, in
`EXPECTED_RESULTS.md`.

### `Tests/RielaCLITests/FanoutIncludeStepOutputsTests.swift`

Imitate the temp-directory callee setup in
`Tests/RielaCLITests/WorkflowCommandCrossWorkflowDispatchTests.swift`.

## Tests (situation → expected)

- A temp caller fanout with `toWorkflowId: "callee"` and
  `includeStepOutputs: ["missing"]`, where the callee has steps `a` and `b` →
  `workflow validate` exits with failure. The JSON contains an error at
  `...fanout.includeStepOutputs[0]` naming `missing` and `callee`.
- The same with `["a"]` → exit success, and there is no includeStepOutputs
  diagnostic.
- A cross-workflow fanout without `resumeStepId` and with an unknown id → the
  error is still reported.
- `workflow validate fanout-include-step-outputs --workflow-definition-dir <repo>/examples`
  → success.
- `workflow run fanout-include-step-outputs --workflow-definition-dir <repo>/examples --mock-scenario <repo>/examples/fanout-include-step-outputs/mock-scenario.json --session-store <tmp> --max-steps 50 --output json`
  → exit success, and the join input or final output has two branches, each
  with `stepOutputs.transcribe.transcript` containing its segment id.

## Invariants and pitfalls

- Do not emit diagnostics for fanouts without `includeStepOutputs`. Existing
  validate outputs must stay byte-identical. The existing cross-workflow
  dispatch tests must still pass.
- Do not run callee resolution when no transition uses the field.
- Session stores and scratch files go under `tmp/`. Never write to `~/.riela`.

## Verification (evidence)

```bash
mkdir -p tmp/youtube-processing-builtins/ypb-07
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift build > tmp/youtube-processing-builtins/ypb-07/build.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swift test --filter "FanoutIncludeStepOutputsTests|WorkflowCommandCrossWorkflowDispatchTests|PartialFanoutResumeTests" > tmp/youtube-processing-builtins/ypb-07/test.log 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && .build/debug/riela workflow validate fanout-include-step-outputs --workflow-definition-dir examples --output json > tmp/youtube-processing-builtins/ypb-07/validate.json 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && .build/debug/riela workflow run fanout-include-step-outputs --workflow-definition-dir examples --mock-scenario examples/fanout-include-step-outputs/mock-scenario.json --session-store tmp/youtube-processing-builtins/ypb-07/sessions --max-steps 50 --output json > tmp/youtube-processing-builtins/ypb-07/run.json 2>&1'
arch -arm64 /bin/zsh -lc 'cd /Users/taco/gits/tacogips/riela && swiftlint lint --strict --quiet --no-cache Sources/RielaCLI/WorkflowValidateInspectCommands.swift Tests/RielaCLITests/FanoutIncludeStepOutputsTests.swift > tmp/youtube-processing-builtins/ypb-07/swiftlint.log 2>&1'
```

What each command must show:

- After this plan's final owned edit, build and test must reach exit 0 with 0
  failures at least once. The only exception is a recorded
  `deferred-to-integration` entry whose diagnostics are all in non-owned files.

- build: exit 0.
- test: exit 0 with 0 failures.
- validate: exit 0 and `valid: true`.
- run: exit 0, and `run.json` contains `stepOutputs`.
- swiftlint: empty log.

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

- Before each edit, read the file fresh and record the pre/post SHA-256 in the
  progress log.
- Do not run any git write commands.
- Put scratch files under `tmp/youtube-processing-builtins/ypb-07/`.

## Done criteria

- The callee diagnostics are implemented and tested.
- The example validates and runs with `stepOutputs`.
- The docs subsection exists.
- The progress log contains the hashes and the verification table.
