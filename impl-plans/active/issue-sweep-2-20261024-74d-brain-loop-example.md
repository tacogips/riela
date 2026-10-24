# ISW2-74d: `examples/brain-generated-workflow-loop`, catalog registration, docs

**Status**: Active (not started)
**planId**: ISW2-74d-brain-loop-example
**Issue**: https://github.com/tacogips/riela/issues/74
**Design Reference**: design-docs/specs/design-loop-engineering-brain-generated-workflow-loop.md, section "Example"
**dependsOn**: ISW2-74c-dynamic-workflow-dispatch (serial operator amendment)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-74d-brain-loop-example.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-74d/

## Intent and context

Add a runnable first-party example. Its outer workflow has one LLM brain node. Under `--mock-scenario` it generates and executes two **different** child workflows; the second is derived from the first one's structured result. It then finishes. Register the example in the examples catalog.

## Non-goals

- No Swift source changes.
- Do not run or modify `RielaExampleParityTests.testMockScenarioExamplesRunThroughSwiftCLI`. It is known red for `x-follower-ai-business-digest`.

## Write ownership

- `examples/brain-generated-workflow-loop` (new directory: `workflow.json`, `nodes/node-brain.json`, `prompts/brain.md`, `mock-scenario.json`, `README.md`, `EXPECTED_RESULTS.md`)
- `Tests/RielaCLITests/RielaExampleCatalog.swift`: add the name
- `Tests/RielaCLITests/RielaExampleParityTests.swift`: only `expectedMockScenarioCount`, 44 → 45
- `examples/catalog/workflow-composition-and-coding.md`: add one section
- `docs/workflows/brain-generated-workflow-loop.md` (new)
- `impl-plans/progress/issue-sweep-2-20261024-74d-brain-loop-example.md` (new)

## File-level changes

1. **`workflow.json`**
   - `workflowId: "brain-generated-workflow-loop"`, `defaults: {nodeTimeoutMs: 120000, maxLoopIterations: 6}`, `entryStepId: "brain"`.
   - One node, `{id:"brain", nodeFile:"nodes/node-brain.json"}`.
   - One step, `brain`, whose only transition is `{label:"execute_workflow", toStepId:"brain", dynamicWorkflow:{maxIterations:4, onFailure:"return", allow:{nodeTypes:["agent"], backends:["claude-code-agent"], models:["claude-opus-5-5"]}}}`.
   - When the brain emits `when.finish`, no transition matches and the session completes.
   - Imitate the structure of `examples/loop-stall-guard/workflow.json`.
2. **`nodes/node-brain.json`**
   - `executionBackend: "claude-code-agent"`, `model: "claude-opus-5-5"`, `agentSandbox: "read-only"`, `promptTemplateFile: "prompts/brain.md"`.
   - `output.jsonSchema`: the envelope schema from the design, a `oneOf` of execute_workflow and finish.
   - Imitate `examples/claude-riela-claude-worker/nodes/node-claude-task.json` (claude-code node) and `examples/loop-stall-guard/nodes/node-review.json` (output contract).
3. **`prompts/brain.md`**: give the objective, which is to inventory the small fixture data and verify its gaps. Ask for the next minimal workflow as an envelope that follows rules 9-10: inline prompts only, the allowed keys only, and a payload for every node. Show the previous result with `{{inbox.latest.output}}`, the inbound-payload variable that existing example prompts use (for example in `examples/*/prompts/*.md`).
4. **`mock-scenario.json`**: keyed by node id, as in `examples/loop-stall-guard/mock-scenario-recovered.json`.
   - `brain`: three responses.
     1. `when:{execute_workflow:true}`, with an envelope generating `generated-inventory` (one step and node `inventory`, `claude-code-agent`/`claude-opus-5-5`, inline `promptTemplate`).
     2. `when:{execute_workflow:true}`, with an envelope generating `generated-verify` (node `verify`), whose `input.missingVerification` equals the value the `inventory` mock returns.
     3. `when:{finish:true}`, with `{decision:"finish", rationale, finalResult:{inventory..., verification...}, evidenceRefs:[...]}`.
   - `inventory`: one response with payload `{items:[...], missingVerification:"checksum-of-fixture-a"}`.
   - `verify`: one response with payload `{verified:"checksum-of-fixture-a", ok:true}`.
   - Generated payloads must not use `output.nativeStructuredOutput` or any other key outside the rule 9 allowlist (review note DR-74-3).
5. **`README.md`**: purpose, the live command, the mock command, and the safety rules (deny-by-default, session-scoped). **`EXPECTED_RESULTS.md`** asserts:
   - status `completed`;
   - exactly two child sessions, whose `parentSessionId` and `rootSessionId` equal the brain session;
   - `generatedWorkflow.iteration` values 1 and 2;
   - two distinct `definitionDigest`s;
   - iteration 2's input `missingVerification` equals iteration 1's `rootOutput.missingVerification`;
   - root output `decision == "finish"`;
   - three brain executions.

   Include the exact `riela session status` / `session export` commands used to check each assertion.
6. **Catalog**: add `"brain-generated-workflow-loop"` to `rielaExampleWorkflowNames()` in alphabetical position, set `expectedMockScenarioCount = 45`, and add a section to `examples/catalog/workflow-composition-and-coding.md` imitating the `workflow-call-live-echo` section.
7. **`docs/workflows/brain-generated-workflow-loop.md`**: the user-facing contract.
   - authored `dynamicWorkflow` fields and defaults;
   - the envelope;
   - the `dynamicWorkflowResult` shape;
   - the allowlist summary;
   - iteration and limit behaviour;
   - resume semantics;
   - how to inspect the iterations.

   Link the design.

## Pitfalls

- Mock scenarios match responses by node id, so the generated node ids must be exactly `inventory` and `verify`.
- `maxLoopIterations` must stay at 6, above `maxIterations` (4), or the default loop guard fires first.
- Do not author `prompts/*.md` paths inside generated payloads; rule 9 rejects `*TemplateFile`.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-74d/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-74d/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow validate brain-generated-workflow-loop --workflow-definition-dir ./examples > tmp/issue-sweep-2-20261024/isw2-74d/validate.log 2>&1'` → exit 0, no errors and no warnings.
3. `arch -arm64 /bin/zsh -lc '.build/debug/riela workflow run brain-generated-workflow-loop --workflow-definition-dir ./examples --mock-scenario ./examples/brain-generated-workflow-loop/mock-scenario.json --session-store "$PWD/tmp/issue-sweep-2-20261024/isw2-74d/store" --output json > tmp/issue-sweep-2-20261024/isw2-74d/run.json 2>&1'` → exit 0, status `completed`.
4. Run the `EXPECTED_RESULTS.md` inspection commands against the same `--session-store`, saving the logs. Every assertion must hold; record each one with its exit status.
5. `arch -arm64 /bin/zsh -lc 'swift test --filter RielaExampleParityTests --skip testMockScenarioExamplesRunThroughSwiftCLI > tmp/issue-sweep-2-20261024/isw2-74d/parity.log 2>&1'` → exit 0. This checks the catalog names and the count.

## Execution protocol

Per-edit fresh read, with pre/post hash snapshots under `tmp/issue-sweep-2-20261024/isw2-74d/snapshots/`. Write only to your own progress log.

## Done criteria

- [ ] The example directory contains all 6 files.
- [ ] Verification 1-5 pass, with logs.
- [ ] The progress log records the two child session ids and both digests.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.
