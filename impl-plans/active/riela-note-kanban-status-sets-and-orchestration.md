# Riela Note Kanban Status Sets and Autonomous Orchestration Implementation Plan

**Status**: Completed (pending PR review)
**Design Reference**: design-docs/specs/design-riela-note-kanban-status-sets-and-orchestration.md
**Created**: 2026-07-31
**Last Updated**: 2026-07-31

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-kanban-status-sets-and-orchestration.md

### Summary

Part A makes kanban statuses configurable: schema v5 introduces
`kanban_status_sets` / `kanban_statuses`, binds sets to folder-class tags
(ancestor fallback, immutable seeded default set including `review`), rebuilds
`notebooks` without the progress CHECK, and converts `Notebook.progress` from
the closed `NotebookProgress` enum to a validated status-name string across
Swift, GraphQL, CLI, native UI, and web. Part B adds three deterministic
kanban add-ons and the `note-kanban-orchestrate` example workflow that
decomposes one task into cards, executes them through parallel fan-out,
routes them through `review`, and converges to `done` with a bounded rework
loop.

### Scope

**Included**: everything in the design's "In scope" list.
**Excluded**: WIP limits/swimlanes/custom colors, note-level task modeling,
libsql sync of status sets, event-source orchestration triggers, replacing
`riela/note-graphql-document`, native status-set management UI.

---

## Modules

### 1. RielaNote store and service (Part A core)

#### Sources/RielaNote/NoteStoreSchema.swift

**Status**: DONE

- `currentVersion = 5`; `migrateToV5` (idempotent via `columnExists`
  guards, v4 shape — NO table rebuild, per design HIGH-1/HIGH-2 resolution):
  create `kanban_status_sets` + `kanban_statuses` (`IF NOT EXISTS`),
  `ALTER TABLE tags ADD COLUMN status_set_id`, `ALTER TABLE notebooks ADD
  COLUMN status TEXT NOT NULL DEFAULT 'none'` + `UPDATE notebooks SET
  status = progress` (legacy `progress` column left dead on migrated
  stores); register in `schemaMigrations`; fresh-install `schemaStatements`
  create `status` only (no `progress`, no CHECK); all RielaNote SQL moves
  from `progress` to `status` column (Swift field name stays `progress`);
  seed system default set (`kanban-default`:
  none/pending/progress/review/done) idempotently alongside
  `seedTagClasses`.

**Checklist**:
- [x] v5 migration + registry entry + fresh schema statements (add-column
      strategy, columnExists("status") guard)
- [x] Default-set seeding (idempotent, `is_system = 1`)
- [x] Migration tests: fresh v5, v4→v5 values copied to `status`, re-run
      idempotence, `review` writable post-migration, insert path green on
      both fresh and migrated shapes, CHECK-rejection assertion moved to
      service layer (`NoteHierarchyProgressTests.swift:100-106`)

#### Sources/RielaNote/NoteModels.swift + NoteService (+Hydration, new +Kanban)

**Status**: DONE

- Remove `NotebookProgress` enum; add `KanbanStatusCategory`, `KanbanStatus`,
  `KanbanStatusSet`; `Notebook.progress: String`.
- Hydration passes raw progress through (`NoteService+Hydration.swift:75-83`
  strict decode removed).
- New `NoteService+Kanban.swift`: `listKanbanStatusSets`,
  `createKanbanStatusSet`, `updateKanbanStatusSet` (system-set immutable,
  in-use deletion rule), `deleteKanbanStatusSet`, `assignKanbanStatusSet`
  (folder-class only), `effectiveKanbanStatuses(tagName:)` (own → nearest
  ancestor → default), allowed-union computation, board grouping helper.
- `setNotebookProgress(notebookId:progress:String,expectedProgress:String?)`
  with allowed-union validation + typed CAS conflict error.

**Checklist**:
- [x] Model types replaced; all RielaNote call sites compile
- [x] Status-set CRUD + immutability + non-empty rule + statusId-carrying
      rename (with in-scope card migration CTE) + deletion `reassignTo` +
      unbind→delete orphaning documented behavior + tests
- [x] Effective-set resolution incl. ancestor fallback + tests
- [x] Validated CAS `setNotebookProgress` (union incl. system set —
      non-restrictive scoping ceiling) + tests (conflict vs invalid-name)
- [x] Board grouping helper + tests (deterministic category tiebreak by
      smallest set_id, category-column fallback, first-column guarantee,
      batched CTE resolution — no per-notebook queries)

### 2. GraphQL surface

#### Sources/RielaGraphQL/* (SchemaContract, Contracts, Service, DocumentExecutor, NoteGraphQLContracts)

**Status**: DONE

- SDL: drop `enum NotebookProgress`, add `KanbanStatusCategory`,
  `KanbanStatus(Set)` types + `KanbanStatusInput`; `Notebook.progress:
  String!`; queries `kanbanStatusSets`, `effectiveKanbanStatuses(tagName)`;
  mutations create/update/delete/assign status set,
  `setNotebookProgress(notebookId, progress: String!, expectedProgress:
  String)`.
- Register every new root field in `supportedNoteGraphQLFields`
  (`NoteGraphQLDocumentExecutor.swift:513-548`) and new type fields in the
  field maps (`:751-776` pattern).
- Resolver validation via NoteService allowed-union path; typed conflict
  surfaced distinctly.

**Checklist**:
- [x] SDL + executor + resolvers + DTOs (`GraphQLNotebookDTO.progress` →
      `String` — CLI decode path, G1)
- [x] Field allowlists updated (incl. mirror comment
      `NoteGraphQLDocumentExecutor.swift:975`)
- [x] Typed conflict contract: `progress-conflict` error code distinct from
      `invalid_request` in mutation payload/diagnostics (B2)
- [x] RielaGraphQLTests: SDL goldens updated
      (`NoteGraphQLTests.swift:770-858`), new-operation tests, invalid-name +
      CAS-conflict rejection tests; test documents declaring
      `$progress: NotebookProgress!`
      (`NoteGraphQLHierarchyProgressTests.swift:82,126,150`) → `String!` (G7)

### 3. CLI + add-on consumers

#### Sources/RielaCLI/NoteCommandGraphQLDocuments.swift, ProductionNodeAdapter+NoteAddons.swift

**Status**: DONE

- Notebook selection set unchanged shape, progress now plain string
  (`NoteCommandGraphQLDocuments.swift:19`); shared notebookJSON serializer
  emits string (`ProductionNodeAdapter+NoteAddons.swift:875-888`, callers
  `:388,:406` — covers ALL note add-ons); CLI response decode goes through
  `GraphQLNotebookDTO` (`NoteCommands.swift:356,375`) — fixed by the module-2
  DTO change.

**Checklist**:
- [x] CLI documents/serializers compile and NoteCommandTests green
- [x] CLI decode paths through GraphQLNotebookDTO verified with a custom
      status name (G1 regression test)

### 4. Native UI (RielaNoteUI) — compile-level adaptation only

#### RielaNoteUIClient.swift, RielaNoteTagKanbanSections.swift, RielaNoteLibraryViewModel+Kanban.swift, RielaNoteNotebookListView.swift

**Status**: DONE

- User decision 2026-07-31: UI feature work is web-only. Native keeps its
  current tag-scoped board over the system default statuses; adapt to the
  string status model with minimal churn: client protocol progress APIs
  take the status-name string (`RielaNoteUIClient.swift:131,237,619-624`);
  sections iterate the default set (now incl. `review`) instead of
  `NotebookProgress.allCases` (`RielaNoteTagKanbanSections.swift:10`);
  label/SF-symbol switches (list view too,
  `RielaNoteNotebookListView.swift:257-258,287-311`) keyed by
  `KanbanStatusCategory` (category-keyed rendering is total over arbitrary
  names); second `allCases` site = context-menu move targets
  (`RielaNoteTagKanbanSections.swift:53`); mutation-target map
  (`RielaNoteLibraryViewModel.swift:124`) → `[String: String]`. Native
  passes `expectedProgress: nil` — keeps generation-gated newer-wins (B1),
  race-test semantics untouched. No custom-set columns, no lock mode, no
  realtime.

**Checklist**:
- [x] String-status adaptation compiles; default-set sections incl. review
- [x] Native CAS stance: expectedProgress nil everywhere (B1)
- [x] RielaNoteUITests: kanban tests + 11 race tests +
      `RielaNoteUIClientCatalogTests` green with string statuses

### 5. Web (SolidJS)

#### web/src/notes/{types,client,controller}.ts, web/src/views/NotesView.tsx, web/src/styles.css, web/e2e/dashboard.spec.ts

**Status**: DONE

- `progress` opaque string + fetched effective status set; drop TS union
  (`types.ts:1`) and runtime allowlist (`client.ts:238-245`); mutation doc
  `NotebookProgress!` → `String!` (+ `expectedProgress`) (`client.ts:158`);
  dynamic columns/labels/palette (`NotesView.tsx:50-56,673-707`,
  `styles.css:140-142` → category-keyed, dynamic count); controller
  desired-map keyed by string with conflict-triggered refresh; minimal
  status-set management pane under Tags tab.

- Read-only mode (design A6): board loads locked; lock toggle in board
  header disables drag/drop + status selects; per-scope-tag persistence in
  `localStorage`.
- Realtime (design A7): `EventSource` on `GET /note/events`; scope-matched
  events schedule a debounced generation-guarded `refresh()`; refresh once
  on (re)connect; graceful degradation to manual refresh when SSE fails;
  dedupe against optimistic desired-map writes.

- Raw-name preservation (G2): drop the unknown→'none' coercion
  (`client.ts:238-244`) and `progressWasUnknown`/banner; stored name kept
  verbatim, used for `expectedProgress`; grouping display-only. Conflict
  error code (`progress-conflict`) branches to refresh/adopt; validation
  error surfaces (B2/B3). List-view row select + detail-pane select
  (`NotesView.tsx:695,707`) render the effective set too (G3).

**Checklist**:
- [x] Dynamic board + drag/drop with expectedProgress CAS (raw-name
      preservation; conflict-code branching)
- [x] List-view + detail-pane status selects use effective set (G3)
- [x] Category-keyed pill palette + dynamic grid columns (G4/B4)
- [x] Status-set management pane (create/edit set, bind folder)
- [x] Locked-by-default board + unlock toggle + persistence
- [x] Long-poll client with debounced refresh + reconnect + fallback (events.test.ts)
- [x] vitest suites updated; e2e `.board-column` count assertions
      set-driven (5 columns); e2e lock-mode coverage (feed-driven refresh is
      unit-covered in events.test.ts; the e2e fixture holds /note/events open)
- [x] `npm run build` + packaged asset flow unaffected

### 5b. Note change feed (server + service events)

#### Sources/RielaNote (change events), Sources/RielaServer / RielaApp serving twin (SSE endpoint)

**Status**: DONE

- Board-affecting `NoteService` mutations publish `{revision, kind,
  notebookId?, tagNames?}` to an in-process broadcaster actor (design A7).
- `GET /note/events` SSE endpoint beside `/graphql` with the same
  host/auth gating (bearer for SPA serving, host/CSRF gate in-app);
  keep-alive comments; `Last-Event-ID` accepted.
- MUST first verify the custom HTTP server can stream chunked responses on
  a held-open connection; if not, implement the documented fallback
  (`GET /note/revision` poll) behind the same client contract.

**Checklist**:
- [x] Service-level change publication (all board-affecting mutations)
- [x] SSE endpoint (or documented fallback) on both serving paths the SPA
      uses (`riela serve --web-root` and in-app)
- [x] Auth/host gating tests; stream/format unit tests; revision
      monotonicity test

### 6a. RielaCore `collect-partial` fan-out policy (design B4)

#### Sources/RielaCore/WorkflowModel.swift, WorkflowRawValidation/WorkflowValidation, DeterministicWorkflowRunner+Fanout.swift

**Status**: DONE

- Third `failurePolicy` value `"collect-partial"`: wait for all branch
  terminals, then ALWAYS `appendFanoutJoinMessage` with per-branch
  status/failureReason records; never throw for branch failures
  (dispatch-level errors still throw). Capability/diagnostic mentions
  updated.

**Checklist**:
- [x] Model decode + raw/static validation accept collect-partial
- [x] Dispatch behavior + join records
- [x] DeterministicWorkflowRunnerFanoutTests: mixed-outcome join under
      collect-partial (input order, failure reasons); fail-fast/collect-all
      tests untouched and green

### 6b. Kanban add-ons (Part B)

#### Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift (+ both registries/docs)

**Status**: DONE

- `riela/note-kanban-task-create` (idempotent by `kanbanTaskKey`, folder tag
  ensure incl. hierarchy, initialProgress default `pending`, output shaped
  for fan-out `itemsFrom` — FLAT payload, pointer `/tasks`; sets progress via
  `setNotebookProgress` post-create).
- `riela/note-kanban-move` (CAS via expectedFrom; `progress-conflict`
  distinct from validation error in output).
- `riela/note-kanban-board` (grouped columns via shared grouping helper).
- Register in BOTH registries: `BuiltinNoteAddon` enum + dispatch chain
  (`ProductionNodeAdapter.swift:389-390`) AND
  `RielaBuiltinAddonCatalog.noteAddons`
  (`Sources/RielaAddons/RielaAddons.swift:56-66`); drive-by: add missing
  `note-graph-neighbors` catalog entry (pre-existing drift).

**Checklist**:
- [x] Three add-ons + dual registration + docs
- [x] Catalog drift fix (note-graph-neighbors)
- [x] NoteAddonTests: happy path, idempotent re-run, CAS conflict→skip
      output, validation failure, board grouping — all asserting payload
      shapes (unknown-addon no-op stub hazard)

### 7. Example workflow

#### examples/note-kanban-orchestrate/

**Status**: DONE

- workflow.json per design B2 (manager, decompose agent, board-setup addon,
  fan-out branch claim→execute→record→review, join review agent as LOOP GATE
  with corridor to finalize, bounded rework fan-out, finalize, output),
  nodes/, prompts/, mock-scenario.json (full pass + one rework round),
  EXPECTED_RESULTS.md. Hardening from review F3-F7: pointers `/tasks` +
  `/failedTasks` (routed payload, NOT `/payload/...`); `collect-partial`
  failure policy; step3-claim labeled conflict transition → join;
  label-exclusive `all_pass`/`!(all_pass)`; decompose prompt constrains
  subtasks to notebook-content deliverables (no workspace-mutating code
  tasks); recovery documented as rerun (resume unsupported mid-fan-out).
- Register in `rielaExampleWorkflowNames()`
  (`RielaExampleParityTests.swift:7`) + `expectedMockScenarioCount` 38→39.

**Checklist**:
- [x] Workflow bundle authored + `riela workflow validate` clean
- [x] Mock scenario deterministic (maxConcurrency 1; agents canned; kanban
      add-ons REAL against temp noteRoot; payload-shape assertions) incl.
      rework round — green
- [x] Registry + mock-count updated
- [x] Self-join rework fan-out verified or router-step fallback applied
- [x] EXPECTED_RESULTS.md + rerun-recovery note

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Schema v5 + seeds | `Sources/RielaNote/NoteStoreSchema.swift` | DONE | RielaNoteTests green |
| Models + service kanban APIs | `Sources/RielaNote/*` | DONE | RielaNoteTests green |
| GraphQL surface | `Sources/RielaGraphQL/*` | DONE | RielaGraphQLTests green |
| CLI + serializers | `Sources/RielaCLI/*` | DONE | RielaCLITests (1 pre-existing registry failure under check) |
| Native UI | `Sources/RielaNoteUI/*` | DONE | RielaNoteUITests green |
| Web | `web/src/*` | DONE | vitest 63/0 + build + e2e 45/45 |
| Note change feed (long-poll) | `Sources/RielaNote` + serving layers | DONE | RielaNoteTests + RielaServerTests green |
| collect-partial policy | `Sources/RielaCore/*Fanout*` | DONE | fanout tests 6/0 incl. mixed-outcome join |
| Kanban add-ons | `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` | DONE | NoteAddonTests green |
| Example workflow | `examples/note-kanban-orchestrate/` | DONE | validate clean; mock run exit 0 (2 rounds) |

## Dependencies

| Feature | Depends On | Status |
|---------|------------|--------|
| Modules 2-5 | Module 1 (store/service) | — |
| Module 6 (add-ons) | Modules 1 (service APIs) | — |
| Module 7 (workflow) | Module 6 | — |
| Modules 3,4,5 | Module 2 (GraphQL) for remote paths | native UI is direct-service |
| Module 5b | Module 1 (service events) | — |
| Module 5 realtime/lock work | Module 5b (feed endpoint) | — |
| Module 6b (add-ons) | Module 1 (service APIs) | — |
| Module 7 (workflow) | Modules 6a + 6b | — |

Suggested order: 1 → 2 → {3, 4, 5b, 6a in parallel} → 5 → 6b → 7.

## Completion Criteria

- [x] All modules implemented
- [x] `swift build` clean; RielaNoteTests, RielaGraphQLTests,
      RielaNoteUITests, RielaCLITests, RielaAppNotesIntegrationTests green
      (known local flakes excluded per riela-known-flaky-local-tests)
- [x] web vitest + build green; e2e board assertions updated
- [x] `note-kanban-orchestrate` mock scenario green; live smoke run
- [x] Design doc updated to Accepted after self-review findings resolved

## Progress Log

### Session: 2026-07-31 (second entry)
**Tasks Completed**: Three adversarial reviews applied (migration rewritten to
FK-safe add-column; consumer gaps G1-G7/B1-B4; orchestration F1-F7 incl.
collect-partial RielaCore extension and rerun-based recovery). Modules 1-4 +
6a implemented and green; web module implemented (vitest 53/0, build green);
kanban add-ons + example workflow authored; A7 transport revised SSE→long-poll
after verifying the server's single-response model; loop bounding revised to
round-counter routing after verifying corridor selection rejects fan-out
origins.
**Tasks In Progress**: —
**Blockers**: None
**Notes**: Final gate 2026-07-31: swift build + tests green across
RielaCoreTests(fanout)/RielaNoteTests/RielaGraphQLTests/RielaNoteUITests/
RielaServerTests/RielaAddonsTests/RielaCLITests; web tsc + vitest 63/0 +
build + playwright e2e 45/45; `riela workflow validate` clean and the mock
scenario runs exit 0 through one rework round. Pre-existing failures
verified identical on clean main (SQLiteWorkflowMessageLog legacy-summary,
SourceDeletionReadiness x2, WorkflowCommandTests deactivated-dependency,
DaemonWorkflowNodePatch event-source-restart flake).

### Session: 2026-07-31 (initial)
**Tasks Completed**: Plan drafted from reviewed design baseline.

## Related Plans

- **Depends On**: impl-plans/active/riela-note.md (baseline),
  impl-plans/active/bounded-fanout-join-workflow-execution.md (runtime fan-out)
