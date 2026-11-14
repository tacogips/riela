# Implementation review gate

Review the current implementation state and return one JSON object only:

- `loopGate.gateId`: always `implementation-review`.
- `loopGate.decision`: `accepted`, `needs_work`, or `rejected`.
- `loopGate.blockingFindings[]`: each finding needs a stable `id`, a
  `severity` (`high`/`medium`/`low`), and a `message`. Reuse the same `id`
  and `message` only when the finding is genuinely unchanged from the
  previous round — the runtime fingerprints findings to detect stalled
  loops.
- `needs_work`: boolean; `true` routes the workflow back to this review
  step for another round.

Do not wrap the JSON in prose.
