# Riela Note Kanban Status Sets and Autonomous Orchestration Implementation Plan

**Status**: Planning (pending design self-review completion)
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

**Status**: NOT_STARTED

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
- [ ] v5 migration + registry entry + fresh schema statements (add-column
      strategy, columnExists("status") guard)
- [ ] Default-set seeding (idempotent, `is_system = 1`)
- [ ] Migration tests: fresh v5, v4→v5 values copied to `status`, re-run
      idempotence, `review` writable post-migration, insert path green on
      both fresh and migrated shapes, CHECK-rejection assertion moved to
      service layer (`NoteHierarchyProgressTests.swift:100-106`)

#### Sources/RielaNote/NoteModels.swift + NoteService (+Hydration, new +Kanban)

**Status**: NOT_STARTED

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
- [ ] Model types replaced; all RielaNote call sites compile
- [ ] Status-set CRUD + immutability + non-empty rule + statusId-carrying
      rename (with in-scope card migration CTE) + deletion `reassignTo` +
      unbind→delete orphaning documented behavior + tests
- [ ] Effective-set resolution incl. ancestor fallback + tests
- [ ] Validated CAS `setNotebookProgress` (union incl. system set —
      non-restrictive scoping ceiling) + tests (conflict vs invalid-name)
- [ ] Board grouping helper + tests (deterministic category tiebreak by
      smallest set_id, category-column fallback, first-column guarantee,
      batched CTE resolution — no per-notebook queries)

### 2. GraphQL surface

#### Sources/RielaGraphQL/* (SchemaContract, Contracts, Service, DocumentExecutor, NoteGraphQLContracts)

**Status**: NOT_STARTED

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
- [ ] SDL + executor + resolvers + DTOs (`GraphQLNotebookDTO.progress` →
      `String` — CLI decode path, G1)
- [ ] Field allowlists updated (incl. mirror comment
      `NoteGraphQLDocumentExecutor.swift:975`)
- [ ] Typed conflict contract: `progress-conflict` error code distinct from
      `invalid_request` in mutation payload/diagnostics (B2)
- [ ] RielaGraphQLTests: SDL goldens updated
      (`NoteGraphQLTests.swift:770-858`), new-operation tests, invalid-name +
      CAS-conflict rejection tests; test documents declaring
      `$progress: NotebookProgress!`
      (`NoteGraphQLHierarchyProgressTests.swift:82,126,150`) → `String!` (G7)

### 3. CLI + add-on consumers

#### Sources/RielaCLI/NoteCommandGraphQLDocuments.swift, ProductionNodeAdapter+NoteAddons.swift

**Status**: NOT_STARTED

- Notebook selection set unchanged shape, progress now plain string
  (`NoteCommandGraphQLDocuments.swift:19`); shared notebookJSON serializer
  emits string (`ProductionNodeAdapter+NoteAddons.swift:875-888`, callers
  `:388,:406` — covers ALL note add-ons); CLI response decode goes through
  `GraphQLNotebookDTO` (`NoteCommands.swift:356,375`) — fixed by the module-2
  DTO change.

**Checklist**:
- [ ] CLI documents/serializers compile and NoteCommandTests green
- [ ] CLI decode paths through GraphQLNotebookDTO verified with a custom
      status name (G1 regression test)

### 4. Native UI (RielaNoteUI) — compile-level adaptation only

#### RielaNoteUIClient.swift, RielaNoteTagKanbanSections.swift, RielaNoteLibraryViewModel+Kanban.swift, RielaNoteNotebookListView.swift

**Status**: NOT_STARTED

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
- [ ] String-status adaptation compiles; default-set sections incl. review
- [ ] Native CAS stance: expectedProgress nil everywhere (B1)
- [ ] RielaNoteUITests: kanban tests + 11 race tests +
      `RielaNoteUIClientCatalogTests` green with string statuses

### 5. Web (SolidJS)

#### web/src/notes/{types,client,controller}.ts, web/src/views/NotesView.tsx, web/src/styles.css, web/e2e/dashboard.spec.ts

**Status**: NOT_STARTED

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
- [ ] Dynamic board + drag/drop with expectedProgress CAS (raw-name
      preservation; conflict-code branching)
- [ ] List-view + detail-pane status selects use effective set (G3)
- [ ] Category-keyed pill palette + dynamic grid columns (G4/B4)
- [ ] Status-set management pane (create/edit set, bind folder)
- [ ] Locked-by-default board + unlock toggle + persistence
- [ ] SSE client with debounced refresh + reconnect + fallback
- [ ] vitest suites updated; e2e `.board-column` count assertions
      (`dashboard.spec.ts:538,598,602,721`) set-driven; e2e lock-mode and
      SSE-refresh coverage
- [ ] `npm run build` + packaged asset flow unaffected

### 5b. Note change feed (server + service events)

#### Sources/RielaNote (change events), Sources/RielaServer / RielaApp serving twin (SSE endpoint)

**Status**: NOT_STARTED

- Board-affecting `NoteService` mutations publish `{revision, kind,
  notebookId?, tagNames?}` to an in-process broadcaster actor (design A7).
- `GET /note/events` SSE endpoint beside `/graphql` with the same
  host/auth gating (bearer for SPA serving, host/CSRF gate in-app);
  keep-alive comments; `Last-Event-ID` accepted.
- MUST first verify the custom HTTP server can stream chunked responses on
  a held-open connection; if not, implement the documented fallback
  (`GET /note/revision` poll) behind the same client contract.

**Checklist**:
- [ ] Service-level change publication (all board-affecting mutations)
- [ ] SSE endpoint (or documented fallback) on both serving paths the SPA
      uses (`riela serve --web-root` and in-app)
- [ ] Auth/host gating tests; stream/format unit tests; revision
      monotonicity test

### 6a. RielaCore `collect-partial` fan-out policy (design B4)

#### Sources/RielaCore/WorkflowModel.swift, WorkflowRawValidation/WorkflowValidation, DeterministicWorkflowRunner+Fanout.swift

**Status**: NOT_STARTED

- Third `failurePolicy` value `"collect-partial"`: wait for all branch
  terminals, then ALWAYS `appendFanoutJoinMessage` with per-branch
  status/failureReason records; never throw for branch failures
  (dispatch-level errors still throw). Capability/diagnostic mentions
  updated.

**Checklist**:
- [ ] Model decode + raw/static validation accept collect-partial
- [ ] Dispatch behavior + join records
- [ ] DeterministicWorkflowRunnerFanoutTests: mixed-outcome join under
      collect-partial (input order, failure reasons); fail-fast/collect-all
      tests untouched and green

### 6b. Kanban add-ons (Part B)

#### Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift (+ both registries/docs)

**Status**: NOT_STARTED

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
- [ ] Three add-ons + dual registration + docs
- [ ] Catalog drift fix (note-graph-neighbors)
- [ ] NoteAddonTests: happy path, idempotent re-run, CAS conflict→skip
      output, validation failure, board grouping — all asserting payload
      shapes (unknown-addon no-op stub hazard)

### 7. Example workflow

#### examples/note-kanban-orchestrate/

**Status**: NOT_STARTED

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
- [ ] Workflow bundle authored + `riela workflow validate` clean
- [ ] Mock scenario deterministic (maxConcurrency 1; agents canned; kanban
      add-ons REAL against temp noteRoot; payload-shape assertions) incl.
      rework round — green
- [ ] Registry + mock-count updated
- [ ] Self-join rework fan-out verified or router-step fallback applied
- [ ] EXPECTED_RESULTS.md + rerun-recovery note

---

## Module Status

| Module | File Path | Status | Tests |
|--------|-----------|--------|-------|
| Schema v5 + seeds | `Sources/RielaNote/NoteStoreSchema.swift` | NOT_STARTED | RielaNoteTests |
| Models + service kanban APIs | `Sources/RielaNote/*` | NOT_STARTED | RielaNoteTests |
| GraphQL surface | `Sources/RielaGraphQL/*` | NOT_STARTED | RielaGraphQLTests |
| CLI + serializers | `Sources/RielaCLI/*` | NOT_STARTED | RielaCLITests |
| Native UI | `Sources/RielaNoteUI/*` | NOT_STARTED | RielaNoteUITests |
| Web | `web/src/*` | NOT_STARTED | vitest + e2e |
| Note change feed (SSE) | `Sources/RielaNote` + serving layers | NOT_STARTED | RielaNoteTests + server tests |
| collect-partial policy | `Sources/RielaCore/*Fanout*` | NOT_STARTED | RielaCoreTests |
| Kanban add-ons | `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` | NOT_STARTED | RielaCLITests |
| Example workflow | `examples/note-kanban-orchestrate/` | NOT_STARTED | RielaCLITests + mock run |

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

- [ ] All modules implemented
- [ ] `swift build` clean; RielaNoteTests, RielaGraphQLTests,
      RielaNoteUITests, RielaCLITests, RielaAppNotesIntegrationTests green
      (known local flakes excluded per riela-known-flaky-local-tests)
- [ ] web vitest + build green; e2e board assertions updated
- [ ] `note-kanban-orchestrate` mock scenario green; live smoke run
- [ ] Design doc updated to Accepted after self-review findings resolved

## Progress Log

### Session: 2026-07-31
**Tasks Completed**: Plan drafted from reviewed design baseline (survey
integrated; adversarial self-review in flight)
**Tasks In Progress**: Design self-review findings pending
**Blockers**: None
**Notes**: Plan details may shift when the three Fable review reports land.

## Related Plans

- **Depends On**: impl-plans/active/riela-note.md (baseline),
  impl-plans/active/bounded-fanout-join-workflow-execution.md (runtime fan-out)
