# Expected Results

Stable assertions for the baseline/regression operations example, verified
with the bundled mock scenarios. Ignore `sessionId` suffixes, timestamps, and
artifact paths. `$WF` is `loop-baseline-regression-ops`.

## Validate / promote

```bash
riela workflow validate $WF --workflow-definition-dir ./examples --output json
riela loop promote $WF --workflow-definition-dir ./examples
```

Expected: `"valid": true`; promote reports `{"issues": [], "ready": true}`.

## loop start (accepted scenario)

```bash
riela loop start $WF --var target=demo-branch \
  --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-accepted.json \
  --session-store <store> --output jsonl
```

Expected (exit **0**): the **first** emitted record is the policy panel —

```json
{
  "type": "loop_policy",
  "panel": {
    "workflowId": "loop-baseline-regression-ops",
    "required": true,
    "loopKind": "design-implement-review",
    "gates": [{"gateId": "implementation-review", "required": true, "stepId": "implementation-review"}],
    "allowedBackends": ["codex-agent"],
    "requiredWorkerModel": "gpt-5.5",
    "nestedProcessPolicy": {"codex": "deny", "riela": "deny"},
    "commit": "deny",
    "push": "deny",
    "evidenceRequiredSections": ["review"]
  }
}
```

— followed by the ordinary `session_started` … `session_completed` events;
the session completes with the gate `accepted`.

## Baseline

```bash
riela loop baseline set $WF $WF-session-1 --note "known-good accepted run" --session-store <store>
riela loop baseline show $WF --session-store <store>
```

Expected: both exit **0**; `show` returns `"existed": true`, the pinned
`sessionId`, and the note. `loop baseline clear` exits 0 and `show`
afterwards returns `"existed": false`.

## Regress before the bad run

```bash
riela loop regress $WF --session-store <store>
```

Expected (exit **0**): `"verdict": "no-regression"` — the newest *completed*
session with evidence is the baseline itself.

## Regressed run

```bash
riela workflow run $WF --workflow-definition-dir ./examples \
  --mock-scenario ./examples/$WF/mock-scenario-regressed.json \
  --session-store <store> --output json
```

Expected (exit **1**): required gate `needs_work` with one authored high
finding fails the session closed. The loop evidence additionally synthesizes
two `gate-policy-…` findings (decision mismatch, max-high-findings breach),
so the recorded blocking-finding count is **3**.

## Regress against the bad session

```bash
riela loop regress $WF --session $WF-session-2 --session-store <store>
```

Expected (exit **3**): `"verdict": "regressed"` with two regressions —

```json
[
  {"kind": "required-gate-downgrade", "gateId": "implementation-review",
   "detail": "required gate 'implementation-review' was accepted in baseline; target is needs_work"},
  {"kind": "blocking-findings-added", "gateId": "implementation-review",
   "detail": "required gate 'implementation-review' gained 3 blocking finding(s)"}
]
```

## Diff

```bash
riela loop diff --baseline $WF --session $WF-session-2 --session-store <store>
riela loop diff $WF-session-1 $WF-session-2 --session-store <store>
```

Expected (exit **0**): both render the same `schemaVersion: 1` diff with
`gateChanges[0]` = `accepted` → `needs_work`
(`severityCountsDelta.high` = 1), three entries in
`blockingFindingsAdded` (the authored `regressed-error-handling` plus the two
synthesized gate-policy findings), and a diagnostic noting the cost delta is
partial because mock runs record no usage.

## Stats

```bash
riela loop stats $WF --session-store <store>
```

Expected: `windowRuns` = 2, `completedRuns` = 1, `acceptedRuns` = 1,
`failedRuns` = 1, `gateFailureCounts` = `{"implementation-review": 1}`,
`lastAcceptedSessionId` = session 1.

## Findings (JSON)

```bash
riela loop findings $WF-session-2 --format json --session-store <store>
```

Expected: three findings, each `"level": "error"` / `"severity": "high"`
with `gateId` `implementation-review`: the two synthesized `gate-policy-…`
findings and the authored `regressed-error-handling`.
