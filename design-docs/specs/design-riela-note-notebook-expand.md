# Riela Note Notebook Expansion

## Summary

Notebook rows expose **Expand with Agent** from both the notebook list and the
file-tree pane. The action lazily derives and caches a compact key-points
summary of the selected source notebook, and persists that summary as the seed
of a new `notebook-kind:agent-conversation` notebook. Every persisted expansion
turn is linked back to source notes with AI provenance.

This is one issue-resolution work package on
`feat/riela-note-agent-expand`; it does not change the general Note Agent,
selection Q&A, edit rewrite, ingestion, or retrieval behavior.

Issue reference: workflow input for
`codex-design-and-implement-review-loop-session-614`, communication
`comm-001401` (no GitHub repository, number, or URL was supplied).

## Behavioral Requirements

1. `Sources/RielaNoteUI/RielaNoteNotebookListView.swift` and
   `Sources/RielaNoteUI/RielaNoteFileTreePane.swift` each offer the same
   per-notebook **Expand with Agent** context-menu action.
2. A notebook is compacted only when the action is first invoked for the
   current source revision. A valid cached summary is reused; a never-expanded
   notebook is not compacted or mutated.
3. The compacting stage may read the complete, ordered source-note snapshot.
   The expansion stage receives only the compact summary and the expansion
   question; its interface must not accept notebook or note bodies.
4. A successful action creates a new agent-conversation notebook seeded by the
   compact summary. The first conversation-turn note pairs a fixed,
   system-generated action prompt with the compact summary; later user
   questions and answers each produce another turn note. This resolved
   persistence decision is recorded in
   `design-docs/user-qa/qa-riela-note-notebook-expand-seed-format.md`.
5. Every expansion-conversation note links to the source notes through
   `NoteService.linkNotes`, using `provenance: .ai` and
   `linkKind: "source-citation"` (or `"related"` only when citation semantics
   are unavailable). `NoteService.listLinks` must expose the association.
6. An unavailable workflow provider throws the same `.notConfigured` error
   shape as existing note workflow providers and never crashes the app.

## Design Decisions

### D1 — Two explicit agent boundaries prevent grounding leakage

Compaction and expansion are separate logical stages:

- **Compaction input:** source notebook id/title plus source notes ordered by
  `noteNumber`; full bodies are permitted only here.
- **Compaction output:** non-empty compact Markdown key points and provider
  version.
- **Expansion input:** compact summary plus the user question. It contains no
  `Notebook`, `Note`, source-note body, attachment, search result, or ambient
  Note Agent retrieval context.
- **Expansion output:** assistant Markdown suitable for a conversation turn.

The boundaries and owners are concrete while remaining inside the one accepted
provider and workflow bundle:

- `Sources/RielaNoteUI/RielaNoteNotebookExpansionModels.swift` owns the DTOs.
  `RielaNoteNotebookCompactRequest` contains notebook identity and ordered
  `RielaNoteNotebookCompactSourceNote` values (`noteId`, `noteNumber`,
  `bodyMarkdown`). `RielaNoteNotebookCompactDraft` contains
  `summaryMarkdown` and `version`.
- `RielaNoteNotebookExpansionRequest` contains exactly
  `compactSummaryMarkdown` and `questionMarkdown`.
  `RielaNoteNotebookExpansionAnswer` contains `assistantMarkdown`. Source
  notebook ids, source-note ids, note bodies, attachments, and search results
  are intentionally absent from this request type.
- One `RielaNoteNotebookExpansionProviding` boundary exposes
  `compactNotebook(request:)` and `answerNotebookExpansion(request:)` and is
  implemented by
  `Sources/RielaNoteUI/RielaNoteWorkflowNotebookCompactProvider.swift`.
- Both methods run the accepted `note-notebook-compact` workflow from
  `examples/note-notebook-compact/`. An explicit operation discriminator keeps
  full-note compaction inputs separate from summary-only answer inputs; the
  workflow result is decoded according to that operation.
- `NoteServiceRielaNoteUIClient` owns this one optional provider.
  `expandNotebook(_:)` verifies that it is configured before reading or writing
  cache state and before calling `saveConversation`, on both cache-hit and
  cache-miss paths. When it is absent, the action immediately throws
  `RielaNoteNotebookExpansionError.notConfigured` and leaves the source cache,
  notebook count, and note count unchanged. A valid cache still skips only the
  compaction provider call; the configured provider remains available for later
  summary-grounded answers. A later answer also throws `.notConfigured` if the
  provider becomes unavailable after the session begins.

The workflow-subprocess adapter follows
`Sources/RielaNoteUI/RielaNoteWorkflowProviderSupport.swift`: trusted absolute
executable/workflow paths, sanitized environment with the existing model-auth
allowlist, private variables files, cancellation-safe process termination, and
last-valid-JSONL `result.rootOutput` parsing. The adapter runs
`riela workflow run note-notebook-compact --workflow-definition-dir <dir>
--variables-file <file> --output jsonl` for both operations. Its agent worker
uses `executionBackend: codex-agent`. Codex-agent is an execution backend here,
not a copied source-code reference; no external codex-agent repository behavior
is adopted.

Provider construction must make the stage boundary testable: an expansion
request can be captured and asserted to contain the compact summary while
excluding distinctive source-body text. The compaction request is separately
allowed to contain that text.

### D2 — Cache is namespaced derived metadata

The source notebook's `metaJSON` retains unrelated keys and adds this object:

```json
{
  "rielaNote": {
    "notebookCompact": {
      "version": 1,
      "summaryMarkdown": "...",
      "computedAt": "ISO-8601 UTC",
      "sourceNoteIds": ["note-01", "note-02", "note-03"],
      "source": {
        "updatedAt": "ISO-8601 UTC",
        "noteCount": 3
      }
    }
  }
}
```

The cache is valid only when `version` is supported, the summary is non-empty,
and both source markers equal the current notebook values. `sourceNoteIds`
records the ordered snapshot used for the summary so cached expansions can
recreate provenance links without reloading bodies. Malformed,
non-object, unknown-version, or incomplete cache data is a miss, not a fatal
read error. Unknown top-level and sibling metadata is preserved on write.

Updating this derived cache must not change the notebook's source
`updatedAt`; otherwise the write would invalidate itself. Source-content
operations continue updating `updatedAt`, while note-count changes provide a
second invalidation signal. The minimal service mutation for cache metadata
must validate JSON and preserve this distinction.

### D3 — Lazy computation is single-flight and snapshot checked

The shared library view model owns one in-flight expansion task per source
notebook. Concurrent actions for the same notebook await the same task instead
of launching duplicate compactions. Different notebooks remain independent.

Before compaction, the action captures the notebook markers and the complete
ordered note snapshot. Before caching the result, it re-reads the source
markers. A changed marker makes the result stale; the action discards it and
retries once from a fresh snapshot. A second change surfaces a recoverable
error and writes no stale cache.

### D4 — Conversation persistence uses existing seams

After compaction or cache reuse, `saveConversation` receives one seed turn that
follows the existing `## User` and `## Agent` representation. The seed uses a
fixed, visibly system-generated action prompt such as
`Expand this notebook into useful key points and follow-up directions.` as the
user field and the compact summary itself as the agent field. This avoids a
second initial agent call, makes the compact summary the persisted seed, and
keeps notebook creation on the intake-required `saveConversation` seam.

Conversation creation, turn creation, and their AI links are atomic service
operations. Existing `saveConversation` and `appendConversationTurn` gain
optional, defaulted source-link input containing `sourceNoteIds`, `linkKind`,
and `provenance`; existing callers retain current behavior. Expansion callers
leave `NoteConversationTurn.sourceNoteIds` empty and pass
`linkKind: "source-citation"`, `provenance: .ai` through the new input. The
service validates all source ids, writes the notebook/turn, and writes every
generated-note/source-note pair inside the same SQLite transaction. The public
`linkNotes` method and these transactional paths share one
`linkNotesInDatabase` rule implementation, so upsert and provenance behavior
cannot diverge. Any link failure rolls back notebook or turn creation; retrying
cannot leave an orphan or duplicate from a failed attempt.

The new conversation notebook's `metaJSON` stores a versioned
`rielaNote.notebookExpansion` object containing source notebook id, source-note
ids, source marker, and compact summary. `saveConversation` accepts this
optional notebook metadata in the same transaction. This durable context is
the source of truth for the active expansion session and keeps later turns
summary-grounded without reading source bodies.

### D5 — UI and state behavior are shared

Both context menus call one `RielaNoteLibraryViewModel.expandNotebook(_:)`
operation with the selected `Notebook`. While its task is active, duplicate
activation for that notebook is disabled. A successful operation publishes one
`RielaNoteNotebookExpansionSession` containing the conversation notebook id,
initial persisted turn, compact summary, source-note ids, and source marker.

`RielaNoteRootView` consumes that one-shot result, selects the new notebook,
calls `RielaNoteAgentViewModel.beginNotebookExpansionSession(_:)`, switches to
the existing Agent tab, and focuses its composer. The agent view model gains an
explicit mode: `.general` or `.notebookExpansion(session)`. In expansion mode,
`submitDraft()` calls `answerNotebookExpansion` with only the session summary
and typed question, then atomically persists and links the returned turn via
`appendConversationTurn`. It must not call the general
`answerNoteAgentTurn`, FTS search, current-note attachment composition, or any
source-body load. Thus every question and answer submitted during the opened
expansion session becomes exactly one note in the created notebook.

Starting a new general conversation ends expansion mode. Reopening a historical
expansion notebook after app relaunch is not part of this action; the durable
notebook metadata makes a future continuation UI possible without changing the
grounding contract. On failure, the current selection remains and a recoverable
expansion error is exposed. No path silently falls back to the full-body Note
Agent.

### D6 — Packaging and rollout remain local and deterministic

`examples/note-notebook-compact/` is the only new workflow bundle. Its
deterministic mock coverage exercises both the full-note compaction operation
and the summary-only answer operation. Workflow, prompt, script, or
packaged-skill edits require refreshed `riela-package.json` integrity digests
where the package manifest applies. No remote push, main-branch update,
migration, second expansion bundle, or background precomputation is part of
this work package.

## Data Flow

1. A context-menu action identifies the source notebook.
2. The view model verifies provider availability and fails with
   `.notConfigured` without cache or conversation mutations when unavailable.
3. The view model reads current notebook metadata and note count. A valid cache
   proceeds directly to expansion; a miss loads the complete
   ordered source-note snapshot and invokes the compacting provider.
4. The view model snapshot-checks and stores the compact result without
   changing source `updatedAt`.
5. Extended `saveConversation` atomically persists the conversation metadata,
   compact-summary seed turn, and AI `source-citation` links in a new
   agent-conversation notebook.
6. The root selects the new notebook and opens an expansion-mode Agent session.
7. Each later question is sent through the same provider and workflow with an
   answer-operation request containing only the compact summary and question,
   then atomically persisted and linked through extended
   `appendConversationTurn`.

## Validation and Review Gates

- Service tests cover cache miss, cache reuse without provider invocation,
  invalidation by `updatedAt`, invalidation by note count, malformed metadata,
  unrelated-metadata preservation, and untouched notebooks.
- View-model/provider tests cover both UI dispatch paths, same-notebook
  single-flight behavior, fail-fast `.notConfigured` behavior on cache-hit and
  cache-miss paths, unchanged cache/notebook/note counts after that failure,
  operation-specific payloads, summary-only later expansion input, and
  distinctive source-body exclusion.
- Relation tests query `NoteService.listLinks` for generated notes and assert
  direction, every source id, `source-citation`, and `.ai` provenance. An
  injected link failure proves the notebook/turn and all links roll back.
- Agent view-model tests prove expansion mode bypasses `answerNoteAgentTurn`,
  persists each successful question/answer pair, and exits only on explicit
  new-conversation behavior.
- Adversarial review is required for cache self-invalidation, prompt/context
  leakage, partial persistence, link provenance, subprocess environment
  handling, and cancellation.

Verification commands:

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaNoteUITests
swift test --filter RielaAppNotesIntegrationTests
riela workflow validate note-notebook-compact
```

Use narrower new test-case filters when available; do not run the full suite.

## Non-goals

- Precomputing summaries for notebooks the user has not expanded.
- Sending full source bodies to the expansion stage or general Note Agent.
- Changing general Note Agent retrieval, selection Q&A, or edit-rewrite flows.
- Adding a separate `note-notebook-expand` provider or workflow bundle.
- Adding a standalone summary-note representation outside the existing
  `saveConversation` paired-turn contract.
- Reopening historical expansion sessions after app relaunch; the active
  session opened by Expand with Agent supports all subsequent turns in scope.
- Cross-device cache synchronization or a new note-store schema migration.
- Pushing to `origin/main`.

## Risks and Mitigations

- **Cache self-invalidation:** derived metadata writes preserve source
  `updatedAt`, and tests cover immediate cache reuse.
- **Grounding leakage:** separate request types and captured-provider tests
  prevent source bodies from entering expansion input.
- **Concurrent source mutation:** marker re-check and bounded retry prevent a
  stale summary from being cached.
- **Partial persistence/linking:** notebook/turn creation and all corresponding
  links share one transaction, so any failure rolls back the complete unit.
- **Large link fanout:** correctness requires each generated turn to link to
  every note in the compacted source snapshot. This is an accepted linear
  write cost; no silent cap may weaken provenance.
- **External command behavior:** existing trust, environment, cancellation,
  private-file, and JSONL parsing rules apply unchanged.

## Open Questions

No unresolved user decision blocks implementation planning. The paired
`saveConversation` seed decision is recorded in
`design-docs/user-qa/qa-riela-note-notebook-expand-seed-format.md`; a standalone
summary-note representation is deferred. Active-session continuation is in
scope, while historical-session reopening is explicitly deferred. The exact
targeted test-case filter names and package-manifest location are
repository-discovery details for the implementation plan, not behavioral
choices.
