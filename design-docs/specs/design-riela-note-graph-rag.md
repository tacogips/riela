# Riela Note Bounded Graph-RAG Retrieval

- Status: Revised for session-612 design review
- Date: 2026-07-21
- Workflow mode: `issue-resolution`
- Workflow session: `codex-design-and-implement-review-loop-session-612`
- Intake communication: `comm-001387`, normalized by `comm-001388`
- Self-review feedback: `comm-001373`, `comm-001375`, `comm-001377`, `comm-001382`, `comm-001384`, `comm-001390`
- Independent-review feedback: `comm-001380`
- Issue reference: workflow-provided title only; no GitHub URL, repository, or issue number was supplied
- Issue-reference communication: `comm-001388`
- Review mode: standard, with adversarial review required because the work executes workflows and creates commits

## Purpose

Riela Note needs one deterministic relatedness policy for agent retrieval,
search expansion, and related-note proposals. The policy must use the graph
already present in the embedded note store and remain small enough to inspect,
test, and explain. It must not become an unbounded notebook crawl or introduce
a second retrieval system for individual surfaces.

This design defines a bounded graph API owned by `NoteService`. CLI add-ons,
GraphQL, search, related-note association, and example workflows consume that
same API. The work is one dependency-coupled feature; it must not fan out into
independent feature branches.

## Code-verified baseline

- `Sources/RielaNote/NoteStoreSchema.swift` already stores directed
  `note_links`, note-to-tag assignments through `note_tags`, tag metadata in
  `tags` and `tag_classes`, and a trigram `note_fts` FTS5 index.
- `Sources/RielaNote/NoteSearch.swift` ranks direct FTS hits, then optionally
  appends only one-hop, bidirectional `note_links` neighbors with a fixed rank.
- `Sources/RielaNote/NoteService+Relations.swift` currently proposes links by
  extracting terms from a note and issuing independent text searches. Existing
  links and the seed are excluded, and proposals are not persisted.
- `Sources/RielaNote/NoteService+Relations.swift` protects human and system
  link provenance from an AI upsert. That rule is authoritative and remains
  unchanged.
- `Sources/RielaGraphQL/NoteGraphQLService.swift` exposes search and link
  proposals but no graph-neighbor query.
- `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` exposes
  `riela/note-search` but has neither graph depth inputs nor a graph-neighbor
  add-on.

## Scope and boundaries

### In scope

- A public bounded-neighbor result contract and traversal entry point in
  `Sources/RielaNote`.
- Shared graph scoring for linked search expansion and related-note proposals.
- GraphQL and built-in add-on adapters over the shared `NoteService` seam.
- Agentic retrieval in `examples/note-agent` and bounded candidate generation
  in `examples/note-link-extract`.
- Deterministic unit, adapter, and workflow-scenario coverage.

### Out of scope

- More than the service safety cap of five hops, transitive closure,
  whole-notebook traversal, background graph materialization, or a new
  persisted score table.
- Semantic vector retrieval, embeddings, ANN, cosine similarity, sqlite-vec,
  faiss, an external or separate-process graph database, loadable SQLite
  extensions, or SQLite user-defined-function bridges.
- New SwiftPM or native dependencies.
- Changes to translate-related, web-dashboard, daemon-workflow, or
  `Sources/RielaNoteUI` behavior. `Sources/RielaNoteUI` must remain
  iOS-compilable and free of AppKit and `Process` dependencies.
- Automatic acceptance of related-note proposals. Confirmation remains a
  distinct user or workflow action.

## Public behavior

### Neighbor result

Each ranked neighbor returned by `NoteService` carries:

- the seed note ID whose winning path produced the result;
- the neighbor note;
- `edgeKind`: `explicit-link`, `shared-tag`, or `lexical`, describing the
  terminal edge on the winning path;
- `weight`: the final bounded path score used for ranking;
- `hopCount`: one through the normalized request depth;
- `pathNoteIds`: the complete ordered path from seed to neighbor, inclusive.

The result is sufficient for an agent to explain the connection without
recomputing it. A note appearing through multiple seeds or paths is returned
once. Distinct result notes are ordered only by descending weight and then
lexicographically ascending neighbor note ID, matching the public ranking
contract.

Winning-path selection is a separate evidence decision for paths ending at the
same neighbor. The highest-weight eligible admitted path wins; equal-weight
paths resolve by fewer hops, stronger terminal edge kind (`explicit-link`
before `shared-tag` before `lexical`), lexicographically smaller seed ID, then
lexicographically smaller `pathNoteIds`. Because the destination is identical
in this comparison, neighbor note ID is not an evidence tie-breaker. Separating
result ordering from evidence selection keeps both decisions deterministic
across SQLite query plans and repeated runs.

### Request policy

- `maxDepth` defaults to five for the dedicated Graph-RAG API and is
  hard-capped at five by the service. Each request's normalized `maxDepth` is
  the traversal's explicit hard ceiling; traversal never increases it based on
  result count, convergence, or graph shape.
- Depth zero returns no neighbors. Negative depth is invalid.
- Limit defaults to 16 and is hard-capped at 20. Limit zero returns no
  neighbors; a negative limit is invalid.
- An empty seed list returns no neighbors. Duplicate seed IDs are normalized.
- A request may contain at most 20 distinct seed IDs; a larger normalized seed
  set is invalid rather than silently truncated.
- Every non-empty, normalized seed must exist; otherwise the request fails with
  the existing note-not-found error contract.
- Seed notes never appear as neighbors.
- A graph with no qualifying edge returns an empty result.
- Scoring and ranking are deterministic for an unchanged database snapshot.

Adapters may accept a larger positive depth or limit for forward compatibility,
but `NoteService` normalizes them to the service caps of five hops and 20
results. No surface may bypass these caps. Association always supplies
`maxDepth = 2` even though general Graph-RAG retrieval may use five.

## Graph substrate and weights

All scores are normalized to the interval zero through one. Defaults are part
of the product contract and must be centralized in `Sources/RielaNote`, not
redeclared by adapters.

### Explicit links: strong

Rows in `note_links` form bidirectional retrieval edges even though their stored
direction remains meaningful for editing and provenance. Every qualifying
explicit edge has weight `1.0`. `link_kind` and provenance do not change
retrieval strength in this iteration; they remain available as source data.

### Shared entity tags: medium

Two notes have a shared-tag edge when they share at least one eligible tag with
a non-null entity class. The contribution of a tag is IDF-weighted from its
document frequency across notes:

`idf(tag) = log((noteCount + 1) / (tagNoteCount + 1)) / log(noteCount + 1)`

For each eligible tag shared by two notes:

`tagWeight(tag) = 0.30 + 0.35 * idf(tag)`

The shared-tag edge weight is `max(tagWeight(tag))` across their eligible shared
tags. Contributions are never summed. If multiple tags have the same winning
weight, the lexicographically smaller tag ID supplies the evidence. A rarer
shared tag therefore outranks a common shared tag, and multiple common tags
cannot accumulate into a score stronger than an explicit link. Eligible
shared-tag weights occupy `[0.30, 0.65)` for a qualifying shared edge. The `0.30`
base keeps every eligible shared-tag edge above the lexical maximum of `0.25`,
while the `0.35 * idf` term preserves strict rare-over-common ordering. Tags
excluded by the structural rules below do not create edges at any weight.

Tags are ineligible when `tags.is_system` is true, their class is
`document-kind`, or their name begins with `notebook-kind:`. This deliberately
excludes structural labels without excluding the seeded entity classes merely
because their `tag_classes` rows are system-managed. Unclassified tags do not
form graph edges in this iteration.

### Lexical overlap: weak and seed-only

The existing FTS5 trigram index supplies weak candidate edges only while
expanding an original seed at hop one. Lexical edges are never emitted from an
already-discovered neighbor and therefore cannot create lexical chains.

Lexical seed terms are derived deterministically from the seed title followed
by its body. The scanner splits on non-alphanumeric Unicode scalars, retains
tokens with at least four characters, compares tokens case-insensitively for
deduplication, and keeps the first eight distinct tokens in source order. This
is the same bounded term shape already used by deterministic link proposals;
the implementation must centralize it rather than preserve two copies.

Each retained term is issued separately through the existing FTS match-query
escaping. A term query returns at most 20 non-seed notes ordered by FTS rank and
then note ID. Across all term queries, a seed retains at most the best 20
distinct lexical candidates, ordered by descending number of matched seed terms
and then note ID. Earliest matching seed-term position and lowest numeric FTS
rank select evidence when repeated rows describe the same destination. This
bounds lexical collection to eight queries and at most 160 examined rows per
seed before the 20-candidate reduction.

For a candidate matching at least one retained seed term:

`lexicalWeight = 0.10 + 0.15 * (matchingTermCount / retainedSeedTermCount)`

The division uses real numbers, so the result is in `(0.10, 0.25]`. The match
count is based on distinct retained terms, not occurrences. FTS rank selects
and tie-breaks candidates but does not alter the published weight. This fixed
mapping avoids database-dependent score scaling while preserving deterministic
FTS candidate ordering. A lexical edge cannot outrank an eligible shared-tag
or explicit edge. Empty or non-searchable seed content yields no lexical edges
rather than falling back to a whole-store scan.

## Traversal and scoring policy

Traversal is a weighted, best-path-first expansion through the normalized
`maxDepth`, never beyond the service cap of five. Edge candidates may be loaded
with bounded plain SQL, including `WITH RECURSIVE` through
`RielaSQLite.SQLiteDatabase.query`, and evaluated in Swift. The storage choice
does not change the observable rules below.

For a path containing `hopCount` edges:

`pathScore = product(edgeWeights) * pow(0.5, hopCount)`

The `0.5` factor applies once per hop, so nearer otherwise-equivalent paths
always outrank farther paths. A candidate path is eligible for the best-path
frontier only when its final score is at least `0.03`, it does not repeat a
note ID, and it does not end at any request seed.
The frontier is global across all normalized seeds. Distinct destinations use
the public result ordering: descending path score, then ascending destination
note ID. Competing paths to the same destination use the winning-path evidence
rules above.

### Candidate materialization budgets

Every expansion origin has deterministic loader and merge caps before paths may
enter the global frontier:

1. The loader applies edge-source eligibility, calculates the candidate path
   score, and performs source-local destination deduplication, including
   maximum-tag selection for shared-tag edges.
2. Before any source's 20-destination limit, it removes every destination that
   is a normalized request seed, already occurs in the current path, is already
   finalized, or produces a path below the `0.03` relevance floor. These hard
   path-invalid destinations never consume a source slot.
3. A destination already pending in the frontier is not removed before the
   source limit because a newly offered path may replace it. A caller-specific
   result exclusion is also not removed: in particular, an already-linked note
   excluded from proposal output remains eligible to finalize and expand as a
   bridge.
4. The loader applies its source-specific ordering and 20-destination limit.
   No lower source row is paged or backfilled after this point.
5. The bounded source outputs merge by destination and apply the 20-path
   per-origin cap. Surviving paths then compete for insertion or replacement in
   the 40-destination global frontier. Merge deduplication, a non-winning
   pending-path comparison, or frontier eviction does not trigger source
   backfill.

Search-only removal of notes present in the complete direct-result set remains
after graph traversal as defined by the Search contract, so it likewise does
not change loader admission or trigger backfill.

- the bidirectional explicit-link loader returns at most 20 distinct
  destinations, ordered by destination note ID because all explicit edges have
  weight `1.0`;
- the shared-tag loader first reduces multiple shared tags for a destination to
  the maximum-weight tag, using the smaller tag ID on a tie, then returns at
  most 20 distinct destinations ordered by descending edge weight and
  destination note ID;
- the seed-only lexical loader retains at most 20 distinct destinations ordered
  by descending lexical weight and destination note ID; term position and FTS
  rank select evidence for repeated rows of the same destination but do not
  precede destination note ID across distinct results;
- the three loader outputs are merged by destination, retaining the strongest
  local edge and the documented edge-kind precedence on a tie for the same
  destination, then only the first 20 distinct destinations ordered by
  descending candidate path score and destination note ID may be offered to
  the frontier.

A seed origin therefore emits at most 60 loader-output candidates, a non-seed
origin emits at most 40 because lexical loading is seed-only, and either offers
at most 20 candidate paths. Each distinct request seed expands once, and each
finalized non-seed note expands at most once when its hop count permits. With at
most 20 seeds and 20 finalized notes, one request receives at most 4,800 bounded
edge-loader query-result rows: 800 explicit-link rows, 800 shared-tag rows, and
3,200 lexical rows under the separately documented eight-query bound. Those
rows reduce to at most 2,000 loader-output candidates and 800 paths offered to
the frontier across the bounded traversal. Scalar counts, seed-note reads, and
final note hydration are outside this edge-candidate row bound but do not add
graph paths.

The global pending frontier retains at most 40 distinct destination notes. A
better path replaces the pending path for the same destination. When a new
destination arrives at capacity, the frontier keeps the best 40 destinations
by descending path score and destination note ID and discards the rest. Loader
truncation, the per-origin merge cap, and frontier eviction are final for that
candidate path: traversal does not page, rerun, or backfill a truncated source.
A later expansion may independently offer another path to the same destination. These
caps define the request's observable candidate graph and apply equally to
dedicated retrieval, search, and proposal traversal; lower candidates outside
the caps are not considered reachable for that request.

The hard traversal budget is 20 globally finalized, distinct non-seed note IDs
per request:

- request seeds do not consume the budget;
- merely queued candidate paths do not consume the budget;
- the first path popped for a destination finalizes that note and consumes one
  slot, because best-path ordering guarantees it is the winning path;
- alternative paths to a finalized note and duplicate paths across seeds do
  not consume additional slots;
- a finalized note may add qualifying next-hop paths to the frontier only when
  its hop count is below the normalized depth and budget remains;
- traversal stops when the requested number of return-eligible results has
  finalized, 20 distinct non-seed notes have finalized, the depth is exhausted,
  or no qualifying frontier remains.

The requested result limit is applied to return-eligible finalized notes after
path deduplication and any caller-specific result exclusion. The dedicated
graph API and add-on have no result exclusions, so they return the first
`min(limit, 20)` finalized notes. The budget is global rather than per seed and
does not reset between hops.

Lexical edges may occur only as the first edge from a seed. Explicit and
shared-tag edges may occur at any permitted hop. Cycles are prevented by
rejecting a path that repeats a note ID. A seed may still reach a note through
a different acyclic path; only the best path survives.

Five hops is the general retrieval safety cap because it permits an agent to
walk a short explicit-link chain while the `0.5` decay, `0.03` floor, 20-node
budget, loader caps, and 40-destination frontier suppress weak expansion in
practice. A caller may choose any smaller ceiling, and the chosen value remains
hard: there is no adaptive continuation or convergence test. Related-note
association is deliberately tighter at two hops because a proposal must remain
close enough to explain and confirm; farther indirect relationships are useful
as retrieval context but too weak and surprising as proposed durable links.
The explicit depth policy is simpler to inspect and test than an adaptive stop
rule and gives every surface the same upper-bound semantics.

## Data flow

1. A caller supplies one or more seed note IDs, depth, and limit to
   `NoteService`.
2. `NoteService` validates seeds and normalizes bounds.
3. The embedded store supplies explicit edges, eligible tag frequencies and
   shared tags, and seed-only FTS candidates.
4. The traversal ranks and deduplicates paths under the fixed decay, floor, and
   cap policy.
5. The caller receives ranked notes plus the winning connection evidence.
6. Search, proposals, GraphQL, and add-ons adapt that result without rescoring.

The traversal is read-only. It does not add links, tags, or auxiliary graph
state.

## Surface contracts

### Search

`NoteService.searchNotes` retains `includeLinked = false` by default, so callers
using the default retain their current result set. A `depth` option is added
and defaults to one. For callers that explicitly set `includeLinked = true`,
depth one preserves the current hop count but intentionally broadens candidates
from explicit links only to all three graph edge kinds. This behavior change is
required by the single shared relatedness policy and must be release-noted; no
explicit-links-only compatibility mode is introduced. Depth is ignored when
`includeLinked` is false.

Direct search hits remain first and preserve their current FTS/filter ordering.
When direct hits do not fill the requested pre-offset fetch window, search uses
the first 20 distinct direct note IDs in that direct-result order as graph
seeds. Direct hits after the twentieth remain in the combined result but do not
seed expansion. If direct hits already fill the fetch window, search does not
invoke graph traversal. This search-only selection rule ensures the shared
graph API never receives more than its 20-seed hard cap and never turns a valid
large search request into an invalid graph request.

Graph neighbors of the selected direct hits fill only the remaining result
capacity, are ordered by graph weight descending and then note ID, and retain
`isLinkedNeighbor = true`.
Before appending, search removes every graph result whose note ID already
appears anywhere in the complete direct-result set, including direct hits after
the twentieth that did not seed traversal. Filtering never removes or reorders
direct hits. Search does not rerun traversal or backfill entries removed by this
combined-result deduplication; the result may therefore contain fewer than the
requested limit, preserving the graph API's 20-result cap and bounded work.
Existing tag, class, and created-date filters also apply to appended neighbors.
Offset and limit apply to the final combined list. Search delegates neighbor
discovery to the graph API and does not maintain a separate link query.

### Related-note proposals

`NoteService.proposeLinks` calls the shared traversal with `maxDepth = 2` and
uses those bounded graph results rather than independent term searches. The
seed and already-linked notes remain
excluded from proposals, though an existing explicit link may serve as the
first hop to a different second-hop candidate. Candidate order follows graph
weight descending and then candidate note ID. The proposal reason names the
separately selected winning edge kind and path; `source` remains deterministic.

Proposal traversal marks the seed's already-linked note IDs as result-ineligible
before applying the requested proposal limit. Those notes remain traversable
bridge nodes and each still consumes one of the global 20 finalized-node slots.
Traversal stops when the proposal limit is filled or the shared node budget is
exhausted. It does not reset the budget or perform an unbounded backfill after
excluded links consume slots, so a highly connected seed may return fewer than
the requested number of proposals.

Proposal generation stays read-only. A proposal creates no link until the
existing confirmation path invokes link creation. AI-originated confirmation
continues to use the existing upsert protection so it cannot replace human or
system provenance.

### GraphQL

`Sources/RielaGraphQL` adds a bounded `noteGraphNeighbors` query accepting
`noteIds`, `depth`, and `limit`. Its result DTO exposes `seedNoteId`, the note,
`edgeKind`, `weight`, `hopCount`, and `pathNoteIds`. `searchNotes` also accepts
`depth` and forwards both graph parameters to `NoteService`.

GraphQL performs input mapping and error translation only. It does not query
graph tables or calculate scores.

### Built-in add-ons

`riela/note-graph-neighbors` version 1 accepts `noteIds`, `depth`, and `limit`
from the normal add-on config/resolved-input contract. It returns `results`,
`resultCount`, and ordered `noteIds`; each result contains the same graph
evidence as the `NoteService` model. `riela/note-search` accepts
`includeLinked` and `depth` and otherwise preserves its output contract.

Malformed arrays and negative numeric values fail as invalid input. Positive
depth and limit values are subject to the central service caps.

### Example workflows

`examples/note-agent` becomes an explicit agent-RAG loop:

1. `riela/note-search` obtains direct FTS seeds without linked expansion.
2. `riela/note-graph-neighbors` walks the bounded graph.
3. `riela/note-get` retrieves the selected seed and neighbor bodies.
4. The answer prompt permits claims only from retrieved bodies and requires
   exact source `note_id` citations.

Its deterministic mock scenario must exercise the sequence and assert the
expected cited IDs in `EXPECTED_RESULTS.md`.

`examples/note-link-extract` obtains bounded graph candidates, presents
reasons and paths, and keeps proposal and confirmation as separate workflow
steps. Neither example may reproduce scoring rules in prompts.

## Embedded-store rationale

The required relationships already exist beside note content in SQLite. FTS5
provides lexical seeding, ordinary joins provide tag document frequency, and
`note_links` provides explicit edges. Plain SQL plus a bounded Swift traversal
keeps transactions, backup, deployment, and failure behavior inside the
existing note store.

A vector index would introduce a second relevance model, model/version
lifecycle, opaque score explanations, and additional dependencies without
being required for the deterministic relatedness policy. An external graph
database would duplicate note identity and edge state, add synchronization and
process-lifecycle failure modes, and weaken portability. The bounded embedded
design is sufficient for configurable traversal through five hops and makes
every result explainable with stored links, tags, FTS evidence, and an explicit
path.

## Validation and rollout constraints

- Tests must prove the configured hard stop, depth-five service cap, per-hop
  decay ordering, association's depth-two bound, rare-tag IDF ordering,
  structural-tag exclusion, weight-then-note-ID result ordering, deterministic
  same-destination path evidence selection, node-cap enforcement,
  explicit/shared-tag loader caps, per-origin and global frontier caps,
  pre-limit path-invalid filtering, pending-path replacement, preservation of
  proposal bridge nodes, no-backfill behavior, empty-graph behavior, and
  graph-scored proposal ordering.
- CLI tests must execute the new add-on and verify `includeLinked` and `depth`
  forwarding for search.
- GraphQL contract and document execution tests must cover the new query and
  search depth input.
- Workflow validation and deterministic mock execution must run against the
  checked-in example definition directories, not an installed registry copy.
- Targeted tests must report nonzero executed counts.
- The implementation diff must remain within retrieval, graph, association,
  GraphQL/add-on adapters, examples, tests, this design, and its implementation
  plan. Existing unrelated work, including book-reader changes, must remain
  intact.
- Substantive implementation is committed for review, but nothing is pushed.

Verification commands:

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
riela workflow validate note-agent --workflow-definition-dir examples/note-agent
riela workflow validate note-link-extract --workflow-definition-dir examples/note-link-extract
rg -n 'embedding|vector|cosine|sqlite-vec|faiss' Sources/RielaNote Sources/RielaCLI
git diff --name-only
```

The known-flaky `DaemonWorkflowNodePatchTests` event-source-restart test is not
part of this feature's evidence and must not be investigated or attributed.

## Issue-to-design traceability

| Intake requirement | Design decision |
| --- | --- |
| Ranked neighbors with kind, weight, hops, and path | Distinct results order by weight descending then note ID; deterministic best-path evidence is selected separately for each destination |
| Configurable hard depth, decay, floor, and node cap | Request `maxDepth` is a hard ceiling; general retrieval defaults and caps at 5, association uses 2, every hop decays by 0.5, the relevance floor is 0.03, and at most 20 distinct non-seed nodes finalize per request |
| Bounded candidate materialization | Path-invalid destinations are removed before source limits; pending and proposal-excluded bridge destinations remain eligible; then at most 60 seed-origin or 40 non-seed-origin loader outputs, 20 offered paths per origin, 40 pending destinations, 4,800 edge-loader rows, 2,000 loader outputs, and 800 offered paths per request, with no post-limit backfill |
| Strong links, medium IDF tags, weak lexical evidence | Explicit `1.0`, shared-tag `0.30 + 0.35 * idf` in `[0.30, 0.65)`, lexical `0.10...0.25` at seed only |
| Shared policy across surfaces | `NoteService` is the only scoring and traversal seam |
| Search graph parameters | `includeLinked = false` preserves defaults; explicit opt-in uses all edge kinds and depth defaults to one |
| Large search seed selection | First 20 ordered direct hits seed expansion; later direct hits remain results without seeding |
| Combined search deduplication | Remove all direct-note IDs from graph results; do not rerun or backfill filtered entries |
| Graph add-on and GraphQL exposure | Thin adapters expose the shared result fields and central caps |
| Agent-RAG example with exact citations | Search seed, bounded walk, note retrieval, citation-constrained answer |
| Graph-scored link proposals | Read-only graph candidates, existing-link exclusion, explicit confirmation |
| Provenance protection | Existing human/system-over-AI upsert protection remains authoritative |
| Embedded and dependency-free | Existing SQLite tables, FTS5, plain SQL, and Swift traversal only |

## Open questions

None. The operator supplied fixed bounds, storage constraints, edge ordering,
surface ownership, provenance behavior, verification expectations, and commit
policy. Exact implementation types and SQL shape belong in the implementation
plan provided they preserve this observable contract.

## Session-612 authoritative revision

The session-612 intake supersedes the session-610 review assumption that all
traversal must stop at depth two. General Graph-RAG now uses a configurable
request `maxDepth` with a default and service cap of five; association remains
fixed at depth two. The revised scoring formula applies `0.5` decay per hop and
uses a `0.03` floor so a five-edge explicit-link path can remain eligible while
weaker paths terminate earlier. Existing deterministic loader, frontier, and
20-node budgets continue to bound work independently of depth.

## Addressed self-review feedback

The Step 2 self-review cycle (`comm-001373`, `comm-001375`, and `comm-001377`)
raised six mid-severity findings, all resolved in this revision:

- shared-tag scoring is exactly `0.30 + 0.35 * idf`, aggregated by maximum
  rather than summation, and remains strictly above the lexical range;
- lexical term extraction, query count, row/candidate bounds, ranking, and
  weight calculation are deterministic and explicit;
- same-destination path evidence uses terminal edge-kind precedence of
  `explicit-link`, `shared-tag`, then `lexical` after equal score and hop count;
- search compatibility now distinguishes unchanged default behavior from the
  intentional candidate broadening when `includeLinked` is explicitly true;
- large searches use the first 20 direct results as graph seeds; later direct
  results remain visible but do not seed expansion, preventing cap violations;
- combined search removes every direct-result ID from graph results and accepts
  bounded underfill rather than rerunning or backfilling traversal.

## Addressed independent-review feedback

The `comm-001380` independent review raised two mid-severity findings, both
resolved in this revision:

- shared-tag weights now occupy `[0.30, 0.65)`, so the equations enforce the
  documented medium-over-weak ordering while retaining IDF rare-tag ranking;
- the 20-node budget now counts globally finalized distinct non-seed notes,
  with explicit rules for seeds, queued and duplicate paths, multiple seeds,
  hop expansion, result limits, and proposal exclusions.

## Addressed latest self-review feedback

The `comm-001382` self-review found that finalized-node accounting did not bound
candidate enumeration. This revision defines deterministic 20-destination
loader-output caps, a 20-path per-origin merge cap, a 40-destination global
frontier cap, cumulative request maxima, and no paging, rerun, or backfill for
truncated candidates.

The `comm-001384` self-review found that filtering order around those caps was
ambiguous. This revision places seeds, current-path cycles, finalized notes, and
below-floor paths before each source limit; preserves pending destinations and
proposal bridge nodes through truncation; keeps search deduplication after
traversal; and forbids backfill after source limits, merge deduplication, pending
comparison, or frontier eviction.

## Addressed session-612 self-review feedback

The `comm-001390` self-review raised one mid-severity and one low-severity
finding, both resolved in this revision:

- distinct result ranking, frontier admission, bounded loader selection, and
  proposal ordering now use weight descending and then destination note ID;
  equal-score winning-path evidence for the same destination uses hop, edge,
  seed, and path tie-breakers separately;
- the issue-reference communication now identifies the session-612 normalized
  intake at `comm-001388` instead of the stale session-610 reference.
