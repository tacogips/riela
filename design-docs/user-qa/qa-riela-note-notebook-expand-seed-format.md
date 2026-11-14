# Riela Note Notebook Expansion Seed Format

## Status

Resolved for this work package from the accepted requirement to create the
agent-conversation notebook through `saveConversation` and preserve the
existing conversation-turn contract.

## Decision

When **Expand with Agent** creates the agent-conversation notebook, the cached
compact summary appears as its initial persisted content using this decision:

- Call `saveConversation` with a fixed, visibly system-generated action prompt
  in the user field and the compact summary in the agent field.
- Preserve the existing one-note-per-turn `## User` / `## Agent`
  representation and perform no extra initial agent invocation.
- Treat a standalone summary note as a future non-goal because it requires a
  new conversation-seeding representation outside the accepted
  `saveConversation` seam.

## Invariants Regardless of Choice

- The persisted seed is the cached compact summary; no full source-note body is
  copied into the agent-conversation notebook.
- The seed note and every later turn note link to the compacted source-note ids
  with `source-citation` and AI provenance.
- Later agent answers receive only the compact summary and current question.
- The choice does not add another provider or workflow bundle.

## Rationale

The paired seed makes the Step 4 persistence plan unambiguous and reuses the
required service contract. It changes only the first note's user-visible
representation; lazy caching, summary-only grounding, later-turn persistence,
provenance links, and the single `note-notebook-compact` workflow remain
unchanged.
