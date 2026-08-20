# workflow-knowledge-base

A cross-workflow knowledge base built on kaiba long-term memory, fed by a self-review step that runs before workflow completion.

Every run:

1. **Recalls prior knowledge** (`kaiba/memory-recall`) for the task's topic and hands the prompt-ready `recallText` to the task worker, so the worker benefits from lessons learned in earlier runs of *any* workflow.
2. **Does the task** with an LLM worker whose node declares the `kb-run-journal` memory, so riela automatically journals the node's input and output into short-term memory.
3. **Self-reviews the run**: loads the run journal (`riela/memory-load`, workflow scope) and extracts at most one piece of durable knowledge — a lesson, a mistake, an approach that worked or did not.
4. **Recalls related knowledge** for the candidate's topic, then a **merge judge** decides:
   - `skip` — nothing durable, or already known. The default when uncertain, so the base does not overfit to single runs.
   - `merge` — an existing note covers the topic: `kaiba/note-update` **replaces** the note body with one rewritten, generalized version that absorbs the candidate. This is compaction: the base absorbs knowledge without growing.
   - `create` — clearly novel: `kaiba/memory-consolidate` writes a new note and auto-associates it in the note graph.
5. **Verifies** with a final recall and emits the knowledge-base state as the workflow output.

## Ownership split

riela owns the short-term run journal (`.riela/memory`, workflow-scoped, disposable). kaiba owns the durable knowledge notes (note root, notebook + `kb` topic tags + graph associations). Because kaiba notes are not keyed by workflow id, every workflow that recalls with the same tags/queries shares the same knowledge base. Use an extra topic tag per knowledge set (for example `kb-riela-dev` vs `kb-ops`) when you want separate bases.

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

and interpolate `{{recallText}}` into the downstream worker prompt. Agent nodes can also search interactively with the `kaiba` note tools when available.

## Run it (mock, deterministic)

```bash
riela workflow validate workflow-knowledge-base --workflow-definition-dir examples

riela workflow run workflow-knowledge-base \
  --workflow-definition-dir examples \
  --mock-scenario examples/workflow-knowledge-base/mock-scenario.json \
  --variables '{
    "memoryRoot": "./tmp/workflow-knowledge-base/memory",
    "noteRoot": "./tmp/workflow-knowledge-base/notes",
    "workflowInput": {
      "task": "Implement retry handling for the flaky sync API client.",
      "knowledgeQuery": "backoff",
      "runKey": "kb-demo-2026-08-21"
    }
  }'
```

The three agent steps are mocked; the memory and kaiba add-on steps run for real against the given roots, so the final recall proves a real note was written and is retrievable.

Re-running with the same `runKey` is an idempotent replay: `kb-create` reports `idempotentReplay: true` and no duplicate note appears. A `merge`-shaped judge output (`merge_knowledge: true` with `mergeNoteId`/`mergedBody`) exercises the compaction path: `kaiba/note-update` rewrites the existing note in place instead of adding a second one.

## Run it (live)

Requires the `codex` CLI for the three agent nodes. Drop `--mock-scenario` and point `noteRoot` at your durable note root (or omit it to use the kaiba default). Live runs share the knowledge base across every workflow using the same note root.

## Compacting a grown knowledge base

When the base grows past a comfortable recall size, run a periodic consolidation pass (for example from `riela events serve` with a cron binding, as in `examples/memory-consolidation`): recall each topic with `kaiba/memory-recall`, have an LLM node rewrite the topic's notes into one generalized note, apply it with `kaiba/note-update`, and retag superseded notes (for example `kb-archived`) instead of deleting them so graph provenance survives.
