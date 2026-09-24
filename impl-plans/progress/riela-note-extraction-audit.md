# Riela Note plan ownership audit (2026-09-23)

This is a routing audit, not an implementation-acceptance decision. Riela
commit `d4268c34` (merged by `817ed12`, PR #86) removed the local
`Sources/RielaNote`, `Sources/RielaNoteUI`, and `Tests/RielaNoteTests`
implementation. Current Riela retains Kaiba-facing add-ons and workflows;
`cb01478b` restored graph-RAG examples on the `kaiba/*` add-on boundary.
Do not dispatch a plan against removed Riela source paths or archive it only
because its old paths are absent.

| Active Riela plan | Current evidence | Disposition before implementation |
| --- | --- | --- |
| `riela-note-new-features` | Its 33 unchecked items still target the old Riela Note stack. Kaiba `impl-plans/completed/note-capture-and-entity-pages.md` closes F1 Anywhere Capture and F2 Entity Pages; its completion is on Kaiba `origin/main` via `2949ba7`. | Reconcile F1/F2 against the accepted Riela design, then split out or rebase the unresolved F3 Scoped Ask. Do not implement F1/F2 again in Riela. |
| `riela-note-graph-rag` | The plan says ready, but Riela commits `ef43924e` and `b33f922f` implemented and hardened graph-RAG before extraction; the code/tests were removed at `d4268c34`, while examples were restored at `cb01478b`. Kaiba `origin/main` contains the bounded graph service, traversal tests and GraphQL; Riela retains `kaiba/note-graph-neighbors` adapter/tests and examples (cross-check below). | Reconcile the accepted policy and surface contracts against these current boundaries. Do not treat Kaiba's later `note-retrieval-fusion` plan as proof of this distinct bounded-path contract, and do not replay removed Riela Note service paths. |
| `riela-note-notebook-expand` | The plan says implemented; `40ec3428` delivered the Riela implementation and its Note tests were later extracted. Kaiba currently retains service primitives/tests, but no expansion UI/provider or compact workflow (cross-check below). | Do not archive as feature-complete. Decide whether Kaiba restores the user-facing feature or the product explicitly retires it; do not replay removed Riela paths. |
| `riela-note-system-memory` | The old plan targets local Note system memory; `81542b5a` added it before extraction and `987c8a4` later split short-term Riela memory from Kaiba long-term memory. | Reconcile against the post-split architecture; do not replay its old removal/migration steps. |
| `riela-note` | Its remaining baseline deferrals refer to the former local Note substrate. | Reassign each deferral to the actual current Riela or Kaiba owner and trigger before closing or moving the plan. |

Kaiba's local `main` was ahead of `origin/main` by three commits and had
untracked `.riela/` state at audit time. That checkout belongs to another
session and was inspected read-only; this audit neither merges nor modifies
Kaiba. No Riela active Note plan is declared complete by this audit.

## F1/F2 ownership cross-check (2026-09-24)

Kaiba `2949ba7` is an ancestor of `origin/main`. Its current completed plan
`impl-plans/completed/note-capture-and-entity-pages.md` records F1 capture
and F2 entity-page delivery, and the local three-commit lead has no diff in
the server, Quick Memo, tag-detail, or corresponding test files checked here.
These are **functional ownership evidence**, not permission to mark the old
Riela checklist complete by file name:

- F1: Kaiba has a real `NWListener` server, `GET/POST /note/register`,
  `POST /note/capture`, the SPA capture page, Quick Memo service, and route/
  socket tests (`KaibaLocalHTTPServer.swift`, `ServerContracts.swift`,
  `NoteCaptureRouteTests.swift`, `KaibaServerRuntimeTests.swift`). Its design
  deliberately reuses the existing registration and listener; the Riela
  plan's tasks to add `NWListenerHTTPTransport` and replace registration
  pages/routes in removed `RielaServer` paths are therefore **obsolete as
  implementation instructions**, not unfinished Riela code work. Compare
  the accepted F1 behavior (particularly auth/error sanitization and live
  auto-actions) against Kaiba before closing the feature-level acceptance.
- F2: Kaiba's schema stores `tags.canonical_note_id` and extends the existing
  tag pane, rather than adding Riela's `tags.entity_note_id` and a new
  `RielaNoteUI` entity view. Service, GraphQL, UI, and tests exist in
  `NoteService+TagDetail.swift`, `TagEntityPageTests.swift`,
  `TagEntityGraphQLTests.swift`, and `web/src/components/TagPane.tsx`.
  Treat the old Riela file/schema names as superseded; verify the accepted
  promote/delete/query-bound behaviors before closing F2 acceptance.
- F3: The Kaiba tree has generic `saveConversation` support, but the checked
  `Sources/`, `Tests/`, and active plans do not show the scoped-ask types,
  filter-corpus provider, citation validation, or scoped-ask workflow from
  Riela TASK-007/008. F3 remains an explicit unresolved design/owner decision;
  generic conversation saving is not evidence of Scoped Ask completion.

This cross-check changes no plan checkbox or Kaiba worktree. The next plan
revision should replace obsolete Riela path-level tasks with a behavioral
parity matrix, then route any real F1/F2 gaps and F3 to their present owner.

## Notebook expansion cross-check (2026-09-24)

The old `riela-note-notebook-expand` plan records a completed feature, not
merely service primitives: `Expand with Agent` UI, a compact/answer workflow,
cache orchestration, expansion-session persistence, and cited later turns.
Kaiba `origin/main` retains `NoteService+NotebookExpansion.swift` and
`NoteServiceNotebookExpansionTests.swift`, covering service metadata and
conversation-link transactions. The checked Kaiba tree has no corresponding
notebook-expansion UI/provider or `note-notebook-compact` workflow bundle, and
the extracted Riela tree retains none of those old paths either. Therefore
service migration alone does **not** prove the accepted feature survived the
extraction. Keep this plan out of the archive-candidate set until its present
owner decides whether to restore the user-facing feature in Kaiba or records
an explicit product-level retirement; do not replay old `RielaNoteUI` paths.

## Bounded Graph-RAG cross-check (2026-09-24)

Kaiba `origin/main` contains `Sources/AppCore/NoteGraph.swift` and
`NoteGraphTraversal.swift` with the original depth-five/default-16/hard-20,
frontier-40, decay-0.5 and relevance-floor-0.03 policy, plus
`NoteGraphTraversalTests.swift`. `NoteSearch.swift`, relation proposal code,
`noteGraphNeighbors` GraphQL, and GraphQL tests also use that service seam.
Riela now exposes `kaiba/note-graph-neighbors` through `RielaKaibaAddons` and
retains `note-agent`/`note-link-extract` examples and add-on tests. This is
stronger ownership evidence than the later Kaiba `note-retrieval-fusion`
plan, which adds PPR/RRF/context indexing on top of retrieval rather than
defining the original bounded path result. Before checking off or archiving
the old plan, still compare its TASK-001..008 acceptance matrix with current
Kaiba traversal, GraphQL, Riela adapter and workflow tests, including the
intentional add-on rename from `riela/` to `kaiba/` and any live-client gap.
