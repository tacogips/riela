# QA: step deadline and retry policy (tacogips/riela#188)

These questions do not block implementation. Each one has a default chosen in
`design-docs/specs/design-step-deadline-and-retry-policy.md`. The user may override a
default later.

## Q1. Should an ambiguous Notion create be reconciled automatically?

- Default: **no**. Notion has no idempotency key, and `findChildPage` matches on title,
  which is not unique: an older page with the same title may already exist. Riela
  reports `effectOutcome=unknown`, stops, and the caller keeps the item (fanout
  `collect-partial`).
- Alternative for later: an opt-in reconcile mode in which ART writes a deterministic
  marker property and Riela queries for it before it retries. That needs a
  notion-gateway query capability and an ART schema change.

## Q2. Should an operator `session resume`/`rerun` refuse to re-execute a step that failed with `effectOutcome=unknown`?

- Default: **unchanged behaviour**. Resume and rerun are explicit operator actions.
  The failure reason shows `effectOutcome=unknown`, so the operator can decide.
- Alternative: block it unless the operator passes `--acknowledge-unknown-outcome`.
  This is a separate change to resume semantics.

## Q3. ART concrete step ids and values

- Default: use the values in design §9 (save step `timeoutMs` 180000, `deadlineMs`
  600000, 4 attempts with delays of 2 s, 4 s and 8 s capped at 60 s, deterministic
  jitter; fanout `collect-partial`; json-route `deadlineMs` 120000).
- Save steps must use `failurePolicy: "fail"` (the default), not `advisory`. Otherwise a
  failed save can produce a `completed` branch record.
- Riela retains unresolved items only as runtime evidence in the current run: the
  failed execution and the failed join record. Carrying them into the next hourly run
  is ART's responsibility.
- The ART repository was not readable from this design sandbox. The later ART Opus/Terra
  integration maps these values onto the real step ids in `workflows/art/workflow.json`.
