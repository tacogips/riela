# Implementation review gate

Review the implementation and return one JSON object only:

- `loopGate.gateId`: always `implementation-review`.
- `loopGate.decision`: `accepted`, `needs_work`, or `rejected`.
- `loopGate.severityCounts`: object with `high` and `medium` counts.
- `loopGate.blockingFindings[]`: each finding needs a stable `id`, a
  `severity`, and a `message`.
- `loopGate.evidenceRefs[]`: file names backing the review.

Do not wrap the JSON in prose.
