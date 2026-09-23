# note-rag-retrieval-fusion Expected Results

Stable assertions for deterministic verification with the bundled mock
scenario. Ignore `sessionId`, timestamps, note ids, and artifact paths.

## Validate

```bash
riela workflow validate note-rag-retrieval-fusion --workflow-definition-dir examples/note-rag-retrieval-fusion
```

Expected result: the workflow is valid.

## Run

```bash
riela workflow run note-rag-retrieval-fusion \
  --workflow-definition-dir examples/note-rag-retrieval-fusion \
  --mock-scenario examples/note-rag-retrieval-fusion/mock-scenario.json \
  --variables '{"noteRoot":"<tmp-note-root>","workflowInput":{"question":"How does retrieval-fusion search behave on a tagged notebook?"}}' \
  --output json
```

Expected result: the session completes and the final payload contains the
retrieval-fusion benchmark report.

## Stable payload assertions

- `seededPageCount` is `5` and `seededNoteIds` has 5 entries.
- `queryPlan` echoes the four mock queries (`strict`/`graph` =
  `hybrid reranking`, `context` = `atlas eviction`, `relaxed` =
  `eviction telemetry planner`).
- `strictSearch.resultCount` is `1`; its single result has
  `termCoverage: 1` and `isLinkedNeighbor: false`, and its note body contains
  `hybrid reranking`.
- `contextualSearch.resultCount` is `5`; the first result is the cache
  eviction page with `termCoverage: 1` (the `atlas` term matches through the
  notebook-title context column), and the remaining results have
  `termCoverage: 0.5`.
- `relaxedSearch.resultCount` is `3`; every result has `termCoverage` ≈ `0.333`
  and the hit set is the eviction, telemetry, and planner pages (RRF-tied
  ranks, so the order among the three may vary).
- `graphSearch.resultCount` is `3`; the first result is the hybrid reranking
  page with `isLinkedNeighbor: false`, followed by the two `retrieval-fusion`
  shared-tag neighbours (cache eviction and query planner pages) with
  `isLinkedNeighbor: true` and equal personalized-PageRank `rank` values. The
  `operations`-tagged pages do not appear.
- The `graph-neighbors` step (seeded with `strictSearch.noteIds`) has
  `resultCount: 2`: the cache eviction and query planner pages, each with
  `edgeKind: "shared-tag"` and `hopCount: 1`.
