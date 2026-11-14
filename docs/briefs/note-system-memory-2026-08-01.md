# Research brief: fold the Riela memory feature into Riela Note (2026-08-01)

## Goal (operator decisions, already made — do not re-litigate)

1. **Delete the standalone Riela memory feature completely. No compatibility shim,
   no deprecation window. Breaking change is explicitly accepted.**
2. **Riela Note gains a default, read-only "system memory" notebook** that is created
   automatically and used as Riela's system memory substrate.
3. **`readOnly` is a notebook-level default, not an absolute lock.** In the web UI the
   system-memory notebook renders read-only, and an explicit unlock **button** lets the
   user turn writing on for that notebook. Riela's own system-memory write path
   (the replacement for `riela/memory-save`) writes to it regardless of the UI toggle.

## Current memory-feature surface (verified 2026-08-01 at `b2c7206`)

Everything below is in scope for deletion or replacement.

### Package

- `Packages/RielaMemory/` — standalone SwiftPM package, 1395 LOC across
  `RielaMemory.swift`, `MemoryModels.swift`, `SQLiteMemorySupport.swift`,
  `MemoryFileSupport.swift`, `MemoryEncodingSupport.swift`; tests in
  `Packages/RielaMemory/Tests/RielaMemoryTests/RielaMemoryTests.swift`.
- Wired into the root `Package.swift` at lines 48, 66, 174, 214 (dependency + three
  target products). Removing the package requires editing all four sites.
- Storage: SQLite databases under `.riela/memory/` (`chat-memory.sqlite`,
  `persona-chat-memory.sqlite`) plus a file sidecar tree at `.riela/memory/files/`.

### CLI

- `riela memory` route registered in `Sources/RielaCLI/RielaClientCommandRouter.swift:63`
  (`passthroughRouteConfiguration("memory", …)`).
- `Sources/RielaCLI/MemoryCommands.swift` (315) — subcommands
  `save`, `update`, `load`, `search`, `metadata`, `tags`, `related-ids`.
- `Sources/RielaCLI/MemoryCommandModels.swift` (86),
  `Sources/RielaCLI/ParsedMemoryOptions.swift` (85),
  `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift` (238 — memory
  parsing is mixed into a file that ALSO parses workflow options; split, do not
  delete wholesale).

### Node add-ons (built-in)

Registered in `Sources/RielaCLI/ProductionNodeAdapter+MemoryAddonCore.swift` (545) and
dispatched around lines 132–155 / 329–371:

- `riela/memory-save`, `riela/memory-update`, `riela/memory-load`, `riela/memory-search`
- `riela/chat-persona-memory-read`, `riela/chat-persona-memory-write`
  (`ProductionNodeAdapter+PersonaMemory.swift`, 689)
- `riela/chat-memory-raw-daily-summary` (`ProductionNodeAdapter+ChatMemory.swift`, 368)
- File attachment support: `ProductionNodeAdapter+MemoryFiles.swift` (177)

Note the prefix match on `"riela/memory-"` at line ~329 — a catch-all that must go too.

### Core / workflow schema

- `Sources/RielaCore/WorkflowModel.swift` declares `WorkflowMemoryScope` (199),
  `WorkflowMemoryDeclaration` (205), and a `memories: [WorkflowMemoryDeclaration]?`
  field on **six** struct levels (341, 535, 577, 622, 825) plus tolerant decode at 973.
- `Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift` (401) — runtime
  resolution of declared memories.
- `Sources/RielaCore/WorkflowMemoryValidation.swift` (179) — authored-workflow validation.
- Referenced from `WorkflowValidation.swift`, `WorkflowRawValidation.swift`,
  `DeterministicWorkflowRunner.swift`, `+Prompting.swift`, `+CrossWorkflow.swift`,
  `+Fanout.swift`, `+FailurePublication.swift`, `RuntimePublication.swift`,
  `RuntimeStore.swift`, `RuntimeStorePublicationTransactions.swift`,
  `SQLiteWorkflowRuntimePersistenceStore+Rollup.swift`, `LoopCostAccumulator.swift`,
  `WorkflowStdioNodeExecution.swift`.

**No GraphQL surface exists for memory** (`Sources/RielaGraphQL` has zero memory
references) — nothing to remove there.

### Examples and fixtures that depend on memory

- `examples/chat-memory-raw-and-daily-summary/` (whole example: workflow.json,
  mock-scenario.json, EXPECTED_RESULTS.md)
- `examples/slack-agent-trio-chat/`, `examples/telegram-agent-trio-chat/`,
  `examples/discord-agent-trio-chat/` — each declares `"memories"` in workflow.json and
  has six `node-{read,write}-{rina,mika,yui}-memory.json` nodes using the
  `chat-persona-memory-*` add-ons.
- `examples/catalog/chat-persona-and-agent-trio.md`
- `.riela/workflows/riela-memory-design-impl-review/` — project-scope fixture workflow
  whose entire subject is the memory feature.
- No **installed package** under `~/.riela/packages` references memory — the blast
  radius is repo-local.

**Critical fixture rule (learned the hard way):** examples are parity-checked. Any
example added/removed must be reflected in `rielaExampleWorkflowNames()` and the mock
count, and `Tests/RielaCLITests/RielaExampleParityTests.swift` must pass.

### Tests referencing memory

- `Tests/RielaCLITests/MemoryAddonFileTests.swift`,
  `Tests/RielaCLITests/PersonaMemoryAddonTests.swift`,
  `Tests/RielaCoreTests/DeterministicWorkflowRunnerMemoryTests.swift` (delete)
- Memory usage is also threaded through shared test support that must be repaired,
  not deleted: `WorkflowCommandTestSupport.swift`, `WorkflowCommandTestHelpers.swift`,
  `WorkflowCommandScenarioTests.swift`, `WorkflowCommandTests.swift`,
  `WorkflowCommandInspectionTests.swift`, `WorkflowCommandCatalogTests.swift`,
  `WorkflowCommandPackageLifecycleTests.swift`, `CommandParsingTests.swift`,
  `RielaExampleParityTests.swift`, `DeterministicWorkflowRunnerTestSupport.swift`,
  `DeterministicWorkflowRunnerTests.swift`,
  `DeterministicWorkflowRunnerCrossWorkflowDispatchTests.swift`,
  `DeterministicWorkflowRunnerFailureStateTests.swift`,
  `WorkflowRunnerCapabilityPreflightTests.swift`.

Neither `README.md` nor `AGENTS.md` mentions memory — no doc rewrite needed there,
but check `examples/catalog/`.

## Riela Note side: what already exists (verified)

- `Sources/RielaNote/` — `NoteService` + extensions, `NoteStoreSchema.swift`,
  `NoteModels.swift`. Note store is SQLite via `NoteDatabaseDriving`.
- **Schema is at version 5** with an ordered migration list at
  `NoteStoreSchema.swift:303-306` (`migrateToV2`…`migrateToV5`). The established
  pattern is `ALTER TABLE … ADD COLUMN` in a new `migrateToV6` appended to
  `schemaMigrations` — **never rebuild existing notebooks.**
- `notes.read_only INTEGER NOT NULL DEFAULT 0` already exists (`NoteStoreSchema.swift:415`)
  and is surfaced as `NotePage.readOnly` / `NotePageDraft.readOnly`
  (`NoteModels.swift:109,142`). **`notebooks` has NO read_only column** — the
  notebook-level flag is new work (schema v6).
- System tag classes and `systemNotebookKindTags` (`NoteStoreSchema.swift:383`) already
  seed `notebook-kind:imported-material`, `notebook-kind:agent-conversation`,
  `notebook-kind:user-memo`. A `notebook-kind:system-memory` tag fits this existing seam.
- `NoteService.createNotebook(title:kindTagName:metaJSON:originatingActionId:)` and
  `createNotebookWithNotes(…pages:provenance:assignedBy:…)` are the creation entry points.
- Existing note add-ons to model the replacement on:
  `riela/note-create`, `riela/note-update`, `riela/note-get`, `riela/note-search`,
  `riela/note-tag-apply`, `riela/note-attach-file`, `riela/note-comment-add`,
  `riela/note-conversation-save`, `riela/note-graph-neighbors`,
  `riela/note-graphql-document`, `riela/notebook-ingest-pages`,
  `riela/note-kanban-*` — all in `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`.
- Note has a full GraphQL surface (`Sources/RielaCLI/NoteCommandGraphQLDocuments.swift`
  shows `readOnly` already selected on note fields) and a SolidJS web UI under `web/`
  serving the notebook list/kanban/detail views. The unlock **button** belongs there.

## Design questions the design step must answer

1. What replaces the memory record model? Memory records carried
   `memoryId, workflowId, nodeId, registeredAt, tags[], relatedRecordIds[], files[], payload`.
   Notes carry `notebookId, noteNumber, title, bodyMarkdown, readOnly, metaJSON` plus
   tags, relations, and file attachments. Map each memory field onto a note concept
   (payload → bodyMarkdown or metaJSON; tags → note tags; relatedRecordIds → note
   relations; files → note attachments; workflowId/nodeId → tags or metaJSON).
2. How is the default system-memory notebook created and identified? (Seeded during
   schema migration/bootstrap vs lazily on first write; identified by a stable
   `notebook_id`, by a `notebook-kind:system-memory` system tag, or both.)
3. What is the notebook-level `readOnly` enforcement boundary — which service methods
   reject writes, and how does the system write path bypass it? `NoteServiceError`
   already has a `.readOnly(String)` case (`NoteService.swift:6`).
4. What does the web UI unlock button do — a persisted per-notebook toggle written back
   to the DB, or a session-local UI override? (Operator said "書き込みもできるようになる";
   pick one, state the choice, keep it simple.)
5. Which of the six memory add-ons need note-backed successors at all, given the three
   trio-chat examples must keep working, and what are their new IDs?

## Constraints

- Treat this whole request as **exactly one feature / one work package**;
  `has_feature_fanout` must be `false`.
- Additive schema migration only (append `migrateToV6`); never drop or rebuild
  existing note tables.
- Update the three trio-chat examples and their mock scenarios to the new note-backed
  add-ons; delete `examples/chat-memory-raw-and-daily-summary` outright and keep
  `rielaExampleWorkflowNames()` + mock counts + `RielaExampleParityTests` consistent.
- Do not leave dangling `import RielaMemory` or dead `memories:` workflow-schema fields.
- Do not touch unrelated feature areas (kanban, graph-RAG, workflow registry internals).

## Verification

- `swift build` must succeed with `Packages/RielaMemory` removed from `Package.swift`.
- Targeted suites: `swift test --filter RielaNoteTests`,
  `--filter RielaCLITests`, `--filter RielaCoreTests`.
- `riela workflow validate` on each modified example; example parity test green.
- Web: `cd web && bun run build && bun test src`. Rebuild BOTH
  `swift build -c release` and the web bundle before any browser QA — stale artifacts
  reliably masquerade as source bugs.
