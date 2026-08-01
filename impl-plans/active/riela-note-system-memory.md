# Riela Note System Memory and Standalone-Memory Removal — Implementation Plan

**Status**: Step 6 remediation after `comm-000346` complete; ready for implementation self-review; pre-browser artifact gate pending
**Workflow Mode**: `issue-resolution`
**Issue Reference**: `codex-design-and-implement-review-loop-session-21`
**Communications**: intake `comm-000270`; accepted revision `comm-000274`;
consumer/design feedback `comm-000279`, `comm-000282`, `comm-000283`, and
`comm-000284`; accepted Step 3 review `comm-000285` (superseding the earlier
Step 3 review `comm-000277`); Step 4 plan output `comm-000286`; Step 4
self-review `comm-000287`; revised plan outputs `comm-000288` and `comm-000290`;
Step 4 self-reviews `comm-000289` and `comm-000291`; Step 5 plan review
`comm-000292`; implementation/review remediation through `comm-000297`,
`comm-000299`, `comm-000301`, `comm-000304`, `comm-000308`, `comm-000311`,
`comm-000314`, `comm-000315`, and `comm-000317`; ordinary Step 7 review
`comm-000318`; adversarial Step 7 review `comm-000319`; test-integrity review
`comm-000322`; implementation self-review `comm-000324`; accepted test-integrity
review `comm-000327`; ordinary Step 7 revision `comm-000328`; implementation
output `comm-000329`; implementation self-review revision `comm-000330`;
implementation and review trace `comm-000331` through `comm-000334`; adversarial
Step 7 revision request `comm-000335`; test-integrity remediation through
`comm-000341`; ordinary Step 7 revision requests `comm-000342` and
`comm-000346`
**Branch / Base**: `feat/note-system-memory` / `c967229`
**Design Reference**: `design-docs/specs/design-note-system-memory.md`
**User-QA Reference**:
`design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md`
**Intake Reference**: `docs/briefs/note-system-memory-2026-08-01.md`
(read-only input)
**Codex-Agent References**: none (`codexAgentReferences: []`)
**Created / Last Updated**: 2026-08-01 / 2026-08-02

## Objective and accepted boundaries

Execute exactly one issue-resolution work package that removes the standalone
memory package, CLI, workflow schema, runtime behavior, add-ons, and obsolete
fixtures; makes Riela Note the only system-memory substrate; migrates the Note
schema additively to v6; bootstraps one tag-identified system-memory notebook;
adds a narrow system append path, two Note-backed persona-context add-ons, and
the confirmed narrow generic Note-backed save/load successors required by the
retained Telegram SDK example;
and exposes persisted lock/unlock behavior in the SolidJS Notes UI.

The accepted design is the source of truth. Preserve these decisions:

- No compatibility shim, tolerant legacy decoder, deprecation route, or
  successor for update/search/raw-daily-summary. The confirmed Telegram SDK
  decision authorizes only `riela/note-memory-save` and
  `riela/note-memory-load` as narrow Note-backed replacements.
- Add only `ALTER TABLE notebooks ADD COLUMN read_only INTEGER NOT NULL DEFAULT
  0`; never drop, rebuild, rename, or copy the note/notebook tables.
- Identify system memory through protected `notebook-kind:system-memory`, not a
  generated notebook ID or title.
- Ordinary content/membership writes honor notebook `readOnly`; only a narrow
  internal system-memory append API may bypass it.
- Web Unlock/Lock persists per notebook, adopts canonical mutation responses,
  and rejects stale refresh/mutation completions.
- Add `riela/note-persona-context-read` and
  `riela/note-persona-context-write`, plus the confirmed narrow
  `riela/note-memory-save` and `riela/note-memory-load` successors used by the
  retained Telegram SDK example.
- Leave existing `.riela/memory` data intact but inert and inaccessible.
- Do not change kanban orchestration, graph-RAG, workflow registry behavior
  beyond removal of dead memory propagation, event sources, agent backends, or
  official SDK adapters.

`Sources/CodexAgent/**`, `Sources/ClaudeCodeAgent/**`, and
`Sources/CursorCLIAgent/**` are outside the write set. Cursor command/session,
model, authentication, and stream normalization behavior remains isolated
behind its existing adapter. No Codex reference repository or intentional
reference divergence applies.

## Accepted consumer disposition

The accepted design resolves the expanded repository inventory as follows:

- Migrate `examples/matrix-agent-trio-chat/**` with the same persona-context
  contract as Slack, Telegram Gateway, and Discord.
- Migrate `examples/shared-agent-trio-personas/**` by removing memory roots and
  declarations and replacing `memoryEntries` with `noteEntries`; agent backend
  and provider behavior remains unchanged.
- Mechanically remove dead memory plumbing from
  `Sources/RielaWorkflowRegistry/WorkflowRegistryBundleLoader+SharedNodeRefs.swift`,
  `Tests/RielaAdaptersTests/WorkflowStdioNodeExecutorTests.swift`,
  `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`, and any
  other source/test match without changing unrelated behavior.
- Refresh `examples/catalog/chat-persona-and-agent-trio.md`,
  `examples/catalog/digest-gateway-and-reply.md`, and
  `examples/event-sources/README.md`; event-source runtime remains out of scope.

The decision in
`design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md` is
CONFIRMED: retain `examples/telegram-sdk-trio-chat/**`, remove its workflow
`memories` surface and standalone-memory root/database configuration, and
migrate its generic save/load flow to the system-memory notebook through
`riela/note-memory-save` and `riela/note-memory-load`. The retained five parity
cases must remain enabled and pass.

## Task breakdown

### TASK-001 — Baseline, traceability, and dependency inventory

**Status**: complete
**Depends on**: accepted Step 3 review `comm-000285`
**Write scope**: this plan's Progress Log; scratch only under
`tmp/note-system-memory/`
**Parallelizable**: no; mandatory implementation gate

**Tasks**:

- Confirm branch, base, dirty-worktree ownership, accepted design, and the
  unchanged read-only intake brief.
- Preserve `comm-000270`, `comm-000274`, `comm-000279`, `comm-000282`,
  `comm-000283`, `comm-000284`, `comm-000285`, the Step 3 low finding, and
  `codexAgentReferences: []` in all handoffs.
- Inventory package imports/products, CLI routing/parsing, add-on
  registration/dispatch, workflow fields, runtime/persistence/transport state,
  examples, shared fixtures, tests, and docs using removed contracts.
- Assign every match to an accepted task disposition; do not reopen the Matrix,
  shared-persona, documentation, adapter-test, app-test, or registry decisions.
- Read and follow the confirmed Telegram SDK decision record; retain all five
  parity cases and include examples in the removal-reference sweep.

**Deliverables**:

- Progress-log inventory with every match assigned to an owning task, retained
  user changes, and the Telegram SDK decision state.

**Verification**:

```bash
git status --short --branch
git rev-parse HEAD
git diff --exit-code -- docs/briefs/note-system-memory-2026-08-01.md
rg -n 'RielaMemory|riela/memory-|chat-persona-memory|WorkflowMemory(Scope|Declaration)|"memories"[[:space:]]*:' Package.swift Sources Tests examples .riela/workflows
rg -n 'memoryRootDirectory|availableMemories|RIELA_MEMORY_ROOT|persona-chat-memory' Sources Tests examples
```

### TASK-002 — Add schema v6, notebook model state, and system identity

**Status**: complete
**Depends on**: TASK-001
**Write scope**:

- `Sources/RielaNote/NoteStoreSchema.swift`
- `Sources/RielaNote/NoteModels.swift`
- `Sources/RielaNote/NoteService+Hydration.swift`
- focused schema/model tests under `Tests/RielaNoteTests/`

**Parallelizable**: no; creates the Note landing zone

**Tasks**:

- Append migration v6 with only the accepted `ALTER TABLE`; add the identical
  column/default to fresh-schema creation.
- Hydrate/expose notebook `readOnly` without changing note-level `readOnly`.
- Add protected `notebook-kind:system-memory` to system notebook-kind tags.
- Test populated-v5-to-v6 preservation and fresh-v6 creation, including
  notebooks, notes, tags, relations, files, metadata, and IDs.

**Deliverables**:

- Additive schema/model support with populated-v5 migration evidence.

**Verification**:

```bash
swift test --filter NoteStoreSchemaTests
git diff --check -- Sources/RielaNote Tests/RielaNoteTests
```

### TASK-003 — Bootstrap system memory and enforce the service boundary

**Status**: complete
**Depends on**: TASK-002
**Write scope**:

- `Sources/RielaNote/NoteService.swift`
- relevant `Sources/RielaNote/NoteService+*.swift` extensions
- focused service tests under `Tests/RielaNoteTests/`

**Parallelizable**: no; defines the shared service contract

**Tasks**:

- After schema/tag seeding, resolve or create one `Riela System Memory`
  notebook in one write transaction. A newly created notebook must set
  `readOnly = true` (`read_only = 1`) before applying the non-deletable kind
  tag; do not inherit the schema column's ordinary-notebook default of `0`.
- Preserve an existing tagged notebook's lock and fail on duplicate tagged
  notebooks.
- Reserve `notebook-kind:system-memory` at the shared notebook-tag assignment
  boundary so ordinary create, ingest, and tag-mutation APIs cannot create a
  second system-memory identity; only bootstrap may create the first identity.
- Add persisted notebook lock management.
- Enforce the lock for note creation/ingestion, body updates, note/notebook
  deletion, note/notebook attachments, and future membership moves; retain the
  accepted comment/relation/tag/progress/lock-management policies.
- Preserve independent note locks.
- Add one internal system append operation that bypasses only the notebook flag
  while retaining validation, attachment limits, transactionality, and note
  invariants. Do not expose a general bypass Boolean.
- Test that fresh bootstrap is locked by default, while an existing tagged
  notebook's persisted explicit unlock remains unchanged on service reopening.

**Deliverables**:

- Idempotent read-only-by-default bootstrap, persisted-unlock preservation,
  duplicate rejection, lock enforcement, and one auditable system append seam.

**Verification**:

```bash
swift test --filter RielaNoteTests
rg -n 'bypass|systemMemory|readOnly' Sources/RielaNote
git diff --check -- Sources/RielaNote Tests/RielaNoteTests
```

### TASK-004 — Expose notebook lock state through GraphQL

**Status**: complete
**Depends on**: TASK-003
**Write scope**:

- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift` where shared
- focused `Tests/RielaGraphQLTests/`

**Parallelizable**: yes, with TASK-005 after TASK-003; scopes are disjoint

**Tasks**:

- Add `Notebook.readOnly` to all projections and DTO mappings.
- Add `setNotebookReadOnly(notebookId:readOnly)` with canonical notebook output,
  `updatedAt`, established errors, and normal change notification.
- Test projection, persistence, invalid IDs, and service error mapping without
  adding another bypass or auth path.

**Deliverables**:

- One additive GraphQL field and mutation for the web client.

**Verification**:

```bash
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
```

### TASK-005 — Add the accepted Note-backed successor add-ons

**Status**: complete
**Depends on**: TASK-003
**Write scope**:

- `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` or a focused
  Note-persona extension
- existing built-in registration/dispatch seams under `Sources/RielaCLI/` and
  `Sources/RielaAddons/` only where required
- focused `Tests/RielaCLITests/`

**Parallelizable**: yes, with TASK-004 after TASK-003; scopes are disjoint until
final integration

**Tasks**:

- Register/dispatch the two persona-context version-1 IDs and the confirmed
  generic Note-backed save/load IDs; reject unsupported versions and legacy
  memory-root/database configuration.
- Implement deterministic bounded persona-tag reads in newest-first order with
  accepted notes, attachments, context, guidance, and handoff trail.
- Validate `noteEntries` and preflight every relationship and attachment before
  the first append; append one note per prepared entry through the narrow system
  path; preserve provider-neutral reply/handoff normalization; treat absent or
  empty entries as a successful no-op.
- Test persona isolation, ordering/bounds, attachment/relation/metadata mapping,
  invalid/empty writes, and system writes while the notebook is locked.
- Test generic save/load payload rendering, workflow isolation, bounded
  newest-first reads, locked-system writes, materialized attachments, and
  rejection of legacy storage configuration.
- Reserve internal stream/workflow/node tag prefixes, require matching metadata
  during loads, and reject more than 64 unique attachment references before
  reading or staging files.

**Deliverables**:

- Four focused successors: two persona-context add-ons and the confirmed narrow
  generic save/load pair; no update/search/raw-daily-summary replacement.

**Verification**:

```bash
swift test --filter RielaCLITests
rg -n 'note-(persona-context-(read|write)|memory-(save|load))' Sources Tests
```

### TASK-006 — Remove the standalone package and `riela memory` CLI

**Status**: complete
**Depends on**: TASK-002, TASK-005, TASK-007; successor dispatch and all
remaining package imports must be resolved before package unwiring
**Write scope**:

- `Package.swift`
- delete `Packages/RielaMemory/**`
- `Sources/RielaCLI/RielaClientCommandRouter.swift`
- workflow-only replacement for
  `Sources/RielaCLI/RielaArgumentParser+WorkflowAndMemory.swift`
- delete CLI memory command/model/options and legacy memory add-on files
- affected CLI parsing/catalog/add-on tests

**Parallelizable**: no; overlaps TASK-005 registration/dispatch

**Tasks**:

- Remove all package products/targets/dependencies/imports and delete the
  package.
- Remove the route, commands, models, options, help, and memory parsing while
  preserving workflow parsing.
- Remove legacy add-on registrations, prefix catch-all dispatch, file support,
  raw/daily summarization, and dedicated tests.
- Repair shared CLI fixtures to assert removal rather than accept dead routes.

**Deliverables**:

- SwiftPM and CLI build with no standalone memory package or legacy route/add-on.

**Verification**:

```bash
swift build
swift test --filter CommandParsingTests
swift test --filter RielaCLITests
grep -rn 'RielaMemory\|riela/memory-\|chat-persona-memory\|WorkflowMemoryDeclaration' Sources Tests Package.swift
```

The grep must produce no output.

### TASK-007 — Remove workflow-memory schema and runtime propagation

**Status**: complete
**Depends on**: TASK-001
**Write scope**:

- `Sources/RielaCore/WorkflowModel.swift`
- delete `Sources/RielaCore/DeterministicWorkflowRunner+Memory.swift`
- delete `Sources/RielaCore/WorkflowMemoryValidation.swift`
- all Core, adapter, registry, CLI, and test-support call sites carrying memory
  declarations, roots, or resolved-memory state
- `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift`

**Parallelizable**: yes, with TASK-004 after TASK-003; avoid TASK-006 CLI files

**Tasks**:

- Remove memory types/fields/tolerant decode, validation, runtime resolution,
  prompt/cross-workflow/fanout/failure propagation, publication,
  persistence/rollup, loop-cost, and stdio/container transport state.
- Repair shared builders/fixtures; delete only dedicated memory tests.
- Remove memory container mounts/configuration without changing unrelated
  stdio/container behavior.
- Preserve registry behavior except removal of dead shared-node memory merging.

**Deliverables**:

- Memory-free workflow model/runtime with all shared suites compiling.

**Verification**:

```bash
swift test --filter RielaCoreTests
swift test --filter WorkflowStdioNodeExecutorTests
swift test --filter RielaAppSettingsSectionLayoutTests
swift test --filter RielaCLITests
rg -n 'WorkflowMemory(Scope|Declaration)|memoryRootDirectory|availableMemories|"memories"[[:space:]]*:' Sources Tests
```

The `rg` must produce no output.

### TASK-008 — Migrate/delete affected examples and preserve parity

**Status**: complete; confirmed Telegram SDK migration implemented and parity verification passing
**Depends on**: TASK-001 decision check, TASK-005, TASK-007
**Write scope**:

- delete `examples/chat-memory-raw-and-daily-summary/**`
- `examples/{slack,telegram,discord,matrix}-agent-trio-chat/**`
- `examples/shared-agent-trio-personas/**`
- retain and migrate `examples/telegram-sdk-trio-chat/**`
- `examples/catalog/chat-persona-and-agent-trio.md`
- `examples/catalog/digest-gateway-and-reply.md`
- `examples/event-sources/README.md`
- delete `.riela/workflows/riela-memory-design-impl-review/**`
- `Tests/RielaCLITests/RielaExampleParityTests.swift`

**Parallelizable**: no; integrates successor contracts and schema deletion

**Tasks**:

- Delete the raw/daily example and project memory fixture workflow.
- Remove all `memories` declarations from the four provider trio examples;
  replace six read/write nodes per example and update their mocks and expected
  results.
- Remove memory roots/declarations from the shared persona workflow and change
  its schemas/prompts from `memoryEntries` to `noteEntries` without changing
  Codex-agent, Claude, Cursor, or provider adapter behavior.
- Update both catalog documents and the event-source README to the accepted
  Note-backed storage/data-flow contract; do not change event-source runtime.
- Update `rielaExampleWorkflowNames()` and expected mock count atomically.
- Apply the confirmed Telegram SDK decision exactly: retain the example,
  replace its generic memory save/load nodes with the narrow Note-backed pair,
  remove workflow/node `memories` fields and storage roots, and preserve all
  five parity cases.
- Preserve gateway/agent behavior, reply identity, handoff bounds, and
  provider-neutral output.

**Deliverables**:

- All retained examples validate without memory contracts and pass mocks;
  deleted examples are absent from parity.

**Verification**:

```bash
swift test --filter RielaExampleParityTests
riela workflow validate slack-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate telegram-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate discord-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate matrix-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate shared-agent-trio-personas --workflow-definition-dir ./examples
riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples
riela workflow run slack-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/slack-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run telegram-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run discord-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/discord-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run matrix-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/matrix-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run telegram-sdk-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
test ! -e .riela/workflows/riela-memory-design-impl-review
rg -n 'RielaMemory|riela/memory-|chat-persona-memory|WorkflowMemory(Scope|Declaration)|persona-chat-memory|memoryRoot|RIELA_MEMORY_ROOT|memoryEntries|"memories"[[:space:]]*:' examples .riela/workflows
```

The `test` must pass and the final `rg` must produce no output. The retained
Telegram SDK example must validate, pass its mock scenario, and retain all five
parity cases.

### TASK-009 — Add persisted web Lock/Unlock with stale-state safety

**Status**: complete; operator-owned browser QA remains pending
**Depends on**: TASK-004
**Write scope**:

- `web/src/notes/types.ts`
- `web/src/notes/client.ts` and tests
- `web/src/notes/controller.ts` and tests
- `web/src/components/NoteDetailPane.tsx` and logic tests
- `web/src/views/NotesView.tsx` only where integration requires

**Parallelizable**: yes, with TASK-007 after TASK-004; scopes are disjoint

**Tasks**:

- Carry notebook `readOnly` through types, queries, and mutation client.
- Identify system memory by its kind tag, show a badge, and disable content
  creation/edit controls while locked.
- Add explicit Unlock/Lock; adopt canonical mutation results across list, board,
  and detail; retain canonical prior state and show errors on failure.
- Guard selection, refresh, and mutation completions so stale work cannot
  overwrite a newer lock decision.
- Keep annotation/organization controls aligned with service policy.

**Deliverables**:

- Persisted accessible Lock/Unlock with deterministic newer-wins convergence.

**Verification**:

```bash
(cd web && bun run typecheck && bun run build && bun test src)
swift build -c release
(cd web && bun run build)
```

The final two commands are the browser-QA artifact handoff gate. Browser QA is
operator-owned and must use those rebuilt release/web artifacts.

### TASK-010 — Documentation, integrity, and source hygiene

**Status**: complete after `comm-000330`; current Note and Hermes designs/plans are rebased onto Note-backed contracts
**Depends on**: TASK-006 through TASK-009
**Write scope**: directly affected docs, including
`examples/catalog/chat-persona-and-agent-trio.md`,
`examples/catalog/digest-gateway-and-reply.md`, and
`examples/event-sources/README.md`; this Progress Log;
`riela-package.json` only if governed workflow/prompt/script/skill content changes
**Parallelizable**: no; post-implementation reconciliation

**Tasks**:

- Update design status and directly affected user docs only when implementation
  evidence requires it; never modify the intake brief.
- Review `README.md`, `.codex/skills/riela-impl-workflow/SKILL.md`, and affected
  workflow-use docs for stale memory behavior.
- Refresh `riela-package.json` digests if a governed file changes.
- Keep all scratch/evidence under `tmp/note-system-memory/` and unstaged.
- Record the Step 3 low deletion-gate finding as addressed by explicit
  nonexistence and `.riela/workflows` sweeps.

**Deliverables**:

- Docs/integrity aligned with behavior, including explicit no-change decisions.

**Verification**:

```bash
git diff --check
git status --short
git diff --exit-code -- docs/briefs/note-system-memory-2026-08-01.md
```

### TASK-011 — Ordered final verification and handoff

**Status**: in progress after `comm-000346` remediation; code and focused verification complete, immediate pre-browser artifact refresh pending
**Depends on**: TASK-002 through TASK-010
**Write scope**: this Progress Log; fixes remain in owning task scope
**Parallelizable**: no; final gate

**Tasks**:

- Run canonical verification in order; record command, exit status, test count,
  material duration, and failure ownership. Never run unfiltered `swift test`.
- Re-run repository-wide reference sweeps.
- Record changed/deleted paths, findings/dispositions, verification gaps,
  residual risks, and operator-owned browser QA.
- Leave commit/push behavior to its later workflow step; this plan grants no
  external publication authority.

**Canonical verification**:

```bash
swift build
test -z "$(rg -n 'RielaMemory|WorkflowMemoryDeclaration|persona-chat-memory|memoryRoot|RIELA_MEMORY_ROOT|memoryEntries' Package.swift Sources Tests examples .riela/workflows || true)"
test -z "$(rg -n 'riela/memory-|chat-persona-memory|chat-memory-raw-daily-summary' Package.swift Sources examples .riela/workflows || true)"
test "$(rg -o 'riela/(memory-(save|update|load|search)|chat-persona-memory-(read|write)|chat-memory-raw-daily-summary)' Tests/RielaCLITests/WorkflowCommandTests.swift | wc -l | tr -d ' ')" = "7"
test ! -e .riela/workflows/riela-memory-design-impl-review
swift test --filter RielaNoteTests
swift test --filter RielaCoreTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
swift test --filter RielaAppSettingsSectionLayoutTests
riela workflow validate slack-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate telegram-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate discord-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate matrix-agent-trio-chat --workflow-definition-dir ./examples
riela workflow validate shared-agent-trio-personas --workflow-definition-dir ./examples
riela workflow validate telegram-sdk-trio-chat --workflow-definition-dir ./examples
riela workflow run slack-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/slack-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run telegram-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run discord-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/discord-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run matrix-agent-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/matrix-agent-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
riela workflow run telegram-sdk-trio-chat --workflow-definition-dir ./examples --mock-scenario ./examples/telegram-sdk-trio-chat/mock-scenario.json --input '{"request":"Yui, give your opinion and ask Mika too"}'
(cd web && bun run typecheck && bun run build && bun test src)
swift build -c release
(cd web && bun run build)
git diff --check
git diff --exit-code -- docs/briefs/note-system-memory-2026-08-01.md
git status --short
```

The first two live-contract gates must produce no output. The count assertion
preserves exactly seven deliberate fail-closed rejection IDs in
`WorkflowCommandTests.swift` without treating that negative coverage as a live
contract. The nonexistence assertion must pass. The retained Telegram SDK
example must validate, pass mocks, and keep all parity tests enabled.

Supplemental sweeps:

```bash
test -z "$(rg -n 'WorkflowMemoryScope|memoryRootDirectory|availableMemories|"memories"[[:space:]]*:' Sources Tests examples .riela/workflows --glob '!WorkflowRawValidation.swift' --glob '!WorkflowModelTests.swift' || true)"
test -z "$(rg -n 'riela/memory-|chat-persona-memory|RIELA_MEMORY_ROOT|persona-chat-memory' Sources Tests examples .riela/workflows --glob '!WorkflowCommandTests.swift' || true)"
```

Both must produce no live contract references. The exclusions retain the
intentional fail-closed parser diagnostic and deleted-add-on rejection tests;
their focused tests verify those negative contracts. Historical design/plan
evidence may retain descriptive names.

## Dependency summary

1. TASK-001 is the mandatory scope/baseline gate.
2. TASK-002 creates the schema/model landing zone.
3. TASK-003 establishes bootstrap, enforcement, and system append.
4. TASK-004 and TASK-005 may run in parallel after TASK-003.
5. TASK-007 may run in parallel with TASK-004 after confirming disjoint files,
   but must serialize with TASK-005 anywhere CLI dispatch/test support overlaps.
   TASK-006 follows TASK-005 and TASK-007 so package removal does not strand
   imports or shared dispatch.
6. TASK-008 requires TASK-005 and TASK-007.
7. TASK-009 requires TASK-004 and may run in parallel with TASK-007.
8. TASK-010 follows stabilized behavior; TASK-011 is the final ordered gate.

Any overlap in `ProductionNodeAdapter`, shared test support, or parity files
serializes the affected tasks.

## Completion criteria

- [x] Every current memory consumer is resolved without unapproved example
  deletion or unrelated behavior change; only the confirmed narrow generic
  Note-backed save/load pair was added.
- [x] The confirmed Telegram SDK retention/migration decision is recorded and
  followed; all five parity cases remain enabled.
- [x] Package, imports, CLI route, and all legacy add-on dispatch are removed.
- [x] Workflow-memory schema, tolerant decode, runtime/persistence/transport
  propagation, and fixtures are removed with no dangling live references.
- [x] Schema v6 is additive and preserves populated v5 notebooks, notes, tags,
  links, files, attachment rows, metadata, and identifiers; fresh v6 includes
  notebook `readOnly`.
- [x] Bootstrap creates exactly one protected tag-identified system notebook
  with `readOnly = true` (`read_only = 1`), verifies that initial locked state,
  preserves a persisted explicit unlock on reopening, rejects duplicates, and
  fails closed on pre-v6 user-tag collisions or noncanonical assignments.
- [x] The shared notebook-tag assignment boundary reserves
  `notebook-kind:system-memory`: ordinary notebook creation, note-created
  notebooks, ingestion, service tag mutation, and GraphQL creation/tag mutation
  cannot create a second identity, and reopening still resolves the canonical
  notebook.
- [x] Ordinary content/membership writes enforce the lock; note locks remain
  independent; conversation append, attachment, and deletion paths fail without
  partial rows/blobs. The named system append is package-only, is the sole
  notebook-lock bypass, and rejects batches above 64 attachments or individual
  attachments above 8 MiB before staging.
- [x] GraphQL projects notebook `readOnly`; real document mutations persist
  Lock/Unlock, return canonical notebooks, and map missing IDs to `not_found`.
- [x] The two persona-context successor add-ons pass persona, bounds, mapping, empty-write,
  atomic multi-entry rollback, retry idempotency, operational relation-error
  propagation, locked-system-write, and retained self/visited/max-turn/unvisited/
  final-turn handoff and false-positive-safe reply-normalization tests. Returned
  local attachment paths are materialized under the active Note root and
  verified as readable with preserved content.
- [x] The confirmed generic Note-backed save/load pair passes payload,
  isolation, multi-record newest-first ordering, read-limit bounds, attachment,
  locked-system-write, and legacy-config rejection tests without reintroducing
  update/search or standalone storage.
- [x] Generic load isolation cannot be widened by spoofed internal user tags;
  tags and versioned metadata must agree. Generic save accepts at most 64 unique
  attachments and rejects overflow before file reads or staging.
- [x] Deleted built-in memory add-on IDs fail closed instead of returning a
  misleading successful no-op result.
- [x] Generic saves reject reserved `persona:` tags, and persona-context reads
  require both the persona tag and matching versioned persona metadata,
  excluding manually forged records with mismatched persona tags.
- [x] Failed page-attachment ingestion restores every requested page lock before
  returning the original failure.
- [x] The retained `riela/chat-persona-router` has explicit earliest-alias
  ordering coverage after its former memory-focused test file was deleted.
- [x] All retained examples validate/pass mocks; parity and catalog match,
  including all five retained Telegram SDK cases.
- [x] Matrix and shared-persona migrations, both catalog documents, the
  event-source README, the chat-example verification skill/references, and the
  authoritative workflow add-on catalog match the accepted Note-backed contract.
- [x] Current Riela Note and Hermes design/active-plan references no longer
  direct work toward the deleted package, CLI, workflow schema, or legacy
  add-ons; future episodic recall is explicitly rebased onto Note system memory.
- [x] Web list/board/detail state exposes canonical persisted Lock/Unlock,
  disables locked content writes, shows errors, and rejects stale refresh,
  selection, progress, and Lock/Unlock cross-field completions. Mocked browser
  regressions assert the system-memory badge, disabled Add/Edit controls,
  Unlock/Lock mutation flow, and failure-state preservation.
- [x] Build, targeted Note/Core/CLI suites, examples, web build/tests, reference
  sweeps, and diff hygiene pass; no full `swift test` is run.
- [x] Focused `RielaAppSettingsSectionLayoutTests` and
  `WorkflowStdioNodeExecutorTests` pass 27/27.
- [ ] Release and web artifacts are rebuilt immediately before operator-owned
  browser QA handoff.
- [x] Intake brief remains unchanged; documentation/digest review and browser-QA
  gap are explicit.

## Progress-log expectations

Append a dated entry for every implementation/review session with:

- completed/in-progress/blocked tasks;
- exact changed/deleted paths and retained user-owned changes;
- accepted consumer assignments, Telegram SDK decision state, and any
  stop-for-design decision;
- implementation deviations, or `none`;
- verification commands, exit status, counts, and material durations;
- high/mid/low findings and disposition;
- docs/digest review outcome;
- remaining gaps, risks, next owner, and commit/push state.

## Progress log

### 2026-08-01 — Step 4 plan creation

- Created the plan from accepted design
  `design-docs/specs/design-note-system-memory.md` and `comm-000277`.
- Addressed the Step 3 low traceability finding by carrying `comm-000274` in
  the plan header; accepted behavior was not reopened.
- Recorded `codexAgentReferences: []` and agent-adapter exclusions.
- Baseline read-only inventory found additional committed Matrix, Telegram SDK,
  shared-persona, adapter-test, app-test, and registry consumers. This initial
  classification gate was superseded by the accepted dispositions recorded in
  the revision below.
- Plan formatting/reference verification passed after file restoration.

### 2026-08-01 — Step 4 plan revision after accepted review `comm-000285`

- Replaced provisional scope classification with the accepted Matrix,
  shared-persona, source/test repair, catalog, and event-source documentation
  dispositions from `design-docs/specs/design-note-system-memory.md`.
- Added the sole operator gate at
  `design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md`; no Telegram
  SDK deletion or redesign is authorized while it remains pending.
- Addressed the Step 3 low finding with
  `test ! -e .riela/workflows/riela-memory-design-impl-review` and expanded
  `.riela/workflows` reference sweeps.
- Added Matrix/shared validation, Matrix mock execution, web typecheck, expanded
  documentation paths, and current communication references through
  `comm-000285`.

### 2026-08-01 — Step 4 revision after self-review `comm-000287`

- Addressed the mid plan-only finding by adding
  `Tests/RielaAppSupportTests/RielaAppSettingsSectionLayoutTests.swift` to
  TASK-007 and running `swift test --filter RielaAppSettingsSectionLayoutTests`
  in TASK-007 and TASK-011.
- Addressed the low plan-only finding by adding `swift build -c release`
  followed by `cd web && bun run build` as the explicit browser-QA artifact
  handoff gate.
- No design revision or Codex-agent reference was required.

### 2026-08-01 — Step 4 revision after self-review `comm-000289`

- Addressed the working-directory finding in TASK-009 and TASK-011 by running
  each web command group in a subshell.
- The browser-QA artifact gate now runs `swift build -c release` from the
  repository root and `(cd web && bun run build)` without leaking directory
  state to later commands.
- Recorded plan output `comm-000288` and self-review `comm-000289`; no design or
  agent-adapter change was required.

### 2026-08-01 — Step 4 revision after Step 5 review `comm-000292`

- Addressed the mid plan-only bootstrap finding in TASK-003 by requiring every
  newly created `Riela System Memory` notebook to set `readOnly = true`
  (`read_only = 1`) rather than inherit the schema's ordinary-notebook default.
- Added explicit focused coverage for the fresh bootstrap's initial locked state
  and preservation of an existing notebook's persisted explicit unlock after
  reopening the service.
- Updated TASK-003 deliverables and the completion criteria with the same
  read-only-by-default contract; the accepted design and Codex-agent boundaries
  remain unchanged.
- Recorded plan output `comm-000290`, self-review `comm-000291`, and Step 5
  review `comm-000292` for traceability.

### 2026-08-01 — Step 6 implementation after acceptance `comm-000295`

- Completed TASK-001 through TASK-007 and TASK-009. Added additive schema v6,
  notebook `readOnly`, idempotent locked system-memory bootstrap, persisted
  Lock/Unlock, narrowly scoped system append, GraphQL/web projection, and the
  two Note-backed persona-context add-ons.
- Deleted `Packages/RielaMemory/**`, the `riela memory` CLI route and parser
  surface, legacy memory add-ons, workflow-memory schema/runtime propagation,
  dedicated memory tests, `examples/chat-memory-raw-and-daily-summary/**`, and
  `.riela/workflows/riela-memory-design-impl-review/**`.
- Migrated Slack, Telegram gateway, Discord, Matrix, and shared-persona
  examples plus parity/catalog/event-source documentation. The authorized
  examples validate and their mock runs pass with isolated `RIELA_NOTE_ROOT`
  paths under `tmp/note-system-memory/`.
- Kept `examples/telegram-sdk-trio-chat/**` unchanged because
  `design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md` remains
  pending. TASK-008, the repository-wide example parity suite, and TASK-011
  therefore remain blocked only on that accepted operator gate.
- Verification: `swift build` passed; `RielaNoteTests` passed 136/136;
  `RielaCoreTests` passed 478/478; `RielaGraphQLTests` passed 109/109; the
  successor add-on focused test passed; web typecheck/build passed and web
  tests passed 149/149. `RielaExampleParityTests` failed only for the untouched
  Telegram SDK workflow's removed `memories` contract, as expected from the
  gate. No unfiltered `swift test` was run.
- SwiftLint was run with `.swiftlint.yml`. Newly introduced files are clean;
  the repository-wide strict run still reports existing oversized-file/type,
  complexity, tuple, and conversion findings in previously oversized files.
- Implementation deviations: the documented example mock command uses
  `--variables` because this CLI does not support `workflow run --input`.
  Browser QA, release artifact rebuild, final digest, commit, and push remain
  pending; no external publication occurred.

### 2026-08-01 — Step 6 accepted-design closure and focused re-verification

- Closed the remaining TASK-005 contract details: persona reads now filter by
  persona before applying the deterministic limit and return bounded
  `filePaths`, `imagePaths`, `audioPaths`, `videoPaths`, and `pdfPaths`.
- Persona writes now validate every `noteEntries` item, resolve note IDs into
  transactional `related` links, retain unresolved external IDs in
  `metaJSON.relatedRecordIds`, and attach bounded inline/local files through a
  system-memory-specific attachment path that preserves ordinary notebook lock
  enforcement.
- Added focused relation, attachment, grouped-path, and external-ID assertions
  in `Tests/RielaCLITests/NotePersonaAddonTests.swift`.
- Re-verification: `swift build` passed; `swift test --filter
  NotePersonaAddonTests` passed 1/1; `swift test --filter
  NoteSystemMemoryTests` passed 3/3; `git diff --check` passed; the canonical
  removal grep over `Sources Tests Package.swift` is empty; and the intake brief
  remains unchanged.
- Remaining state is unchanged: TASK-008 and TASK-011 are blocked only on the
  pending Telegram SDK operator gate. No unfiltered `swift test`, commit, push,
  release publication, or browser QA was performed.

### 2026-08-01 — Step 6 targeted-suite remediation and final non-gated audit

- Removed stale `riela memory` help text and the remaining top-level command
  expectation; the removal command surface test and registered-command test
  pass.
- Added `Notebook.readOnly` to Note CLI GraphQL selections, attached imported
  page images before applying requested note-level locks, excluded the seeded
  system notebook from ordinary notebook-count fixtures, and isolated GraphQL
  and trio-chat Note roots under test-owned directories.
- Restored the provider-neutral bounded handoff trail by deriving visited
  personas from runtime executed reply steps before normalizing the next
  handoff. The Slack three-person handoff assertion passes.
- `swift test --filter RielaCLITests` now executes 650 tests with failures only
  in the five Telegram SDK parity cases that are intentionally blocked by the
  pending operator gate: 9 assertions, including cleanup follow-on errors. No
  other CLI test failed.
- Additional verification passed: seven focused regression tests covering Note
  ingestion, Note CLI GraphQL, PDF example counts, Slack handoff, and isolated
  workflow GraphQL; `RielaAppSettingsSectionLayoutTests` 19/19; release Swift
  build; web production build, typecheck, and 149/149 web tests; focused
  SwiftLint reported zero violations.
- The accepted Telegram SDK scope remains untouched. Browser QA, operator gate
  resolution, final all-example parity, commit, and push remain pending.

### 2026-08-01 — Step 6 self-review remediation after `comm-000297`

- Addressed all three mid-severity self-review findings. Notebook Lock/Unlock
  now uses a notebook-keyed convergence controller whose version snapshots
  protect refresh, selection, and serialized mutation completion ordering.
- Persona attachments are fully resolved and size-validated before persistence.
  Each entry stages its blobs and persists its note, tags, relations, file rows,
  and attachments in one database transaction; failures remove staged blobs and
  leave no partial note or file records.
- Expanded TASK-005 coverage to four add-on tests for persona isolation,
  deterministic bounded reads, mapping, locked writes, empty no-op writes,
  invalid-attachment rollback, unsupported versions, and rejected legacy
  memory configuration. Added a Note-service rollback test and three web
  read-only convergence tests.
- Extracted the Note add-on operation vocabulary into
  `Sources/RielaCLI/ProductionNodeAdapter+NoteAddonDispatch.swift`; the focused
  SwiftLint run covers all six affected Swift files with zero violations.
- Verification passed: debug and release `swift build`; `NotePersonaAddonTests`
  4/4; `NoteSystemMemoryTests` 4/4; `RielaNoteTests` 137/137; web typecheck;
  152/152 web source tests; web production build; focused ESLint; production
  source audit; focused SwiftLint with zero violations; removal grep; intake
  immutability; and `git diff --check`.
- `RielaCLITests` now executes 653 tests: 648 pass, while the same five
  `RielaExampleParityTests` cases fail only because the untouched gated
  `examples/telegram-sdk-trio-chat/**` still carries the removed `memories`
  declaration. A focused parity run confirmed that exact boundary.
- TASK-005 and TASK-009 completion claims are now backed by the required race,
  rollback, isolation, bounds, invalid-input, and empty-write evidence. TASK-008
  and TASK-011 remain blocked only on the accepted Telegram SDK operator gate;
  no unfiltered `swift test`, browser QA, commit, or push was performed.

### 2026-08-01 — Step 6 cross-field convergence remediation after `comm-000299`

- Addressed the remaining mid-severity TASK-009 finding by composing progress
  and read-only controller state before any mutation response reaches the list,
  deferred drag commit, or external detail notebook.
- Progress and read-only controllers now retain their latest canonical owned
  field when the other controller returns an older full-notebook response.
  Tag-membership and external-notebook requests also carry both controller
  snapshots so their responses cannot restore stale progress or lock state.
- Added two deterministic cross-controller tests covering progress completion
  after Unlock and Unlock completion after progress. The complete web source
  suite passes 154/154 with typecheck, focused ESLint, production source audit,
  and production build also passing.
- TASK-009 remains complete with explicit cross-field evidence. TASK-008 and
  TASK-011 remain blocked only on the accepted Telegram SDK operator gate; no
  unfiltered `swift test`, browser QA, commit, or push was performed.

### 2026-08-01 — Step 6 batch preflight remediation after `comm-000301`

- Addressed the remaining mid-severity TASK-005 finding by preparing every
  persona entry, relationship classification, and attachment before the first
  system-memory append. Local-file attachments are materialized through the
  existing bounded reader during preflight, so later entries cannot fail after
  an earlier entry has already been persisted.
- Replaced the single-entry missing-attachment case with a regression containing
  a valid attached first entry and an invalid attached second entry. The failed
  invocation leaves zero persona notes and zero stored blobs.
- Verification passed: debug `swift build`; focused `NoteAddonTests` plus
  `NotePersonaAddonTests` 21/21; focused strict SwiftLint over the three affected
  Swift files with zero violations; removal grep, intake immutability, and diff
  hygiene remain clean.
- TASK-005 remains complete with explicit batch-preflight evidence. TASK-008 and
  TASK-011 remain blocked only on the accepted Telegram SDK operator gate; no
  unfiltered `swift test`, browser QA, commit, or push was performed.

### 2026-08-01 — Step 6 test-integrity remediation after `comm-000304`

- Addressed all four mid-severity test-integrity findings without reopening the
  accepted design. `Tests/RielaNoteTests/NoteStoreSchemaTests.swift` now builds
  a populated v5-equivalent store and proves preservation of notebooks, notes,
  tags, links, files, attachment rows, metadata, blobs, and stable IDs through
  additive v6 migration.
- Expanded `Tests/RielaNoteTests/NoteSystemMemoryTests.swift` to cover locked
  create/update/delete paths, note and notebook attachment rejection without
  staged files, note-lock independence after notebook Unlock, and duplicate
  `notebook-kind:system-memory` bootstrap rejection.
- Added `Tests/RielaGraphQLTests/NoteGraphQLNotebookReadOnlyTests.swift` using
  the real document executor. It verifies `readOnly` projection, persisted
  Lock/Unlock, canonical mutation output, and missing-notebook `not_found`
  mapping rather than relying on a mocked web response.
- Ported retained persona edge coverage into
  `Tests/RielaCLITests/NotePersonaAddonTests.swift`. The regressions exposed and
  fixed missing self-handoff blocking and restored visited-persona, max-turn,
  runtime-trail, guard-metadata, reply-sanitization, and persona fallback
  behavior in `Sources/RielaCLI/ProductionNodeAdapter+NotePersonaAddons.swift`.
- Verification passed: debug build; focused remediation tests 18/18;
  `RielaNoteTests` 141/141; `RielaGraphQLTests` 111/111; `RielaCoreTests`
  478/478; web source tests 154/154 plus typecheck, production build, and source
  audit; release build; focused strict SwiftLint with zero violations; removal
  grep; and `git diff --check`.
- `RielaCLITests` executed 656 tests. 651 passed; the same five
  `RielaExampleParityTests` cases failed with nine assertions/follow-on cleanup
  errors exclusively because untouched `examples/telegram-sdk-trio-chat/**`
  still contains the operator-gated removed memory contract. No other CLI test
  failed.
- Changed paths for this remediation are
  `Sources/RielaCLI/ProductionNodeAdapter+NotePersonaAddons.swift`,
  `Tests/RielaCLITests/NotePersonaAddonTests.swift`,
  `Tests/RielaNoteTests/NoteSystemMemoryTests.swift`,
  `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`,
  `Tests/RielaGraphQLTests/NoteGraphQLNotebookReadOnlyTests.swift`, and this
  active plan. Codex-agent references remain empty. TASK-008 and TASK-011 stay
  blocked only on the Telegram SDK operator decision; browser QA, commit, and
  push remain pending, and unfiltered `swift test` was not run.

### 2026-08-01 — Step 6 singleton-identity remediation after `comm-000308`

- Addressed the Step 7 mid finding by enforcing the protected
  `notebook-kind:system-memory` singleton in the shared `applyNotebookTag`
  primitive. Bootstrap has the only explicit first-identity allowance;
  ordinary create, note-created notebook, ingest, and tag-mutation paths now
  reject a second assignment transactionally.
- Added service coverage for `createNotebook`, `createNote`,
  `createNotebookWithNotes`, `applyNotebookTags`, rollback/non-creation, and
  successful service reopening. Added real GraphQL document coverage for the
  exposed `createNotebook` and `applyNotebookTags` mutation paths, canonical
  identity preservation, and reopening.
- Refreshed the accepted design header from the stale pending Step 3 status to
  accepted review `comm-000285` and current Step 7 revision `comm-000308`
  without changing design behavior or the Telegram SDK operator gate.
- Verification passed: focused singleton/read-only tests 12/12; combined
  `RielaNoteTests|RielaGraphQLTests` 254/254; debug build reached `Build
  complete`; focused strict SwiftLint passed 0 violations in the new extension
  and regression files. Strict lint of `NoteService.swift` retains only its
  pre-existing `large_tuple` finding at line 391; the new whitespace finding
  was removed. Diff hygiene, intake immutability, removal grep, and deleted
  workflow-directory checks pass.
- This remediation changed no TypeScript, package digest-governed workflow,
  prompt, script, or skill file. README and the implementation workflow skill
  contain no stale removed-memory contract reference, so neither requires a
  content update. Codex-agent references remain empty.
- TASK-008 and TASK-011 remain blocked only on the accepted Telegram SDK
  operator decision. Browser QA, operator cleanup of the already-duplicated
  user-scope store, commit, and push remain pending; unfiltered `swift test`
  was not run.

### 2026-08-01 — Step 6 test-integrity remediation after `comm-000311`

- Addressed all three mid findings and the low finding from the latest Step 6
  test-integrity review. Restored the retained chat-persona router's
  earliest-alias ordering regression in
  `Tests/RielaCLITests/WorkflowCommandTests.swift`.
- Expanded `Tests/RielaCLITests/NotePersonaAddonTests.swift` with the retained
  unvisited-handoff success path, final-turn continuation cleanup without a
  requested handoff, and preservation of a blocked target mention that is not
  a continuation. The tests use the current `upstream` execution shape rather
  than reviving any deleted memory API.
- Corrected
  `Tests/RielaNoteTests/NoteServiceNotebookStatsTests.swift` so the listed
  empty-notebook assertion selects the created notebook by `notebookId`
  instead of accidentally accepting the seeded system notebook.
- Added two mocked browser regressions in `web/e2e/dashboard.spec.ts`. They
  assert the tag-identified system-memory Read-only badge, disabled Add note
  and Edit controls, persisted Unlock/Lock mutations, success feedback, and
  locked-state/error preservation when Unlock fails.
- Verification passed: focused Swift regressions 12/12; `RielaNoteTests`
  142/142; focused SwiftLint 0 violations; TypeScript compiler, focused ESLint,
  and production source audit; web source tests 154/154; production web build;
  and focused Playwright 2/2. `RielaCLITests` executed 660 tests: 655 passed,
  while the same five operator-gated Telegram SDK parity cases produced nine
  failure records; no other CLI test failed.
- Changed paths for this remediation are
  `Tests/RielaCLITests/WorkflowCommandTests.swift`,
  `Tests/RielaCLITests/NotePersonaAddonTests.swift`,
  `Tests/RielaNoteTests/NoteServiceNotebookStatsTests.swift`,
  `web/e2e/dashboard.spec.ts`, and this active plan. Codex-agent references
  remain empty. Operator-owned live browser QA, the Telegram SDK decision,
  user-scope duplicate disposition, commit, and push remain pending. The
  prohibited unfiltered `swift test` was not run.

### 2026-08-01 — Step 6 attachment-path remediation after `comm-000314`

- Addressed the remaining mid-severity test-integrity finding without changing
  the accepted file-to-Note-attachment mapping. `LocalNoteFileStore` now owns
  materialization of its stored relative locator into an absolute file URL,
  and its read/delete paths reuse that boundary.
- The Note-backed persona read add-on now returns absolute `filePaths`,
  `imagePaths`, `audioPaths`, `videoPaths`, and `pdfPaths` under the active Note
  root instead of exposing database-relative locator strings.
- Restored the retained attachment regression in
  `Tests/RielaCLITests/NotePersonaAddonTests.swift`: the returned image/file path
  must be rooted under the test Note store, exist, match across both arrays, and
  preserve the exact stored bytes.
- Verification passed: focused `NotePersonaAddonTests|NoteFileStoreTests` 25/25;
  the complete filtered `RielaNoteTests` suite executed 142/142 successfully
  before its command wrapper timed out after suite completion; strict SwiftLint
  reported zero violations in all three changed Swift files; and `git diff
  --check` passed immediately after the edits. No TypeScript file changed, so
  the previously accepted web verification remains current.
- The complete filtered `RielaCLITests` suite executed 660 tests: 655 passed and
  the same five operator-gated Telegram SDK parity cases produced nine failure
  records. A focused `RielaExampleParityTests` rerun confirmed every failure is
  caused by the untouched `examples/telegram-sdk-trio-chat/**` removed-memory
  contract or its cleanup follow-on; the migrated trio-chat Note-context test
  passed.
- `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md` contain no
  persona attachment-path contract requiring refresh for this internal locator
  correction.
- Codex-agent references remain empty. The Telegram SDK operator decision,
  user-scope duplicate disposition, browser QA, commit, and push remain pending;
  unfiltered `swift test` remains prohibited.

### 2026-08-01 — Step 6 adversarial-review remediation after `comm-000319`

- Addressed all three mid findings and all four low follow-ups from the
  adversarial Step 7 review. `appendConversationTurn` now requires a writable
  notebook, closing the public conversation-content bypass while focused tests
  prove comments, links, note tags, notebook tags, and progress remain allowed
  on locked notebooks.
- Replaced per-entry persona persistence with one system-memory batch
  transaction. Every note, tag, relation, file row, and attachment now commits
  together; staged blobs are removed on rollback. Stable note IDs derived from
  the workflow execution/source-step identity make post-commit retries return
  the original batch without duplicate notes or files.
- System-tag seeding now fails closed when a pre-v6 user-owned
  `notebook-kind:system-memory` tag collides with the protected identity.
  Bootstrap also rejects a tagged notebook whose assignment is not the
  non-deletable `riela-note` system assignment. The v5 collision test proves
  the v6 column and version marker roll back without mutating the user tag.
- Relation preflight now classifies only `NoteServiceError.notFound` as an
  external identifier and propagates invalid-row or operational failures.
  Added focused observer coverage for both Lock and Unlock publication and
  refreshed this plan's communication trace through `comm-000319`.
- Verification passed: debug `swift build`; the focused adversarial regression
  set 33/33; complete filtered `RielaNoteTests` 149/149; and strict SwiftLint
  over seven changed Swift files with zero violations. The separately linted
  `NoteStoreSchema.swift` retains only its pre-existing `large_tuple` finding,
  shifted to line 106. A tracked-source deletion grep returned no removed-memory
  references.
- `RielaCLITests` executed 662 tests: 657 passed, while the same five
  operator-gated Telegram SDK parity cases produced nine failure records. A
  focused `RielaExampleParityTests` rerun confirmed all failures originate from
  the untouched `examples/telegram-sdk-trio-chat/**` legacy `memories` surface
  and its cleanup follow-ons; the migrated trio-chat Note-context test passed.
- No TypeScript file changed, so the accepted web verification remains current.
  The intake brief remains untouched. Codex-agent references remain empty; no
  unfiltered `swift test`, commit, push, browser QA, or operator-gated Telegram
  SDK modification was performed.

### 2026-08-01 — Step 6 confirmed Telegram SDK migration after `comm-000322`

- Addressed both mid-severity test-integrity findings from `comm-000322`. The
  CONFIRMED decision in
  `design-docs/user-qa/qa-note-system-memory-telegram-sdk-example.md` is now the
  implementation contract: the Telegram SDK example is retained, all five
  parity cases remain enabled, and its generic save/load flow is Note-backed.
- Added `riela/note-memory-save` and `riela/note-memory-load` through
  `Sources/RielaCLI/ProductionNodeAdapter+NoteMemoryAddons.swift`, with
  system-notebook lock bypass, workflow/stream isolation, bounded newest-first
  reads, structured payload metadata, materialized attachments, and rejection
  of unsupported versions and legacy storage configuration. No update, search,
  raw-summary, standalone database, or root compatibility surface was added.
- Added the query/tag seam in
  `Sources/RielaNote/NoteService+SystemMemory.swift`; registered, validated, and
  dispatched the two IDs through the existing Note add-on boundary; and added
  `Tests/RielaCLITests/NoteMemoryAddonTests.swift` for payload, isolation,
  attachment, locked-write, and legacy-config coverage.
- Migrated `examples/telegram-sdk-trio-chat/workflow.json` by deleting the
  top-level and seven node `memories` fields and replacing legacy save/load IDs.
  Updated its expected results, example catalog/event-source documentation, and
  parity test Note-root isolation without deleting, skipping, or weakening any
  retained case.
- Verification passed: `swift build`; focused `NoteMemoryAddonTests` 2/2;
  focused port/validation and Telegram routing regressions 4/4; complete
  filtered `RielaCLITests` 664/664; complete filtered `RielaNoteTests` 149/149;
  complete filtered `RielaCoreTests` 478/478; Telegram SDK CLI validation with
  no diagnostics; and its deterministic mock with exit 0 and 10 node
  executions against `tmp/note-system-memory/telegram-sdk-note`.
- The canonical removal sweep across `Sources`, `Tests`, `Package.swift`, and
  `examples` produced no output, including a separate example `memories` sweep.
  Focused strict SwiftLint passed with zero violations after removing four
  blank lines from `ProductionNodeAdapter+NoteAddons.swift` to preserve its
  1,200-line limit. `git diff --check`, the deleted-workflow assertion, the
  unchanged-intake assertion, and 24 balanced plan fence markers passed.
- No TypeScript file changed during this remediation, so the accepted web
  evidence remains current: 154/154 source tests, production build, and focused
  Playwright 2/2 from `comm-000321`. GraphQL behavior was unchanged and its
  focused system-memory evidence remains current. Operator-owned live browser
  QA, user-scope duplicate disposition, best-effort staged-file cleanup risk,
  commit, and push remain explicit. Unfiltered `swift test` was not run.

### 2026-08-01 — Step 6 isolation and attachment-bound remediation after `comm-000324`

- Addressed both mid-severity self-review findings. Generic Note-memory saves
  reject the reserved `system-memory-stream:`, `system-memory-workflow:`, and
  `system-memory-node:` tag prefixes, and loads now require the internal tags
  and versioned `metaJSON` scope to agree before returning a note.
- Added a spoofed-tag regression proving a note tagged for two workflows is
  visible only to the workflow recorded in its metadata. Added deterministic
  attachment boundary coverage proving 64 unique references succeed and 65
  unreadable unique references are rejected before any file is read or staged.
- Updated `design-docs/specs/design-note-system-memory.md` to identify both
  authorized system-append callers and record the reserved-prefix, metadata
  agreement, and 64-attachment contracts. `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` require no contract refresh.
- Verification passed: `swift build`; focused `NoteMemoryAddonTests` 4/4;
  complete filtered `RielaCLITests` 666/666; complete filtered
  `RielaNoteTests` 149/149; and strict SwiftLint over the three changed Swift
  files with zero violations. The CLI wrapper timed out only after the complete
  passing suite while SwiftPM entered post-test planning.
- Canonical removal sweeps across `Sources`, `Tests`, `Package.swift`, and
  `examples`, the separate example `memories` sweep, `git diff --check`, the
  unchanged-intake assertion, the deleted-workflow assertion, and 24 balanced
  plan fence markers passed. No TypeScript or Core file changed, so the accepted
  web evidence (154/154, build, Playwright 2/2) and filtered Core evidence
  (478/478) remain current.
- Codex-agent references remain empty. Operator-owned live browser QA and
  user-scope duplicate system-memory disposition remain pending. Staged-file
  cleanup remains best-effort; no unfiltered `swift test`, commit, or push was
  performed.

### 2026-08-01 — Step 6 lock-bypass and operational-doc remediation after `comm-000328`

- Addressed both Step 7 mid findings. `SystemMemoryAttachmentInput`,
  `SystemMemoryNoteInput`, `systemMemoryNotebook`, both append methods, both
  list methods, and internal scope-tag helpers now use Swift package access;
  only the required public Lock/Unlock mutation remains public. The package-only
  append boundary validates a maximum of 64 attachments per batch and 8 MiB per
  attachment before any staging or database mutation.
- Added `testSystemAppendEnforcesAttachmentCountAndSizeBeforeStaging`, which
  proves both limits fail without persona-note rows or staged files. Verification
  passed: `swift build`; focused `NoteSystemMemoryTests` 15/15; focused
  `NoteMemoryAddonTests|NotePersonaAddonTests` 16/16; complete filtered
  `RielaNoteTests` 150/150; complete filtered `RielaCLITests` 666/666; and strict
  SwiftLint over the two changed Swift files with zero violations.
- Refreshed `.codex/skills/riela-chat-example-verification/SKILL.md`,
  `references/matrix-local.md`, and `references/history-evidence.md`. Deleted
  standalone-memory commands and artifacts are now explicitly historical-only;
  current deterministic and attachment checks use isolated `RIELA_NOTE_ROOT`,
  `note-store.sqlite`, system-memory notebook tags, and Note file relations.
  The skill-creator validation script reports `Skill is valid!`.
- Updated `design-docs/specs/design-workflow-json.md` to list only
  `riela/note-persona-context-read|write` and `riela/note-memory-save|load`, with
  no update, search, or raw/daily-summary successor. No `riela-package.json`
  exists in this repository, so no governed digest refresh applies.
- The stale-contract sweep, canonical removal sweep across `Sources`, `Tests`,
  `Package.swift`, and `examples`, package-access sweep, deleted-workflow check,
  `git diff --check`, and unchanged-intake assertion passed. No TypeScript or
  Core file changed in this remediation, so accepted web evidence (154/154,
  production build, Playwright 2/2) and filtered Core evidence (478/478) remain
  current from `comm-000327`.
- Findings are resolved and Step 6 is ready for Step 7 re-review. Codex-agent
  references remain empty. Existing user-scope duplicate system-memory
  assignments require operator disposition; staged-file cleanup after deletion
  failure remains best-effort; operator-owned live browser QA remains pending;
  no unfiltered `swift test`, commit, or push was performed.

### 2026-08-01 — Step 6 current-design remediation after `comm-000330`

- Addressed the mid-severity documentation finding without changing runtime,
  tests, TypeScript, workflows, or the accepted design. Updated
  `design-docs/specs/design-riela-note.md` and
  `impl-plans/active/riela-note.md` to describe the Note-backed persona-context
  and workflow/stream save-load add-ons instead of the deleted legacy family.
- Rebased `design-docs/specs/design-hermes-inspired-capabilities.md` and
  `impl-plans/active/hermes-inspired-capabilities.md` Phase H-B onto eligible
  system-memory notes, Note-backed recall, the `riela note`/Note GraphQL
  surfaces, and workflow/stream/persona isolation. The future plan explicitly
  forbids restoring the standalone store, memory CLI, regex compatibility,
  workflow `memories`, or legacy add-ons.
- Updated the current loop-engineering gap design so its independent lesson
  store is contrasted with Note system memory rather than nonexistent
  standalone chat memory. Historical reviewed-at-commit and superseded decision
  records remain unchanged as evidence, not current implementation guidance.
- Expanded documentation verification to inventory wildcard references and
  deleted types/files, then applied a fail-closed stale-positive-contract gate
  across current designs, active plans, README, and workflow-use skills. The
  current-contract gate, canonical implementation/example removal sweep,
  `git diff --check`, unchanged-intake assertion, deleted-workflow assertion,
  and 24 balanced plan fence markers passed.
- No Swift or TypeScript file changed in this remediation, so current passing
  evidence remains applicable: `swift build`; filtered RielaNoteTests 150/150,
  RielaCLITests 666/666, and RielaCoreTests 478/478; web source tests 154/154
  and production build. Immediate release/web artifact refresh remains the
  pre-browser-QA gate rather than a documentation blocker.
- Findings are resolved and Step 6 is ready for implementation self-review.
  Codex-agent references remain empty. Existing user-scope duplicate
  system-memory assignments require operator disposition; staged-file cleanup
  after deletion failure remains best-effort; operator-owned live browser QA
  remains pending; no unfiltered `swift test`, commit, or push was performed.

### 2026-08-01 — Step 6 attachment-security remediation after `comm-000335`

- Addressed both mid-severity adversarial findings without changing the
  accepted design. Local attachment containment now compares symlink-resolved
  roots and targets, rejecting an in-root symlink whose target escapes the
  configured root. Generic Note-memory saves now reject every non-null missing,
  malformed, unsupported, or otherwise unresolved requested attachment before
  invoking the system append path; mixed valid/invalid batches persist no note
  or staged blob.
- Added focused regressions for symlink escape, mixed valid/missing atomic
  failure, unsupported URL references, and malformed reference objects in
  `Tests/RielaCLITests/NoteMemoryAddonTests.swift`. The shared attachment
  boundary moved to
  `Sources/RielaCLI/ProductionNodeAdapter+NoteAttachmentSupport.swift`, and
  page-input parsing moved to
  `Sources/RielaCLI/ProductionNodeAdapter+NoteIngestSupport.swift`; this reduced
  `ProductionNodeAdapter+NoteAddons.swift` from 1,199 to 981 lines without
  changing Note-ingest behavior.
- Verification passed with the explicit Xcode Swift toolchain: `swift build`
  completed successfully; rebuilt `NoteMemoryAddonTests` passed 7/7; complete
  filtered `RielaCLITests` passed 669/669 in 137.164 seconds; strict SwiftLint
  over all five changed Swift/test files reported zero violations; and
  `git diff --check` passed. The earlier `--skip-build` 4/4 result was discarded
  because it used the old test bundle. The complete CLI wrapper timed out only
  after XCTest reported the full 669/669 passing summary.
- Recorded the ordinary Step 7 focused AppSupport and stdio evidence from
  `comm-000334`: 27/27 passed. TASK-011 remains in progress because `swift
  build -c release` and the web production build must be refreshed immediately
  before operator-owned browser QA, not during this earlier remediation.
- Updated the accepted design's attachment-security wording. `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` were reviewed and need no
  contract change. No governed `riela-package.json` digest applies. TypeScript
  was unchanged, so current web evidence remains 154/154 source tests,
  production build, and focused Playwright 2/2.
- Codex-agent references remain empty. Best-effort cleanup after a failed
  staged-file deletion and operator-owned browser QA remain explicit. No
  unfiltered `swift test`, release artifact refresh, browser QA, commit, or push
  was performed.

### 2026-08-01 — Step 6 test-integrity remediation after `comm-000338`

- Addressed the sole mid-severity test-integrity finding without changing
  production behavior or accepted scope. Added
  `testLoadReturnsNewestBoundedRecordsInWorkflowOrder` in
  `Tests/RielaCLITests/NoteMemoryAddonTests.swift`.
- The regression saves three records for one workflow and a newer record for a
  different workflow, assigns deterministic timestamps, loads with `limit: 2`,
  and asserts the exact newest two in service order while excluding the newer
  unrelated record.
- Completion criteria now name multi-record newest-first ordering and read-limit
  bounds explicitly. The rebuilt focused suite passed 8/8, and the complete
  filtered `RielaCLITests` suite passed 670/670 in 141.177 seconds; both wrappers
  timed out only after their complete XCTest summaries while SwiftPM entered
  post-test planning. Strict SwiftLint over the changed test reported zero
  violations. `git diff --check`, intake immutability, changed-file whitespace,
  and 24 balanced plan fence markers passed.
- The pending immediate pre-browser release/web artifact refresh, operator-owned
  browser QA, best-effort staged-file cleanup risk, user-scope duplicate
  disposition, and no-commit/no-push state remain unchanged. Unfiltered
  `swift test` was not run.
- Codex-agent references remain empty. No production, TypeScript, workflow,
  example, README, skill, or read-only intake file changed in this remediation.

### 2026-08-01 — Step 6 ordinary-review remediation after `comm-000342`

- Addressed all three mid-severity findings without changing the accepted
  design. The built-in resolver now fails closed for every unresolved
  `riela/*` name, including every deleted memory add-on ID; the two existing
  container-backed gateway add-ons remain an explicit recognized passthrough
  contract. Focused rejection coverage includes all seven deleted IDs and an
  arbitrary unknown built-in.
- Generic Note-memory saves now reject the reserved `persona:` namespace.
  Persona context reads also require the `persona:<id>` tag and versioned
  metadata (`systemMemoryVersion == 1` and the same `personaId`) to agree.
  Added reservation and mismatched-tag regressions and updated the parity seed
  fixture to use the accepted versioned persona metadata contract.
- Notebook page ingestion now recovers the requested final read-only state for
  every created page when attachment processing fails. The focused oversized
  attachment regression reopens the Note store and proves the persisted page
  is locked after the reported failure.
- Verification passed with the explicit Xcode Swift toolchain: six focused
  remediation and parity tests passed 6/6; the requested combined Note add-on
  suites passed 39/39; and the complete filtered `RielaCLITests` suite passed
  673/673 in 140.880 seconds after the final persona-tag reservation. A
  test-only declaration split restored the
  type-length boundary without changing assertions; the rebuilt combined suite
  again passed 39/39. Strict SwiftLint passed all nine changed Swift/test files
  with zero violations. `git diff --check`, the unchanged-intake assertion, the
  canonical removal sweep (allowing only the deliberate `memories` rejection
  diagnostic), and 24 balanced plan fences passed.
- No TypeScript file changed, so no new TypeScript post-modification check was
  required. TASK-011 remains in progress for the immediate release/web artifact
  refresh before operator-owned browser QA. Codex-agent references remain
  empty; no unfiltered `swift test`, commit, or push was performed.

### 2026-08-02 — Step 6 catalog and lock/tag convergence remediation after `comm-000346`

- Addressed both mid-severity ordinary-review findings without changing the
  accepted design. `RielaBuiltinAddonCatalog.noteAddons` now declares version 1
  descriptors for `riela/note-memory-save`, `riela/note-memory-load`,
  `riela/note-persona-context-read`, and
  `riela/note-persona-context-write`. `AddonExecutionContractsTests` asserts
  their ordered catalog membership, names, supported version, and version-2
  rejection.
- `NotebookReadOnlyController` now versions adopted notebook models. When a
  Lock/Unlock response completes after another controller adopted a newer
  notebook snapshot, it merges only the returned `readOnly` value into that
  newest snapshot instead of replacing tags, folder membership, progress, or
  other model fields. Deterministic controller tests cover both completion
  orders for concurrent tag and Lock/Unlock operations.
- Focused web controller tests passed 17/17. The full TypeScript post-change
  chain passed typecheck, 156/156 source tests with 1,815 assertions, production
  build, focused ESLint, and production-source audit. `RielaAddonsTests` passed
  53/53, and `swift build` completed successfully; their wrappers timed out only
  after the complete success summaries because of the recurring SwiftPM
  post-command process behavior.
- Replaced TASK-011's impossible literal no-output search with separate live
  contract gates and an exact count assertion for the seven intentional
  fail-closed deleted-add-on rejection IDs. Supplemental sweeps now explicitly
  allow only the parser diagnostic and focused negative tests.
- TASK-011 remains in progress solely for the immediate release/web artifact
  refresh before operator-owned browser QA. Codex-agent references remain
  empty. No unfiltered `swift test`, browser QA, commit, or push was performed.
