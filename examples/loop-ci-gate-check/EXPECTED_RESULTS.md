# Expected Results

Stable assertions for the CI gate-check example, verified with the bundled mock
scenario. Ignore `sessionId` suffixes, timestamps, and artifact paths.

## Validate

Command:

```bash
riela workflow validate loop-ci-gate-check --workflow-definition-dir ./examples --output json
```

Expected: `"valid": true` with no diagnostics.

## Inspect

Command:

```bash
riela workflow inspect loop-ci-gate-check --workflow-definition-dir ./examples --output json
```

Expected stable facts:

- `loop.required` is `true`
- the workflow declares one required `implementation-review` gate with
  `acceptWhen.maxHighFindings` = 0
- the `implementation-review` step is tagged as a loop `gate`

## Run (mock scenario)

Command:

```bash
riela workflow run loop-ci-gate-check --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-ci-gate-check/mock-scenario-rejected.json \
  --session-store <store> --output json
```

Expected: overall `status` is `failed` (fail-closed on the blocking required
gate); the recorded loop evidence contains one `implementation-review` gate with
a high-severity blocking finding `missing-regression-test`.

## Gate check

Command:

```bash
riela loop gates loop-ci-gate-check-session-1 --check --session-store <store>
```

Expected verdict (exit code **3**):

```json
{
  "exitCode": 3,
  "failingGates": ["implementation-review"],
  "requiredGates": ["implementation-review"],
  "sessionId": "loop-ci-gate-check-session-1",
  "verdict": "failed"
}
```

## SARIF export

Command:

```bash
riela loop findings loop-ci-gate-check-session-1 --format sarif --session-store <store>
```

Expected stable SARIF facts:

- `version` is `"2.1.0"`
- `runs[0].tool.driver.name` is `"riela-loop"`
- `runs[0].tool.driver.rules` contains one rule with `id` = `implementation-review`
- every result has `level` `"error"` (high severity), `ruleId`
  `implementation-review`, and `properties.sessionId` / `properties.gateId` set;
  `properties.severity` is `"high"`
- one result is the gate-policy summary
  (`required loop gate 'implementation-review' has 1 high findings; maximum is 0`)
  and one is the blocking finding
  (`The implementation lacks a regression test for the required gate behavior.`)
