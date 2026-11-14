# Expected Results

Stable assertions for the convergence stall-guard example, verified with the
bundled mock scenarios. Ignore `sessionId` suffixes, timestamps, and artifact
paths.

## Validate

```bash
riela workflow validate loop-stall-guard --workflow-definition-dir ./examples --output json
```

Expected: `"valid": true` with no diagnostics.

## Run (stall scenario)

```bash
riela workflow run loop-stall-guard --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-stall-guard/mock-scenario-stall.json \
  --session-store <store> --output jsonl
```

Expected (CLI exit code **1**):

- exactly one `loop_stall` event:

```json
{
  "type": "loop_stall",
  "loopStallGateId": "implementation-review",
  "loopStallViolationKind": "repeatedFindingsStall",
  "loopStallAction": "fail",
  "loopStallGateVisits": 2,
  "loopStallRepeatedRounds": 2,
  "loopStallFingerprints": ["id:flaky-retry-loop"],
  "stepId": "review"
}
```

- the final record has `"status": "failed"`,
  `"failureKind": "loopNotConverging"`, and an `error` of the form
  `loop convergence stalled at gate 'implementation-review' with 2 visits and
  2 repeated finding rounds; fingerprints: [id:flaky-retry-loop]`.
- `nodeExecutions` is 2 — the guard stops the loop before a third round.

## Run (recovered scenario)

```bash
riela workflow run loop-stall-guard --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-stall-guard/mock-scenario-recovered.json \
  --session-store <store> --output json
```

Expected (CLI exit code **0**):

- `"status": "completed"` with `nodeExecutions` = 3
- `loopEvidence.gateCount` = 3, `needsWorkGateCount` = 2,
  `acceptedGateCount` = 1
- no `loop_stall` event — the second round's findings differ from the
  first, so the repeated-finding counter resets.
