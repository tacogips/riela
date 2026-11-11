# mrot-01: Terminal-reserve precondition (Bug B)

**planId**: mrot-01-terminal-reserve-precondition
**dependsOn**: none (wave 1)
**Design Reference**: design-docs/specs/design-manual-run-overlap-and-terminal-reserve.md §1 (Bug B), §4, §6 (loop reserve row); design-docs/specs/design-loop-engineering-convergence-and-operations.md "Reserved terminal steps" (amended 2026-11-11)
**Created**: 2026-11-11
**Progress log**: impl-plans/progress/mrot-01-terminal-reserve-precondition.md (edit only this log)
**Evidence root**: tmp/manual-overlap-terminal-reserve/mrot-01/

## Intent and context

In ART output-monitor (sessions output-monitor-session-251 and 255), the
2-step acyclic workflow `check -(labelled)-> remediate` with
`maxLoopIterations 1` has a default budget of 3 (`steps.count +
maxLoopIterations`, `Sources/RielaCore/DeterministicWorkflowRunner.swift`
around line 247). Its corridor is `[remediate]`. At `visitedSteps = 0`,
`DeterministicWorkflowRunner.redirectForTerminalReservationIfNeeded`
(`Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift:257`) sees
`remaining 3 <= max(3, 1)` and jumps straight to `remediate`. `check` never
runs. The reserve exists only to stop undeclared loops, so it must not fire
when the remaining reachable graph is acyclic and fits the remaining budget.

## Non-goals

- Do not change the reserve window arithmetic (`max(3, corridor.count)`, the
  `maxSteps >= reservedSteps` guard, `remainingSteps >= corridor.count`), the
  marker shape, the payload carry-over, or `maxStepsExceeded` behavior.
- Do not change `LoopTerminalCorridorSelector.select`, corridor
  construction, or `hasReachableDispatchBoundary`.
- Do not touch `DeterministicWorkflowRunner.swift` (read-only reference) or
  the existing `Tests/RielaCoreTests/DefaultLoopGuardTests.swift`.
- No changes to authored loop policy, `--disable-default-loop-guard`, or the
  convergence guard.

## File-level changes

### Sources/RielaCore/LoopTerminalCorridor.swift

Add one method to `LoopTerminalCorridorSelector`. The contract:

```swift
public func acyclicRemainingStepBound(workflow: WorkflowDefinition, originStepId: String) -> Int?
```

- Graph: the steps reachable from `originStepId` over **local** edges
  (`isLocalLinearEdge`). Edges whose `toStepId` is not a known step are
  ignored. **Every** local edge counts whatever its `label` or condition.
  Do not filter with `isUnconditional`.
- Return `nil` if any cycle is reachable: a self-edge, or a back edge found
  by a DFS with white/grey/black colouring.
- Otherwise return the number of steps on the longest path from the origin
  (counted) to a sink (counted). An isolated origin with no edges returns 1.
  Use memoized DFS, O(V+E). Use an explicit stack or memo so that a long
  chain (for example 15 steps or more) is safe, and do not use exponential
  path enumeration.
- Unknown `originStepId` → return `nil`. This is conservative and keeps the
  existing behavior.
- Imitate the traversal style of `reachableTransitionlessSinks` and
  `hasReachableDispatchBoundary` in the same file. Build the `stepsById`
  dictionary the same way.

### Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift

In `redirectForTerminalReservationIfNeeded`, after the existing `guard`
that computes `reservedSteps` and `remainingSteps` and returns `nil`
outside the window, and **before** `inputResolver.resolveInput` is called,
add exactly one early return:

- If `LoopTerminalCorridorSelector().acyclicRemainingStepBound(workflow:
  workflow, originStepId: currentStepId)` is non-nil **and** `<=
  remainingSteps`, return `nil`.

Pitfalls:

- `remainingSteps = maxSteps - visitedSteps` already includes the current
  step. The bound counts the current step too. Compare with `<=`, not `<`.
- Keep the check after the window guard so that the common out-of-window
  path stays cheap.
- Do not move or reorder the existing guards.

### Tests/RielaCoreTests/TerminalReservePreconditionTests.swift (new)

Copy the small fixture helpers you need (`workflow`, `step`, `transition`,
node payloads, and a scripted adapter) from
`Tests/RielaCoreTests/DefaultLoopGuardTests.swift`. Do **not** edit that
file. Each labelled edge must actually be selected at runtime: the scripted
adapter must emit an output whose `when` map makes the label true. Look at
how `GateSequenceAdapter` emits `when`. Run each regression test against the
unmodified code first and record in the progress log that it fails.

Tests (`situation -> expected`):

- 2 steps, `check` → `remediate` via a **labelled** edge (for example
  `has_issues`, made true by the adapter), `maxLoopIterations 1`, no
  `maxSteps` (default budget 3) → executions `[check, remediate]`, and the
  root output has **no** `loopGuardOutcome`.
- A 15-step chain `s1 → … → s15` where every edge is labelled and selected,
  `maxLoopIterations 1` (default budget 16) → executions are exactly
  `s1…s15` in order, with no `loopGuardOutcome`.
- Unit tests of `acyclicRemainingStepBound`:
  - self-loop → `nil`
  - 2-cycle reachable downstream → `nil`
  - diamond `a→b→d`, `a→c→x→d` → 4
  - linear chain of 3 → 3
  - origin with no transitions → 1
- Explicit `maxSteps` smaller than the acyclic longest path (for example a
  5-step labelled chain with `maxSteps 4`) → the redirect still happens
  inside the window (`trigger == "terminal-step-reserve"`). This proves the
  hard limit is preserved.

## Invariants

- `DefaultLoopGuardTests` passes unmodified. In particular
  `testTerminalReservationRedirectsBeforeNonTerminalDispatch` (the `revise`
  self-edge) still redirects.
- No public API besides `acyclicRemainingStepBound` is added.

## Acceptance criteria

- The 2-step and 15-step regression tests fail on base `c6e127b6` and pass
  after the change.
- All tests in the new file and in the existing `DefaultLoopGuard*` suites
  pass.

## Verification (run from repo root, write logs under the evidence root)

- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift build --target RielaCore'`: exit 0.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter TerminalReservePreconditionTests'`: all pass, at least 4 tests run.
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swift test --filter DefaultLoopGuard'`: all pass (covers DefaultLoopGuardTests and DefaultLoopGuardRecoveryTests).
- `/usr/bin/arch -arm64 /bin/zsh -lc 'swiftlint lint Sources/RielaCore/LoopTerminalCorridor.swift Sources/RielaCore/DeterministicWorkflowRunner+LoopPolicy.swift Tests/RielaCoreTests/TerminalReservePreconditionTests.swift'`: no new violations.

Record each command's exit status and complete log path in the progress log.

## Edit safety

Before each edit, re-read the target file and record its `shasum -a 256` in
the progress log. Record it again after the edit. If the pre-hash differs
from your last recorded post-hash, someone else changed the file: stop and
note the drift. Do not overwrite it.

## Done when

- [ ] Method added, with the early return in the redirect.
- [ ] New test file covers all the bullets above.
- [ ] The verification commands are green, with logs recorded.
- [ ] Progress log is complete: hashes, the failing-before evidence, and command results.
