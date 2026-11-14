# note-rag-retrieval-fusion

A self-contained benchmark of kaiba's retrieval-fusion RAG pipeline
(kaiba v0.1.12, `design-docs/specs/note-retrieval-fusion.md`). The workflow
seeds a small tagged notebook and then probes it with four searches whose
results make each retrieval technique visible in one JSON report:

| Stage | Technique | What the output shows |
| --- | --- | --- |
| `strict-search` | RF1 BM25 with weighted columns | one full-coverage hit (`termCoverage: 1`) |
| `contextual-search` | RF1 contextual index | a page hits on a term that appears **only in the notebook title** — zero hits without the context column |
| `relaxed-search` | RF2 relaxed matching + reciprocal rank fusion | three partial hits, each with `termCoverage ≈ 0.33`, because no single page contains all three query terms |
| `graph-search` | RF3 personalized PageRank neighbours | the direct hit first, then shared-tag neighbours flagged `isLinkedNeighbor: true`, ordered by PageRank mass |
| `graph-neighbors` | bounded graph traversal | the neighbour edges with `edgeKind`, `weight`, and `hopCount` |

## Corpus

One notebook, "Atlas Retrieval Playbook", with five pages:

1. **Hybrid reranking pipeline** — tags `retrieval-fusion`, `ranking`
2. **Cache eviction policy** — tags `retrieval-fusion`, `index-maintenance`
3. **Telemetry dashboards** — tag `operations`
4. **Query planner fallback** — tags `retrieval-fusion`, `planner`
5. **Rollout checklist** — tag `operations`

The word `atlas` appears only in the notebook title; `eviction`, `telemetry`,
and `planner` each appear in exactly one page body; `hybrid reranking`
co-occurs only in page 1.

Every tag is declared with the seeded `topic` tag class
(`{"name": "...", "class": "topic"}`): kaiba's graph traversal builds
shared-tag edges only from class-bearing, non-structural tags, so classless
tags would leave the graph stages without shared-tag neighbours.

## Probe queries (mock scenario)

- strict: `hybrid reranking` → page 1, `termCoverage: 1`
- contextual: `atlas eviction` → page 2 at full coverage (its FTS row carries
  the notebook title as context); every other page matches only `atlas` and
  trails at `termCoverage: 0.5`
- relaxed: `eviction telemetry planner` → pages 2, 3, 4 fused by RRF at
  `termCoverage: 1/3`
- graph: `hybrid reranking` with `includeLinked: true` → page 1 plus its
  `retrieval-fusion` shared-tag neighbours (pages 2 and 4) by PageRank;
  the `operations` pages stay out, showing the expansion is bounded

## Run

```bash
riela workflow run note-rag-retrieval-fusion \
  --workflow-definition-dir examples/note-rag-retrieval-fusion \
  --mock-scenario examples/note-rag-retrieval-fusion/mock-scenario.json \
  --variables '{"noteRoot":"/tmp/rag-fusion-demo-notes","workflowInput":{"question":"How does retrieval-fusion search behave on a tagged notebook?"}}' \
  --output json
```

Use a fresh `noteRoot` per run: the seed step always creates a new notebook, so
re-running against the same root duplicates pages and shifts the counts.

Without `--mock-scenario`, the `plan-queries` step asks a real model to derive
the four probe queries from `workflowInput.question` (the prompt describes the
corpus), so hit counts may vary with the generated queries.

## Output

The final payload is the `graph-neighbors` step plus its passthrough chain:

- `seededNotebookId`, `seededNoteIds`, `seededPageCount`
- `queryPlan` — the four probe queries
- `strictSearch` / `contextualSearch` / `relaxedSearch` / `graphSearch` — each
  with `query`, `resultCount`, `noteIds`, and full `results` including
  `termCoverage` and `isLinkedNeighbor` per hit
- `results` — the graph-neighbour edges walked from the strict-search hit
  (`edgeKind`, `weight`, `hopCount`)
