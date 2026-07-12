# loop-baseline-regression-ops

A tour of the **loop operations CLI** around a single required review gate:

- `loop start` — runs the workflow with a **policy panel** (`loop_policy`
  record) emitted before the session starts, plus `--var` sugar for
  `--variables`.
- `loop baseline set|show|clear` — pin a known-good session as the
  workflow's baseline.
- `loop regress` — classify the newest (or an explicit) session against the
  baseline; exits **3** on regression.
- `loop diff --baseline` / `loop diff <a> <b>` — deterministic evidence
  diff (gate changes, blocking findings added/resolved, cost delta).
- `loop stats` — aggregate run/gate statistics for the workflow.
- `loop findings --format json` — flat findings export (SARIF also
  available; see `loop-ci-gate-check`).
- `loop promote` — advisory packaging-readiness report for the loop
  declaration (`ready: true` here; try deleting
  `loop.policies.mutation` to see `level: "enforced"` issues).

## Reproduce locally

```bash
STORE=/tmp/riela-loop-ops
WF=loop-baseline-regression-ops

# 1. Known-good run via `loop start`: prints the loop_policy panel first,
#    then the ordinary run events. Session 1 is accepted.
riela loop start $WF --var target=demo-branch \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-accepted.json \
  --session-store $STORE --output jsonl

# 2. Pin it as the baseline.
riela loop baseline set $WF $WF-session-1 \
  --note "known-good accepted run" --session-store $STORE
riela loop baseline show $WF --session-store $STORE

# 3. No regression yet (target defaults to the newest completed session).
riela loop regress $WF --session-store $STORE          # exit 0, "no-regression"

# 4. A later run regresses: the gate reports a high blocking finding, so the
#    required loop fails closed (run exits 1) and records session 2.
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-regressed.json \
  --session-store $STORE --output json

# 5. Classify it against the baseline (failed sessions are not auto-picked,
#    so name the target explicitly).
riela loop regress $WF --session $WF-session-2 --session-store $STORE   # exit 3

# 6. Inspect the delta and the aggregate picture.
riela loop diff --baseline $WF --session $WF-session-2 --session-store $STORE
riela loop diff $WF-session-1 $WF-session-2 --session-store $STORE
riela loop stats $WF --session-store $STORE
riela loop findings $WF-session-2 --format json --session-store $STORE

# 7. Advisory packaging readiness for the loop declaration.
riela loop promote $WF --workflow-definition-dir ./examples   # ready: true

# 8. Clean up the pin.
riela loop baseline clear $WF --session-store $STORE
```

## Exit-code contract

| Command | 0 | 3 | 4 | 1 |
| ------- | - | - | - | - |
| `loop regress` | no regression | regressed | baseline/target evidence missing | operational error |
| `loop diff --baseline` | diff rendered | — | baseline/evidence missing | operational error |
| `loop gates --check` | required gates accepted | gate failed | no loop evidence | operational error |

See `EXPECTED_RESULTS.md` for the stable assertions verified with the bundled
mock scenarios.
