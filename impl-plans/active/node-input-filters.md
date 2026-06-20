# Node Input Filters Implementation Plan

**Status**: Implemented; post-review P2 findings fixed
**Workflow Mode**: issue-resolution
**Issue Reference**: node-input-filters
**Design Reference**: design-docs/specs/design-node-input-filters.md
**Created**: 2026-06-20
**Last Updated**: 2026-06-20

---

## Source of Truth

The accepted design in `design-docs/specs/design-node-input-filters.md` is the
source of truth. Step 3 accepted the design with no high or mid findings in the
available workflow context. Step 5 accepted the implementation plan with no
high or mid findings in
`.riela/sessions/runtime-records/design-and-implement-review-loop-feature-plan-session-1640/runtime-snapshot.json`.

## Summary

Add node-attached `inputFilters` so event-source workflow input starts only
matching nodes. The first supported filter kind is `telegram` with JavaScript
expressions evaluated through an isolated Swift JavaScriptCore package target.

## Scope

**Included**:

- Decode and validate authored node `inputFilters`.
- Evaluate multiple filters as OR conditions before node execution starts.
- Build a Telegram JavaScript filter context from normalized runtime variables.
- Treat filter parse or evaluation errors as logged non-matches.
- Record non-matching filtered nodes as skipped and continue through ordinary
  transitions, including skip-aware transition labels.
- Update `telegram-sdk-trio-chat` to use node-level filters instead of a persona
  router node.

**Excluded**:

- Non-Telegram filter kinds.
- Non-JavaScript filter languages.
- Remote or sandboxed JavaScript runtimes outside JavaScriptCore.
- Changing unfiltered node execution behavior.

## Task Breakdown

### TASK-001: Workflow Model and Validation

**Write Scope**:

- `Sources/RielaCore/WorkflowModel.swift`
- `Sources/RielaCore/WorkflowValidation.swift`
- `Tests/RielaCoreTests/WorkflowModelTests.swift`

**Deliverables**:

- Add an authored node `inputFilters` model with `kind`, `language`, and
  `expression`.
- Decode filters from workflow and node registry JSON without changing behavior
  when the field is absent.
- Validate supported values: `kind == "telegram"`, `language == "javascript"`,
  and non-empty `expression`.
- Add model tests for missing filters, one Telegram filter, multiple filters,
  and invalid validation diagnostics.

**Dependencies**: none.

**Completion Criteria**:

- Workflow JSON with `inputFilters` decodes deterministically.
- Invalid filter definitions fail validation before runtime.
- Existing workflows without filters keep their current decoding behavior.

### TASK-002: Isolated JavaScriptCore Evaluator

**Write Scope**:

- `Package.swift`
- `Sources/RielaJavaScript/`
- `Tests/RielaJavaScriptTests/`

**Deliverables**:

- Add a reusable `RielaJavaScript` target with no `RielaCore` dependency.
- Evaluate boolean JavaScript expressions against a JSON-compatible context.
- Return structured success, false, parse-error, and evaluation-error results.
- Add tests for true/false expressions, syntax failures, runtime failures,
  missing fields, regex matching, and non-boolean result handling.

**Dependencies**: none.

**Completion Criteria**:

- JavaScriptCore usage is isolated behind a small package API.
- Evaluator failures are observable to callers without throwing through the
  runner boundary.
- `swift test --filter JavaScriptCoreBooleanEvaluatorTests` passes.

### TASK-003: Telegram Filter Context and Evaluator Integration

**Write Scope**:

- `Sources/RielaCore/WorkflowInputFilterEvaluation.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Deliverables**:

- Build the `telegram` JavaScript context from normalized event runtime
  variables, accepting `event.provider == "telegram"` and
  `event.input.provider == "telegram"`.
- Expose `telegram.message.text`, `attachments`, `imagePaths`,
  `attachmentText`, `actor`, `conversation`, `chat`, `input`, plus `event`,
  `workflowInput`, and `input`.
- Evaluate filters in declaration order and return pass on the first matching
  filter.
- Log parse and evaluation errors and treat the failed filter as false.

**Dependencies**: TASK-001, TASK-002.

**Completion Criteria**:

- Multiple filters behave as OR conditions.
- Telegram variables match the accepted design context shape.
- Parse/evaluation failures skip the node without failing the workflow.

### TASK-004: Runner Skip Semantics

**Write Scope**:

- `Sources/RielaCore/DeterministicWorkflowRunner.swift`
- `Sources/RielaCore/DeterministicWorkflowRunner+InputFilters.swift`
- `Sources/RielaCore/RuntimeSession.swift`
- `Sources/RielaCore/RuntimeStore.swift`
- `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift`

**Deliverables**:

- Gate node startup with input-filter evaluation.
- Record non-matching filtered nodes as skipped step executions.
- Continue from skipped nodes through the first matching transition; unlabelled
  transitions match the skip context.
- Expose `input_filter_skipped: true` in `when` and
  `inputFilterSkipped: true` in payload.
- Complete terminal skipped nodes without root output.

**Dependencies**: TASK-003.

**Completion Criteria**:

- Filtered non-matches are visible in runtime history as skipped executions.
- Skip transitions are deterministic and compatible with existing transition
  selection rules.
- Terminal skipped nodes complete without producing misleading output.

### TASK-005: Example Workflow Migration

**Write Scope**:

- `examples/telegram-sdk-trio-chat/workflow.json`
- `examples/telegram-sdk-trio-chat/mock-scenario.json`
- `examples/telegram-sdk-trio-chat/EXPECTED_RESULTS.md`
- `examples/README.md`
- `Tests/RielaCLITests/RielaExampleParityTests.swift`
- `Tests/RielaCLITests/WorkflowCommandTests.swift`

**Deliverables**:

- Replace the persona router node in `telegram-sdk-trio-chat` with node-level
  Telegram filters.
- Keep the example's expected conversation behavior stable.
- Add CLI/example coverage proving validation and scenario-backed run behavior.

**Dependencies**: TASK-004.

**Completion Criteria**:

- The example validates through the Swift CLI.
- Mock scenario parity still passes and demonstrates filter-based node
  selection.

### TASK-006: Final Verification and Documentation Alignment

**Write Scope**:

- `impl-plans/active/node-input-filters.md`
- Existing docs touched by TASK-005 only.

**Deliverables**:

- Run focused and broad verification commands listed below.
- Record verification outcomes and known external failures in the progress log.
- Confirm no scratch files were created outside repository-root `tmp/`.

**Dependencies**: TASK-001 through TASK-005.

**Completion Criteria**:

- All focused input-filter tests pass.
- Example validation and mock run pass.
- `git diff --check` and `xcrun swiftlint` pass or have explicit documented
  environment blockers.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-001 | none | Establishes authored schema and validation contract. |
| TASK-002 | none | Provides independent JavaScript evaluator. |
| TASK-003 | TASK-001, TASK-002 | Needs decoded filters and JavaScript evaluator API. |
| TASK-004 | TASK-003 | Runner can only gate nodes after filter evaluation exists. |
| TASK-005 | TASK-004 | Example behavior depends on runtime skip semantics. |
| TASK-006 | TASK-001 through TASK-005 | Final evidence must cover the complete behavior. |

## Parallelizable Tasks

- TASK-001 and TASK-002 are parallelizable because their write scopes are
  disjoint except for final package integration review.
- TASK-005 documentation updates in `examples/README.md` may run in parallel
  with TASK-003 only if no example workflow or CLI test files are touched in the
  same pass.
- TASK-003, TASK-004, and TASK-005 are otherwise sequential because they share
  runtime behavior and test expectations.

## Verification

- `swift test --filter JavaScriptCoreBooleanEvaluatorTests`
- `swift test --filter WorkflowModelTests/testWorkflowDecodesNodeInputFilters`
- `swift test --filter DeterministicWorkflowRunnerTests/testTelegramInputFilter`
- `swift test --filter 'JavaScriptCoreBooleanEvaluatorTests|WorkflowModelTests/testWorkflowDecodesNodeInputFilters|DeterministicWorkflowRunnerTests/testTelegramInputFilter|WorkflowCommandTests/testScenarioBackedAddonResolverUsesMockResponseBeforeFallback|RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI'`
- `swift run riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples --output json`
- `swift run riela workflow run telegram-sdk-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json --variables '{"event":{"provider":"telegram","message":{"text":"mika hello"}}}' --output json`
- `xcrun swiftlint`
- `git diff --check`

## Progress Log Expectations

- Add one log entry per implementation session with completed tasks, in-progress
  tasks, blockers, verification commands run, and evidence paths under
  `tmp/node-input-filters/` when logs are captured.
- Do not mark a task complete until its deliverables, tests, and completion
  criteria are satisfied.
- If full `swift test` fails for unrelated local readiness issues, record the
  exact failing tests and keep focused input-filter verification separate.
- Keep scratch logs and ad-hoc inputs under `tmp/node-input-filters/`; never
  commit those artifacts.

## Progress Log

### 2026-06-20 Step 6 Implementation

**Status**: TASK-001 through TASK-006 implemented.

Completed work:

- Added `inputFilters` model decoding on node registry/runtime node models and
  validation for supported `telegram` + `javascript` filters.
- Added isolated `RielaJavaScript` JavaScriptCore boolean expression evaluator
  and tests for true, false, regex, syntax error, runtime error, and
  non-boolean results.
- Added Telegram filter context evaluation, including `event.message` and
  `event.input` normalized inputs, OR semantics, logged non-matches, and
  provider mismatch handling.
- Added runner skip semantics with `skipped` execution records, terminal skip
  completion, unlabelled transition continuation, and
  `input_filter_skipped`/`inputFilterSkipped` transition context.
- Reworked skipped-node transition publication to use the shared runtime
  publisher, preserving normal append-failure and unsupported-transition
  failure semantics.
- Preselected exactly one skipped-node transition before publication so
  overlapping default and skip-aware transitions do not enqueue extra messages
  and non-matching transitions complete without root output.
- Migrated `examples/telegram-sdk-trio-chat` from router-style mention routing
  to node-level Telegram `inputFilters`, with CLI and parity test coverage.
- Split new input-filter runner tests into
  `Tests/RielaCoreTests/WorkflowInputFilterRunnerTests.swift` so
  `Tests/RielaCoreTests/DeterministicWorkflowRunnerTests.swift` remains below
  1000 lines after this change.

Verification:

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter JavaScriptCoreBooleanEvaluatorTests`
  passed: 6 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowModelTests/testWorkflowDecodesNodeInputFilters`
  passed: 1 test.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter WorkflowInputFilterRunnerTests`
  passed after the review fixes: 10 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'JavaScriptCoreBooleanEvaluatorTests|WorkflowModelTests/testWorkflowDecodesNodeInputFilters|WorkflowModelTests/testWorkflowValidationRejectsUnsupportedNodeInputFilterKind|WorkflowInputFilterRunnerTests|WorkflowCommandTests/testScenarioBackedAddonResolverUsesMockResponseBeforeFallback|RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI'`
  passed after the review fixes: 20 tests.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples --output json`
  passed with `valid: true` and no diagnostics.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow run telegram-sdk-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json --variables '{"event":{"provider":"telegram","message":{"text":"mika hello"}}}' --output json`
  passed with `status: completed`; `mika-claude-sdk` and `send-mika-reply`
  completed while non-matching Yui/Rina steps were skipped.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
  passed with 0 violations.
- `git diff --check` passed with no output.
- `timeout 600 codex exec review --uncommitted --model gpt-5.5 --dangerously-bypass-approvals-and-sandbox`
  final rerun reported no discrete correctness issues after the review fixes.
- `swift test > tmp/node-input-filters/swift-test-final.log 2>&1` executed 488
  tests with 6 failures in unrelated readiness-gate checks:
  `RielaTestSurfaceCoverageTests.testEnvrcKeepsRielaKinkoDirenvExportValue`
  and
  `SwiftDeletionReadinessTests.testTrackedGateAllowsDeletionWithAcceptedReviewedTreeEvidence`.
  The focused input-filter, example parity, and JavaScriptCore tests passed.

Notes:

- No TypeScript files changed, so no TypeScript post-modification checks were
  required.
- Existing unrelated long-running verification artifacts are under
  `tmp/node-input-filters/`; no Step 6 scratch artifacts were created outside
  repository-root `tmp/`.
- No tracked `riela-package.json` manifest exists for the edited example
  workflow, so there was no package digest metadata to refresh.

## Completion Criteria

- [x] `inputFilters` are decoded, validated, and ignored only when absent.
- [x] Telegram JavaScript filters expose the accepted context shape.
- [x] Multiple filters are OR conditions.
- [x] Filter parse/evaluation errors are logged and treated as non-matches.
- [x] Non-matching filtered nodes are recorded as skipped and route through
  skip-aware ordinary transitions.
- [x] `telegram-sdk-trio-chat` demonstrates node-level Telegram filters.
- [x] Focused tests, example validation, example run, SwiftLint, and diff checks are
  completed or have explicit environment blockers documented in the progress
  log.
- [x] Step 5 implementation-plan review reports no high or mid findings before Step
  6 implementation starts.

## Addressed Feedback

| Source | Finding | Resolution |
| ------ | ------- | ---------- |
| Step 3 design review | Design accepted with no high or mid findings in available workflow context. | Plan traces directly to `design-docs/specs/design-node-input-filters.md` and keeps unsupported filter kinds/languages out of scope. |
| Step 5 implementation-plan review | Accepted with no high or mid findings in `design-and-implement-review-loop-feature-plan-session-1640`. | Step 6 implementation proceeded under the accepted plan contract. |
| Codex uncommitted implementation review | P2: skipped-node append failures left executions marked skipped/running. | Skipped nodes now publish through `InMemoryWorkflowOutputPublisher`; append failures mark the execution and session failed. Added regression coverage. |
| Codex uncommitted implementation review | P2: skipped-node unsupported transition shapes bypassed publisher checks. | Skipped nodes now use the shared publisher unsupported-transition checks. Added regression coverage for cross-workflow, resume-only, and fanout shapes. |
| Codex uncommitted implementation review rerun | P2: skipped-node publication could enqueue multiple matching transitions or persist skip payload as root output. | Skip publication now preselects only the first matching transition, or no transitions with root-without-output completion. Added regression coverage. |

## Codex-Agent References

No Codex-agent reference inputs were provided for this planning run. If later
inputs include codex-agent behavior, update TASK-003 through TASK-005 to trace
intentional parity or accepted divergences.

## Risks

- JavaScriptCore availability differs by platform; isolate evaluator tests and
  document any environment-specific blocker.
- Skip semantics can change graph traversal behavior; focused runner tests must
  cover unlabelled transitions, skip-aware labels, and terminal skipped nodes.
- Telegram runtime input may arrive under different normalized roots; TASK-003
  must cover both accepted provider locations.
- Example migration can mask behavior regressions if expected results are
  updated without asserting node-selection evidence.
