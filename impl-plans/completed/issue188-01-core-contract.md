# Issue 188 Plan 01: Core contract (step fields, effect outcome, retry clock, backoff math)

**Status**: Completed (2026-11-10; accepted by step7 adversarial review and combined-tree integration, issue #188)
**planId**: issue188-01-core-contract
**dependsOn**: (none; wave 1)
**Design Reference**: design-docs/specs/design-step-deadline-and-retry-policy.md (§3, §4.1, §5.4, §7)
**Issue**: tacogips/riela#188
**Created**: 2026-11-10
**Last Updated**: 2026-11-10

## Intent and context

Riela needs a per-step deadline (`deadlineMs`) and a bounded retry policy (`retry`) for add-on save steps. This plan owns only the **shared contracts** that the wave-2 plans compile against:
- issue188-03 (Notion classification)
- issue188-04 (step supervisor)
- issue188-05 (fanout expiry)

It must not change any runtime behaviour. Every new field is optional and defaults to `nil`, and every existing call site keeps compiling unchanged.

## Non-goals

- No supervisor, retry loop or fanout change. Those belong to plans 04 and 05.
- No validation rules. Those belong to plan 02.
- No Notion parsing. That belongs to plan 03.
- No changes to `Sources/RielaAdapters/AdapterUtilities.swift` (`RetryPolicy`/`executeWithRetry` stay as they are).
- No change to `DynamicWorkflowPolicy.swift`. Dynamic workflows keep rejecting the new keys.
- No GraphQL/SDL change. `WorkflowStepRef` is not a GraphQL DTO; the registry patch classifier defaults new paths to `sensitive`.

## File-level changes

### Sources/RielaCore/WorkflowStepRef.swift
- Add `public var deadlineMs: Int?` and `public var retry: WorkflowStepRetryPolicy?`.
- Append `deadlineMs: Int? = nil, retry: WorkflowStepRetryPolicy? = nil` as the **last** init parameters, after `placement`, so positional and labelled callers keep compiling.
- Keep synthesized `Codable`/`Equatable`. JSON keys are exactly `deadlineMs` and `retry`.

### Sources/RielaCore/WorkflowStepRetryPolicy.swift (new)

Pinned shapes (other plans depend on these names):

```swift
public enum WorkflowStepRetryJitter: String, Codable, Sendable, Equatable { case none, deterministic }
public struct WorkflowStepRetryPolicy: Codable, Equatable, Sendable {
  public var maxAttempts: Int; public var initialDelayMs: Int?; public var multiplier: Double?
  public var maxDelayMs: Int?; public var jitter: WorkflowStepRetryJitter?
  // effective accessors: effectiveInitialDelayMs (default 1000), effectiveMultiplier (2.0),
  // effectiveMaxDelayMs (30000), effectiveJitter (.none)
}
public protocol WorkflowRetryClock: Sendable { func now() -> Date; func sleep(until: Date) async throws }
public struct SystemWorkflowRetryClock: WorkflowRetryClock  // now() = Date(); sleep via Task.sleep, cancellation-aware
public enum StepRetryStopReason: String, Sendable {
  case succeeded, nonRetryable = "non-retryable", outcomeUnknown = "outcome-unknown"
  case retryExhausted = "retry-exhausted", deadlineExhausted = "deadline-exhausted"
  case stepDeadline = "step-deadline", retryAfterExceedsMaxDelay = "retry-after-exceeds-max-delay", cancelled }
public enum StepTimeoutKind: String, Sendable { case attempt, stepDeadline = "step-deadline" }
public enum StepRetryBackoff {
  /// Delay in ms after failed attempt `failedAttempt` (1-based), before Retry-After handling.
  public static func delayMs(policy: WorkflowStepRetryPolicy, failedAttempt: Int,
                             sessionId: String, executionId: String) -> Int
}
public enum StepRetryDiagnostics {
  /// " [rielaRetry attempts=<n> stopReason=<r> elapsedMs=<ms>[ timeoutKind=<k>][ effectOutcome=<o>][ queueWaitMs=<ms>]]"
  public static func suffix(attempts: Int, stopReason: StepRetryStopReason, elapsedMs: Int,
                            timeoutKind: StepTimeoutKind?, effectOutcome: AdapterEffectOutcome?, queueWaitMs: Int?) -> String
  public static let backstopGraceMs = 5000
}
```

Delay math (design §3.3):
1. `base = initialDelayMs * multiplier^(failedAttempt-1)`.
2. `d = min(base, maxDelayMs)`.
3. With `.deterministic` jitter: `d = d * (0.5 + 0.5 * u)`. Here `u` is the first 8 bytes of SHA-256 of the UTF-8 string `"<sessionId>/<executionId>/<attempt>"`, read as a big-endian UInt64 and divided by 2^64. `attempt` is the `failedAttempt` value.
4. Round down to Int ms.
5. Overflow-safe: compute in Double, then clamp to `maxDelayMs` before converting.

SHA-256: imitate `Sources/RielaCore/SpecialistSupervisorStore+StatusReplies.swift`, which uses `import Crypto` and `SHA256.hash(data:)`. RielaCore already depends on Crypto. **Do not add a new package dependency.**

### Sources/RielaCore/AdapterContracts.swift
- Add `public enum AdapterEffectOutcome: String, Codable, Sendable, Equatable { case notDispatched, rejected, unknown }`.
- Add `public var effectOutcome: AdapterEffectOutcome?` to `AdapterExecutionError`. Append the init param `effectOutcome: AdapterEffectOutcome? = nil` **last**, after `failureKind`.
- Equatable stays synthesized.

### Sources/RielaCore/DeterministicWorkflowRunner.swift
- Add `public var runStartedAt: Date?` to `DeterministicWorkflowRunRequest`. Add it as a stored var defaulting to nil, set after init the way `workflowRunId`/`parentSessionId` are set; do **not** add it to the long init.
- Add `public var retryClock: any WorkflowRetryClock` to `DeterministicWorkflowRunner`, with init param `retryClock: any WorkflowRetryClock = SystemWorkflowRetryClock()` appended **last** in `public init(...)` (around line 185).
- In `run` (near line 256, where `effectiveRequest` exists): `if effectiveRequest.runStartedAt == nil { effectiveRequest.runStartedAt = retryClock.now() }`. Put this **before** any step dispatch and before the call to `sessionExecutionAdmission`. A resume or rerun request arrives with nil, so it gets a fresh value, which is the design's fresh-window rule.

### Tests/RielaCoreTests/ManualWorkflowRetryClock.swift (new, test support shared by plans 04 and 05)
- `final class ManualWorkflowRetryClock: WorkflowRetryClock, @unchecked Sendable`. It is lock-protected and has these members:
  - `now()`.
  - `sleep(until:)`, which suspends until `advance(to:)` or `advance(by:)` moves the time to at least the target date.
  - `advance(byMs:)`.
  - `waitForSleepers(count:) async`, which lets tests synchronise without real sleeps.
- `sleep(until:)` **must** be cancellation-aware. Use `withTaskCancellationHandler`. On cancel, resume the stored continuation with `CancellationError` exactly once.
- If `until <= now`, return immediately.
- Pitfall: resuming a continuation twice. Guard every resume with the lock and remove the continuation from the table before resuming it.

### Tests/RielaCoreTests/StepRetryBackoffTests.swift (new)

## Invariants

- No behaviour change for existing workflows. Only fields, types and one `runStartedAt` assignment are added. `deadline(for:)` is untouched.
- All new init params have defaults, so a full `swift build` compiles every existing call site with zero edits elsewhere.
- Do not touch the `DeterministicWorkflowRunner+*.swift` extension files. They belong to plans 04 and 05.

## Test cases (StepRetryBackoffTests)

- policy `{maxAttempts:4}` → delays after attempts 1, 2, 3 are 1000, 2000, 4000.
- `{initialDelayMs:2000, multiplier:2, maxDelayMs:5000}` → 2000, 4000, 5000 (capped).
- `multiplier:1` → constant delay.
- `initialDelayMs:0` → 0.
- `.deterministic` jitter → the same (sessionId, executionId, attempt) gives the same value twice. The value is within `[d/2, d]`. A different executionId gives a different value for a fixture where the values differ (assert explicitly with fixed strings).
- A huge attempt number (60) gives no crash and the result is `maxDelayMs`.
- `JSONDecoder` decoding `WorkflowStepRef` with `"deadlineMs":600000,"retry":{"maxAttempts":4,"jitter":"deterministic"}` → fields populated. Without them → both nil. Round-trip encode is equal.
- `AdapterExecutionError(.providerError, "x")` has `effectOutcome == nil`, and existing equality still works.
- `StepRetryDiagnostics.suffix(...)` produces the exact format string, and omits nil fields.
- `ManualWorkflowRetryClock`: a sleeper resumes on advance, and a cancelled sleeper throws `CancellationError`.

## Verification (run from repo root; each must exit 0)

There is no per-plan full `swift build` gate. The full build runs only at serial integration. The focused `swift test` in step 2 already compiles every target, which proves that existing call sites still compile.

If a compile error in step 2 comes only from files in a **sibling plan's** writePaths, record it in the progress log as `sibling-blocked` and re-run after the sibling finishes. Never edit sibling files to fix it.

2. `mkdir -p tmp/issue-188 && arch -arm64 /bin/zsh -lc 'swift test --filter StepRetryBackoffTests 2>&1 | tee tmp/issue-188/p01-test.log; exit ${pipestatus[1]}'`. The log must show every new test passing and 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swift test --filter "WorkflowStepFailurePolicyTests|RunnerFailurePolicyTests|RunnerNonTerminalStepFailureTests" 2>&1 | tee tmp/issue-188/p01-regression.log; exit ${pipestatus[1]}'`. This proves there is no regression.
4. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaCore/WorkflowStepRetryPolicy.swift Sources/RielaCore/WorkflowStepRef.swift Sources/RielaCore/AdapterContracts.swift Sources/RielaCore/DeterministicWorkflowRunner.swift Tests/RielaCoreTests/ManualWorkflowRetryClock.swift Tests/RielaCoreTests/StepRetryBackoffTests.swift 2>&1 | tee tmp/issue-188/p01-lint.log; exit ${pipestatus[1]}'`. Expect no errors.

Concurrent workers share `.build`. SwiftPM serialises on its lock, so wait for it. Never delete `.build`.

## Edit safety

- Before each edit, re-read the file. Record `shasum -a 256 <file>` before and after in the progress log.
- If a file changed unexpectedly between your read and your edit (drift), re-read it and re-apply only your intent.
- Edit only the files listed in writePaths.

## Completion criteria

- [x] All symbols above exist with the exact names and shapes shown.
- [x] Verification 2–4 exit 0, with log paths recorded. There is no item 1; the full build belongs to integration.
- [x] This plan edited only its writePaths; the shared tree also contains sibling work.

## Progress Log

### Session: 2026-11-10
**Tasks Completed**: Plan authored (Opus).
**Tasks In Progress**: None.
**Blockers**: None.

### Implementation: 2026-11-10
- Implemented optional step fields, retry clock and backoff contracts, adapter effect outcome, diagnostics and cancellation-aware manual clock. No supervisor or fanout wiring is included.
- Focused tests: 3 passed, exit 0, `tmp/issue-188/issue188-01-core-contract/test-current.log`. Regression: 12 passed, exit 0, `tmp/issue-188/issue188-01-core-contract/regression-final.log`. Both ran on the moving shared tree.
- Selected-file strict lint and plan lint exit 0: `tmp/issue-188/issue188-01-core-contract/lint-current.log` and `tmp/issue-188/issue188-01-core-contract/plan-lint-current.log`.
- Earlier regression was sibling-blocked by `Sources/RielaCore/WorkflowRawValidation.swift` missing `nodeEntries`; `regression.log` records the failure and the final rerun passed. The initial test continuation type inference failure was fixed; `test.log` records it.
- Per-edit intentions and pre/post SHA-256 records are in `tmp/issue-188/issue188-01-core-contract/`; initial hashes are in `pre-sha256.txt`. Formal review, serial integration and commit are downstream.

### Current-tree verification: 2026-11-10
- Focused test: 3 passed; regression: 12 passed; both exit 0. Logs: `tmp/issue-188/issue188-01-core-contract/redispatch-test.log`, `tmp/issue-188/issue188-01-core-contract/redispatch-regression.log`.
- Plan lint and strict selected-file lint exit 0: `tmp/issue-188/issue188-01-core-contract/redispatch-plan-lint.log`, `tmp/issue-188/issue188-01-core-contract/redispatch-strict-lint.log`; selected paths: `tmp/issue-188/issue188-01-core-contract/redispatch-swift-files.nul`. Shared-tree results remain subject to serial integration.
