# loop-ci-gate-check

Demonstrates gating CI on a Riela loop's **required review gates** and publishing
loop findings as **SARIF 2.1.0**.

The workflow declares one required `implementation-review` gate with
`acceptWhen.maxHighFindings: 0`. The bundled mock scenario
(`mock-scenario-rejected.json`) makes the gate report a high-severity blocking
finding, so the loop fails closed — exactly the situation CI should catch.

## Reproduce locally

```bash
# 1. Run the loop with the deterministic mock scenario.
riela workflow run loop-ci-gate-check \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/loop-ci-gate-check/mock-scenario-rejected.json \
  --session-store /tmp/riela-loop-ci --output json

# 2. Gate CI on the required loop gates (exit 3 here because the gate has a
#    blocking high finding).
riela loop gates loop-ci-gate-check-session-1 --check \
  --session-store /tmp/riela-loop-ci

# 3. Export findings as SARIF for code scanning.
riela loop findings loop-ci-gate-check-session-1 --format sarif \
  --session-store /tmp/riela-loop-ci > riela-loop.sarif
```

## `loop gates --check` exit codes

| Code | Meaning |
| ---- | ------- |
| 0 | all required gates present and accepted |
| 3 | a required gate is rejected/needs-work/missing, or has blocking findings |
| 4 | no loop evidence recorded for the session |
| 1 | operational error (e.g. session not found) |

## GitHub Actions

`github-actions-loop-gate-check.yml` is a documentation-only workflow showing the
run → `loop gates --check` → `loop findings --format sarif` → `upload-sarif`
sequence. Copy it into a consuming repo's `.github/workflows/`.

See `EXPECTED_RESULTS.md` for the stable assertions verified with the mock
scenario.
