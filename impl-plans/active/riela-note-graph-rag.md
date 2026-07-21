# Riela Note Bounded Graph-RAG Implementation Plan

- Status: Ready for implementation
- Created: 2026-07-21
- Last updated: 2026-07-21
- Workflow mode: `issue-resolution`
- Workflow session: `codex-design-and-implement-review-loop-session-612`
- Issue-reference communication: `comm-001388`
- Accepted-design communication: `comm-001393`
- Codex-agent references: none supplied
- Design source: `design-docs/specs/design-riela-note-graph-rag.md`, especially
  [`#public-behavior`](../../design-docs/specs/design-riela-note-graph-rag.md#public-behavior),
  [`#graph-substrate-and-weights`](../../design-docs/specs/design-riela-note-graph-rag.md#graph-substrate-and-weights),
  [`#traversal-and-scoring-policy`](../../design-docs/specs/design-riela-note-graph-rag.md#traversal-and-scoring-policy),
  [`#surface-contracts`](../../design-docs/specs/design-riela-note-graph-rag.md#surface-contracts), and
  [`#validation-and-rollout-constraints`](../../design-docs/specs/design-riela-note-graph-rag.md#validation-and-rollout-constraints)

## Objective and boundaries

Deliver bounded Graph-RAG retrieval, graph-scored related-note proposals, and
agentic note workflows as one dependency-coupled feature. The accepted design is
the source of truth for public behavior, scoring, ordering, caps, provenance,
and surface ownership.

The implementation must use the existing embedded SQLite store and the shared
`NoteService` seam. It must not add vectors, embeddings, ANN, cosine similarity,
sqlite-vec, faiss, an external graph database, a separate process, a loadable
SQLite extension, a SQLite user-defined-function bridge, or a new SwiftPM/native
dependency. It must not change translate-related, web-dashboard,
daemon-workflow, or `Sources/RielaNoteUI` behavior. Existing book-reader work
must remain intact and building. This is one work package with no feature
fanout, and nothing is pushed.

## Design traceability

| Accepted design section | Accepted behavior | Planned delivery |
| --- | --- | --- |
| [Public behavior](../../design-docs/specs/design-riela-note-graph-rag.md#public-behavior) | Shared bounded graph contract and deterministic evidence | TASK-001 and TASK-002 |
| [Graph substrate and weights](../../design-docs/specs/design-riela-note-graph-rag.md#graph-substrate-and-weights) | Explicit-link, IDF shared-tag, and seed-only lexical edges | TASK-002 |
| [Surface contracts](../../design-docs/specs/design-riela-note-graph-rag.md#surface-contracts) | Search expansion and depth-two association | TASK-003 |
| [Built-in add-ons](../../design-docs/specs/design-riela-note-graph-rag.md#built-in-add-ons) | `riela/note-graph-neighbors` and search inputs | TASK-004 |
| [GraphQL](../../design-docs/specs/design-riela-note-graph-rag.md#graphql) | GraphQL parity over `NoteService` | TASK-005 |
| [Example workflows](../../design-docs/specs/design-riela-note-graph-rag.md#example-workflows) | Agentic note-agent and graph-based link extraction | TASK-006 |
| [Validation and rollout constraints](../../design-docs/specs/design-riela-note-graph-rag.md#validation-and-rollout-constraints) | Regression, bounds, workflow, release-note, and prohibited-technology evidence | TASK-007 and TASK-008 |

No reference-repository or Cursor-adapter work is required because no
Codex-agent reference input was supplied.

## Task breakdown

### TASK-001: Establish the public graph contract and centralized policy

- Status: NOT_STARTED
- Depends on: accepted design only
- Write scope:
  - `Sources/RielaNote/NoteGraph.swift` (new; contract and policy)
  - `Sources/RielaNote/NoteService.swift` only for the public service entry point

Deliverables:

- Define public, `Sendable` graph request/result models carrying seed note ID,
  neighbor note, terminal edge kind, final weight, hop count, and complete
  seed-to-neighbor path.
- Centralize the design constants: general default and maximum depth 5,
  association depth 2, default limit 16, hard result/node cap 20, frontier cap
  40, per-source and per-origin caps, decay 0.5, and relevance floor 0.03.
- Define validation and normalization behavior for empty/duplicate/missing
  seeds, depth and limit zero, negative values, and over-cap inputs.
- Keep public result ordering separate from same-destination winning-path
  evidence selection exactly as specified by the accepted design.

Completion checks:

- One `NoteService` API owns graph scoring and traversal semantics.
- Adapters can map the result without querying graph tables or rescoring.
- No adapter-specific constants or duplicate traversal APIs are introduced.

### TASK-002: Implement bounded edge loading and traversal

- Status: NOT_STARTED
- Depends on: TASK-001
- Write scope:
  - `Sources/RielaNote/NoteGraphTraversal.swift` (new)
  - `Sources/RielaNote/NoteGraph.swift` for internal contract integration
  - `Tests/RielaNoteTests/NoteGraphTraversalTests.swift` (new)

Deliverables:

- Load bidirectional retrieval edges from stored directed `note_links`, with
  weight 1.0 and deterministic destination ordering.
- Load shared-entity-tag edges from `note_tags`, `tags`, and `tag_classes`,
  calculate the accepted normalized IDF weight, select the maximum eligible
  shared tag, and exclude system, `document-kind`, `notebook-kind:*`, and
  unclassified structural tags as designed.
- Reuse and centralize bounded term extraction and existing FTS escaping to load
  weak lexical candidates only for the first hop from an original seed.
- Implement weighted best-path-first traversal in Swift and/or bounded plain SQL
  through `RielaSQLite.SQLiteDatabase.query`; enforce normalized hard depth,
  acyclic paths, relevance floor, loader caps, per-origin merge cap, 40-node
  pending frontier, 20 finalized-node budget, requested limit, and no-backfill
  rules.
- Hydrate each returned note once and expose the deterministic winning path.
- Add focused fixtures/tests for max-depth hard stop, depth-five service cap,
  decay ordering, rare-versus-common IDF ordering, structural-tag exclusion,
  seed-only lexical behavior, no-edge empty results, node cap, source/merge/
  frontier caps, cycles, duplicate paths/seeds, and all tie-break contracts.
- Add deterministic budget-order tests proving that seed, current-path,
  finalized, and below-floor destinations are removed before each source limit;
  a stronger path replaces the pending path for the same destination; and
  loader truncation, merge deduplication, pending-path comparison, and frontier
  eviction never page, rerun, or backfill lower candidates.

Completion checks:

- Depth 2 excludes a node reachable only at depth 3; depth 5 never expands to
  depth 6.
- Result order is weight descending then note ID; path evidence is selected by
  score, hops, terminal edge kind, seed ID, and path IDs for one destination.
- Candidate work remains bounded independently of database graph size.
- The pre-limit filtering, pending replacement, and no-backfill tests each fail
  if their ordering or truncation rule is removed.

### TASK-003: Route search expansion and association through the graph seam

- Status: NOT_STARTED
- Depends on: TASK-002
- Write scope:
  - `Sources/RielaNote/NoteSearch.swift`
  - `Sources/RielaNote/NoteService.swift`
  - `Sources/RielaNote/NoteService+Relations.swift`
  - focused additions in `Tests/RielaNoteTests/NoteServiceTests.swift`, or a
    responsibility-based new relation/search test file if that file would grow
    excessively

Deliverables:

- Add search depth input while keeping `includeLinked = false` as the unchanged
  default and depth 1 as linked-expansion default.
- Replace the private one-hop linked-neighbor query with the shared traversal;
  preserve direct FTS/filter ordering, use only the first 20 ordered direct hits
  as graph seeds, apply existing filters to appended neighbors, deduplicate
  against the complete direct set, apply final offset/limit, and do not backfill
  after exclusions.
- Rewrite `proposeLinks` candidate generation to call traversal with
  `maxDepth = 2`; retain seed and already-linked result exclusions while
  allowing already-linked bridge nodes to consume traversal budget and expand.
- Preserve read-only propose-then-confirm behavior and existing protection that
  AI provenance cannot replace human/system provenance.
- Produce deterministic proposal order and reasons from returned graph evidence
  without reimplementing scores.

Completion checks:

- Default search results remain compatible; linked opt-in intentionally uses all
  three edge kinds.
- Association cannot inherit the depth-five default and never persists a link
  during proposal generation.
- Tests cover search seed truncation/deduplication/underfill, filters and paging,
  graph-scored proposal ordering, depth-two association, bridge behavior, and
  provenance preservation.

### TASK-004: Add CLI built-in add-on contracts and tests

- Status: NOT_STARTED
- Depends on: TASK-001 and TASK-003
- Write scope:
  - `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`
  - relevant focused files under `Tests/RielaCLITests/`

Deliverables:

- Register and dispatch `riela/note-graph-neighbors` version 1 with `noteIds`,
  `depth`, and `limit` inputs using normal config/resolved-input precedence.
- Return ordered `results`, `resultCount`, and `noteIds`, including the complete
  graph evidence from the `NoteService` result.
- Extend `riela/note-search` inputs with `includeLinked` and `depth` without
  changing unrelated output fields.
- Reject malformed arrays and negative numeric values; let central service caps
  normalize positive depth/limit values.
- Add adapter tests that execute both add-ons against a real temporary note
  store and assert forwarding, output shape, ordering, and error behavior.

Completion checks:

- Add-on code performs mapping only and contains no scoring/traversal fork.
- `swift test --filter RielaCLITests` executes a nonzero count and passes.

### TASK-005: Expose GraphQL parity from the same service seam

- Status: NOT_STARTED
- Depends on: TASK-001 and TASK-003
- Write scope:
  - `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
  - `Sources/RielaGraphQL/NoteGraphQLDocumentInputs.swift`
  - `Sources/RielaGraphQL/NoteGraphQLDocumentParsing.swift`
  - `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`
  - `Sources/RielaGraphQL/NoteGraphQLService.swift`
  - `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
  - focused GraphQL tests under `Tests/RielaGraphQLTests/`

Deliverables:

- Add `noteGraphNeighbors(noteIds:, depth:, limit:)` with DTO fields matching the
  public graph contract.
- Extend the existing note-search GraphQL input with linked-expansion depth and
  forward it to `NoteService` with the existing include-linked setting.
- Update schema contract, document parsing/execution, result serialization, and
  error translation consistently.
- Add contract and executable-document tests for success, bounds/error mapping,
  ordering, complete path evidence, and search depth forwarding.

Completion checks:

- GraphQL contains no direct SQLite access or graph rescoring.
- Schema, document executor, and service tests agree on names and nullability.

### TASK-006: Rewrite the example workflows and deterministic scenarios

- Status: NOT_STARTED
- Depends on: TASK-004
- Write scope:
  - `examples/note-agent/workflow.json`
  - `examples/note-agent/nodes/`
  - `examples/note-agent/prompts/`
  - `examples/note-agent/mock-scenario.json`
  - `examples/note-agent/EXPECTED_RESULTS.md`
  - `examples/note-link-extract/workflow.json`
  - `examples/note-link-extract/nodes/`
  - `examples/note-link-extract/prompts/`
  - `examples/note-link-extract/mock-scenario.json`
  - `examples/note-link-extract/EXPECTED_RESULTS.md`

Deliverables:

- Make `note-agent` perform direct FTS seed search, bounded
  `note-graph-neighbors`, `note-get` body retrieval, and an answer step limited
  to retrieved content with exact `note_id` citations.
- Make `note-link-extract` obtain depth-two graph-scored candidates and keep
  selection/proposal separate from confirmation.
- Keep scoring out of prompts; prompts consume service-provided reason/path
  evidence.
- Update deterministic mocks so the add-on sequence, graph outputs, and exact
  cited IDs are asserted and documented as runnable expected results.

Completion checks:

- Both workflow definitions validate from their checked-in definition dirs.
- The note-agent mock run produces the exact cited IDs recorded in
  `EXPECTED_RESULTS.md` with no unsupported claim.
- Link extraction demonstrates propose-then-confirm rather than silent writes.

### TASK-007: Complete focused regression coverage and code-quality checks

- Status: NOT_STARTED
- Depends on: TASK-002 through TASK-006
- Write scope:
  - `Tests/RielaNoteTests/`
  - `Tests/RielaCLITests/`
  - `Tests/RielaGraphQLTests/`
  - implementation files only for defects exposed by tests

Deliverables:

- Audit acceptance-criterion coverage and add any missing deterministic tests.
- Confirm targeted test filters execute nonzero counts rather than succeeding
  because no tests matched.
- Run SwiftLint with the repository configuration against changed Swift code;
  split any Swift file over 1000 lines by responsibility before handoff.
- Confirm no existing book-reader changes are overwritten and no protected
  source area is touched.

Completion checks:

- Core, CLI, and GraphQL focused suites pass with explicit test counts.
- New Swift code is lint-clean and contains no duplicated traversal policy.

### TASK-008: Documentation refresh, full verification, and commit handoff

- Status: NOT_STARTED
- Depends on: TASK-007
- Write scope:
  - `design-docs/specs/design-riela-note-graph-rag.md` only for factual alignment
    discovered during implementation
  - `impl-plans/active/riela-note-graph-rag.md` progress log
  - `README.md` Riela Note section for the mandatory linked-search behavior
    release note
  - `.codex/skills/riela-impl-workflow/SKILL.md` only if the implemented
    user-facing workflow contract directly requires an update

Deliverables:

- Add a release note under `README.md`'s Riela Note section stating that default
  search remains unchanged, while explicit `includeLinked = true` now expands
  through explicit-link, shared-tag, and seed-only lexical edges with depth 1 by
  default and the centrally bounded depth option.
- Review the remaining repository-facing documentation against the accepted and
  implemented behavior; record reviewed-but-unchanged files as evidence instead
  of making unrelated edits.
- Run the full verification matrix below and record command, exit status,
  nonzero test count, and any justified gap.
- Inspect the final diff for protected areas, unrelated changes, scratch files,
  prohibited technologies, and accidental dependency updates.
- Refresh `riela-package.json` digests only if workflow, prompt, script, or skill
  files governed by the package are changed and the package manifest requires
  it.
- Commit substantive implementation and documentation for review without
  pushing. Preserve the issue communication and commit hash in the handoff.

Completion checks:

- All required verification passes or a concrete blocker/gap is recorded.
- `README.md` contains the mandatory linked-search behavior release note and the
  progress log records the exact section reviewed.
- The working tree contains no task scratch outside repository-root `tmp/` and
  no unrelated user work is committed.
- The implementation is ready for independent implementation review.

## Dependencies

| Task | Depends on | Reason |
| --- | --- | --- |
| TASK-001 | Accepted design (`comm-001393`) | Public models and policy must stabilize first |
| TASK-002 | TASK-001 | Traversal implements the shared contract |
| TASK-003 | TASK-002 | Search/proposals consume tested traversal |
| TASK-004 | TASK-001, TASK-003 | CLI maps final service signatures |
| TASK-005 | TASK-001, TASK-003 | GraphQL maps final service signatures |
| TASK-006 | TASK-004 | Workflows require the registered add-on contract |
| TASK-007 | TASK-002 through TASK-006 | Coverage audit follows all implementation slices |
| TASK-008 | TASK-007 | Docs, verification, and commit use completed evidence |

There are no new external package, service, database, or native dependencies.

## Parallelizable tasks

Parallel work is optional and does not create feature fanout. It is safe only
after TASK-003 stabilizes shared `NoteService` signatures and only when the
listed write scopes remain disjoint:

| Tasks | Disjoint write scopes | Coordination gate |
| --- | --- | --- |
| TASK-004 and TASK-005 | `Sources/RielaCLI`/`Tests/RielaCLITests` versus `Sources/RielaGraphQL`/GraphQL tests | Freeze service result and error contracts first |
| TASK-005 and TASK-006 | GraphQL files versus `examples/note-*` | TASK-006 also waits for TASK-004 add-on names/output |
| Focused test additions for TASK-004, TASK-005, and TASK-006 | Separate test/example directories | Do not edit shared core fixtures concurrently |

TASK-001 through TASK-003 are sequential because they share the public service
contract and core files. TASK-007 and TASK-008 are integration gates and are not
parallelizable with unfinished implementation.

## Verification

Required commands, run from the committed feature-branch worktree:

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
riela workflow validate note-agent --workflow-definition-dir examples/note-agent
riela workflow validate note-link-extract --workflow-definition-dir examples/note-link-extract
riela workflow run note-agent --workflow-definition-dir examples/note-agent --mock-scenario examples/note-agent/mock-scenario.json
riela workflow run note-link-extract --workflow-definition-dir examples/note-link-extract --mock-scenario examples/note-link-extract/mock-scenario.json
rg -n 'embedding|vector|cosine|sqlite-vec|faiss' Sources/RielaNote Sources/RielaCLI
GIT_PAGER=cat git -c core.fsmonitor=false --no-pager diff --no-ext-diff --check
GIT_PAGER=cat git -c core.fsmonitor=false --no-pager diff --no-ext-diff --name-only
```

Before implementation handoff, determine the repository-supported SwiftLint
invocation and record the exact command and outcome. For each Swift test filter,
record the executed test count. The prohibited-term grep is evaluated against
new implementation code; pre-existing design prose is outside that check. Do
not investigate or attribute the known-flaky
`DaemonWorkflowNodePatchTests` event-source-restart test.

## Completion criteria

- `NoteService` exposes one bounded graph API with configurable hard depth,
  three ordered edge kinds, decay, floor, node/frontier/loader caps, and complete
  deterministic path evidence.
- Core tests prove hard depth, decay, IDF behavior, structural exclusions,
  seed-only lexical edges, node/candidate caps, empty traversal, cycles, and
  deterministic result/evidence ordering, including pre-limit invalid filtering,
  pending-path replacement, and no paging/rerun/backfill after truncation.
- Search uses graph expansion only when requested and preserves direct-result
  semantics; proposals use max depth 2 and preserve confirmation/provenance.
- The CLI add-on and GraphQL query expose the shared service result without
  duplicate scoring; search depth is wired through both surfaces.
- `note-agent` performs search, bounded walk, note retrieval, and exact source
  citations in a deterministic mock run; `note-link-extract` uses graph-scored
  depth-two candidates and keeps confirmation separate.
- Build, targeted tests with nonzero counts, workflow validations, mock run,
  lint, diff hygiene, and prohibited-technology checks pass.
- `README.md` release-notes the intentional `includeLinked = true` candidate
  broadening and depth behavior while documenting that default search is
  unchanged.
- No forbidden dependency/technology or protected-area change is introduced;
  book-reader work still builds; substantive work is committed but not pushed.

## Progress-log expectations

Append dated entries below during implementation. Each entry must record:

- tasks started/completed and exact file paths changed;
- design decisions applied without reopening accepted scope;
- tests or commands run, exit status, and executed test counts;
- failures, fixes, residual risks, and verification gaps;
- mandatory `README.md` release-note path/section and remaining documentation/
  skill review outcome;
- final commit hash and explicit confirmation that no push occurred.

## Progress log

### 2026-07-21 — Step 4 plan creation

- Tasks completed: implementation plan authored from the Step 3 accepted design.
- Files changed: `impl-plans/active/riela-note-graph-rag.md`.
- Review decision: `comm-001393`, accepted for implementation plan with zero
  high, mid, or low findings.
- Codex-agent references: none.
- Implementation status: not started.
- Verification: plan structure, source/design path checks, and `git diff --check`
  passed during Step 4 creation.

### 2026-07-21 — Step 4 self-review

- Design defects: none.
- Plan-only defect resolved: added the missing deterministic
  `note-link-extract` mock-scenario command so both changed workflow fixtures
  have execution evidence in addition to validation.
- Files changed: `impl-plans/active/riela-note-graph-rag.md`.
- Review decision: ready for independent implementation-plan review.

### 2026-07-21 — Step 5 review feedback revision

- Review communication: `comm-001396`.
- Design defects: none; the accepted design remains unchanged.
- Plan findings resolved: added section-level design traceability; named
  deterministic pre-limit filtering, pending-path replacement, and no-backfill
  tests; and made the `README.md` Riela Note release note a mandatory TASK-008
  deliverable, completion criterion, and progress-log item.
- Files changed: `impl-plans/active/riela-note-graph-rag.md`.
- Implementation status: not started; ready for plan self-review.

## Risks and controls

| Risk | Control |
| --- | --- |
| Depth-five expansion exceeds practical bounds | Enforce loader, per-origin, frontier, finalized-node, floor, and hard-depth caps in core tests |
| Path evidence changes public ordering | Keep destination ordering and same-destination evidence selection separate and test both |
| Association accidentally inherits depth five | Use an explicit association policy/call with `maxDepth = 2` and regression test depth-three exclusion |
| Search pagination or filtering regresses | Preserve direct ordering; test first-20 seed selection, full direct-ID dedupe, final paging, and bounded underfill |
| Adapters fork scoring | Restrict CLI/GraphQL to mapping and assert parity with direct `NoteService` results |
| FTS or common tags create noisy chains | Lexical edges are seed-only; structural tags are excluded; weights, floor, and caps are centralized |
| Existing user work is overwritten | Inspect status/diff before each slice; edit only owned paths; never reset or clean unrelated changes |
| Workflow mocks validate the wrong bundle | Always pass the checked-in `--workflow-definition-dir` and scenario path |
| Verification silently matches zero tests | Record nonzero executed counts for every targeted filter |
| Intentional linked-search broadening ships without notice | Require the explicit `README.md` Riela Note release note in TASK-008 and completion evidence |
| Scope expands into forbidden technology or modules | Run prohibited-term and changed-path audits before commit; stop on protected-area changes |
