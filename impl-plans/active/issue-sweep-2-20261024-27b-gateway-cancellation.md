# ISW2-27b: agent-gateway turns surface cancellation as `CancellationError`

**Status**: Active (not started)
**planId**: ISW2-27b-gateway-cancellation
**Issue**: https://github.com/tacogips/riela/issues/27 (P2)
**Design Reference**: design-docs/specs/design-cancellation-and-orphan-session-resilience.md, section "2026-10-24 Contract (issue #27)", subsection "P2 contract"
**dependsOn**: ISW2-32-recovery-hydration (serial operator amendment)
**Progress log**: impl-plans/progress/issue-sweep-2-20261024-27b-gateway-cancellation.md
**Scratch root**: tmp/issue-sweep-2-20261024/isw2-27b/

## Intent and context

The CLI-agent preflight catch-alls cited in the original #27 design were removed. Every CLI agent now runs in-process through `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`. One gap remains: when the host task is cancelled, `withTaskCancellationHandler`'s `onCancel` cancels the ACP turn.

- **Gap 1.** The stream then ends with `stopReason == .cancelled`. Unless the watchdog deadline expired, `consumeGatewayTurn` (about lines 304-311) returns an ordinary turn, which later fails as invalid output or `adapterFailure`.
- **Gap 2.** An `ACPError` raised during the cancellation becomes `providerError` (about line 312).
- **Gap 3.** `executeWithRetry` (`Sources/RielaAdapters/AdapterUtilities.swift:139-158`) checks only the error type, not `Task.isCancelled`.

## Non-goals

- No session status change; ISW2-27a owns that.
- No change to `agentPreflightErrorDetail` (`AdapterUtilities.swift:98`). It has no callers and is a defensive helper.
- No change to timeout semantics: a deadline expiry stays `AdapterExecutionError(.timeout, ...)`.

## Write ownership

- `Sources/RielaAdapters/AgentGatewayNodeAdapter.swift`
- `Sources/RielaAdapters/AdapterUtilities.swift`
- `Tests/RielaAdaptersTests/AgentGatewayCancellationTests.swift` (new)
- `impl-plans/progress/issue-sweep-2-20261024-27b-gateway-cancellation.md` (new)

## File-level changes

1. **`consumeGatewayTurn`**, after the stream loop and before the `guard let response`:
   - Check `if Task.isCancelled && !watchdog.deadlineExpired { throw CancellationError() }`.
   - The existing `stopReason == .cancelled && watchdog.deadlineExpired` → `.timeout` check stays and keeps priority when the deadline expired.
2. **`catch let error as ACPError`**: `if Task.isCancelled { throw CancellationError() }` before the `providerError` mapping.
3. **`executeWithRetry`**, inside the catch: after `try rethrowIfCancellation(error)`, add `if Task.isCancelled { throw CancellationError() }`. It must come before `normalizeError` and before any retry sleep.
4. Follow the existing style of `rethrowIfCancellation`. Do not add a new public helper unless two call sites need it.

## Pitfalls

- `withGatewayTurnLifetime` must still run its cleanup on the cancellation path. Throwing inside `operation` already does this; do not bypass it.
- Do not treat every `stopReason == .cancelled` as cancellation. A vendor-side cancel while the host task is live keeps the current behaviour.
- The watchdog's `deadlineExpired` is read after the stream ends. Keep the read order, so that a timeout that raced with cancellation reports `.timeout` only when the deadline really expired.

## Test cases (`AgentGatewayCancellationTests`, new)

Imitate the fake executor and factory in `Tests/RielaAdaptersTests/AgentGatewayNodeAdapterTests.swift` (`AgentGatewayNodeAdapter(executorFactory: executor.factory)`).

- An executor whose turn suspends until cancelled; cancel the calling task → `execute` throws `CancellationError`, not `AdapterExecutionError`.
- An executor that throws a non-cancellation error after the host task is cancelled → `CancellationError`, not `.providerError` or `.policyBlocked`.
- `executeWithRetry` with an operation that throws `AdapterExecutionError(.providerError)` (retryable) while the task is cancelled → throws `CancellationError`. `normalizeError` is never called and no retry happens; count attempts to prove it.
- The deadline expires (short deadline, task not cancelled) → still `AdapterExecutionError(.timeout)`.
- A vendor `stopReason .cancelled` without host cancellation → the existing behaviour, unchanged.

## Verification (logs under tmp/issue-sweep-2-20261024/isw2-27b/)

Record `exitStatus`, `testsRun` and `failureCount` for each command:

1. `arch -arm64 /bin/zsh -lc 'swift build > tmp/issue-sweep-2-20261024/isw2-27b/build.log 2>&1'` → exit 0.
2. `arch -arm64 /bin/zsh -lc 'swift test --filter "AgentGatewayCancellationTests|AgentGatewayNodeAdapterTests|GatewayTurnLifetimeTests" > tmp/issue-sweep-2-20261024/isw2-27b/focused.log 2>&1'` → exit 0, 0 failures.
3. `arch -arm64 /bin/zsh -lc 'swiftlint lint --quiet Sources/RielaAdapters/AgentGatewayNodeAdapter.swift Sources/RielaAdapters/AdapterUtilities.swift Tests/RielaAdaptersTests/AgentGatewayCancellationTests.swift'` → no new warnings.

If a build break comes from a sibling-owned file, do not edit it. Record it and retry.

## Execution protocol

Per-edit fresh read, with pre/post hash snapshots under `tmp/issue-sweep-2-20261024/isw2-27b/snapshots/`. Write only to your own progress log.

## Done criteria

- [ ] All three gaps are closed.
- [ ] The 5 tests pass and verification 1-3 pass, with logs.
- [ ] The progress log states that no CLI-agent auth preflight exists anymore, with evidence: `grep -rn "authentication is unavailable" Sources` returns empty.

> Operator amendment (2026-10-24, after blocked-only wave 1 of session-1): the remaining plans run strictly serially to avoid shared-tree compile breakage; ISW2-27a also owns `Sources/RielaCLI/TaskDispatch+Handover.swift` and `Tests/RielaWorkTests/WorkStoreTakeoverTests.swift` (handover predicates/tests that must accept the new `cancelled` terminal). Continue from the existing uncommitted work in the tree.
