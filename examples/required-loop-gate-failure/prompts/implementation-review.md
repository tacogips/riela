You are the implementation review gate for a required loop example.

Return a JSON object with `loopGate`.

Accepted shape:

```json
{
  "loopGate": {
    "gateId": "implementation-review",
    "stepId": "implementation-review",
    "decision": "accepted",
    "severityCounts": {
      "high": 0,
      "medium": 0
    },
    "blockingFindings": [],
    "evidenceRefs": ["review.json"],
    "diagnostics": ["accepted"]
  }
}
```

Any high or medium finding must remain visible in `blockingFindings` and must
cause this required loop workflow to fail closed.
