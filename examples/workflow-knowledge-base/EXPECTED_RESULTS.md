# Expected Results — workflow-knowledge-base

## What this workflow does

1. `recall-prior-knowledge` — `kaiba/memory-recall` for `workflowInput.knowledgeQuery`; passes `task` and `recallText` to the worker.
2. `do-task` — LLM worker performs the task; its input/output are auto-journaled into the `kb-run-journal` memory.
3. `load-run-journal` — `riela/memory-load` (workflow scope) turns the journal into `recordsText`.
4. `self-review` — LLM worker extracts at most one durable knowledge candidate plus a `knowledgeQuery`.
5. `recall-related-knowledge` — `kaiba/memory-recall` for the candidate topic.
6. `merge-judge` — LLM worker decides `create` / `merge` / `skip`; labeled transitions on the boolean flags `create_knowledge` / `merge_knowledge` route accordingly (`skip` falls through to the output step).
7. `kb-create` (`kaiba/memory-consolidate`) or `kb-merge` (`kaiba/note-update`), then `recall-verify` re-reads the base.
8. `workflow-output` — emits the latest payload (the verification recall on create/merge, the judge payload on skip).

## How to run (mock)

```bash
riela workflow validate workflow-knowledge-base --workflow-definition-dir examples

riela workflow run workflow-knowledge-base \
  --workflow-definition-dir examples \
  --mock-scenario examples/workflow-knowledge-base/mock-scenario.json \
  --variables '{"memoryRoot":"./tmp/workflow-knowledge-base/memory","noteRoot":"./tmp/workflow-knowledge-base/notes","workflowInput":{"task":"Implement retry handling for the flaky sync API client.","knowledgeQuery":"backoff","runKey":"kb-demo-2026-08-21"}}'
```

## Expected mock output

The run terminates successfully on the `create` path. The final payload comes from `recall-verify`:

- `status`: `"ok"`
- `query`: `"backoff"`
- `resultCount`: `1` (>= 1)
- `noteIds`: one note id (the note written by `kb-create`)
- `recallText`: one line starting with `#<noteId>` whose text contains `exponential backoff with jitter`

Earlier steps observable via `riela session progress <session-id>`:

- `recall-prior-knowledge` returns `resultCount: 0` against an empty note root.
- `load-run-journal` returns `recordsText` containing the auto-journaled `do-task` inbox and outbox records (`#1` / `#2`).
- `kb-create` returns `entriesWritten: 1`, a non-empty `noteIds`, and `idempotentReplay: false`; the note carries the `kb` and `retry-backoff` topic tags.
- `kb-merge` does not execute (judge decided `create`).

## How to run (live)

Remove `--mock-scenario`; requires the `codex` CLI. The agent steps then really perform the task, self-review, and merge judgment; the knowledge base persists under your durable `RIELA_NOTE_ROOT`.

## Notes

- The judge's `skip` default keeps the base from overfitting to single runs; the `merge` path rewrites (not appends) an existing note, keeping the base compact.
- Re-running with the same `runKey` makes `kb-create` an idempotent replay (`idempotentReplay: true`, no duplicate note).
