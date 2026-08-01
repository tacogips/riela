# Riela Note Implementation Plan

**Status**: COMPLETE — TASK-024 through TASK-030 delivered the sole current
work package: the Note hub gap-and-waste analysis, standalone-memory removal,
and the read-only system-memory notebook. Earlier packages in this file are
historical records; baseline deferrals remain out of scope.
**Workflow Mode**: `issue-resolution` (exactly one feature/work package;
`has_feature_fanout = false`)
**Issue Reference**: No GitHub issue was provided. Runtime issue title:
“Riela Note hub: gap-and-waste analysis + fold system memory into Riela Note
(delete RielaMemory, add read-only system-memory notebook).” Workflow execution:
`codex-design-and-implement-review-loop-session-650`.
**Codex-Agent References**: None provided; the runtime intake and accepted
design are authoritative.
**Design Reference**: `design-docs/specs/design-riela-note.md` (D20–D24,
Schema-v6 and system-memory bootstrap, memory-to-note mapping, standalone
memory removal boundary, GraphQL/REST/UI surfaces, and Verification)
**Accepted Design Review**: `comm-001847`, accepted with no findings and no
revision requested.
**Created**: 2026-07-04
**Last Updated**: 2026-08-01

## Current Issue-Resolution Work Package: System Memory in Riela Note

### Objective and boundaries

Deliver exactly one issue-resolution work package on
`feat/note-hub-improve`, confined to
`<isolated-worktree>`:

1. Write and commit the Note hub gap-and-waste analysis before implementation.
2. Remove the standalone `RielaMemory` package, CLI, add-ons, workflow schema,
   runner/validation code, fixtures, and examples without touching stored
   `.riela/memory/` data.
3. Add the schema-v6 read-only system-memory notebook, privileged NoteService
   write path, six note-backed successor add-ons, GraphQL/REST lock mutation,
   and SolidJS Unlock/Lock UI.
4. Migrate the Slack, Telegram, and Discord trio examples atomically with
   example-name, mock-count, and parity fixtures.
5. Verify, review, document, and commit all work locally. Do not push, switch
   branches, rebase, merge, or modify the parallel checkout at
   `<parallel-checkout>`.

The accepted design is authoritative. Optional Phase 3 implementation is
permitted only after TASK-025 through TASK-029 are complete and every required
Phase 2 build, test, typecheck, example-validation, and deletion-audit gate is
green. Even then, TASK-024 must have ranked the item as small and high-value;
otherwise record it only as a follow-up in the analysis document.

### Data flow and invariants

1. Store preparation runs schema migrations through additive `migrateToV6`,
   then idempotently seeds `notebook-kind:system-memory` and the fixed
   `notebook-system-memory` notebook. Conflict handling never rewrites the
   persisted `read_only` value.
2. Ordinary NoteService content writes compute effective lock state as
   `notebook.readOnly || note.readOnly`. Allowed metadata/navigation flows
   remain available exactly as D21 specifies.
3. Typed system-memory save/update entry points resolve the reserved notebook,
   bypass only its notebook-level lock, and suppress auto-action enqueueing.
   No public Boolean bypass is accepted by GraphQL, REST, CLI, or generic note
   add-ons.
4. Successor add-ons translate memory inputs into note body, tags, links,
   files, and bounded metadata; read/load/search operations are restricted to
   the reserved notebook and outputs use notebook/note ids.
5. GraphQL and same-origin REST call the ordinary
   `setNotebookReadOnly` mutation. The web client adopts only the canonical
   response and preserves locked state on failure. Locked content controls stay
   disabled, while read-only source actions such as Expand with Agent remain
   available as required by D21.
6. The trio examples call the new persona Note add-ons with ordinary
   `noteRoot` configuration and no workflow-level `memories` declaration.

### TASK-024: Commit the Note hub gap-and-waste analysis first

**Status**: COMPLETE — committed as `82140ac`.
**Depends On**: Accepted design review `comm-001847`
**Write Scope**:
`docs/briefs/note-hub-gap-and-waste-2026-08-01.md` only for the first commit.

**Deliverables**:

- Reconfirm the verified inventory in
  `docs/briefs/note-system-memory-2026-08-01.md` without reopening operator
  decisions.
- Survey the current Note domain, add-on, GraphQL, REST, and web workspace
  surfaces named by the accepted design.
- Create missing-capability and waste/redundancy tables. Every row must include
  evidence, rationale, a `keep`/`add`/`remove`/`simplify` decision, value, risk,
  and disposition in this work package or as a follow-up.
- Rank the memory-to-note fold first. Treat additional implementation as
  optional and bounded; record anything not selected as a follow-up.
- Commit this document as the first implementation-phase commit, staging only
  its exact path. Do not stage the already modified design or plan in this
  first commit.

**Completion Criteria**:

- The document exists under `docs/briefs/`, covers both gaps and waste, and
  makes every decision explicit.
- `git show --stat --oneline HEAD` proves the first implementation-phase commit
  contains the analysis document and no production code.
- The branch remains `feat/note-hub-improve`; no push occurs.

### TASK-025: Schema v6, system notebook, and NoteService lock boundary

**Status**: COMPLETE — committed in `7e5c29c`; persistence coverage completed in `1d9b11c`.
**Depends On**: TASK-024
**Write Scope**:
`Sources/RielaNote/`, `Tests/RielaNoteTests/`, and only directly required Note
test support.

**Deliverables**:

- Append schema migration 6 with only
  `ALTER TABLE notebooks ADD COLUMN read_only INTEGER NOT NULL DEFAULT 0`;
  update fresh schema and notebook row/model projections.
- Seed the non-deletable `notebook-kind:system-memory` tag and fixed
  `notebook-system-memory` row after migration with `read_only = 1` on insert.
  Preserve an existing row's lock value on every later prepare/open.
- Reject ordinary content mutations covered by D21 when the notebook or note
  lock applies; keep tag, comment, link, progress, read/search, and lock-toggle
  behavior available.
- Protect the reserved notebook from ordinary deletion and reject attempts to
  claim its fixed id or kind through ordinary notebook creation.
- Add narrow typed system-memory save/update operations that resolve the
  reserved notebook, bypass only its notebook lock, reject out-of-notebook
  targets, and suppress auto-actions.
- Add fresh/migrated schema, bootstrap idempotency, persisted unlock, ordinary
  lock rejection, allowed metadata flow, system bypass, target confinement,
  and auto-action behavior tests.

**Completion Criteria**:

- Fresh and v5-migrated stores have equivalent schema-v6 projections and
  preserve existing notebook/note data.
- Exactly one locked system-memory notebook is prepared, and a persisted
  unlock survives reopen.
- Ordinary locked content writes fail with `NoteServiceError.readOnly`; typed
  system writes succeed only in the reserved notebook.
- Focused `RielaNoteTests` pass before downstream adapters are integrated.

### TASK-026: Remove the standalone memory package and runtime surface

**Status**: COMPLETE — committed as part of `7e5c29c`.
**Depends On**: TASK-024
**Write Scope**:
`Package.swift`, `Packages/RielaMemory/`, memory-specific files under
`Sources/RielaCLI/` and `Sources/RielaCore/`, `.riela/workflows/riela-memory-design-impl-review/`,
memory-specific tests, and the shared CLI/Core test-support files enumerated in
`docs/briefs/note-system-memory-2026-08-01.md`.

**Deliverables**:

- Remove all root SwiftPM references and delete `Packages/RielaMemory/`.
- Delete the `riela memory` route, commands, models, parsing, runner injection,
  and help text; split the mixed parser so workflow parsing remains intact.
- Delete legacy memory/persona/raw-summary adapters, file helpers, and the
  `riela/memory-` prefix catch-all. Leave a deliberate registration seam for
  the TASK-027 Note-backed successors without retaining compatibility aliases.
- Delete `WorkflowMemoryScope`, `WorkflowMemoryDeclaration`, all authored and
  resolved `memories` fields/decoding, memory runner resolution, and memory
  validation. Repair shared publication, persistence, prompting, fanout,
  failure, stdio, loop-cost, initializer, and test-support call sites.
- Delete the memory-specific project workflow fixture and tests; do not
  enumerate, migrate, rewrite, or delete any user `.riela/memory/` data.

**Completion Criteria**:

- SwiftPM resolves without `RielaMemory`; workflow and non-memory CLI parsing
  remain represented by tests.
- No production, example, fixture, or test reference to removed memory schema
  symbols remains, except the three examples awaiting TASK-028 and the new
  Note-successor work explicitly owned by TASK-027.
- The deletion is limited to the accepted memory surface and does not alter
  unrelated workflow engine, event-source, or package-manager behavior.

### TASK-027: Implement the six Note-backed memory successor add-ons

**Status**: COMPLETE — committed in `7e5c29c`; persona file continuity completed in `1d9b11c`.
**Depends On**: TASK-025, TASK-026
**Write Scope**:
focused Note add-on adapter files under `Sources/RielaCLI/`, directly required
validation/registration files, and focused successor coverage under
`Tests/RielaCLITests/`.

**Deliverables**:

- Register `riela/note-memory-save`, `riela/note-memory-update`,
  `riela/note-memory-load`, `riela/note-memory-search`,
  `riela/note-persona-memory-read`, and
  `riela/note-persona-memory-write` as exact ids, never prefix dispatch.
- Resolve note roots through the existing Note add-on order and use only
  `RielaNote`/`NoteService` domain boundaries.
- Implement the D24 field mapping for body markdown, metadata provenance,
  tags, related note ids, and attachments; return note/notebook ids rather
  than legacy integer record ids or database paths.
- Restrict load/search/persona reads to the reserved notebook and clamp persona
  limits to `1...30` with deterministic newest-first ordering.
- Preserve persona chat contracts (`memoryMarkdown`, `memoryGuidance`, reply
  text, and handoff flags) while changing the storage contract.
- Cover all six ids, lock bypass, out-of-notebook rejection, provenance,
  attachments, bounded reads, and persona reply/handoff behavior.

**Completion Criteria**:

- All six successors execute through typed NoteService behavior while the
  system-memory notebook is locked.
- No public adapter input can select a privileged bypass or another notebook.
- Focused CLI/add-on tests pass and contain no `RielaMemory` import.

### TASK-028: Migrate trio examples and parity fixtures atomically

**Status**: COMPLETE — committed as part of `7e5c29c`.
**Depends On**: TASK-026, TASK-027
**Write Scope**:
`examples/slack-agent-trio-chat/`, `examples/telegram-agent-trio-chat/`,
`examples/discord-agent-trio-chat/`,
`examples/chat-memory-raw-and-daily-summary/`,
`examples/catalog/chat-persona-and-agent-trio.md`, example-name/mock-count
fixtures, `Tests/RielaCLITests/RielaExampleParityTests.swift`, and directly
related mock scenario tests.

**Deliverables**:

- Remove every workflow/node `memories` declaration from the three trio
  examples and point their six persona read/write nodes at the new Note ids.
- Replace memory-root/database terminology and fixture data with
  note-root/notebook/note terminology while preserving conversational and
  handoff expectations.
- Delete `examples/chat-memory-raw-and-daily-summary/` and its catalog
  reference.
- Update `rielaExampleWorkflowNames()`, expected mock counts, and parity tests
  in the same change.
- Validate and mock-run each modified example.

**Completion Criteria**:

- All three trio examples validate and exercise Note-backed persona memory.
- Example names, counts, mock scenarios, catalog references, and parity tests
  agree exactly.
- No removed add-on id or workflow `memories` key remains outside historical
  documentation.

### TASK-029: Expose persisted lock control through GraphQL, REST, and web

**Status**: COMPLETE — committed in `7e5c29c`; locked-control revision completed in `1d9b11c`.
**Depends On**: TASK-025
**Write Scope**:
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaCLI/NoteCommandGraphQLDocuments.swift`,
`Sources/RielaApp/RielaAppWebNoteWorkspaceAPI.swift`,
`Sources/RielaNoteWorkspace/RielaNoteUIClient.swift`,
`web/src/notes/types.ts`, `web/src/notes/client.ts`,
`web/src/notes/controller.ts`, `web/src/notes/workspace.ts`,
`web/src/views/NotesView.tsx`, directly supporting Note components/styles,
and focused tests in `Tests/RielaGraphQLTests/`,
`Tests/RielaAppSupportTests/RielaAppWebNoteWorkspaceAPITests.swift`,
`Tests/RielaNoteWorkspaceTests/`, and `web/src/**/*.test.ts`. This scope
excludes TASK-027 add-on adapter files.

**Deliverables**:

- Add `Notebook.readOnly` and
  `setNotebookReadOnly(notebookId:readOnly)` to synchronized GraphQL DTOs,
  contracts, selections, and execution through ordinary NoteService behavior.
- Add `POST /api/v1/notes/notebooks/{notebookId}/read-only` using existing
  Host, Origin, CSRF/session, JSON, and active-profile policies; return the
  canonical notebook and expose no bypass.
- Project `readOnly` into the SolidJS Note client/controller/view. Detect the
  system notebook by `notebook-kind:system-memory`, disable content
  creation/editing while locked, keep read-only source expansion available,
  and render explicit Unlock/Lock controls.
- Adopt only the canonical mutation response; retain the prior lock state and
  show existing error handling on failure.
- Cover GraphQL contract/execution, REST policy/error mapping/profile race,
  web client/controller state, locked controls, unlock, relock, and failure.

**Completion Criteria**:

- GraphQL and REST persist the same notebook-level value and expose no system
  write bypass.
- The system-memory UI is locked by default, unlocks/relocks durably, and does
  not show new lock chrome for ordinary notebooks. A rendered browser test
  distinguishes blocked Add/Edit actions from permitted agent expansion.
- Focused Swift and `web/src` tests pass, and
  `cd web && bun run typecheck` succeeds independently of the Vite build.

### TASK-030: Integration, deletion audit, documentation, and local commits

**Status**: COMPLETE — required gates are green; design/plan evidence is the
final local documentation commit.
**Depends On**: TASK-027, TASK-028, TASK-029
**Write Scope**:
focused regression repairs, `README.md`, directly affected user-facing skills,
`design-docs/specs/design-riela-note.md`, this plan, and the analysis document.

**Deliverables**:

- Run every required verification command below and record exact outcome,
  counts where available, reruns, and any verified unrelated timing flake.
- Audit for dangling `RielaMemory`, legacy add-on ids,
  `WorkflowMemoryDeclaration`, and authored `memories:` references while
  excluding only `docs/**` and `design-docs/**`.
- Review `README.md`, `.codex/skills/riela-impl-workflow/SKILL.md`, example
  catalog text, design, and plan; update only directly affected user-facing
  contracts and preserve accepted historical documentation.
- Review the final diff for additive schema-v6 behavior, lock/bypass
  separation, example parity, removal boundaries, and scope containment.
- Commit implementation and documentation in logical local commits on
  `feat/note-hub-improve`; never push. Record commit hashes and finish with a
  clean status.

**Completion Criteria**:

- TASK-024 through TASK-029 are complete with no unresolved high/mid review
  finding.
- Every required command passes. The known interleaved-submit full-suite flake
  is relevant only if independently reproduced; it cannot waive a filtered
  suite failure.
- All work is committed locally on `feat/note-hub-improve`, no file outside the
  isolated worktree was modified, and `git status --short` is empty.

### Current-work-package dependencies

| Task | Depends On | Reason |
| --- | --- | --- |
| TASK-024 | accepted design | Analysis must be authored and committed first. |
| TASK-025 | TASK-024 | Note schema/domain implementation follows the committed ranking. |
| TASK-026 | TASK-024 | Deletion follows the committed inventory and decisions. |
| TASK-027 | TASK-025, TASK-026 | Successors require Note system writes and the legacy dispatch removal. |
| TASK-028 | TASK-026, TASK-027 | Examples must target final ids after legacy removal. |
| TASK-029 | TASK-025 | API/UI require the completed notebook lock model. |
| TASK-030 | TASK-027, TASK-028, TASK-029 | Integration starts after all product surfaces converge. |

### Parallelization

- TASK-024 is an exclusive first phase because its exact-path commit must
  precede implementation.
- After TASK-024, TASK-025 and TASK-026 may run in parallel: their write scopes
  are disjoint (`Sources/RielaNote` versus package/CLI/Core deletion). Do not
  parallelize shared build/test repair that crosses those scopes.
- After TASK-025, TASK-029 may run in parallel with the TASK-026→TASK-027
  sequence. Keep TASK-029 out of TASK-027's add-on adapter/registration files;
  coordinate any unavoidable shared `Sources/RielaCLI/` registry edit
  sequentially.
- TASK-027 is sequential after TASK-026 because both touch production adapter
  registration. TASK-028 follows TASK-027. TASK-030 is exclusive.

### Required verification

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
swift test --filter RielaCoreTests
riela workflow validate examples/slack-agent-trio-chat
riela workflow validate examples/telegram-agent-trio-chat
riela workflow validate examples/discord-agent-trio-chat
cd web && bun run typecheck
cd web && bun run build
cd web && bun test src
rg -n 'RielaMemory|riela/(memory-|chat-persona-memory-|chat-memory-raw)|WorkflowMemoryDeclaration|memories:' --glob '!docs/**' --glob '!design-docs/**' .
git diff --check
git branch --show-current
git log --oneline --decorate -n 12
git status --short
```

The deletion audit must produce no production/example/fixture/test matches.
Also inspect `Package.swift` and the tracked tree to confirm
`Packages/RielaMemory/` is absent. Record whether each modified trio example
was validated with the built worktree executable if `riela` on `PATH` points
elsewhere.

### Current-work-package completion criteria

- [x] The gap-and-waste analysis is the first implementation-phase commit and
      every row has evidence, rationale, and an explicit decision.
- [x] Schema v6 is additive and existing Note data is preserved.
- [x] Exactly one default system-memory notebook exists; its persisted lock
      survives reopen and its reserved identity cannot be claimed or deleted.
- [x] Ordinary content writes enforce effective read-only state; the typed
      system path bypasses only the notebook lock and suppresses auto-actions.
- [x] Six exact Note-backed successor add-ons pass focused coverage without a
      public bypass or cross-notebook access.
- [x] `RielaMemory`, the memory CLI/add-ons, workflow memory schema/runtime,
      memory fixtures/tests, and raw-summary example are removed without
      touching user `.riela/memory/` data.
- [x] Slack, Telegram, and Discord trio examples, mocks, names, counts, catalog,
      and parity tests are synchronized and green.
- [x] GraphQL, REST, and web lock/unlock behavior is synchronized and tested;
      locked Add/Edit actions stay disabled while source expansion remains
      available.
- [x] The changed TypeScript passes `cd web && bun run typecheck` as a distinct
      gate from Vite build and `bun test src`.
- [x] Required Swift, example, web, source-audit, diff, branch, commit, and
      status checks are recorded and pass.
- [x] Logical commits exist only on `feat/note-hub-improve`; no push occurred
      and final status is clean.

### Current-work-package progress-log expectations

Append one dated entry per implementation/review session containing:

- tasks completed, in progress, and blocked;
- exact files changed and whether their write scope was planned;
- tests added/updated and exact verification commands/results;
- review findings with severity and disposition;
- deletion-audit results, known-flake reruns, residual risks, and gaps;
- commit hashes, branch confirmation, push status (`not pushed`), and final
  worktree status.

### Session: 2026-08-01 System-memory implementation plan authored

**Tasks Completed**: Planning only; accepted Step 3 design review incorporated.
**Tasks In Progress**: TASK-024.
**Files Changed**:
`design-docs/specs/design-riela-note.md`,
`impl-plans/active/riela-note.md`.
**Review Evidence**: `comm-001847` accepted the design with no findings and no
revision request. No Step 5 feedback exists on this first plan iteration.
**Verification**: `git diff --check` and targeted plan/source-reference audits
are required before handoff; implementation commands are planned, not run.
**References**: No GitHub issue or Codex-agent/Cursor reference was provided.

### Session: 2026-08-01 Step 4 self-review revisions

**Tasks Completed**: Addressed both plan-only mid-severity findings from
`comm-001849`.
**Tasks In Progress**: TASK-024.
**Files Changed**: `impl-plans/active/riela-note.md`.
**Findings Addressed**:

- Added the independent `cd web && bun run typecheck` gate to TASK-029,
  required verification, and completion criteria because `bun run build` is
  Vite-only.
- Required TASK-025 through TASK-029 and all Phase 2 gates to be green before
  any optional Phase 3 implementation; otherwise analysis items remain
  follow-ups.

**Verification**: Plan-only revision; implementation commands remain planned,
not run. Run `git diff --check` and targeted text audits before handoff.
**References**: Accepted design review `comm-001847`; Step 4 self-review
`comm-001849`; no GitHub issue or Codex-agent/Cursor reference was provided.

### Session: 2026-08-01 System-memory implementation and verification

**Tasks Completed**: TASK-024 through TASK-030. No task remains in progress or
blocked, and no optional Phase 3 feature was added.
**Files Changed**: Planned scopes only: `Package.swift`, the removed
`Packages/RielaMemory/` and memory workflow/CLI/Core surfaces,
`Sources/RielaNote/`, `Sources/RielaGraphQL/`, the Note adapter and RielaApp
REST surfaces, affected shared test support, the trio examples and parity
fixtures, `web/src/`, `README.md`, the accepted design, and this plan.
Matrix and Telegram-SDK trio fixtures were also migrated because the deletion
audit found the same removed ids there; this is a compatibility repair inside
the accepted example-removal boundary, not feature fan-out.
**Tests Added/Updated**: Schema-v6/bootstrap, notebook lock, system bypass,
attachment/relationship/provenance mapping, all six successor ids, persona
handoff guards, GraphQL mutation execution, REST profile policy, web canonical
lock adoption, parser removal, shared-node fixtures, and example parity.
**Verification**:

- `swift build`: passed.
- `swift test --filter RielaNoteTests`: 135 passed, 0 failed.
- `swift test --filter RielaCLITests`: 649 passed, 0 failed.
- `swift test --filter RielaCoreTests`: 477 passed, 0 failed.
- Focused Note add-on/GraphQL/RielaApp REST tests: 31 passed, 0 failed.
- Worktree executable validation: Slack, Telegram, Discord, Matrix, and
  Telegram-SDK trio workflows all returned `valid: true`.
- `cd web && bun run typecheck`, `bun run build`, and `bun test src`: passed;
  149 web tests passed, 0 failed.
- Removed-symbol/package audit and `git diff --check`: passed with no scoped
  matches or whitespace errors; `Packages/RielaMemory/` is absent.
- Advisory `swiftlint lint --strict` still reports repository-baseline findings
  outside this work package; it is not a required acceptance gate and no new
  feature-specific lint finding remains unresolved.

**Review Findings**: Two implementation-review findings were resolved before
the final gate: D24 relationship/file projection was completed, and direct
GraphQL/REST lock tests plus the supported-mutation inventory were added.
Full CLI rerun failures exposed stale parser, seeded-notebook-count,
shared-node-memory, and persona-handoff fixtures; each was repaired and the
required filter then passed in full.
**Commits**: `82140ac` (analysis only) and `7e5c29c` (implementation, tests,
examples, and public README). This design/plan evidence update is the final
local documentation commit. Branch: `feat/note-hub-improve`; push status: not
pushed. Final status is required to be clean after that commit.
**Residual Risks**: Existing `.riela/memory/` data intentionally remains
orphaned and unread; Matrix/Telegram-SDK migrations exceed the three named
examples only to remove dangling ids. The known unrelated interleaved-submit
timing flake was not observed and did not affect any required filtered suite.

### Session: 2026-08-01 Step 6 self-review revisions

**Tasks Completed**: Closed both mid-severity findings and both verification
gaps from `comm-001854`; TASK-025, TASK-027, TASK-029, and TASK-030 remain
complete. No scope outside the accepted D20-D24 system-memory work was added.
**Files Changed**: `Sources/RielaCLI/ProductionNodeAdapter+NoteMemoryAddons.swift`,
focused CLI and Note tests, `web/src/views/NotesView.tsx`, the focused
`web/src/notes/notebookLock*` helper/tests, and this progress log.
**Findings Addressed**:

- Persona writes attach every projected file to every generated memory note;
  persona reads return deterministic file projections clamped by `fileLimit`.
- Canonical relock success closes stale composer/detail content; the initial
  Expand guard was later removed after `comm-001865` confirmed that D21 keeps
  read-only source expansion available. A failed mutation preserves visible
  state.
- Persisted unlock is asserted after reopening NoteService, and a synthetic
  v5 database proves additive v6 `read_only` migration and legacy-row default.

**Verification**:

- Focused Swift revision tests: 30 passed, 0 failed.
- `swift build`: passed.
- `swift test --filter RielaNoteTests`: 136 passed, 0 failed.
- `swift test --filter RielaCLITests`: 649 passed, 0 failed.
- `swift test --filter RielaCoreTests`: 477 passed, 0 failed.
- Slack, Telegram, Discord, Matrix, and Telegram-SDK workflow validation:
  all returned `valid: true`.
- `cd web && bun run typecheck`, `bun test src`, and `bun run build`: passed;
  154 web tests passed, 0 failed.
- Removed-symbol audit and `git diff --check`: passed.
- Advisory `swiftlint lint --strict`: the same 11 repository-baseline errors;
  no finding in a revision file.

**Commit**: `1d9b11c` (`fix(riela-note): preserve locked memory contracts`).
This progress update is the final local documentation commit; push status is
not pushed and final status must be clean.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. The repository-baseline SwiftLint violations remain
outside the required acceptance gates and revision files.

### Session: 2026-08-01 Step 6 test-integrity revisions

**Tasks Completed**: Closed all three mid-severity test-integrity findings
from `comm-001857`; TASK-025, TASK-027, TASK-028, and TASK-030 remain complete.
No behavior outside the accepted D20-D24 system-memory work was added.
**Files Changed**:
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteMemoryAddons.swift`,
`Tests/RielaNoteTests/SystemMemoryNotebookTests.swift`,
`Tests/RielaCLITests/NoteMemoryAddonHandoffTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`, and this progress log.
**Findings Addressed**:

- Comment promotion now enforces effective note/notebook read-only state.
  The system-memory lock test asserts exact `readOnly` failures for editing,
  deletion, note creation, attachment writes, notebook deletion, and comment
  promotion, plus rejection of reserved-kind claims.
- Persona successor coverage again exercises visited and self handoffs,
  runtime trails, deterministic multiple-flag priority, allowed handoffs,
  maximum-turn continuation removal, non-continuation mentions, and the
  established persona fallback replies.
- Slack, Telegram, and Discord parity coverage now seeds the system-memory
  notebook, mock-runs each workflow with a new Yui memory entry, asserts the
  read-node projection, and verifies the written Note record.

**Verification**:

- Focused system-memory, handoff, and trio persistence tests: 11 passed,
  0 failed.
- `swift build`: passed.
- `swift test --filter RielaNoteTests`: 136 passed, 0 failed.
- `swift test --filter RielaCLITests`: 657 passed, 0 failed.
- `swift test --filter RielaCoreTests`: 477 passed, 0 failed.
- Slack, Telegram, Discord, Matrix, and Telegram-SDK workflow validation:
  all returned `valid: true` through `.build/debug/riela`.
- `cd web && bun run typecheck && bun test src && bun run build`: passed;
  154 web tests passed, 0 failed.
- Production/test/example removed-symbol audit, `git diff --check`, branch,
  and package-removal checks passed.
- `swiftlint lint --strict --no-cache` reported the same 11 repository-baseline
  errors. Focused lint reported only the pre-existing large-tuple diagnostic
  on `NoteService.promoteCommentToNotebook`; the four other revision files
  were clean.

**Documentation Review**: `README.md` and
`.codex/skills/riela-impl-workflow/SKILL.md` remain aligned with the accepted
system-memory contract and require no additional user-facing change.
**Commit**: `c9acbf2` (`fix(riela-note): restore system-memory regressions`).
Branch: `feat/note-hub-improve`; push status: not pushed. This progress-log
update is the final documentation commit, after which status must be clean.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. The 11 repository-baseline SwiftLint errors remain outside
the required gates; no new test-integrity gap remains.

### Session: 2026-08-01 Step 7 implementation-review revisions

**Tasks Completed**: Closed all three mid-severity findings from `comm-001861`.
TASK-024 through TASK-030 and every current-work-package completion criterion
remain complete; no optional Phase 3 scope was added.
**Files Changed**:
`Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+SystemMemory.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteMemoryAddons.swift`,
`Tests/RielaNoteTests/NoteStoreSchemaTests.swift`,
`Tests/RielaNoteTests/SystemMemoryNotebookTests.swift`,
`Tests/RielaCLITests/NoteAddonTests.swift`, and this progress log.
**Findings Addressed**:

- System-memory bootstrap now promotes a same-name pre-v6 tag to the reserved
  system classification while preserving and resolving its stored `tag_id`;
  the v5 migration fixture proves the notebook assignment uses that id.
- System-memory and persona reads apply notebook, namespace, and requested tag
  constraints in SQLite before `LIMIT`, order newest-first, and have no 10,000
  note truncation window. Saturation and 10,001-note regressions cover both
  failure modes.
- Memory-save relationship and attachment inputs are preflighted before the
  first write. A typed system-memory rollback removes partial notes, links,
  attachment rows, file rows, and local blobs when a later composite step
  fails; persona multi-entry writes share the same rollback boundary.

**Verification**:

- Focused migration/search/preflight/rollback tests: 9 passed, 0 failed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed.
- `swift test --skip-build --filter RielaNoteTests`: 139 passed, 0 failed.
- `swift test --skip-build --filter RielaCLITests`: 658 passed, 0 failed.
- `swift test --skip-build --filter RielaCoreTests`: 477 passed, 0 failed.
- `web/` `bun run typecheck && bun test src && bun run build`: passed; 154
  tests, 0 failed, and the production build completed.
- Slack, Telegram, Discord, Matrix, and Telegram-SDK trio workflow validation:
  each returned `valid: true` through `.build/debug/riela`.
- Focused strict SwiftLint found only the two pre-existing large-tuple
  diagnostics in `NoteStoreSchema.swift` and `NoteService.swift`; no revision
  code or test produced a new violation.
- Removed-symbol/package audit, `git diff --check`, and the manual pre-commit
  credential/private-URL/machine-path review passed.

**Documentation Review**: `README.md` and
`.codex/skills/riela-impl-workflow/SKILL.md` remain aligned with the accepted
system-memory contract; the fixes refine correctness without changing the
documented user-facing surface.
**Commit**: `a2c653b` (`fix(riela-note): close system memory review gaps`). This
progress update is committed separately. Branch: `feat/note-hub-improve`;
push status: not pushed. No GitHub issue or Codex-agent reference was provided.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. Repository-baseline SwiftLint violations remain outside
the required gates; no Step 7 verification gap remains.

### Session: 2026-08-01 Step 7 locked-expansion revision

**Tasks Completed**: Closed the mid and low findings from `comm-001865`.
TASK-029 and TASK-030 remain complete; no optional Phase 3 work was added.
**Files Changed**: `README.md`, `impl-plans/active/riela-note.md`,
`web/e2e/dashboard.spec.ts`, `web/src/notes/notebookLock.test.ts`,
`web/src/notes/notebookLock.ts`, and `web/src/views/NotesView.tsx`.
**Findings Addressed**:

- Removed the notebook read-only guard from **Expand with Agent** while
  retaining the lock for source-notebook content mutations such as add and
  edit.
- Added a rendered Playwright regression that routes Unlock and Lock through
  the REST mutation, verifies the persisted canonical state, and proves that
  locked System Memory disables Add note while preserving read-only preview
  and agent expansion.
- Corrected the earlier progress entry and README contract so they record D21
  accurately.

**Verification**:

- `cd web && bun run typecheck`: passed.
- `cd web && bun test src`: 153 passed, 0 failed, 1,814 assertions.
- `cd web && bun run build`: passed.
- Targeted ESLint and `cd web && bun run audit`: passed.
- `cd web && bun run test:e2e`: 46 passed, 0 failed.
- Rendered state was inspected at
  `tmp/web-dashboard-e2e/screenshots/notes-system-memory-lock.png`.
- Removed-symbol audit, `git diff --check`, and the manual pre-commit
  credential/private-URL/machine-path review passed.

**Documentation Review**: `README.md` now states the locked source-expansion
contract; `.codex/skills/riela-impl-workflow/SKILL.md` required no change.
**Commit**: `6572442` (`fix(riela-note): preserve locked source expansion`).
This progress update is committed separately. Branch:
`feat/note-hub-improve`; push status: not pushed. No GitHub issue or
Codex-agent reference was provided.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. Repository-baseline SwiftLint violations remain outside
the required gates; no Step 7 verification gap remains.

### Session: 2026-08-01 Step 6 router test-integrity revision

**Tasks Completed**: Closed the remaining mid-severity test-integrity finding
from `comm-001868`; TASK-026, TASK-028, and TASK-030 remain complete. No
production or TypeScript behavior changed.
**Files Changed**: `Tests/RielaCLITests/WorkflowCommandTests.swift` and this
progress log.
**Finding Addressed**:

- Restored `testBuiltinChatPersonaRouterPrefersEarliestAliasMention` under a
  retained CLI test file. The regression supplies both Rina and Mika aliases
  and asserts that `riela/chat-persona-router` selects the earliest mention,
  preserving non-memory behavior that was previously covered by the deleted
  memory-specific test file.

**Verification**:

- Explicit Xcode Swift toolchain focused router tests: 2 passed, 0 failed.
- `swift test --skip-build --filter RielaCLITests`: 659 passed, 0 failed after
  the focused command rebuilt the current CLI test bundle.
- `git diff --check`: passed.
- Focused strict SwiftLint reported only the pre-existing
  `superfluous_disable_command` at
  `Tests/RielaCLITests/WorkflowCommandTests.swift:8`; the restored test added no
  lint violation.
- Manual staged-patch credential, private-URL, and machine-path review passed.

**Documentation Review**: `README.md` and
`.codex/skills/riela-impl-workflow/SKILL.md` remain aligned because this
revision restores test coverage without changing user-facing behavior.
**Commit**: `493baee` (`test(riela-cli): restore persona routing priority
coverage`). This progress update is committed separately. Branch:
`feat/note-hub-improve`; push status: not pushed. No GitHub issue or
Codex-agent reference was provided.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. Repository-baseline SwiftLint violations remain outside
the required gates. A local blob deletion failure after database rollback can
leave reclaimable unreferenced storage while surfacing the rollback failure.

### Session: 2026-08-01 Step 7 attachment-lock and relock-race revision

**Tasks Completed**: Closed both mid-severity findings from `comm-001872`.
TASK-025, TASK-029, and TASK-030 remain complete; all current-work-package
completion criteria remain satisfied and no optional Phase 3 work was added.
**Files Changed**:
`Sources/RielaNote/AutoActionDispatching.swift`,
`Sources/RielaNote/NoteService+Files.swift`,
`Sources/RielaNote/NoteService+SystemMemory.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`,
`Tests/RielaNoteTests/SystemMemoryNotebookTests.swift`,
`web/src/notes/notebookLock.ts`,
`web/src/notes/notebookLock.test.ts`,
`web/src/views/NotesView.tsx`,
`web/e2e/dashboard.spec.ts`, and this progress log.
**Findings Addressed**:

- Every ordinary local-data, local-URL, and S3 note attachment now enforces
  the effective `notebook.readOnly || note.readOnly` lock at preflight and
  transaction time. The regression covers both local attachment entry points
  for a note-level lock inside a writable notebook.
- Notebook ingestion retains a typed, marker-confined page-image assembly
  capability that bypasses only an imported page note's final lock, never the
  destination notebook lock. Awaiting the canceled auto-action heartbeat task
  prevents a detached cancellation from masking the actual ingest result.
- Relock now runs through the unsaved-edit confirmation without mutating dirty
  state before success. Canonical lock state is always adopted, while draft,
  composer, and preview cleanup requires the response to still target the same
  selected notebook and selection generation.
- Rendered browser regressions cover a declined dirty-draft relock and a
  delayed relock response after navigation to another notebook and composer.

**Verification**:

- Focused Swift attachment and notebook-ingest regressions: 2 passed, 0 failed.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`:
  passed through the focused test rebuild.
- `swift test --skip-build --filter RielaNoteTests`: 140 passed, 0 failed.
- `swift test --skip-build --filter RielaCLITests`: 659 passed, 0 failed.
- `swift test --skip-build --filter RielaCoreTests`: 477 passed, 0 failed.
- `cd web && bun run typecheck`: passed.
- `cd web && bun test src`: 154 passed, 0 failed, 1,816 assertions.
- `cd web && bun run build`: passed.
- `cd web && bun run test:e2e`: 47 passed, 0 failed.
- Targeted ESLint and `cd web && bun run audit`: passed.
- Focused strict SwiftLint found only the pre-existing
  `optional_data_string_conversion` at
  `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift:1095`; no revision
  hunk introduced a lint violation. `swiftformat` is not installed locally.

**Documentation Review**: `README.md` and
`.codex/skills/riela-impl-workflow/SKILL.md` remain aligned because the fixes
enforce the accepted lock and UI-race contracts without changing the public
workflow surface.
**Commit**: This progress entry ships in the local
`fix(riela-note): enforce attachment locks and safe relock` revision on
`feat/note-hub-improve`; push status: not pushed. No GitHub issue or
Codex-agent reference was provided.
**Residual Risks**: Existing `.riela/memory/` data remains intentionally
orphaned and unread. Repository-baseline SwiftLint violations remain outside
the required gates. A local blob deletion failure after database rollback can
leave reclaimable unreferenced storage while surfacing the rollback failure.

## Historical Issue-Resolution Work Package: Hierarchical Tags and Kanban

### Objective and boundaries

Deliver hierarchical tags, the notebook-applicable `folder` system tag class,
typed notebook progress, additive GraphQL exposure, and a minimal per-tag
Kanban presentation as one coherent feature.

Included write scopes:

- `Sources/RielaNote/`: schema v4, models, tag-parent validation, shared
  descendant expansion, notebook progress, and row projection.
- `Sources/RielaGraphQL/`: additive note DTO/SDL/service/document-executor
  changes.
- `Sources/RielaNoteUI/`: notebook progress display and tag-filtered grouped
  presentation.
- `Tests/RielaNoteTests/`, `Tests/RielaGraphQLTests/`,
  `Tests/RielaNoteUITests/`, and
  `Tests/RielaServerTests/ServerContractsTests.swift`.
- This implementation plan and the accepted Riela Note design/progress
  documentation.

Excluded:

- Feature fan-out or a second work package.
- Filesystem folder semantics, notebook ownership changes, containment
  deletion, a general-purpose board designer, or unrelated UI redesign.
- Changed semantics for existing GraphQL fields or exact-name tag-filter
  inputs.
- Unrelated Riela domains, worktrees, and the previously accepted libsql,
  remote-listener, and vector/RAG deferrals.

### Data flow

For every note and notebook tag-filter entry point:

1. Preserve the current tag-name normalization and OR behavior.
2. Resolve requested names to tag ids.
3. Expand each id to itself plus all transitive descendants through
   `tags.parent_tag_id`, with duplicate/bounded traversal for defensive reads.
4. Match note or notebook assignments against the expanded ids.
5. Apply the existing text, class, date, sort, and pagination behavior.

Unknown tag names continue to match nothing. A leaf expands only to itself.
Expansion affects filtering only; it never creates inherited assignments.

### TASK-016: Schema v4, seeds, and typed models

**Status**: COMPLETE
**Depends On**: —
**Write Scope**:
`Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Tests/RielaNoteTests/NoteStoreSchemaTests.swift`, and
`Tests/RielaNoteTests/NoteHierarchyProgressTests.swift` (new).

**Deliverables**:

- Bump `NoteStoreSchema.currentVersion` from 3 to 4 and append
  `NoteSchemaMigration(version: 4, apply: migrateToV4)`.
- Add nullable self-referencing `tags.parent_tag_id` and
  `notebooks.progress TEXT NOT NULL DEFAULT 'none'` with the four-value
  CHECK constraint to both fresh-schema creation and v3→v4 migration.
- Follow the existing guarded migration sequence: probe before alteration,
  apply both changes transactionally, and record version 4 only after success.
  Use the existing rename-copy-rebuild precedent only if the supported SQLite
  runtime cannot add the constrained progress column directly.
- Seed `folder` in `systemTagClasses` without changing existing seed identity
  or idempotency.
- Add `Tag.parentTagId: String?`, `NotebookProgress`
  (`none`, `progress`, `done`, `pending`), and typed `Notebook.progress`.

**Completion Criteria**:

- Fresh databases and migrated v3 databases have equivalent v4 columns and
  constraints.
- Existing notebook rows migrate to `none`; existing tags retain a null
  parent.
- Invalid progress values are rejected by SQLite.
- Existing schema idempotency and system-tag seeds remain intact.

### TASK-017: Shared hierarchy and notebook-progress domain behavior

**Status**: COMPLETE
**Depends On**: TASK-016
**Write Scope**:
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaNote/NoteService+Rows.swift`,
`Sources/RielaNote/NoteService+NotebookTags.swift`,
`Sources/RielaNote/NoteSearch.swift`, one focused hierarchy extension file
under `Sources/RielaNote/` if needed, and
`Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`.

**Deliverables**:

- Extend tag definition/linking with an optional parent.
- Validate parent existence and reject self/ancestor cycles in the same
  transaction that persists the parent relationship.
- Provide one shared descendant-closure facility over `parent_tag_id`; use
  duplicate-eliminating or bounded recursion defensively against malformed
  legacy cycles.
- Route every existing tag-filter site through that shared expansion:
  `NoteService.listNotebooks`, both `NoteService.listNotes` paths,
  `searchNotesByFilters`, `searchNotesByTextLike`, and
  `appendTagPredicates`.
- Parse notebook progress in all notebook row projections and add
  `setNotebookProgress(notebookId:progress:)` through the `NoteService`
  write boundary.
- Preserve exact-name filter inputs, unknown-name behavior, leaf behavior,
  sort order, pagination, FTS behavior, and assignment provenance.

**Completion Criteria**:

- Parent filters surface items assigned to the parent or any descendant for
  both notes and notebooks; child filters do not surface ancestor-only items;
  leaves behave exactly as before.
- List, filtered-search, LIKE fallback, and composed-predicate paths share the
  same expansion behavior.
- Self-parent and ancestor-parent writes fail atomically; defensive reads
  terminate for malformed cyclic data.
- Progress reads and writes round-trip all four enum values.
- A `folder`-class tag can be applied to a notebook through existing notebook
  tag assignment behavior.

### TASK-018: Additive GraphQL contract and execution

**Status**: COMPLETE
**Depends On**: TASK-017
**Write Scope**:
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
supporting note document-input/parsing files only when required,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift` (new), and
`Tests/RielaServerTests/ServerContractsTests.swift`.

**Deliverables**:

- Add `parentTagId` to `NoteTag` and typed progress projection to `Notebook`.
- Let `defineNoteTag` carry the optional parent relationship.
- Add `setNotebookProgress(notebookId, progress)` and route it to
  `NoteService`.
- Keep note/notebook/search `tagFilter` arguments unchanged; inherit
  descendant expansion from the domain service rather than duplicating it in
  GraphQL.
- Add a GraphQL integration test that creates or resolves the seeded `folder`
  class, applies a folder-class tag to a notebook through
  `applyNotebookTags`, and verifies the notebook/tag projection.
- Keep every authoritative `type Query` and `type Mutation` SDL field on one
  physical line and synchronize `GraphQLContracts.swift` with
  `GraphQLNoteSchemaContract.swift`.

**Completion Criteria**:

- Existing GraphQL documents retain their behavior and response fields.
- New parent/progress fields and the progress mutation work through both the
  service facade and document executor.
- GraphQL tag-filter tests prove parent/child/grandchild behavior.
- GraphQL folder-class tagging succeeds through `applyNotebookTags` and is
  projected correctly.
- Server substring contract assertions remain green.

### TASK-019: Minimal notebook progress and per-tag Kanban UI

**Status**: COMPLETE
**Depends On**: TASK-017
**Write Scope**:
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift`, directly supporting
RielaNoteUI components/extensions including the reusable Kanban sections,
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUIClientCatalogTests.swift`,
`Tests/RielaNoteUITests/RielaNoteNotebookRowMetadataTests.swift`, and
`Tests/RielaNoteUITests/RielaNoteKanbanTests.swift` (new).

**Deliverables**:

- Add an explicit tag-filtered notebook-list operation to
  `RielaNoteUIClient`, with a source-compatible default that delegates only for
  an empty filter and fails closed for nonempty filters, plus production
  delegation from `NoteServiceRielaNoteUIClient` to
  `NoteService.listNotebooks(limit:offset:tagFilter:)`.
- Carry notebook progress and tag-filtered notebook pages through the UI client
  and view-model boundary. The Kanban must use notebook-list results, not infer
  notebooks from note-search results.
- Show the progress state on notebook rows.
- When a tag filter is active, present the descendant-inclusive notebook
  result set in fixed `none`, `progress`, `done`, and `pending` groups.
- Route a user progress change through `setNotebookProgress`, refresh the
  affected grouping, and surface mutation failure through existing UI error
  handling.
- Keep filtering and grouping separate; do not introduce folder trees,
  drag-board infrastructure, or broad workspace redesign.

**Completion Criteria**:

- The existing notebook list remains usable without a tag filter.
- UI-client tests prove selected tag names, limit, and offset reach the
  notebook service path while legacy conformers remain source-compatible and
  reject unsupported nonempty filters instead of returning unfiltered results.
- Active tag filtering can switch to or display the four progress groups
  without changing which notebooks the domain query returns.
- The regular-width macOS search popup displays the active per-tag Kanban even
  when the note-search result set is empty.
- Progress changes update persistence and grouping, and failure leaves the
  model/UI consistent with a visible regular-popup error.
- Per-notebook mutation generations and tag/filter context prevent an older
  mutation success or failure from replacing newer canonical state; a
  superseded success reasserts the latest target.
- Failure reconciliation refreshes only the failed notebook and does not
  invalidate a concurrent mutation for another notebook.
- Tag-filter, generation, filter, and offset snapshots prevent stale
  first-page or load-more responses from mutating the active Kanban board.
- The whole package builds, proving RielaNoteUI compiles with the new typed
  models.

### TASK-020: Integrated verification, documentation, and handoff

**Status**: COMPLETE — implementation review was accepted, verification and
documentation refresh are recorded, and commit/push remains a workflow handoff
rather than implementation-plan work.
**Depends On**: TASK-018, TASK-019
**Write Scope**:
focused regression tests, `design-docs/specs/design-riela-note.md`,
`impl-plans/active/riela-note.md`, and directly affected README/skill
documentation only if its user-facing contract requires an update.

**Deliverables**:

- Run the required build and focused suites below, recording exact commands,
  pass/fail counts, reruns, and any verified unrelated flakes.
- Review the changed diff for scope, additive GraphQL behavior, one-line SDL,
  migration parity, and absence of duplicated tag-expansion logic.
- Reconcile design and repository-facing documentation with implemented
  behavior without reopening the accepted scope.
- Append a progress-log entry containing completed tasks, changed files,
  verification evidence, residual risks, and commit/push status.

**Completion Criteria**:

- TASK-016 through TASK-019 are complete with no unaddressed high/mid review
  findings.
- All required verification commands pass; a known flaky failure is accepted
  only after a clean rerun demonstrates it is unrelated.
- No implementation files outside the accepted Riela Note, GraphQL note,
  RielaNoteUI, and focused test scopes are changed.

### Current-work-package dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-016 | — | Establishes schema and public domain types. |
| TASK-017 | TASK-016 | Service behavior consumes the v4 schema and typed models. |
| TASK-018 | TASK-017 | GraphQL projects and invokes the completed domain contract. |
| TASK-019 | TASK-017 | UI consumes the completed domain contract. |
| TASK-020 | TASK-018, TASK-019 | Verification and docs require all surfaces. |

### Parallelization

- TASK-016 and TASK-017 are sequential because both own
  `Sources/RielaNote/` contracts.
- After TASK-017, TASK-018 and TASK-019 are parallelizable: their write scopes
  are disjoint (`RielaGraphQL`/GraphQL+server tests versus
  `RielaNoteUI`/UI tests).
- TASK-020 starts only after both parallel branches merge. Do not parallelize
  overlapping edits within TASK-016 or TASK-017.

### Required verification

```bash
swift build
swift build --target RielaNoteUI --triple arm64-apple-ios17.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift test --filter RielaNoteTests
swift test --filter NoteStoreSchemaTests
swift test --filter NoteServiceMemoKindTagTests
swift test --filter NoteGraphQL
swift test --filter ServerContractsTests
swift test --filter RielaNoteUITests
git diff --check
```

Record a focused source audit confirming that all tag-filter paths use the
shared descendant expansion and that `type Query`/`type Mutation` fields remain
one line. The known `DaemonWorkflowNodePatchTests` event-source restart and
agent-VM interleaved-submit failures are unrelated candidates only; rerun any
failure before classifying it as non-regression.

The iOS-targeted `RielaNoteUI` build is a required portability gate for the
changed UI surface; host-only `swift build` is not a substitute.

### Current-work-package completion criteria

- [x] Exactly one feature/work package is delivered; no feature fan-out.
- [x] Schema v4 migration preserves existing data and fresh-database parity.
- [x] Tag-parent writes are transactional and cycle-safe; recursive reads are
      defensive.
- [x] Every note/notebook list and search tag-filter path expands to self plus
      transitive descendants while preserving leaf and unknown-tag behavior.
- [x] `folder` is seeded and folder-class tags apply to notebooks.
- [x] Notebook progress is typed, defaults/migrates to `none`, and round-trips
      through service, GraphQL, and UI.
- [x] GraphQL changes are additive and one-line SDL assertions pass.
- [x] The minimal UI shows progress and groups active-tag notebooks into the
      four fixed progress states.
- [x] `RielaNoteUI` builds for the iOS simulator target without AppKit or
      unavailable-platform regressions.
- [x] GraphQL verifies folder-class notebook tagging through
      `applyNotebookTags`.
- [x] Required build/tests and `git diff --check` pass with evidence.
- [x] Progress log, documentation review, and commit/push status are recorded.

### Current-work-package progress-log expectations

Each implementation session appends one dated entry with:

- tasks completed and still in progress;
- exact files changed;
- tests added or updated;
- exact verification commands and outcomes;
- review findings and their dispositions;
- residual risks, known-flake reruns, and any verification gaps;
- commit hash and push status when the workflow reaches commit handoff.

### Session: 2026-07-24 Hierarchical-tags/Kanban plan authored

**Tasks Completed**: — (planning only)
**Tasks In Progress**: TASK-016
**Files Changed**:
`design-docs/specs/design-riela-note.md`,
`impl-plans/active/riela-note.md`.
**Review Evidence**: Step 3 accepted
`design-docs/specs/design-riela-note.md` via `comm-001523` with no findings and
no requested revision.
**Verification**: Not run; implementation has not started. Required commands
are listed above.
**References**: No GitHub issue or Codex-agent reference was provided.

### Session: 2026-07-24 Step 5 plan-review revisions

**Tasks Completed**: Plan review findings from `comm-001526` addressed.
**Tasks In Progress**: TASK-016
**Files Changed**: `impl-plans/active/riela-note.md`.
**Review Findings Addressed**:

- Added an explicit iOS-simulator `RielaNoteUI` build gate and matching
  completion criterion.
- Added explicit GraphQL folder-class notebook-tagging coverage through
  `applyNotebookTags`.

**Verification**: Plan-only revision; implementation commands remain
planned-not-run.
**References**: Step 5 review `comm-001526`; accepted design review
`comm-001523`; no GitHub issue or Codex-agent reference was provided.

### Session: 2026-07-24 Hierarchical-tags/Kanban implementation

**Tasks Completed**: TASK-016, TASK-017, TASK-018, TASK-019.
**Tasks In Progress**: TASK-020 (review and commit/push handoff only).
**Files Changed**:
`README.md`,
`design-docs/specs/design-riela-note.md`,
`impl-plans/active/riela-note.md`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaNote/NoteService+Hydration.swift`,
`Sources/RielaNote/NoteService+Rows.swift`,
`Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteTagHierarchy.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+Kanban.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+SearchState.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`,
`Tests/RielaNoteTests/NoteStoreSchemaTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanTests.swift`,
`Tests/RielaNoteUITests/RielaNoteNotebookRowMetadataTests.swift`, and
`Tests/RielaNoteUITests/RielaNoteUIClientCatalogTests.swift`.
**Implementation**: Added schema v4 with nullable single-parent tags and typed
notebook progress; one cycle-safe recursive descendant resolver shared by
notebook listing, note listing, FTS, filter-only search, LIKE fallback, and
linked-neighbor predicates; additive GraphQL parent/progress fields and
progress mutation; and a source-compatible tag-filtered UI client plus fixed
four-state grouped notebook presentation.
**Verification**: Passed
`swift build`;
iOS-simulator `swift build --target RielaNoteUI`;
`swift test --filter RielaNoteTests` (105 tests);
`swift test --filter NoteStoreSchemaTests` (7 tests, included in the domain
suite);
`swift test --filter NoteServiceMemoKindTagTests` (4 tests);
`swift test --filter NoteGraphQL` (61 tests);
`swift test --filter ServerContractsTests` (15 tests);
`swift test --filter RielaNoteUITests` (194 tests);
and `git diff --check`.
SwiftLint completed with no errors; its remaining warnings are pre-existing
large-tuple, file-length, and naming warnings outside this work package.
**Review Evidence**: Step 5 accepted the implementation plan in `comm-001529`;
the initial review evidence and later adversarial revision are recorded below.
**Residual Risks**: Manual visual interaction was not performed; automated UI
construction, grouping/state tests, host compilation, and iOS-simulator
compilation passed. GraphQL SDL remains intentionally one-line and additive.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001523`, `comm-001526`, `comm-001529`; no GitHub issue or
Codex-agent reference was provided.

### Session: 2026-07-24 Adversarial-review revision

**Tasks Completed**: Addressed all Step 7 adversarial findings from
`comm-001534`; TASK-019 completion criteria are reconfirmed.
**Tasks In Progress**: TASK-020 (adversarial re-review and commit/push handoff
only).
**Files Changed**:
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanTests.swift`,
`Tests/RielaNoteUITests/RielaNoteMutationFailureTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUIClientCatalogTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`, and
`impl-plans/active/riela-note.md`.
**Implementation**: The public UI-client compatibility default now delegates
only for an empty tag filter and throws
`notebookTagFilterUnsupported` for nonempty filters, preventing an unfiltered
notebook set from being presented as a successful per-tag board. Capable
conformers explicitly implement the filtered operation.
**Tests Added or Updated**: Added a legacy-conformer fail-closed contract;
empty-query, sub-trigram LIKE-fallback, and linked-neighbor hierarchy
assertions; invalid GraphQL progress rejection with persisted-state
preservation; and failed UI progress mutation grouping preservation.
**Verification**: Passed the combined focused revision suite (12 tests),
`swift build`, the iOS-simulator `RielaNoteUI` target build,
`swift test --filter RielaNoteTests` (105 tests),
`swift test --filter NoteGraphQL` (61 tests),
`swift test --filter RielaNoteUITests` (196 tests), and
`swift test --filter ServerContractsTests` (15 tests);
`git diff --check` passed; SwiftLint completed without errors and reported only
the pre-existing large-tuple, file-length, and type-name warnings.
**Review Findings Addressed**:

- Mid: eliminated the fail-open nonempty UI-client tag-filter fallback.
- Low: covered filter-only, LIKE-fallback, and linked-neighbor descendant
  expansion.
- Low: covered invalid GraphQL progress rejection without persistence changes.
- Low: covered failing UI progress mutations and prior-group preservation.

**Residual Risks**: Manual visual interaction remains unperformed; automated
grouping, error-state, host-build, and iOS-simulator verification passed.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001529`, `comm-001534`; no GitHub issue or Codex-agent
reference was provided.

### Session: 2026-07-24 Step 7 stale-Kanban revision

**Tasks Completed**: Addressed the mid-severity Step 7 finding from
`comm-001538`; TASK-019 completion criteria are reconfirmed.
**Tasks In Progress**: TASK-020 (re-review and commit/push handoff only).
**Files Changed**:
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookPaging.swift` (new),
`Tests/RielaNoteUITests/RielaNoteKanbanRaceTests.swift` (new), and
`impl-plans/active/riela-note.md`.
**Implementation**: Notebook first-page and pagination requests now snapshot
the search generation, notebook-page generation, selected tag filter, list
filter, and pagination offset. Every new first-page request invalidates older
first-page and load-more work. Responses and failures are discarded when those
values become stale; append responses additionally require the original offset
to remain current, so concurrent or superseded pages cannot corrupt notebook
membership or pagination cursors. Notebook paging moved to a focused extension
to keep the main view-model type below its SwiftLint body-length threshold.
**Tests Added**: Deterministic actor-gated races prove a tag change wins over
both an in-flight Kanban load-more page and an in-flight refresh first page,
and that a same-filter refresh invalidates an older load-more page.
**Verification**:
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
passed;
the iOS-simulator `RielaNoteUI` target build passed;
the focused `RielaNoteKanbanRaceTests|RielaNoteKanbanTests` run reported 5
tests passed; the full `RielaNoteUITests` run reported 199 tests passed; and
`git diff --check` passed. Both Swift test commands exited successfully.
SwiftLint completed without errors and reported only the pre-existing
large-tuple, GraphQL file-length, and type-name warnings.
**Review Finding Addressed**:

- Mid: stale refresh or pagination responses can no longer place notebooks
  from an old tag filter onto the active per-tag Kanban board.

**Residual Risks**: Manual visual interaction remains unperformed.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001529`, `comm-001534`, `comm-001538`; no GitHub issue or
Codex-agent reference was provided.

### Session: 2026-07-24 Step 7 macOS Kanban and mutation-race revision

**Tasks Completed**: Addressed both mid-severity adversarial findings and the
bounded-waiter feedback from `comm-001543`; TASK-019 completion criteria are
reconfirmed.
**Tasks In Progress**: TASK-020 (Step 7 re-review and commit/push handoff only).
**Files Changed**:
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+Kanban.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift`,
`Sources/RielaNoteUI/RielaNoteTagKanbanSections.swift` (new),
`Tests/RielaNoteUITests/RielaNoteKanbanRaceTests.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanTests.swift`,
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`, and
`impl-plans/active/riela-note.md`.
**Implementation**: Extracted the four-state notebook board into reusable
SwiftUI sections and mounted it in both the compact notebook list and the
regular-width macOS search popup whenever a tag filter is active. Progress
mutations now carry per-notebook generations and the active notebook-page
generation; stale successes and failures are discarded instead of publishing
or rolling back over newer canonical state, and a current failure reloads the
canonical notebook page before publishing the error state.
**Tests Added or Updated**: Added deterministic actor-gated coverage for
out-of-order success, an older failure completing after newer success, and
refresh invalidation of an in-flight mutation. The actor gate now has a
two-second deterministic timeout. Added regular search-popup content-mode and
AppKit-host rendering coverage for an active parent tag whose notebook is
tagged through a descendant.
**Verification**: The focused
`RielaNoteKanbanRaceTests|RielaNoteKanbanTests|RielaAppNotesIntegrationTests`
run reported 9 tests passed. The combined
`RielaNoteUITests|RielaAppNotesIntegrationTests` run reported 221 tests and
zero failures before its wrapper timeout. The iOS-simulator `RielaNoteUI`
target build and current RielaApp product build passed. SwiftLint completed
without errors and reported only pre-existing warnings.
**Review Findings Addressed**:

- Mid: the regular macOS RielaApp search route now renders the per-tag Kanban.
- Mid: stale progress-mutation completions cannot replace newer state.
- Low: the Kanban request gate waiter now fails with a bounded timeout.

**Visual Verification**: The current direct debug executable was launched with
isolated app/home roots and its base Notes window was captured and inspected.
The AppKit-host PNG from the active hierarchical-tag integration test was
inspected and shows the regular-width four-state board, descendant-tagged
notebook, typed progress state, progress control, and Notes section. An
active-filter window-ID capture from the running executable remains unavailable
because local UI automation timed out and subsequent `screencapture -l`
attempts failed.
**Residual Risks**: The requested active-filter screenshot from the running
executable remains a verification gap; no implementation or automated-test
failure remains.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001542`, `comm-001543`; no GitHub issue or Codex-agent
reference was provided.

### Session: 2026-07-24 Step 6 self-review revision

**Tasks Completed**: Addressed both mid-severity author self-review findings
from `comm-001545`; TASK-019 completion criteria are reconfirmed.
**Tasks In Progress**: TASK-020 (Step 7 re-review and commit/push handoff only).
**Files Changed**:
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+Kanban.swift`,
`Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanRaceTests.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanTests.swift`, and
`impl-plans/active/riela-note.md`.
**Implementation**: The regular-width Kanban now retains its board while
rendering an explicit accessible mutation-failure banner. Progress mutation
validity is scoped by notebook, generation, active tag filter, and list filter
rather than the global notebook-page generation. Failure reconciliation
queries the loaded range and updates only the failed notebook. If an older
successful request persists after a newer request, the view model reasserts
the latest target so persistence and grouping converge on the latest intent.
**Tests Added or Updated**: The failed-mutation test now proves the regular
popup selects its visible failure branch. The actor-gated client now maintains
canonical progress state. Deterministic tests prove refresh plus mutation
completion converges, an older late success cannot persist over a newer target,
and one notebook's failure does not invalidate another notebook's successful
mutation. The regular-width AppKit-host integration test also renders the
failure branch; its inspected PNG shows a legible semantic-color error banner.
**Verification**: The focused
`RielaNoteKanbanRaceTests|RielaNoteKanbanTests|RielaAppNotesIntegrationTests`
run reported 10 tests and zero failures. Broader build, UI suite, iOS target,
lint, and diff checks are recorded in the Step 6 handoff.
**Review Findings Addressed**:

- Mid: regular-width progress-mutation failures are visibly surfaced.
- Mid: per-notebook failure reconciliation no longer invalidates unrelated
  successful mutations.

**Residual Risks**: The active-filter current-executable window-ID screenshot
remains unavailable; the regular-width AppKit-host render remains the visual
evidence.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001545`; no GitHub issue or Codex-agent reference was
provided.

### Session: 2026-07-24 Step 7 filtered-load fail-closed revision

**Tasks Completed**: Addressed the mid-severity Step 7 finding from
`comm-001549`; TASK-019 completion criteria are reconfirmed.
**Tasks In Progress**: TASK-020 (Step 7 re-review and commit/push handoff only).
**Files Changed**:
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+Kanban.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookPaging.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift`,
`Tests/RielaNoteUITests/RielaNoteKanbanRaceTests.swift`,
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`, and
`impl-plans/active/riela-note.md`.
**Implementation**: Every successfully applied notebook first page now records
its exact tag-filter and list-filter context. Compact and regular-width Kanban
surfaces render a notebook snapshot only when that context matches the active
request. Search, refresh, and first-page work clear prior mutation-failure
markers; a load or pagination failure selects a board-load failure surface
without rendering stale membership. Progress-mutation failures retain the
current board only when the stored failure context and message match the active
board and current failed state.
**Tests Added or Updated**: Added deterministic regressions proving that an
initial unfiltered notebook snapshot is not exposed after a tag-filtered load
failure and that an alpha board is not exposed after a failed switch to beta.
The existing mutation-failure and regular-width AppKit-host assertions continue
to prove that a same-board progress failure retains the board and visible error.
**Verification**:

- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaNoteKanbanRaceTests|RielaNoteKanbanTests|RielaAppNotesIntegrationTests.testRegularSearchPopupRendersActiveTagKanban'`
  passed 12 tests with zero failures.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'RielaNoteUITests|RielaAppNotesIntegrationTests'`
  passed 224 tests with zero failures.
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  emitted `Build complete!`; its wrapper remained alive until timeout.
- The iOS-simulator `RielaNoteUI` target build passed.
- Xcode-toolchain SwiftLint completed without errors and reported only the
  pre-existing large-tuple, GraphQL file-length, and type-name warnings.
- Focused `git diff --check` passed.

**Review Finding Addressed**:

- Mid: filtered-load failures can no longer present an unfiltered or
  previous-tag notebook snapshot as the active Kanban board.

**Residual Risks**: The active-filter current-executable window-ID screenshot
remains unavailable; the regular-width AppKit-host render remains the visual
evidence. The host build wrapper remained alive after conclusive successful
output.
**Commit/Push**: Not performed in Step 6; deferred to the workflow commit
handoff.
**References**: `comm-001549`; no GitHub issue or Codex-agent reference was
provided.

### Session: 2026-07-24 Completion-state gate

**Tasks Completed**: TASK-020; TASK-016 through TASK-020 are complete.
**Tasks In Progress**: None in the hierarchical-tags/folder-class/notebook-
progress issue-resolution work package.
**Review Evidence**: Step 7 accepted the implementation as
`accepted_adversarial_review_with_low_coverage_gaps`; Step 8 documentation
refresh `comm-001555` aligned `README.md` and
`.codex/skills/riela-impl-workflow/SKILL.md` and reviewed the design and plan
without reopening scope.
**Verification**:
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests|RielaNoteKanbanRaceTests'`
passed 15 tests with zero failures; `git diff --check` passed. The accepted
SwiftLint command reported only pre-existing warning-level findings before its
wrapper timeout.
**Residual Risks**: The current-executable active-filter window-ID screenshot
remains unavailable; fresh-v4 foreign-key metadata and progress-CHECK
enforcement lack dedicated assertions; GraphQL document execution lacks a
parent-child-grandchild projection assertion for nested `parentTagId`.
**Plan Disposition**: The completed current work package does not justify
archiving this multi-scope plan because the baseline section still owns three
intentional deferrals: real libsql sync, remote note listener/registration, and
vector/embedding multi-source RAG. Each has an exact owner and activation
trigger below. No accepted implementation work remains active.
**Commit/Push**: Not performed; commit generation and push remain downstream
workflow handoff actions.
**References**: `comm-001555`; no external issue or Codex-agent reference was
provided.

## Historical Git-Landing Follow-Up Work Package

### Objective and boundaries

Land the already implemented and review-accepted hierarchical-tags/Kanban
worktree on `feat/riela-note-hierarchical-tags-kanban` as exactly one
`issue-resolution` work package. Success requires a real local commit and a
matching remote branch ref; addon status text is not evidence.

The mandatory scope is repository safety review, exact-path staging, commit,
push, and independent verification. No production-code changes, amend, rebase,
feature fan-out, or other-worktree operations are authorized. The only optional
edits are the two low-severity test additions in TASK-022.

Baseline and target:

- Repository: the repository root containing this active plan
- Branch: `feat/riela-note-hierarchical-tags-kanban`
- Pre-feature HEAD: `e82ede992852a161207c3251168768e8b46a42d4`
- Commit message:
  `feat(riela-note): add hierarchical tags and notebook progress Kanban`
- Remote ref:
  `refs/heads/feat/riela-note-hierarchical-tags-kanban`

### Authorized path manifest

Stage and commit exactly these 37 unique paths from the authoritative runtime
`changedFiles` array:

1. `.codex/skills/riela-impl-workflow/SKILL.md`
2. `README.md`
3. `Sources/RielaGraphQL/GraphQLContracts.swift`
4. `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
5. `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
6. `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`
7. `Sources/RielaGraphQL/NoteGraphQLService.swift`
8. `Sources/RielaNote/NoteModels.swift`
9. `Sources/RielaNote/NoteSearch.swift`
10. `Sources/RielaNote/NoteService+Catalog.swift`
11. `Sources/RielaNote/NoteService+Hydration.swift`
12. `Sources/RielaNote/NoteService+Rows.swift`
13. `Sources/RielaNote/NoteService.swift`
14. `Sources/RielaNote/NoteStoreSchema.swift`
15. `Sources/RielaNote/NoteTagHierarchy.swift`
16. `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`
17. `Sources/RielaNoteUI/RielaNoteLibraryViewModel+Kanban.swift`
18. `Sources/RielaNoteUI/RielaNoteLibraryViewModel+NotebookPaging.swift`
19. `Sources/RielaNoteUI/RielaNoteLibraryViewModel+SearchState.swift`
20. `Sources/RielaNoteUI/RielaNoteNotebookListView.swift`
21. `Sources/RielaNoteUI/RielaNoteSearchPopupSheet.swift`
22. `Sources/RielaNoteUI/RielaNoteTagKanbanSections.swift`
23. `Sources/RielaNoteUI/RielaNoteUIClient.swift`
24. `Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`
25. `Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift`
26. `Tests/RielaGraphQLTests/NoteGraphQLTests.swift`
27. `Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`
28. `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`
29. `Tests/RielaNoteUITests/RielaNoteKanbanRaceTests.swift`
30. `Tests/RielaNoteUITests/RielaNoteKanbanTests.swift`
31. `Tests/RielaNoteUITests/RielaNoteMutationFailureTests.swift`
32. `Tests/RielaNoteUITests/RielaNoteNotebookRowMetadataTests.swift`
33. `Tests/RielaNoteUITests/RielaNoteUIClientCatalogTests.swift`
34. `Tests/RielaNoteUITests/RielaNoteUITests.swift`
35. `design-docs/specs/design-riela-note.md`
36. `impl-plans/README.md`
37. `impl-plans/active/riela-note.md`

The runtime acceptance prose describes “38 changed files,” but its authoritative
`changedFiles` array and the current `git status --porcelain` each contain the
same 37 unique paths. Do not invent a 38th path or stage anything outside that
authoritative set. Record this reconciled count in the progress log and result
payload.

### TASK-021: Repository identity, exact scope, and safety gate

**Status**: COMPLETE
**Depends On**: TASK-020
**Write Scope**: none; this is a read-only gate.

**Deliverables**:

- Confirm the repository root, current branch, and pre-commit HEAD.
- Resolve the authoritative unique path set from runtime `changedFiles`, compare
  it with `git status --porcelain`, and stop if any authorized change is
  missing or an unexpected path would need staging.
- Run the repository `git-precommit-safety-check` workflow over the complete
  unstaged diff, checking credential material, private URLs, and machine-local
  absolute paths. Resolve findings before staging.
- Confirm `git diff --check` is clean.

**Verification**:

```bash
git rev-parse --show-toplevel
git branch --show-current
git rev-parse HEAD
git status --porcelain
git diff --check
```

**Completion Criteria**:

- Repository, branch, and base HEAD match the declared target.
- The authorized unique path set is explicitly recorded and no unrelated path
  is selected for staging.
- The full-diff safety check and `git diff --check` pass.

### TASK-022: Optional low-severity coverage

**Status**: SKIPPED — accepted low-severity residual risks
**Depends On**: TASK-021
**Write Scope**:
`Tests/RielaNoteTests/NoteHierarchyProgressTests.swift` and
`Tests/RielaGraphQLTests/NoteGraphQLHierarchyProgressTests.swift` only.

**Deliverables**:

- Optionally assert fresh-v4 `tags.parent_tag_id` foreign-key metadata through
  `PRAGMA foreign_key_list` and reject an invalid `notebooks.progress` insert.
- Optionally add GraphQL document-execution coverage projecting nested
  `parentTagId` across a parent→child→grandchild chain.
- Keep authoritative `type Query` and `type Mutation` fields one physical line.

**Verification**:

```bash
swift test --filter 'NoteHierarchyProgressTests|NoteGraphQLHierarchyProgressTests'
```

**Completion Criteria**:

- If either optional edit is made, the focused command passes and both modified
  test files remain within the authorized manifest.
- If skipped, record both items as accepted low-severity residual risks.

### TASK-023: Exact commit, push, and independent evidence

**Status**: COMPLETE — final commit and remote-ref evidence is reported in the
Step 6 adapter payload because a commit cannot contain its own hash.
**Depends On**: TASK-021 and TASK-022 only when TASK-022 is executed
**Write Scope**: git index, one new commit, and the target remote branch.

**Deliverables**:

- After all selected edits are complete, rerun the full-diff
  `git-precommit-safety-check` so its evidence covers the exact content that
  will be staged; the earlier TASK-021 result is not sufficient if TASK-022
  changed either test file.
- Reconfirm `git diff --check` immediately before staging.
- Stage each authoritative path explicitly; do not use broad staging.
- Compare the staged path set with the resolved authoritative unique path set
  before committing.
- Create one non-amended commit with the required message.
- Push with upstream tracking to
  `origin/feat/riela-note-hierarchical-tags-kanban`.
- Record the actual local commit hash and the matching remote ref hash.

**Verification**:

```bash
git diff --check
git diff --cached --name-only
git commit -m 'feat(riela-note): add hierarchical tags and notebook progress Kanban'
git rev-parse HEAD
git status --porcelain
git push -u origin feat/riela-note-hierarchical-tags-kanban
git ls-remote --heads origin feat/riela-note-hierarchical-tags-kanban
```

**Completion Criteria**:

- `git rev-parse HEAD` differs from
  `e82ede992852a161207c3251168768e8b46a42d4`.
- The commit contains exactly the resolved authoritative unique path set and
  uses the required message; no amend or rebase occurs.
- The final full-diff safety check and `git diff --check` pass after all
  selected optional edits and before staging.
- `git status --porcelain` is empty after commit, which proves every authorized
  path is clean and no unrelated worktree change was consumed or left behind.
- `git ls-remote --heads origin
  feat/riela-note-hierarchical-tags-kanban` returns the new local commit hash.
- The result payload reports hashes and command evidence, not addon status.

### Inherited implementation, typecheck, test, and documentation gates

TASK-016 through TASK-020 already completed the design-implied production
implementation, macOS build/typecheck, iOS-simulator `RielaNoteUI` build,
domain/GraphQL/UI/integration tests, design refresh, `README.md` refresh, skill
refresh, and progress logging. The accepted evidence records 420 passing tests,
successful macOS and iOS-simulator builds, and a clean `git diff --check`.

This follow-up authorizes no production changes, so those completed gates are
not repeated. If TASK-022 changes either test file, its focused `swift test`
command is mandatory and compiles the affected test and product dependencies.
TASK-023 must still commit the accepted documentation paths
`README.md`, `.codex/skills/riela-impl-workflow/SKILL.md`,
`design-docs/specs/design-riela-note.md`, `impl-plans/README.md`, and this plan.

### Dependencies and parallelization

| Task | Depends On | Parallelization |
| ---- | ---------- | --------------- |
| TASK-021 | TASK-020 | Sequential safety gate. |
| TASK-022 | TASK-021 | Optional; its two test files are disjoint and may be edited in parallel only if explicitly chosen. |
| TASK-023 | TASK-021; TASK-022 if executed | Sequential commit and push gate. |

No mandatory tasks are parallelizable. TASK-023 must wait for all selected
edits and verification to finish.

### Follow-up completion criteria

- [x] Exactly one issue-resolution work package; no feature fan-out.
- [x] No production-code edits beyond the accepted dirty worktree.
- [x] Full-diff safety check reports no unresolved credentials, private URLs,
      or machine-local absolute paths after all selected edits.
- [x] Staged and committed paths exactly match the authoritative unique
      `changedFiles` set.
- [x] A new non-amended commit exists with the required message.
- [x] Authorized paths are clean after commit.
- [x] The remote branch ref exists and equals the new local commit hash.
- [x] Optional test edits, if any, pass the focused test command and are
      included in the commit.

### Follow-up progress-log expectations

Append one dated entry recording TASK-021/TASK-022/TASK-023 dispositions, the
resolved authoritative unique path count, safety findings, optional-test
decision, exact verification commands and results, commit hash, remote ref
hash, residual risks, and the references `comm-001569`,
`codex-design-and-implement-review-loop-session-631`, and
`codex-design-and-implement-review-loop-session-632`. Codex-agent references
remain empty.

### Session: 2026-07-24 Step 4 landing-plan self-review

**Tasks Completed**: Plan-only self-review; no implementation, staging, commit,
or push action performed.
**Tasks In Progress**: TASK-021.
**Files Changed**: `impl-plans/active/riela-note.md`.
**Plan Findings Addressed**:

- Required the safety check and `git diff --check` to run after all optional
  test edits, ensuring they cover the exact final diff.
- Replaced the non-executable path placeholder with the stronger explicit
  `git status --porcelain` clean-worktree command.
- Made completed build/typecheck, test, documentation, and progress-log gates
  explicit without reopening the accepted implementation scope.

**Verification**: `git diff --check -- impl-plans/active/riela-note.md`;
`git branch --show-current`; `git rev-parse HEAD`; and
`git status --porcelain`.
**Review Evidence**: Step 3 accepted the design in `comm-001569`; Step 4 plan
creation is `comm-001570`. No Codex-agent reference was provided.
**Residual Risk**: Runtime prose says 38 files while the authoritative
`changedFiles` array and current status contain the same 37 unique paths.

### Session: 2026-07-24 Step 6 verified git landing

**Tasks Completed**: TASK-021 and TASK-023.
**Task Skipped**: TASK-022; both optional coverage items remain accepted
low-severity residual risks.
**Files Changed by This Follow-Up**:
`impl-plans/active/riela-note.md`; no production-code changes were made beyond
the previously accepted dirty worktree.
**Authorized Manifest**: The runtime `changedFiles` array and
`git status --porcelain` resolve to the same 37 unique paths. The conflicting
runtime prose count of 38 was not used to invent or stage another path.
**Safety Review**: The final full diff was checked for credential material,
private URLs, credential-bearing URLs, private-key content, and machine-local
absolute paths. One machine-local repository path in this plan was replaced
with a repository-relative description; no unresolved safety finding remains.
**Verification**: `git rev-parse --show-toplevel`;
`git branch --show-current`; `git rev-parse HEAD`;
`git status --porcelain`; `git diff --check`;
`git diff --cached --name-only`;
`git commit -m 'feat(riela-note): add hierarchical tags and notebook progress Kanban'`;
`git push -u origin feat/riela-note-hierarchical-tags-kanban`; and
`git ls-remote --heads origin feat/riela-note-hierarchical-tags-kanban`.
The actual local commit hash and matching remote-ref hash are reported in the
Step 6 adapter payload because the commit cannot contain its own hash.
**References**: `comm-001569`, `comm-001570`, `comm-001572`,
`codex-design-and-implement-review-loop-session-631`, and
`codex-design-and-implement-review-loop-session-632`.
**Codex-Agent References**: None.

## Prior Riela Note Baseline and Accepted Deferrals

The previously shipped scope (local note store, CLI/GraphQL/App surfaces, note
agent with cited answers, auto-action loop) is implemented and tested. Its
remaining prose follow-ups remain explicit accepted deferrals:

- **DEFERRED** Real libsql embedded-replica/sync execution and parity
  (TASK-015 is stubbed: driver fails fast for `.embeddedReplica`). Owner:
  next riela-note session; trigger: Turso/libsql sync becomes a user
  requirement (gated test recipe recorded at the bottom of this plan).
- **DEFERRED** Remote note listener/socket and HTTP registration paths
  beyond the local serve surface. Owner: next riela-note session; trigger:
  a remote client (second machine / RielaApp remote mode) needs note sync.
- **DEFERRED** Vector/embedding retrieval, multi-source RAG, and web-search
  behavior for the note agent (current agent answers from local note
  retrieval with citations). Owner: next riela-note session; trigger:
  adoption decision on retrieval quality (relates to the Hermes H-B/H-C
  decision set).

These deferrals are not part of TASK-016 through TASK-020 and must not expand
the current issue-resolution scope.

## Summary

Implement Riela Note: an ontology-oriented note/notebook store on SQLite
with provenance-aware tags, local/S3 file attachments, built-in workflow
add-ons for note operations, a note GraphQL domain (first mutation
surface), a `riela note` CLI family, auto-action workflow dispatch,
packaged ingestion/agent workflows, local note API client management and
auth building blocks, and an iPad-portable SwiftUI UI hosted by
RielaApp. A real remote note socket and libsql sync driver remain
follow-up work.

## Source References

- Design: `design-docs/specs/design-riela-note.md` (decisions D1–D19)
- Requirements memo: `design-docs/riela-note-design.md`
- Code precedents:
  - `Sources/RielaSQLite/SQLiteDatabase.swift` (driver base)
  - `Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift`
    (schema/upsert precedent)
  - `Sources/RielaCLI/ProductionNodeAdapter.swift` (built-in add-on
    dispatch, `riela/memory-*` family)
  - `Sources/RielaGraphQL/GraphQLContracts.swift`,
    `Sources/RielaGraphQL/RielaGraphQL.swift` (DTO/service pattern)
  - `Sources/RielaServer/` (`ServerRequestContext`, route handling)
  - `Sources/RielaCLI/RielaCommand.swift`,
    `Sources/RielaCLI/RielaCLIApplication.swift` (command registration)
  - `Sources/RielaApp/EntryPoint.swift`, window controllers (hosting)

## Scope

**Included**: `RielaNote` target (schema, store, `NoteService`, file
stores, FTS search), `RielaNoteUI` target, note built-in add-ons, note
GraphQL queries + mutations, `riela note` CLI, auto-action dispatch,
packaged example workflows (quick memo, pdf ingest, youtube transcript,
note agent, auto-tagging), note API auth/client-management building
blocks,
RielaApp Notes window + agent/config-agent screens.

**Excluded** (per design Non-Goals): iPhone/iPad apps, Google/Auth0
adapters, vector/embedding RAG, real remote note socket, Turso/libsql
embedded-replica sync driver, OCR/transcription internals, note
revision history.

## Task Breakdown

### TASK-001: RielaNote target — schema and store foundation
**Status**: COMPLETED
**Depends On**: —
**Deliverables**:
- `Package.swift` (new `RielaNote` target + `RielaNoteTests`)
- `Sources/RielaNote/NoteDatabaseDriving.swift`
- `Sources/RielaNote/SQLiteNoteDatabaseDriver.swift`
- `Sources/RielaNote/NoteStoreSchema.swift` (tables, seeds,
  `note_schema_version` migrations)
- `Sources/RielaNote/NoteModels.swift` (Notebook, Note, Tag, TagClass,
  TagAssignment/provenance, FileRecord, Comment, Link, AutoAction)
- `Sources/RielaSQLite/SQLiteDatabase.swift` (FTS5 capability probe in
  `SQLiteOpenOptions`, analogous to `requireJSONB`)
- `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`

**Work**:
- Create target depending on `RielaSQLite` only; implement the driver
  seam (D2) over `SQLiteDatabase` with WAL/busy-timeout/JSONB options.
- Create all tables from the design's Data Model section (including
  locator CHECK on `files` and `note_fts_map`), seed system tag
  classes, notebook-kind system tags, and the default AI-tagging
  `auto_actions` rows (`note-created` and `note-updated`). The seeded
  rows reference the TASK-008 packaged workflow id and stay inert
  (skip-with-diagnostic at dispatch) until that workflow is installed —
  no enable/disable flip needed.
- Add the FTS5 capability probe and the contentless `note_fts` table +
  `note_fts_map`.

**Completion criteria**:
- Fresh open creates schema + seeds idempotently; version table gates
  future migrations; FTS probe fails with a clear diagnostic when
  sqlite lacks FTS5.

### TASK-002: NoteService core (CRUD, tags, links, comments, search)
**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNote/NoteService.swift`
- `Sources/RielaNote/NoteSearch.swift`
- `Tests/RielaNoteTests/NoteServiceTests.swift`
- `Tests/RielaNoteTests/NoteSearchTests.swift`

**Work**:
- Implement notebook/note CRUD with title derivation from the first
  `# ` heading (D4), read-only enforcement (D5), single-note-notebook
  creation path (D3), `listNotebooks` created-desc with first-note
  preview snippet.
- Tag operations enforcing provenance rules (D6): non-deletable guard,
  AI may not remove/overwrite human assignments; tag-class binding (D7).
- Links, comments (allowed on read-only), FTS-backed
  `searchNotes(query, tagFilter, classFilter, limit)` with contentless
  FTS maintenance (delete-command insert + re-insert) inside the write
  transaction.
- `note_number` allocation (`max + 1` in the notebook's write
  transaction) and transactional delete cascades per the design's
  write-semantics rules (bindings + FTS removed; `files` rows retained;
  read-only content rejects deletion).

**Completion criteria**:
- Provenance/read-only/system-tag/deletion rules covered by tests; FTS
  returns ranked snippets and stays consistent after edits/deletes; all
  consumers can operate through `NoteService` only.

### TASK-003: File stores (local + S3) and migration
**Status**: COMPLETED
**Depends On**: TASK-001
**Deliverables**:
- `Sources/RielaNote/NoteFileStore.swift` (protocol + locator model)
- `Sources/RielaNote/LocalNoteFileStore.swift`
- `Sources/RielaNote/S3NoteFileStore.swift` (SigV4 signed HTTP, storage
  profiles; no AWS SDK)
- `Sources/RielaNote/NoteFileMigration.swift`
- `Tests/RielaNoteTests/NoteFileStoreTests.swift`

**Work**:
- Local store with fan-out layout, atomic writes, sha256 verification;
  attach/resolve APIs on `NoteService` (roles: embedded / related /
  source-page-image / source-document).
- S3-compatible backend against named storage profiles (endpoint,
  region, bucket, credential env refs) from note settings.
- Single-file and `migrateAll` local→S3 migration with verify-then-
  switch locator update, per-file error accumulation (D8).

**Completion criteria**:
- Mixed local/S3 attachments resolve transparently; migration is
  verified-copy-then-delete; S3 tests run against a stub HTTP server.

### TASK-004: Auto-action dispatch
**Status**: COMPLETED
**Depends On**: TASK-002
**Deliverables**:
- `Sources/RielaNote/AutoActionDispatching.swift` (protocol)
- `Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`
  (runtime adapter wiring note triggers to workflow execution through
  existing workflow resolution and `WorkflowRunCommand`)
- `Tests/RielaNoteTests/AutoActionTests.swift`
- `Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift`

**Work**:
- After-commit trigger evaluation (`note-created`, `note-updated`,
  `notebook-created`) with tag/kind filter matching; non-blocking,
  at-least-once dispatch carrying note id + content snapshot as
  workflow input (D11).
- Loop guard: `note-updated` fires on body writes only; writes carrying
  an originating action id are excluded from re-dispatch for the same
  note. Unresolved workflow ids are skipped with a diagnostic (keeps
  seeded actions inert until TASK-008 installs the workflow).

**Completion criteria**:
- Matching rows dispatch exactly the configured workflows; failures are
  diagnosed without failing the originating write; loop-guard and
  unresolved-workflow-skip behavior covered by tests.

### TASK-005: Built-in note add-ons
**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003
**Deliverables**:
- Handlers in `Sources/RielaCLI/ProductionNodeAdapter.swift` (or an
  extracted `NoteAddons` file beside it) for: `riela/note-create`,
  `riela/note-update`, `riela/note-get`, `riela/note-search`,
  `riela/note-tag-apply`, `riela/note-attach-file`,
  `riela/note-comment-add`, `riela/notebook-ingest-pages`,
  `riela/note-conversation-save`
- Add-on validation/catalog entries in `Sources/RielaAddons/`
- `Tests/RielaCLITests/NoteAddonTests.swift`

**Work**:
- Implement each add-on over `NoteService`; project event attachments
  via `attachmentReadInputFields`; note root resolved from runtime
  environment (user scope default, D9).
- `notebook-ingest-pages` batch contract per design (pages[],
  sourceDocumentRef, kind tag `imported-material`).

**Completion criteria**:
- Each add-on validated + executable in deterministic mock runs;
  outputs use `candidatePayload` with note ids for downstream steps.

### TASK-006: Note GraphQL domain (queries + mutations)
**Status**: COMPLETED
**Depends On**: TASK-002, TASK-003
**Deliverables**:
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift` (DTOs)
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- Server route wiring in `Sources/RielaServer/`
- `Tests/RielaGraphQLTests/NoteGraphQLTests.swift`

**Work**:
- Queries: note, notebook, notebooks (created-desc + preview),
  searchNotes, tags, tagClasses, noteFile, autoActions.
- Mutations per design (create/update/delete/readonly/tags/comment/
  link/attach/migrate/configureAutoAction/saveConversation) returning
  `GraphQLControlPlaneResult` envelopes; execution through
  `NoteService` (first non-manager mutation path).

**Completion criteria**:
- Same documents succeed via library execution and via server
  `/graphql`; mutation guard failures surface as diagnostics, not
  transport errors.

### TASK-007: `riela note` CLI family
**Status**: COMPLETED
**Depends On**: TASK-006
**Deliverables**:
- Parser cases in `Sources/RielaCLI/RielaCommand.swift` +
  `RielaArgumentParserHelpers.swift`
- `Sources/RielaCLI/NoteCommands.swift`
- Wiring in `Sources/RielaCLI/RielaCLIApplication.swift`
- `Tests/RielaCLITests/NoteCommandTests.swift`

**Work**:
- Subcommands: add, edit, show, delete, list, search, tag, comment,
  attach, readonly, notebook (list/show/create/delete), storage
  migrate, client (register/list/revoke), `--note-root` override,
  `--output json|text`.
- Execute through GraphQL documents against the local note store (per
  requirement), matching existing output-format conventions.

**Completion criteria**:
- CLI round-trip test: add → list → search → attach → storage migrate
  against a temp note root.

### TASK-008: Packaged workflows (ingestion + auto-tagging)
**Status**: COMPLETED
**Depends On**: TASK-005
**Deliverables**:
- Example workflow bundles: `note-auto-tagging`,
  `note-quick-memo`, `note-pdf-ingest`, `note-youtube-transcript`
  (under `examples/` following existing bundle layout)
- Mock scenarios + `EXPECTED_RESULTS.md` per bundle
- `Tests/RielaCLITests/NoteWorkflowExampleTests.swift`

**Work**:
- Auto-tagging: agent worker proposes tags from note body →
  `riela/note-tag-apply` (provenance ai); enable the seeded default
  auto-action.
- Quick memo: chat event → `riela/note-create` (kind user-memo, fixed
  tag `ノート`).
- PDF ingest: OCR/page-image steps (existing capability) →
  `riela/notebook-ingest-pages`; YouTube: transcript →
  `riela/note-create` + `riela/note-attach-file` (related video).

**Completion criteria**:
- All bundles pass `workflow validate` and deterministic mock runs
  asserting created notebook/note/tag/file rows.

### TASK-009: Note API exposure + QR client registration auth
**Status**: PARTIAL
**Depends On**: TASK-006
**Deliverables**:
- `Sources/RielaServer/NoteAPIAuthenticating.swift` (protocol +
  registry)
- `Sources/RielaServer/QRClientRegistrationAuthenticator.swift`
- Registration route + `api_clients` persistence (store in RielaNote)
- CLI: `riela serve --note-api` dry-run/config descriptor,
  `riela note client register|list|revoke`
- `Tests/RielaServerTests/NoteAPIAuthTests.swift` (or existing server
  test suite location)

**Work**:
- Opt-in mount of the note GraphQL surface; network mutations require
  authenticated identity; in-process/local CLI bypasses adapter auth.
- One-time registration codes (CSPRNG, TTL ≤ 5 min, single use), QR
  rendering (terminal + app), bearer tokens stored as sha256, revocation
  and `last_seen_at` (D14, Security section).

**Completion criteria**:
- Local route/auth units reject unauthenticated requests, accept
  registered clients, reject revoked clients, and cover TTL/single-use
  codes. Not complete for remote exposure: `riela serve --note-api`
  does not bind a socket, so an end-to-end HTTP QR registration flow
  remains future work.

### TASK-010: RielaNoteUI SwiftUI module
**Status**: COMPLETED
**Depends On**: TASK-002 (models), TASK-003 (file resolution)
**Deliverables**:
- `Package.swift` target `RielaNoteUI` (SwiftUI, no AppKit imports)
- Views: notebook list (created-desc, first-note preview, search),
  note view (markdown render, text ↔ source-page-image toggle,
  related-files strip, provenance-distinct tag chips, comments,
  linked notes, read-only lock)
- View models bridging `NoteService` via a client protocol so remote
  (GraphQL) backing can substitute later

**Work**:
- Compact-first adaptive layout (iPhone width → split view on regular),
  per D15; keep chrome minimal per requirements.

**Completion criteria**:
- Module compiles for macOS and iOS destinations; previews/tests for
  list + note view; image/text switch works with local and S3-cached
  files.

### TASK-011: RielaApp Notes window + settings integration
**Status**: COMPLETED
**Depends On**: TASK-010, TASK-009 (settings toggle)
**Deliverables**:
- `Sources/RielaApp/NoteWindowController.swift`
  (`NSHostingController` hosting RielaNoteUI)
- Status-bar/menu entry; profile-aware note root
  (`~/.riela/profiles/<profile>/note/`)
- Settings: note API exposure toggle + client management

**Completion criteria**:
- Notes window opens from the status-bar app, browses/searches/edits
  notes against the active profile's note root.

### TASK-012: Note Agent (RAG chat) and conversation persistence
**Status**: PARTIAL
**Depends On**: TASK-005, TASK-008, TASK-010
**Deliverables**:
- Packaged `note-agent` workflow (retrieve via `riela/note-search` →
  cited answer; web/vector retrieval remains follow-up)
- `RielaNoteUI` chat screen (citations deep-link to notes; temp-chat
  toggle + explicit Save)
- Conversation persistence through `riela/note-conversation-save` /
  `NoteService.appendConversationTurn` + `saveConversation(transcript)`
  (temp-chat transcripts held by the caller, never staged in the store)

**Completion criteria**:
- Current local UI/service flow produces an answer with `note_id`
  citations resolvable in the UI; default auto-save creates an
  `agent-conversation` notebook; temp chat persists nothing until Save.
  Full RAG/web-search behavior remains follow-up.

### TASK-013: Note Config Agent screen
**Status**: COMPLETED
**Depends On**: TASK-012
**Deliverables**:
- Dedicated `RielaNoteUI` config-agent screen wired to an agent-worker
  workflow that manipulates tags/classes/auto-actions through note
  GraphQL mutations and workflow authoring surfaces only

**Completion criteria**:
- Config agent can define a tag class, adjust the auto-tagging action,
  and scaffold an ingestion workflow, all auditable as mutations.

### TASK-014: Documentation and registration
**Status**: COMPLETED
**Depends On**: TASK-007
**Deliverables**:
- README/command docs for `riela note` and `--note-api`
- `impl-plans/README.md` row maintenance; progress log entries here

### TASK-015 (optional): Turso libsql-swift driver
**Status**: EXPERIMENTAL / PARTIAL
**Depends On**: TASK-001
**Deliverables**:
- `RielaNoteLibSQL` target and `LibSQLNoteDatabaseDriver` shape behind
  `NoteDatabaseDriving`, dependency gated so non-note targets are
  unaffected. The shipped driver uses plain SQLite for `.local` and
  fails fast for `.embeddedReplica`; no libsql SQL execution or sync is
  implemented yet.

**Completion criteria**:
- Default SQLite note tests pass. Full libsql embedded-replica/sync test
  parity is not complete.

## Dependencies

| Task | Depends On | Reason |
| ---- | ---------- | ------ |
| TASK-002 | TASK-001 | store/schema foundation |
| TASK-003 | TASK-001 | file records in schema |
| TASK-004 | TASK-002 | dispatch fires on service writes |
| TASK-005 | TASK-002, TASK-003 | add-ons call service + file store |
| TASK-006 | TASK-002, TASK-003 | GraphQL executes through service |
| TASK-007 | TASK-006 | CLI goes through GraphQL |
| TASK-008 | TASK-005 | workflows use note add-ons |
| TASK-009 | TASK-006 | exposes the GraphQL surface |
| TASK-010 | TASK-002, TASK-003 | UI reads models/files |
| TASK-011 | TASK-010, TASK-009 | hosts UI, settings toggle |
| TASK-012 | TASK-005, TASK-008, TASK-010 | agent workflow + chat UI |
| TASK-013 | TASK-012 | builds on agent surfaces |
| TASK-014 | TASK-007 | documents shipped surfaces |
| TASK-015 | TASK-001 | driver seam |

## Parallelization

- After TASK-001: TASK-002 and TASK-003 in parallel.
- After TASK-002/003: TASK-004, TASK-005, TASK-006, TASK-010 in
  parallel (distinct modules).
- TASK-007/TASK-009 (CLI/server) parallel after TASK-006; TASK-008
  parallel with them after TASK-005.
- UI track (TASK-010 → 011 → 012 → 013) is independent of the
  CLI/server track after the service layer lands.

## Verification

```bash
swift build
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
swift test --filter RielaGraphQLTests
swift test                       # full suite before completion
swiftlint
git diff --check
```

Plus design-doc verification items: CLI round-trip, packaged-workflow
mock runs, GraphQL parity (library vs server), auth TTL/revocation.

## Completion Criteria

- [x] All non-optional tasks COMPLETED with tests
- [x] Quick-memo, pdf-ingest, youtube, auto-tagging, note-agent bundles
      pass deterministic mock verification
- [x] `riela note` CLI + GraphQL + add-ons all mutate through
      `NoteService` (no duplicate write paths)
- [~] Note API disabled by default; local auth/client persistence exists,
  but `riela serve --note-api` does not bind a remote socket and
  end-to-end QR registration over HTTP remains follow-up work.
- [x] RielaNoteUI compiles for iOS destination with no AppKit imports
- [x] Acceptance Traceability table in the design doc fully satisfied

## Progress Log Expectations

Each implementation session must append: tasks completed / in progress,
files changed, tests added or updated, verification commands run with
results, and limitations or follow-ups.

### Session: 2026-07-04 Plan authored

**Tasks Completed**: — (planning)
**Notes**: Design spec `design-docs/specs/design-riela-note.md` created
from `design-docs/riela-note-design.md`; task breakdown and dependency
map established. Implementation not started.

### Session: 2026-07-04 Self-review pass

**Tasks Completed**: — (planning refinement)
**Notes**: Fixed cross-task references (auto-tagging workflow is
TASK-008, experimental libsql target is TASK-015); added auto-action loop
guard and note-updated trigger semantics; seeded AI-tagging actions now
cover create+update and are inert-until-installed instead of
enable-flipped; added delete to CLI/GraphQL surfaces and delete/FTS
write semantics to the store tasks; clarified temp-chat transcripts are
caller-held (no store staging); moved the FTS5 probe into TASK-001
deliverables (`Sources/RielaSQLite/SQLiteDatabase.swift`).

### Session: 2026-07-04 Implementation slice 1

**Tasks Completed**: TASK-001
**Tasks In Progress**: TASK-002
**Files Changed**: `Package.swift`,
`Sources/RielaSQLite/SQLiteDatabase.swift`,
`Sources/RielaNote/NoteDatabaseDriving.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteStoreSchema.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaNoteTests/NoteStoreSchemaTests.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(7 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the `RielaNote` target and `RielaNoteTests`; added
SQLite FTS5 capability probing; implemented schema creation, version
table, FTS tables, system tag-class/notebook-kind/default auto-action
seeds, and file locator constraints. Added initial `NoteService`
behavior for notebook/note CRUD, title derivation, created-desc notebook
listing with first-note preview, read-only edit/delete rejection,
comment/tag allowance on read-only notes, provenance-protected tag
application/removal, service-managed delete cascades, and FTS search
maintenance after create/update/tag/delete. Remaining work after this
slice was tracked under TASK-002 until completed by the following
implementation slice.

### Session: 2026-07-04 Implementation slice 2

**Tasks Completed**: TASK-002
**Tasks In Progress**: TASK-003
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Relations.swift`,
`Sources/RielaNote/NoteFileStore.swift`,
`Sources/RielaNote/LocalNoteFileStore.swift`,
`Sources/RielaNote/NoteService+Files.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`,
`Tests/RielaNoteTests/NoteFileStoreTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(13 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Completed TASK-002 by adding `NoteSearch.swift`, explicit
note-to-note link APIs, comment listing, and conversation persistence
(`appendConversationTurn` / `saveConversation`) that creates an
`agent-conversation` notebook and system citation links. Started
TASK-003 with `NoteFileStore`, `LocalNoteFileStore`, and NoteService
attach/list/resolve APIs for note files and notebook source documents.
Local writes use fan-out storage under `<note-root>/files/`, SHA-256
metadata, verified reads, and tests for note deletion preserving file
records/content. Remaining TASK-003 work: S3-compatible store,
local-to-S3 single/bulk migration, storage profiles, and stub HTTP
verification.

### Session: 2026-07-04 Implementation slice 3

**Tasks Completed**: —
**Tasks In Progress**: TASK-003, TASK-004
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteFileStore.swift`,
`Sources/RielaNote/S3NoteFileStore.swift`,
`Sources/RielaNote/NoteFileMigration.swift`,
`Sources/RielaNote/NoteService+Files.swift`,
`Sources/RielaNote/AutoActionDispatching.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaNoteTests/NoteFileStoreTests.swift`,
`Tests/RielaNoteTests/AutoActionTests.swift`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(18 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Added S3-compatible storage profiles, environment-backed
credential loading, SigV4 signed path-style S3 PUT/GET/DELETE over an
injectable HTTP client plus URLSession-backed default client, mixed
local/S3 `resolveFileContent`, and single/bulk local-to-S3 migration
that copies, verifies by reading back, switches the SQLite locator, and
then deletes the old local object. Started TASK-004 by
adding `AutoActionDispatching`, list/configure auto-action APIs, and
after-commit dispatch from notebook creation, note creation, and body
updates. Dispatch failures are non-blocking and `originatingActionId`
skips same-action note-update loops. Remaining TASK-004 work after this
slice was unresolved-workflow diagnostics and runtime adapter wiring to
actual workflow execution.

### Session: 2026-07-04 Implementation slice 4

**Tasks Completed**: TASK-003
**Tasks In Progress**: TASK-004
**Files Changed**: `Tests/RielaNoteTests/NoteFileStoreTests.swift`,
`Sources/RielaNote/AutoActionDispatching.swift`,
`Tests/RielaNoteTests/AutoActionTests.swift`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(21 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`, and source/test file line-count audit (all new
RielaNote files below 1000 lines).
**Notes**: Added a test-only localhost S3 HTTP stub using
`Network.NWListener`, exercising the production `URLSessionS3HTTPClient`
over HTTP for migration and mixed S3 resolution. This closes TASK-003's
stub HTTP verification requirement. Added TASK-004 filter matching for
auto-actions with JSON filters (`noteTags`, `notebookKindTag`) and
tests proving tag/kind filters restrict dispatch. Remaining TASK-004
work: runtime adapter wiring to actual workflow execution and
unresolved-workflow diagnostics at the composition boundary.

### Session: 2026-07-04 Implementation slice 5

**Tasks Completed**: TASK-005
**Tasks In Progress**: TASK-004
**Files Changed**: `Package.swift`,
`Sources/RielaCLI/ProductionNodeAdapter.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`,
`Sources/RielaAddons/RielaAddons.swift`,
`Tests/RielaCLITests/NoteAddonTests.swift`,
`Tests/RielaAddonsTests/AddonExecutionContractsTests.swift`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter AddonExecutionContractsTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
(21 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Implemented built-in note add-ons over `NoteService`:
`riela/note-create`, `riela/note-update`, `riela/note-get`,
`riela/note-search`, `riela/note-tag-apply`,
`riela/note-attach-file`, `riela/note-comment-add`,
`riela/notebook-ingest-pages`, and
`riela/note-conversation-save`. Note root resolution now supports
`addon.config.noteRoot`, rendered add-on variables, workflow input,
`RIELA_NOTE_ROOT`, and default `~/.riela/note`. Outputs expose note
ids both top-level and under `candidatePayload`. Added RielaAddons
built-in catalog descriptors for the note add-ons and deterministic CLI
tests covering create/search/tag/comment/get, projected attachment
storage, page ingestion, and conversation citation links. The line-count
audit still reports pre-existing over-1000-line files outside this
slice; changed files remain below 1000 lines.

### Session: 2026-07-04 Implementation slice 6

**Tasks Completed**: —
**Tasks In Progress**: TASK-004, TASK-006
**Files Changed**: `Package.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests/testGraphQLRouteValidatesEnvelopeAndPropagatesContext`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added Note GraphQL DTOs, a `GraphQLNoteGraphQLService`
facade over `NoteService`, tag/tag-class catalog APIs, schema contract
entries for note queries/mutations, and server route coverage proving
the `/graphql` delegated schema exposes the note domain. Library-level
tests cover create/search/tag/read-only rejection, attachment,
conversation citation persistence, and auto-action configuration.

## Implementation slice 6b

**Date**: 2026-07-04
**Task**: TASK-006 completion
**Status**: Completed
**Files**:
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaServer/ServerContracts.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`Package.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaGraphQLTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests/testGraphQLRouteExecutesNoteDocumentsWhenExecutorIsConfigured`,
and
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter ServerContractsTests`.
**Notes**: Added a deterministic Note GraphQL document executor for
note/notebook queries and create/update/delete/readonly/tag/comment/
link/attach/configure-auto-action/save-conversation/migrate-file/
migrate-all mutations. Server `/graphql` now executes Note documents
when an executor is configured, while preserving the existing delegated
schema response when no executor handles the document. Server tests
prove create/search round trips and read-only mutation rejection returns
GraphQL diagnostics with HTTP 200 rather than a transport error.

## Implementation slice 7

**Date**: 2026-07-04
**Task**: TASK-007 partial implementation
**Status**: Completed CLI parser/wiring, core note commands, and storage
migration command; TASK-007 remains in progress.
**Files**:
`Sources/RielaCLI/RielaCommand.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`,
`Sources/RielaCLI/RielaArgumentParserHelpers.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteCommandTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the top-level `riela note` parser scope, CLI help,
application dispatch, and a `NoteCommandRunner` for `add`, `edit`,
`show`, `delete`, `list`, `search`, `tag`, `comment`, `attach`,
`readonly`, `notebook list/create/show/delete`, and
`storage migrate`. Commands resolve `--note-root`, `RIELA_NOTE_ROOT`,
or `~/.riela/note`, follow existing output-format conventions, and use
the `GraphQLNoteGraphQLService` facade over the local note store for
note mutations/queries. Storage migration uses the public S3 migration
API with credential environment variable names. Client
register/list/revoke was completed in implementation slice 10. Remaining
TASK-007 work is replacing facade calls with actual GraphQL document
execution once TASK-006's HTTP/library execution path is complete.

## Implementation slice 8

**Date**: 2026-07-04
**Task**: TASK-004 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift`,
`Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAutoActionWorkflowDispatcherTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAutoActionWorkflowDispatcherTests --filter NoteCommandTests --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added a production auto-action workflow dispatcher that
preflights configured workflow ids with the filesystem workflow
resolver, skips unresolved workflow ids with diagnostics, launches
resolved workflows asynchronously through `WorkflowRunCommand`, and
records workflow-run failures without failing the originating note
write. Dispatch variables include the trigger event, auto-action
metadata, note id/body snapshot, `originatingActionId` for loop
guards, and `noteRoot` so note add-ons invoked by the workflow operate
on the same store. CLI note commands and built-in note add-ons now
construct `NoteService` with this dispatcher.

## Implementation slice 9

**Date**: 2026-07-04
**Task**: TASK-008 completion
**Status**: Completed
**Files**:
`examples/note-auto-tagging/workflow.json`,
`examples/note-auto-tagging/nodes/node-classify-tags.json`,
`examples/note-auto-tagging/nodes/node-workflow-output.json`,
`examples/note-auto-tagging/prompts/classify-tags.md`,
`examples/note-auto-tagging/mock-scenario.json`,
`examples/note-auto-tagging/EXPECTED_RESULTS.md`,
`examples/note-quick-memo/workflow.json`,
`examples/note-quick-memo/nodes/node-workflow-output.json`,
`examples/note-quick-memo/mock-scenario.json`,
`examples/note-quick-memo/EXPECTED_RESULTS.md`,
`examples/note-pdf-ingest/workflow.json`,
`examples/note-pdf-ingest/nodes/node-extract-pages.json`,
`examples/note-pdf-ingest/nodes/node-workflow-output.json`,
`examples/note-pdf-ingest/prompts/extract-pages.md`,
`examples/note-pdf-ingest/mock-scenario.json`,
`examples/note-pdf-ingest/EXPECTED_RESULTS.md`,
`examples/note-youtube-transcript/workflow.json`,
`examples/note-youtube-transcript/nodes/node-extract-transcript.json`,
`examples/note-youtube-transcript/nodes/node-workflow-output.json`,
`examples/note-youtube-transcript/prompts/extract-transcript.md`,
`examples/note-youtube-transcript/mock-scenario.json`,
`examples/note-youtube-transcript/EXPECTED_RESULTS.md`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-auto-tagging --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-quick-memo --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-pdf-ingest --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift run riela workflow validate note-youtube-transcript --workflow-definition-dir ./examples --output json`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteWorkflowExampleTests`,
and
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests/testAllRielaExampleWorkflowsArePortedAndValidateInSwift --filter RielaExampleParityTests/testMockScenarioExamplesRunThroughSwiftCLI`.
**Notes**: Added deterministic note workflow examples for default
auto-tagging, quick memo creation, PDF page ingestion, and YouTube
transcript capture. Mock scenarios only replace external agent/OCR/
transcript work; note add-ons execute through the production built-in
resolver so mock runs mutate a real temporary note store. Dedicated
tests assert the created or updated rows: AI tags on an existing note,
the fixed `ノート` quick-memo tag and user-memo notebook kind, imported
PDF page notes, and a YouTube-related file attachment.

## Implementation slice 10

**Date**: 2026-07-04
**Task**: TASK-009 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteModels.swift`,
`Sources/RielaNote/NoteService+APIClients.swift`,
`Sources/RielaServer/RielaServer.swift`,
`Sources/RielaServer/ServerContracts.swift`,
`Sources/RielaServer/NoteAPIAuthenticating.swift`,
`Sources/RielaServer/QRClientRegistrationAuthenticator.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaCLI/RielaCommand.swift`,
`Sources/RielaCLI/RielaCLIApplication.swift`,
`Sources/RielaCLI/NoteCommands.swift`,
`Tests/RielaServerTests/NoteAPIAuthTests.swift`,
`Tests/RielaServerTests/ServerContractsTests.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAPIAuthTests --filter ServerContractsTests --filter NoteCommandTests --filter RielaNoteTests`
(35 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added note API client persistence over the existing
`api_clients` table, storing only SHA-256 bearer token hashes and
updating `last_seen_at` on successful authentication. Added the
`NoteAPIAuthenticating` seam, QR registration authenticator with
CSPRNG-backed one-time codes capped at a five-minute TTL, `/note/register`
redeem handling, and note GraphQL auth enforcement when a route handler
is configured with a note API authenticator. Tests cover unauthenticated
rejection, registered bearer success, revoked bearer rejection,
single-use code rejection, expiry rejection, and the default
`RielaServerConfiguration` keeping `host == 127.0.0.1` and
`noteAPIEnabled == false`. Added `riela note client register|list|revoke`
for local operator management of the same client registry. `riela serve
--note-api` currently emits an in-process serving descriptor only; it
does not bind a reachable remote HTTP socket, so QR redemption through a
remote listener remains follow-up work.

## Implementation slice 11

**Date**: 2026-07-04
**Task**: TASK-010 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteNotebookListView.swift`,
`Sources/RielaNoteUI/RielaNoteDetailView.swift`,
`Sources/RielaNoteUI/RielaNoteComponents.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests --filter RielaNoteTests`
(27 tests),
`env -u TOOLCHAINS -u SDKROOT DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild -scheme RielaNoteUI -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -derivedDataPath tmp/RielaNoteUI-iOS-DerivedData LD=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang build`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the `RielaNoteUI` SwiftPM library target and
`RielaNoteUITests`, with package platform support for iOS 17. The UI is
SwiftUI-only and imports no AppKit: `RielaNoteRootView` hosts a
compact-first `NavigationSplitView`, `RielaNoteNotebookListView`
provides created-desc notebook rows and FTS search-result rows, and
`RielaNoteDetailView` renders markdown, provenance-distinct tag chips,
read-only lock state, related files, links, comments, and a segmented
text/source-page-image switch. Added `RielaNoteUIClient` plus
`NoteServiceRielaNoteUIClient` so a future remote GraphQL client can
substitute for local `NoteService`. `NoteService.listNotes(notebookId:)`
was added for deterministic first-note loading without FTS side effects.
Tests cover list/detail view construction, load/search selection, source
image switching through a mock client, and real local plus S3-migrated
source-page-image resolution through `NoteServiceRielaNoteUIClient`.

## Implementation slice 12

**Date**: 2026-07-04
**Task**: TASK-011 completion
**Status**: Completed
**Files**:
`Package.swift`,
`Sources/RielaApp/EntryPoint.swift`,
`Sources/RielaApp/EntryPoint+Menu.swift`,
`Sources/RielaApp/EntryPoint+Notes.swift`,
`Sources/RielaApp/NoteWindowController.swift`,
`Sources/RielaApp/NoteSettingsWindowController.swift`,
`Sources/RielaAppSupport/RielaAppLaunchOptions.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteDetailView.swift`,
`Tests/RielaAppSupportTests/RielaAppLaunchOptionsTests.swift`,
`Tests/RielaAppSupportTests/RielaAppNotesIntegrationTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed focused checks:
`swift test --filter RielaNoteUITests`,
`swift test --filter RielaAppNotesIntegrationTests --filter RielaAppLaunchOptionsTests`,
`swift build --product RielaApp`, and a direct
`.build/arm64-apple-macosx/debug/RielaApp --open-notes` launch with
isolated `tmp/rielaapp-note-ui` roots. `screencapture` was blocked by
macOS screen-recording masking in this environment, so the UI screenshot
evidence uses an AppKit offscreen render written under `tmp/` by
`RielaAppNotesIntegrationTests`.
**Notes**: Added a status-bar `Notes...` entry and `Note Settings...`
entry. Notes resolve against the active RielaApp profile at
`<home>/.riela/profiles/<profile>/note/`, so the default production path
is `~/.riela/profiles/<profile>/note/` while tests and debug launches can
isolate with `--home-root`. `NoteWindowController` hosts
`RielaNoteRootView` through `NSHostingController`; `RielaNoteUI` now
supports editing non-read-only note bodies through `RielaNoteUIClient`.
`NoteSettingsWindowController` persists per-profile note API exposure in
`note/app-settings.json` and manages API clients through the existing
`NoteService.registerAPIClient`, `listAPIClients`, and
`revokeAPIClient` APIs. Added `--open-notes` for deterministic RielaApp
UI verification.

## Implementation slice 13

**Date**: 2026-07-04
**Task**: TASK-007 completion
**Status**: Completed
**Files**:
`Sources/RielaCLI/NoteCommands.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNote/NoteService.swift`,
`Tests/RielaCLITests/NoteCommandTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteCommandTests --filter NoteGraphQLTests`
(8 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter NoteGraphQLTests --filter NoteCommandTests --filter NoteAddonTests --filter NoteWorkflowExampleTests`
(36 tests),
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Completed the local `riela note` CLI's GraphQL-document
execution path. `NoteCommandRunner` now drives note create/update/delete,
show/list/search, tag add/remove, comment, attach, read-only toggles,
notebook list/show/create/delete, and storage migration through
`NoteGraphQLDocumentExecutor` against the local note store. Added the
missing `notes` query plus `createNotebook` and `deleteNotebook`
mutations to the note GraphQL service, document executor, and schema
contract. `note list` now lists notes created-desc with optional
`--notebook` and `--tag` filters instead of proxying to notebook list.
CLI ergonomics now accept positional attach paths, `readonly --on|--off`,
`tag --add|--remove`, and `storage migrate --all --to s3 --profile`.
The round-trip test covers add -> list -> search -> tag remove ->
positional attach -> storage migrate --all -> edit -> show ->
notebook list -> delete against a temp note root, plus notebook
create/show/delete and client register/list/revoke.

## Implementation slice 14

**Date**: 2026-07-04
**Task**: TASK-012 completion
**Status**: Completed
**Files**:
`Sources/RielaNote/NoteSearch.swift`,
`Sources/RielaNoteUI/RielaNoteAgentModels.swift`,
`Sources/RielaNoteUI/RielaNoteAgentView.swift`,
`Sources/RielaNoteUI/RielaNoteAgentViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests+NoteExamples.swift`,
`examples/note-agent/`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteUITests --filter NoteWorkflowExampleTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter RielaNoteUITests --filter NoteWorkflowExampleTests --filter NoteAddonTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added the packaged `note-agent` workflow under
`examples/note-agent`, using `riela/note-search` followed by a
`codex-agent` answer node that returns cited note ids. The local
service-backed UI path answers from one FTS-backed search/template pass;
vector retrieval, multi-source RAG, and web search remain follow-up
work. `RielaNoteUI` now has an Agent tab with a temp-chat toggle,
explicit Save action, agent turn view, and citation buttons that
deep-link back to Library selection. `NoteServiceRielaNoteUIClient`
answers turns from real note search results, saves first auto-saved turns through
`saveConversation`, appends later auto-saved turns through
`appendConversationTurn`, and leaves temporary turns in the caller until
Save. The service-backed UI test verifies citations resolve to real note
ids, default persistence creates an `agent-conversation` notebook, and
conversation notes get `source-citation` links. Also hardened note FTS
query normalization so hyphenated user text such as `source-backed`
does not become invalid SQLite FTS syntax.

## Implementation slice 15

**Date**: 2026-07-04
**Task**: TASK-013 completion
**Status**: Completed
**Files**:
`Sources/RielaNote/NoteService.swift`,
`Sources/RielaNote/NoteService+Catalog.swift`,
`Sources/RielaNote/NoteWorkflowScaffolder.swift`,
`Sources/RielaGraphQL/GraphQLContracts.swift`,
`Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`,
`Sources/RielaGraphQL/NoteGraphQLContracts.swift`,
`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`,
`Sources/RielaGraphQL/NoteGraphQLService.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentModels.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentView.swift`,
`Sources/RielaNoteUI/RielaNoteConfigAgentViewModel.swift`,
`Sources/RielaNoteUI/RielaNoteRootView.swift`,
`Sources/RielaNoteUI/RielaNoteUIClient.swift`,
`Tests/RielaNoteTests/NoteServiceTests.swift`,
`Tests/RielaGraphQLTests/NoteGraphQLTests.swift`,
`Tests/RielaNoteUITests/RielaNoteUITests.swift`,
`Tests/RielaCLITests/NoteWorkflowExampleTests.swift`,
`Tests/RielaCLITests/RielaExampleParityTests.swift`,
`examples/note-config-agent/`,
`impl-plans/active/riela-note.md`,
`impl-plans/README.md`.
**Verification**: Passed
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests --filter RielaNoteUITests --filter NoteGraphQLTests --filter NoteWorkflowExampleTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaExampleParityTests`,
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
and `git diff --check`.
**Notes**: Added a dedicated RielaNoteUI Config tab and view model.
The screen submits config-agent requests, displays proposed changes, and
applies them through the `RielaNoteUIClient` boundary. The local
`NoteServiceRielaNoteUIClient` now proposes tag-class/tag,
auto-action, and ingestion-workflow draft changes, then applies them by
defining tag classes/tags, configuring the note auto-action row, and
writing a portable workflow bundle through
`NoteIngestionWorkflowScaffolder`. Added GraphQL mutations and
document-executor support for `defineNoteTagClass`, `defineNoteTag`,
and `scaffoldNoteIngestionWorkflow`, with the note SDL extracted to
`GraphQLNoteSchemaContract` to keep `GraphQLContracts.swift` below the
1000-line threshold. Added packaged `examples/note-config-agent` as the
agent-worker proposal workflow and deterministic mock tests proving the
proposal shape.

## Implementation slice 16

**Date**: 2026-07-04
**Task**: TASK-014 completion and final audit
**Status**: Completed
**Files**:
`README.md`,
`impl-plans/README.md`,
`impl-plans/active/riela-note.md`.
**Verification**: Passed
`env -u LD /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
(1054 tests),
`env -u LD /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`,
`env -u SDKROOT -u TOOLCHAINS -u LD xcodebuild -scheme RielaNoteUI -destination 'platform=iOS Simulator,id=A6768A08-2125-4BB7-B556-AD907C665285' -derivedDataPath tmp/riela-note-ios-derived-data-xcode ONLY_ACTIVE_ARCH=YES ARCHS=arm64 build`,
`env -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`,
`git diff --check`,
`rg -n "import AppKit" Sources/RielaNoteUI || true`, and
`rg --files -g 'riela-package.json'` (no package manifest present, so no
digest refresh was required).
**Notes**: Added README documentation for the shipped `riela note`
command family, default note roots, notebook/storage/client management,
packaged note workflows, RielaApp note root behavior, and the local
`riela serve --note-api` authentication model. Updated the
`impl-plans/README.md` row to partial with the remote socket and real
libsql sync deferred. Final audit confirms the local note store,
GraphQL, CLI, add-on, and UI slices are implemented, while
`RielaNoteUI` compiles for an iOS Simulator destination with no AppKit
imports. The Xcode iOS build must run without the ambient `LD=ld`
environment value; otherwise Xcode imports it as a build setting and
calls `ld` directly with compiler-driver flags.

### 2026-07-04 TASK-015 implementation
**Status**: EXPERIMENTAL / PARTIAL
**Commands**:
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
- `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 RIELA_NOTE_TEST_DRIVER=libsql /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter RielaNoteTests`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test`
- `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
- `env -u LD DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH /usr/bin/xcrun swiftlint`
**Notes**: Added a separate `RielaNoteLibSQL` product/target. The
target is experimental: `.local` currently delegates to plain
`SQLiteDatabase`, and `.embeddedReplica` fails fast because SQL
execution through libsql is not implemented. The main `RielaNote`
target remains free of the extra dependency. Real libsql embedded
replica/sync behavior and full suite parity against that driver remain
follow-up work.
