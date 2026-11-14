# workflow-knowledge-base

A cross-workflow knowledge base built on kaiba long-term memory, fed by a
self-review step that runs before workflow completion — with verifiable
knowledge *usage* and knowledge-base *tidying* built into the deterministic
mock scenario.

Every run:

1. **Seeds knowledge (optional)**: `kb-seed` (`kaiba/memory-consolidate`)
   writes `workflowInput.seedKnowledge` entries into the base. This is how the
   mock scenario creates "mock memory" so the rest of the run can prove the
   knowledge is actually used; pass `[]` for no seeding (the workflow sets
   `allowEmptyEntries: true`, making the write a no-op).
2. **Recalls prior knowledge** (`kaiba/memory-recall`) for the task's topic
   and hands the prompt-ready `recallText` to the task worker, so the worker
   benefits from lessons learned in earlier runs of *any* workflow.
3. **Does the task** with an LLM worker whose node declares the
   `kb-run-journal` memory, so riela automatically journals the node's input
   and output into short-term memory. Because the journal captures the
   worker's *resolved input*, the seeded `recallText` inside it is hard
   evidence that the knowledge reached the worker; the worker also reports
   which entries it applied in `usedKnowledge`.
4. **Self-reviews the run**: loads the run journal (`riela/memory-load`,
   workflow scope) and extracts at most one piece of durable knowledge — a
   lesson, a mistake, an approach that worked or did not.
5. **Recalls related knowledge** for the candidate's topic, then a **merge
   judge** decides:
   - `skip` — nothing durable, or already known. The default when uncertain,
     so the base does not overfit to single runs.
   - `merge` — an existing note covers the topic: `kaiba/note-update`
     **replaces** the note body with one rewritten, generalized version that
     absorbs the candidate. When several existing notes overlap, the judge
     also tidies the base: it folds the redundant note's facts into the merge
     and marks that note for archiving. `archive-brief` (the judge's own
     session) re-emits the instruction after the merge write, and
     `kb-archive` collapses the redundant note to a one-line superseded
     pointer. Two bloated notes become one consolidated note.
   - `create` — clearly novel: `kaiba/memory-consolidate` writes a new note
     and auto-associates it in the note graph.
6. **Verifies** with a final recall and emits the knowledge-base state as the
   workflow output.

## Ownership split

riela owns the short-term run journal (`.riela/memory`, workflow-scoped,
disposable). kaiba owns the durable knowledge notes (note root, notebook +
`kb` topic tags + graph associations). Because kaiba notes are not keyed by
workflow id, every workflow that recalls with the same tags/queries shares the
same knowledge base. Use an extra topic tag per knowledge set (for example
`kb-riela-dev` vs `kb-ops`) when you want separate bases.

## How other workflows consume the knowledge

Add the same entry pattern anywhere:

```json
{
  "id": "recall-prior-knowledge",
  "addon": {
    "name": "kaiba/memory-recall",
    "version": "1",
    "config": { "query": "{{workflowInput.knowledgeQuery}}", "limit": 5 }
  }
}
```

and interpolate `{{recallText}}` into the downstream worker prompt. Agent
nodes can also search interactively with the `kaiba` note tools when
available.

## Run it (mock, deterministic)

See `EXPECTED_RESULTS.md` for the full command (the mock seeds two
overlapping retry-backoff notes and exercises the merge-and-tidy path) and
the step-by-step expected evidence:

- seeded knowledge is recalled (`resultCount: 2`) and verifiably delivered
  into the task worker's resolved input (visible in the run journal),
- the judge merges the candidate into the strongest note and archives the
  redundant one,
- the final recall shows one consolidated generalized note plus a one-line
  superseded pointer — the base learned something new *and shrank*.

The three agent steps plus `archive-brief` are mocked; the memory and kaiba
add-on steps run for real against the given roots.

## Run it (live)

Requires the `codex` CLI for the agent nodes. Drop `--mock-scenario` and point
`noteRoot` at your durable note root (or omit it to use the kaiba default).
Live runs share the knowledge base across every workflow using the same note
root.

## Compacting a grown knowledge base

Per-run tidying (the merge + archive path above) keeps a topic from
accumulating duplicates. For base-wide compaction, run a periodic
consolidation pass (for example from `riela events serve` with a cron
binding, as in `examples/memory-consolidation`): recall each topic with
`kaiba/memory-recall`, have an LLM node rewrite the topic's notes into one
generalized note, apply it with `kaiba/note-update`, and pointer-ize the
superseded notes the same way `kb-archive` does, so graph provenance
survives.
