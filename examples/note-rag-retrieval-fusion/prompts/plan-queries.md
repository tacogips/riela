# Plan retrieval probe queries

User question: {{workflowInput.question}}

A later step seeds a kaiba notebook titled "Atlas Retrieval Playbook" with five
pages: a hybrid reranking pipeline note, a cache eviction policy note, a
telemetry dashboards note, a query planner fallback note, and a rollout
checklist note. The first, second, and fourth pages share the
`retrieval-fusion` tag.

Derive four probe queries that each exercise one retrieval-fusion technique:

1. `strictQuery` — two terms that co-occur in exactly one page body
   (full-coverage BM25 match).
2. `contextQuery` — one term that appears only in the notebook title plus one
   term from a single page body (contextual-index match: the notebook title is
   indexed as note context).
3. `relaxedQuery` — three terms spread across three different pages so that no
   single page contains them all (relaxed matching with reciprocal rank fusion
   and partial term coverage).
4. `graphQuery` — the same terms as `strictQuery`; the search runs with
   `includeLinked` so shared-tag neighbours are appended by personalized
   PageRank.

Return JSON only:

```json
{
  "strictQuery": "...",
  "contextQuery": "...",
  "relaxedQuery": "...",
  "graphQuery": "..."
}
```
