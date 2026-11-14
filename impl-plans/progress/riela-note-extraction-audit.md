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

### Graph-RAG TASK-001..008 current-boundary matrix

| Old task | Current owner/evidence | Acceptance still required |
| --- | --- | --- |
| 001 public contract/policy | Kaiba `NoteGraph.swift` defines the neighbor result and centralized caps/weights. | Compare every accepted normalization and tie-break rule with the current service contract. |
| 002 traversal | Kaiba `NoteGraphTraversal.swift` and `NoteGraphTraversalTests.swift` cover depth, decay, IDF, caps, duplicate seeds, stronger pending paths and linked search. | Audit the full source/merge/frontier/no-backfill and path-evidence matrix against the old design; test-file presence is not full behavioral proof. |
| 003 search and association | Kaiba `NoteSearch.swift` calls the graph seam for linked expansion; `NoteService+Relations.swift` calls it for depth-two proposals. | Verify default search, direct-hit truncation/filter/paging, bridge behavior and provenance on current source. |
| 004 built-in add-ons | Riela `RielaKaibaAddons` exposes `kaiba/note-graph-neighbors` and `kaiba/note-search`; the old local `riela/` IDs are obsolete. | Decide explicit compatibility: current client/add-on defaults are depth 2 and limit 20, rather than the old service defaults 5 and 16; Riela's `bounded` helper clamps negative depth/limit to 1, whereas old TASK-004 required rejection. Do not check this task off by rename alone. |
| 005 GraphQL | Kaiba owns `noteGraphNeighbors` and search-depth schema/service/client contracts and tests. | Recheck nullability, error mapping, ordered path evidence and source-matched owner-side tests. |
| 006 example workflows | Riela `note-agent` and `note-link-extract` now use `kaiba/` add-ons; mock scenarios and expected-results files remain. | Installed-runtime validation, inspection and bundled mocks passed as recorded below. Live Kaiba-client behavior and citation resolution still need owner-side verification. |
| 007 focused verification | Kaiba traversal/GraphQL tests and Riela add-on tests exist in their respective repositories. | Run nonzero source-matched suites and lint in each owning repository; do not use removed Riela Note test paths. |
| 008 docs/handoff | Riela examples and README describe the Kaiba boundary; the old task's local Note release-note path and no-push handoff are historical. | Review current public docs and record the explicit default/negative-input decision before archiving or replacing this plan. |

This is an ownership and discrepancy inventory, not a pass of the old task
checklist. Kaiba was inspected read-only; its other-session checkout was not
modified.

On 2026-09-24, installed Riela 0.1.52 validated and inspected both current
bundles with zero capability gaps, then ran each bundled mock with isolated
`tmp/` session/artifact roots (`--workflow-definition-dir examples/<bundle>`).
Both runs returned `completed`, exit code 0. `note-agent` returned
`sourceNoteIds: ["note-agent-source"]` and a citation for the same ID;
`note-link-extract` returned one `related` proposal for `note-candidate` and
did not create a link. The example `EXPECTED_RESULTS.md` files now carry those
reproducible commands and current Kaiba ownership. This proves deterministic
fixture behavior only, not a live server or the full TASK-001..008 contract.

## System-memory plan architecture cross-check (2026-09-24)

The active `riela-note-system-memory` plan describes the pre-extraction
architecture. Its header still says Step 6 remediation and pre-browser artifact
gate pending, and TASK-011 remains in progress. Its checked completion criteria
include removing `RielaMemory`, `riela memory`, workflow `memories`, and
`riela/memory-*` add-ons in favor of a Note-only system-memory notebook. Those
checks record the outcome of the old work package, **not** acceptance of the
current product architecture.

Commit `987c8a40` deliberately restored `Packages/RielaMemory`, the memory CLI,
workflow-memory schema/runtime, and the short-term memory add-ons after Note
extraction. Current `README.md` defines the split: Riela owns short-term SQLite
workflow memory; Kaiba owns long-term notes, with
`kaiba/memory-consolidate`/`kaiba/memory-recall` bridging the two. Current
`examples/telegram-sdk-trio-chat/workflow.json` uses `riela/memory-save` and
`riela/memory-load`, rather than the old plan's Note-backed
`riela/note-memory-save`/`riela/note-memory-load` successors. The old plan's
removal, migration, and browser-artifact instructions must therefore **not** be
dispatched as current implementation tasks.

Before closing or replacing that plan, make a current-architecture acceptance
matrix for: short-term persistence and workflow scope; persona-context add-ons;
the retained Telegram SDK parity cases; Kaiba consolidation/recall and notebook
identity; and the treatment of the former Note system-memory notebook and web
Lock/Unlock behavior. Verify each against current tests and, where applicable,
Kaiba's owner-side contract. Do not infer that `987c8a40` proves every old
behavior was preserved, and do not delete the historical plan or its evidence
until the replacement disposition is reviewed. Kaiba's checkout remains owned
by another session and was not modified for this audit.

### Current-contract evidence inventory (not acceptance)

| Boundary | Present source/test evidence | Remaining acceptance question |
| --- | --- | --- |
| Riela short-term persistence and workflow scope | `Packages/RielaMemory` and its `RielaMemoryTests` cover per-memory SQLite files, save/load/search, shared-workflow search, file references and concurrent saves; `DeterministicWorkflowRunnerMemoryTests` covers workflow/node recording and declarations. | Run source-matched tests and decide which old Note-only expectations are intentionally retired rather than replaying the old deletion tasks. |
| Persona context | `ProductionNodeAdapter+PersonaMemory.swift`, `PersonaMemoryAddonTests` and `MemoryAddonFileTests` cover current `riela/chat-persona-memory-*` handoff and file behavior. | Compare accepted old persona-context isolation, bounds, relation/error and replay requirements against the current contract; test presence alone does not prove parity. |
| Retained Telegram SDK example | `examples/telegram-sdk-trio-chat/workflow.json` uses `riela/memory-save`/`riela/memory-load`; `RielaExampleParityTests` contains Telegram SDK routing cases. | Verify the accepted five-case example matrix under the current short-term model and classify any changed behavior explicitly. |
| Kaiba long-term bridge | `KaibaLongTermMemoryAddons.swift` and `KaibaLongTermMemoryAddonTests` cover consolidate/recall payload and idempotency behavior. Kaiba has `appendLongTermMemory`, `notebook-kind:long-term-memory`, `Kaiba Long-Term Memory` and owner-side tests. | Verify the current Riela↔Kaiba live-client boundary and notebook identity; neither old `notebook-kind:system-memory` nor a local Note append is the current seam. |
| Notebook lock and UI | Kaiba exposes `setNotebookReadOnly` through its GraphQL/service/client contracts; Riela's extracted Note UI paths are absent. | Determine whether the old Riela web Lock/Unlock feature is represented by Kaiba's current UI/contract or was intentionally retired; no Riela browser-artifact rebuild should be dispatched from the old plan. |

This inventory is read-only. The Kaiba local checkout has other-session state;
no Kaiba source, test, plan, or branch was changed. No row is a passed test or
plan-completion claim.
