# loop-stall-guard

Demonstrates the **loop convergence guard** (`loop.convergence`): when a gate
keeps rejecting with the *same finding fingerprints* round after round, the
runtime emits a `loop_stall` event and — with `onStall: "fail"` — fails the
session closed with `failureKind: "loopNotConverging"` instead of burning
iterations until `maxLoopIterations`.

The workflow is a single review gate step that routes back to itself while the
mocked reviewer sets `needs_work: true`:

```json
"convergence": {
  "maxRepeatedFindingRounds": 2,
  "onStall": "fail"
}
```

Findings are fingerprinted by stable `id` (falling back to content), so a
rejection with *changed* findings counts as progress and never false-stalls.

## Reproduce locally

```bash
# 1. Stalled loop: two consecutive rounds reject with the identical
#    high finding `flaky-retry-loop` -> loop_stall -> fail closed (exit 1).
riela workflow run loop-stall-guard \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-stall-guard/mock-scenario-stall.json \
  --session-store /tmp/riela-loop-stall --output jsonl

# 2. Healthy loop: each round changes the findings (progress), then accepts.
#    Same convergence guard, no stall, session completes (exit 0).
riela workflow run loop-stall-guard \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-stall-guard/mock-scenario-recovered.json \
  --session-store /tmp/riela-loop-stall --output jsonl
```

## What to look for

- The stall run's JSONL stream contains one `loop_stall` event carrying
  `loopStallGateId`, `loopStallViolationKind: "repeatedFindingsStall"`,
  `loopStallGateVisits`, `loopStallRepeatedRounds`, and the offending
  `loopStallFingerprints` (`["id:flaky-retry-loop"]`).
- The stall run's final record has `status: "failed"` and
  `failureKind: "loopNotConverging"`.
- The recovered run completes with three gate visits (two `needs_work`
  rounds with *different* fingerprints, then `accepted`).

`onStall: "warn"` keeps the session running and records the stall as a
residual risk in the loop evidence instead of failing.

Convergence also supports `maxGateVisits` to bound total visits per gate
regardless of finding fingerprints.

See `EXPECTED_RESULTS.md` for the stable assertions verified with the bundled
mock scenarios.
