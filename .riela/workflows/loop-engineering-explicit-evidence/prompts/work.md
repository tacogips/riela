Implement explicit loop evidence projection for legacy workflows.

Acceptance criteria:

- The default projector behavior stays backward-compatible and returns nil for
  workflows without loop metadata.
- A new explicit projection path can emit a manifest from session executions,
  workflow messages, workflow source, policy, and recovery even when
  workflow.loop is absent.
- Explicit `riela loop evidence` and `riela loop gates` can synthesize this
  manifest from the persisted CLI session resolution without mutating the
  stored session snapshot.
- Tests cover default nil behavior, explicit projection, CLI evidence output,
  and continued legacy status behavior.
