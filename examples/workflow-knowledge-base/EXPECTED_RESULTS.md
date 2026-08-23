# Expected Results — workflow-knowledge-base

## What this workflow does

1. `kb-seed` — `kaiba/memory-consolidate` writes `workflowInput.seedKnowledge`
   entries into the knowledge base (`allowEmptyEntries: true`, so `[]` is a
   no-op; the mock scenario seeds two overlapping retry-backoff notes).
2. `recall-prior-knowledge` — `kaiba/memory-recall` for
   `workflowInput.knowledgeQuery`; passes `task` and `recallText` onward.
3. `do-task` — LLM worker performs the task with the recalled knowledge in its
   prompt and reports `usedKnowledge`; its input/output are auto-journaled
   into the `kb-run-journal` memory.
4. `load-run-journal` — `riela/memory-load` (workflow scope) turns the journal
   into `recordsText`.
5. `self-review` — LLM worker extracts at most one durable knowledge candidate
   plus a `knowledgeQuery`.
6. `recall-related-knowledge` — `kaiba/memory-recall` for the candidate topic.
7. `merge-judge` — LLM worker decides `create` / `merge` / `skip` via the
   boolean flags `create_knowledge` / `merge_knowledge`. On merge it may also
   tidy the base: pick the strongest overlapping note as the merge target and
   mark a redundant note for archiving (`archive_note`, `archiveNoteId`,
   `archivedPointerBody`).
8. `kb-create` (`kaiba/memory-consolidate`) or `kb-merge`
   (`kaiba/note-update` body rewrite). After a merge, `archive-brief` (same
   session as the judge) re-emits the archive instruction and `kb-archive`
   replaces the redundant note's body with a short superseded pointer.
9. `recall-verify` re-reads the base; `workflow-output` emits the latest
   payload (the verification recall on create/merge, the judge payload on
   skip).

## How to run (mock)

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
      "runKey": "kb-demo-2026-08-21",
      "seedKey": "kb-seed-demo",
      "seedKnowledge": [
        { "content": "For flaky rate-limited APIs, exponential backoff with jitter stabilizes retries; fixed-interval backoff keeps failing under rate limiting.", "topicTags": ["kb", "retry-backoff"] },
        { "content": "Retrying flaky APIs at a fixed interval keeps failing under rate limiting; prefer exponential backoff.", "topicTags": ["kb", "retry-backoff"] }
      ]
    }
  }'
```

The exact `seedKnowledge` and `seedKey` above matter: seeded note ids are
deterministic for a fixed seed, and the mocked judge addresses those ids.

## Expected mock output

The run terminates successfully on the merge-and-tidy path with steps
`kb-seed → recall-prior-knowledge → do-task → load-run-journal → self-review →
recall-related-knowledge → merge-judge → kb-merge → archive-brief →
kb-archive → recall-verify → workflow-output`.

Observable evidence, via the final payload and
`riela session progress <session-id>`:

- `kb-seed` returns `entriesWritten: 2` (the two seeded notes, deterministic
  ids ending `…-1` and `…-2`).
- `recall-prior-knowledge` returns `resultCount: 2` — the seeded knowledge is
  found before the task runs.
- **Knowledge delivery proof**: `load-run-journal`'s `recordsText` contains
  the `do-task` inbox record, and that record's payload includes the seeded
  `recallText` — the prior knowledge verifiably reached the worker's input.
  The mocked `do-task` output also lists the applied entry in
  `usedKnowledge`.
- `merge-judge` returns `decision: "merge"` with `mergeNoteId: …-1`,
  a generalized `mergedBody`, and `archive_note: true` for `…-2`.
- `kb-merge` rewrites note `…-1`; `kb-archive` replaces note `…-2`'s body
  with `"Superseded by the consolidated note for this topic."`.
- `recall-verify` returns the consolidated note `…-1` with the merged,
  generalized body (backoff + jitter + max-attempts cap) and shows `…-2`
  only as the short superseded pointer — the knowledge base absorbed a new
  lesson while shrinking from two full notes to one.

## Variants

- Empty seed: `"seedKnowledge": []` makes `kb-seed` a no-op
  (`entriesWritten: 0`, requires the addon's `allowEmptyEntries: true`, which
  this workflow sets). With an empty base a live judge should decide `skip`
  or `create`; the mocked judge here targets seeded ids, so use a
  skip/create-shaped mock for empty-seed experiments.
- Re-running with the same `seedKey`/`runKey` replays idempotently: `kb-seed`
  reports `idempotentReplay: true` and no duplicate notes appear.

## How to run (live)

Remove `--mock-scenario`; requires the `codex` CLI. The agent steps then
really perform the task, self-review, and merge judgment; the knowledge base
persists under your durable `noteRoot` and is shared by every workflow using
the same note root.

## Notes

- The judge's `skip` default keeps the base from overfitting to single runs.
- The merge path rewrites (never appends) and the archive path collapses
  superseded notes to pointers, so the base absorbs lessons without growing.
