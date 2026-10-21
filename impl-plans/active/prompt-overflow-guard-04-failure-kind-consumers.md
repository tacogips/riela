# Prompt Overflow Guard 04: Preserve Recovery for `promptTooLarge`

**planId**: `pog-04-failure-kind-consumers`
**Wave**: 2
**dependsOn**: `pog-01-contracts`
**Workflow Mode**: issue-resolution
**Issue Reference**: none. Incident: opus-luna 0.1.8 session-471. Current
run: `opus-luna-design-and-implement-review-loop-session-475`.
**Design Reference**: `design-docs/specs/design-agent-prompt-overflow-guard.md`
Part D, "Consumers of `failureKind`". This plan resolves review finding F1.
**Branch**: `feat/agent-prompt-overflow-guard`. Do not run any git write
command.
**Progress log**: `impl-plans/progress/pog-04-failure-kind-consumers.md`
**Evidence dir**: `tmp/prompt-overflow/pog-04-failure-kind-consumers/`
**planPath**: `impl-plans/active/prompt-overflow-guard-04-failure-kind-consumers.md`

**writePaths**:

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift`
- `Sources/RielaCLI/SessionCommands.swift`
- `Sources/RielaWork/DeterministicDirector.swift`
- `Sources/RielaWork/TaskGuardCoordinator.swift`
- `Tests/RielaCoreTests/PromptTooLargeRecoveryTests.swift`
- `Tests/RielaCLITests/PromptTooLargeResumeMessageTests.swift`
- `Tests/RielaWorkTests/PromptTooLargeRerunTests.swift`
- `impl-plans/progress/pog-04-failure-kind-consumers.md`
- `tmp/prompt-overflow/pog-04-failure-kind-consumers`

**sharedPaths**: none.

**artifactRoots**: `tmp/prompt-overflow/pog-04-failure-kind-consumers`.

## Intent and Context

`pog-01` reclassifies prompt overflow from `adapterFailure` to
`promptTooLarge`. Four existing gates grant recovery only to
`.adapterFailure`, so without this plan overflow failures would lose
`--retry-failed-step`, the CLI retry guidance, and Work Runtime reruns.

`promptTooLarge` is a refinement of `adapterFailure`. Each gate must accept
it as well. This plan adds no new route, rule or setting.

The gates as they are today:

- `Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift:63`:
  `retryableFailureKind = existing.failureKind == .adapterFailure || existing.failureKind == .policyBlocked`.
  The message at line 69 is
  `"--retry-failed-step requires an adapter-failed or policy-blocked current step with no accepted output"`.
- `Sources/RielaCLI/SessionCommands.swift:1001` (`private func nonBudgetFailureResumeMessage`):
  retry guidance is shown for `.adapterFailure || .policyBlocked`.
- `Sources/RielaWork/DeterministicDirector.swift:101`:
  `rerunnable = (kind == .adapterFailure && rules.rerunOnAdapterFailure) || (kind == .nodeTimeout && rules.rerunOnNodeTimeout)`.
- `Sources/RielaWork/TaskGuardCoordinator.swift:111`: the same predicate
  decides whether to record an attempts-budget violation.

## Non-Goals

- Do not change the classifier or the producer sites. `pog-01` owns them.
- No new `rerunOnPromptTooLarge` setting and no new director rule.
- Do not change the policy-blocked or node-timeout behavior.
- Do not touch the guard (`pog-03`) or fanout (`pog-02`).

## File-Level Changes

- **`DeterministicWorkflowRunner+Recovery.swift:63`.** Include
  `|| existing.failureKind == .promptTooLarge`. Change the message at line 69
  to `"--retry-failed-step requires an adapter-failed, prompt-too-large or policy-blocked current step with no accepted output"`.
  - A grep of Tests and Sources found no test asserting the old text. Check
    again with
    `grep -rn "requires an adapter-failed" Tests Sources`.
- **`SessionCommands.swift:1001`.** Include `.promptTooLarge` in the
  retry-guidance condition.
  - Change `private func nonBudgetFailureResumeMessage` to `func`
    (internal) so the test can call it through `@testable import RielaCLI`.
    Do not rename it or change its signature.
- **`DeterministicDirector.swift:101`.** Use
  `((kind == .adapterFailure || kind == .promptTooLarge) && rules.rerunOnAdapterFailure) || (kind == .nodeTimeout && rules.rerunOnNodeTimeout)`.
- **`TaskGuardCoordinator.swift:111`.** Apply the same predicate change.
- To avoid repeating the predicate, a small `fileprivate` helper per file is
  fine. Do not create a cross-module shared helper. That would add a new
  shared file that other plans might need to edit.

## Invariants

- `adapterFailure`, `policyBlocked` and `nodeTimeout` behave exactly as
  before.
- `promptTooLarge` gets exactly the recovery that `adapterFailure` gets, and
  nothing more.

## Tests

### `Tests/RielaCoreTests/PromptTooLargeRecoveryTests.swift` (new)

Imitate
`Tests/RielaCoreTests/DeterministicWorkflowRunnerFailureStateTests.swift:testExplicitRetryOfFailedAdapterStepKeepsSessionHistory`.

- A failing adapter throws
  `AdapterExecutionError(.providerError, "Prompt is too long")`. The
  `pog-01` classifier makes the session fail with `failureKind == .promptTooLarge`.
  - Resume without `retryFailedStep` → still failed, with 1 execution.
  - Resume with `retryFailedStep = true` and a succeeding `StaticAdapter` →
    `.completed` with executions `[.failed, .completed]`.
- A session failed with `.promptTooLarge` and `retryFailedStep` → it does not
  throw `resumeValidation`. Contrast: a session failed with
  `.maxStepsExceeded` plus `retryFailedStep` still throws, and the message now
  contains "prompt-too-large".

### `Tests/RielaCLITests/PromptTooLargeResumeMessageTests.swift` (new)

- A `WorkflowSession` with status `.failed` and `failureKind .promptTooLarge`
  → `nonBudgetFailureResumeMessage` contains `--retry-failed-step`.
- `.internalFailure` → does not contain it.
- Construct the session the way existing RielaCLITests build sessions; see
  `Tests/RielaCLITests/SessionAddonRecoveryTests.swift`. If construction is
  impractical, build the session through `InMemoryWorkflowRuntimeStore`.

### `Tests/RielaWorkTests/PromptTooLargeRerunTests.swift` (new)

- Director: imitate `Tests/RielaWorkTests/DeterministicDirectorTests.swift`
  lines 50-85 (`AttemptOutcome(sessionStatus: .failed, failureKind: .adapterFailure)`).
  - A `.promptTooLarge` attempt with `rerunOnAdapterFailure: true` and
    remaining attempt budget → resolution kind `.rerun`.
  - The same with `rerunOnAdapterFailure: false` → not a rerun.
- Guard coordinator: imitate `Tests/RielaWorkTests/WorkGuardDispatcherTests.swift`
  (`TaskGuardCoordinator(store:).evaluateAndApply`, lines 114-200), or call
  `TaskGuardCoordinator.violations(...)` (line 101).
  - An exhausted `maxAttempts` with a reconciled failed `.promptTooLarge`
    attempt and `rerunOnAdapterFailure: true` → contains the attempts-budget
    violation, the same as for `.adapterFailure`.

## Verification

1. `arch -arm64 /bin/zsh -lc 'swift build' 2>&1 | tee tmp/prompt-overflow/pog-04-failure-kind-consumers/build.log`
   must exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "PromptTooLargeRecoveryTests|PromptTooLargeResumeMessageTests|PromptTooLargeRerunTests|DeterministicDirectorTests|WorkGuardDispatcherTests|DeterministicWorkflowRunnerTests"' 2>&1 | tee tmp/prompt-overflow/pog-04-failure-kind-consumers/test.log`
   must exit 0 and show 0 failures.
3. `arch -arm64 /bin/zsh -lc "swiftlint lint --strict Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift Sources/RielaCLI/SessionCommands.swift Sources/RielaWork/DeterministicDirector.swift Sources/RielaWork/TaskGuardCoordinator.swift Tests/RielaCoreTests/PromptTooLargeRecoveryTests.swift Tests/RielaCLITests/PromptTooLargeResumeMessageTests.swift Tests/RielaWorkTests/PromptTooLargeRerunTests.swift" 2>&1 | tee tmp/prompt-overflow/pog-04-failure-kind-consumers/lint.log`
   must exit 0.
   - The intake says the 30 existing diagnostics are in untouched files. If
     `swiftlint` nevertheless reports a diagnostic on a line this plan did
     not change, fix it minimally only if it is inside an edited function.
     Otherwise record it in the progress log with the base evidence from
     `git show 3f921eb4:<path>`. Do not edit unrelated code.
4. `grep -rn 'promptTooLarge' Sources/RielaCore/DeterministicWorkflowRunner+Recovery.swift Sources/RielaCLI/SessionCommands.swift Sources/RielaWork/DeterministicDirector.swift Sources/RielaWork/TaskGuardCoordinator.swift`
   must show at least 4 hits.

## Done Criteria

- All four gates accept `.promptTooLarge`, and the new tests pass.
- Logs, exit codes, and pre- and post-edit sha256 values are recorded in the
  progress log.

## Overwrite Safety

- Re-read each file before editing it, and hash it before and after.
- Stop on unexpected drift.
- Only this plan edits these four source files.
