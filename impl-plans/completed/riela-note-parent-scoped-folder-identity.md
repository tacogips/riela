# Parent-Scoped Riela Note Folder Identity Implementation Plan

**Status**: Completed and archived after accepted Step 7 adversarial review and Step 8 documentation refresh
**Workflow Mode**: `issue-resolution`
**Issue Reference**: “Allow duplicate Riela Note folder names under different parents”; no GitHub issue URL, repository, or number supplied
**Workflow Execution**: `codex-design-and-implement-review-loop-session-43`
**Design Reference**: `design-docs/specs/design-riela-note-parent-scoped-folder-identity.md`
**Accepted Design Review**: `comm-000373`; adversarial review accepted with no high- or mid-severity findings
**Codex-Agent References**: none supplied
**Created**: 2026-08-03
**Last Updated**: 2026-08-04

---

## Objective and source of truth

Implement the accepted design as one coupled schema-to-Web work package:

- keep `tag_id` globally unique while making folder display-name uniqueness
  parent-scoped and non-folder names globally unique;
- migrate existing Note stores to schema v7 without losing tags, ancestry,
  assignments, or foreign-key enforcement;
- make ID or exact parent-plus-name resolution canonical and make legacy
  name-only access fail closed when ambiguous;
- add and consume ID-based notebook-tag, grouped-filter, and Kanban GraphQL
  operations;
- show path-qualified folder labels in Web selection and search surfaces; and
- change private workflow-run history notebooks to
  `<workflow-id>/history-YYYY-MM-DD`.

The accepted design is authoritative. This plan does not reopen the accepted
identity, duplicate-sibling, compatibility, label, migration, or rollout
decisions. Implementation discoveries that conflict with those contracts must
return to design review instead of being resolved silently in code.

## Working-tree and process constraints

- Preserve every pre-existing tracked and untracked user change, including
  overlapping changes in Note, GraphQL, RielaApp, README, tests, and Web paths.
- Before editing each task's scope, inspect its current diff and integrate with
  it; never reset, discard, overwrite, or stage unrelated work.
- Put all scratch scripts, logs, databases, fixtures, and evidence under
  `tmp/riela-note-parent-scoped-folder-identity/`. Do not add scratch files to
  the repository root or `scripts/`.
- Do not commit, push, pull, open a pull request, or alter branch history.
- Keep production and test files within repository size and lint conventions;
  extract focused helpers or test files when a touched file would become
  unwieldy.

## References and accepted decisions

- Design: `design-docs/specs/design-riela-note-parent-scoped-folder-identity.md`.
- Step 3 handoff: `comm-000373` from
  `codex-design-and-implement-review-loop-session-43`.
- Intake and design communications:
  `comm-000364`, `comm-000365`, `comm-000366`, `comm-000367`, `comm-000368`,
  `comm-000370`, `comm-000371`, and `comm-000372`.
- Canonical identity: `tag_id`.
- Folder uniqueness: `(parent_tag_id, name)`, with a separate root-folder
  uniqueness rule for `NULL` parents.
- Duplicate siblings: rejected without mutation or reparenting.
- Non-folder compatibility: preserve name-based behavior only when the
  candidate is unambiguous.
- Display: ancestor path plus folder name, with visible incomplete-path
  handling for missing or cyclic catalog ancestry.
- Codex-agent/Cursor references and adapter boundaries: none; no reference
  implementation or intentional divergence must be traced.
- User-QA: none required because the accepted design records no open user
  decision.

## Task breakdown

### T1. Baseline, ownership, and caller audit

**Status**: COMPLETED
**Write scope**: this plan's progress log and scratch evidence under
`tmp/riela-note-parent-scoped-folder-identity/` only
**Depends on**: accepted Step 3 review `comm-000373`
**Parallelizable**: no

**Tasks**:

- Capture branch/status and per-path diffs before changing any overlapping
  file; record which changes predate this work package.
- Trace schema preparation, migration transactions, SQLite connection caching,
  local LibSQL delegation, tag seeding, tag definition, folder-path creation,
  notebook assignment/removal, grouped filtering, Kanban inheritance, GraphQL
  SDL/parser/service flow, CLI documents, Web client/state/UI, search labels,
  and workflow-run notebook instructions.
- Classify every name-based tag caller as exact ID, exact parent-plus-name
  folder, unambiguous non-folder name, or unambiguous generic name before
  changing shared lookup helpers.
- Record current `ON CONFLICT(name)`, `LIMIT 1`, and name-based Web operation
  sites so later tasks can prove complete removal or intentional compatibility.

**Deliverables**:

- A dated progress entry containing the dirty-worktree inventory, caller
  classification, selected test files, and any implementation blocker.
- Scratch audit output under the required `tmp/` subdirectory only.

**Verification**:

```bash
git status --short --branch
git diff -- Sources/RielaNote Sources/RielaNoteLibSQL Sources/RielaGraphQL Sources/RielaCLI Sources/RielaApp Tests web README.md
rg -n "ON CONFLICT\\(name\\)|LIMIT 1|requireTag\\(name|tagFilterGroups|effectiveKanbanStatuses|assignKanbanStatusSet|applyNotebookTags|removeNotebookTag" Sources Tests web/src
```

### T2. Schema v7 migration and failed-handle quarantine

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaNote/NoteStoreSchema.swift`
- `Sources/RielaNote/NoteDatabaseDriving.swift`
- `Sources/RielaNoteLibSQL/LibSQLNoteDatabaseDriver.swift`
- focused schema/driver tests under `Tests/RielaNoteTests/`, including
  `Tests/RielaNoteTests/NoteStoreSchemaTests.swift`

**Depends on**: T1
**Parallelizable**: no; it establishes the storage contract for all later work

**Tasks**:

- Bump the Note schema to v7 and make fresh stores create `tags` without global
  `name` uniqueness plus the three accepted partial unique indexes: non-folder
  name, root-folder name, and nested-folder `(parent_tag_id, name)`.
- Split older-store preparation so v2-v6 finish with foreign keys enabled and
  the v7 table rebuild runs only in the accepted connection-level
  disable/rebuild/restore sequence outside the existing outer transaction.
- Preserve every `tag_id`, parent/status reference, `note_tags` identity, and
  `notebook_tags` identity; validate counts, identities, orphan queries, table
  and index shape, and `PRAGMA foreign_key_check` before recording v7.
- Detect a valid markerless-v7 shape after an interruption and validate/mark it
  without repeating the destructive rebuild.
- Restore and verify `PRAGMA foreign_keys = ON` on every exit. Change
  `SQLiteNoteDatabaseConnection.withDatabase` so any thrown body evicts the
  exact cached handle; document the protocol lifecycle and ensure local LibSQL
  inherits it without a separate migration path.
- Add deterministic fault injection at pre-commit, post-rebuild-commit, and
  restoration-verification boundaries. Cover fresh v7, v6-to-v7 preservation,
  rollback, markerless recovery, failed-handle non-reuse, and newly opened
  handle enforcement.

**Deliverables**:

- A restart-safe v7 migration with no tag/assignment loss and no reusable
  connection left in an unknown foreign-key state.
- Focused SQLite, local LibSQL, and controllable test-driver regression evidence.

**Verification**:

```bash
swift test --filter NoteStoreSchemaTests
swift test --filter RielaNoteTests
rg -n "currentVersion = 7|foreign_keys|foreign_key_check|parent_tag_id.*name|class_id.*folder" Sources/RielaNote Tests/RielaNoteTests
```

### T3. Canonical service identity, conflict handling, and ID operations

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaNote/NoteService.swift`
- `Sources/RielaNote/NoteService+Catalog.swift`
- `Sources/RielaNote/NoteService+Hydration.swift`
- `Sources/RielaNote/NoteService+NotebookTags.swift`
- `Sources/RielaNote/NoteService+Kanban.swift`
- focused service tests under `Tests/RielaNoteTests/`

**Depends on**: T2
**Parallelizable**: no; it supplies the canonical APIs consumed downstream

**Tasks**:

- Replace the shared arbitrary name resolver with purpose-specific exact-ID,
  exact-parent folder, unambiguous non-folder name, and unambiguous generic name
  resolvers. Remove `LIMIT 1` from identity decisions and return controlled
  not-found or invalid-input outcomes for zero or multiple candidates.
- Add ID-first notebook assignment/removal primitives and preserve name-based
  methods only as compatibility adapters that resolve before invoking the same
  primitives.
- Make folder definition and folder-path creation resolve each component by
  exact `(parentTagId, name, classId = folder)`, reuse only that sibling, and
  translate concurrent exact-sibling conflicts without consulting global name.
- Remove invalid bare-name conflict targets. Validate targetless seed no-ops,
  update only resolved IDs, and retain compatible non-folder definition
  behavior without allowing cross-class or cross-parent mutation.
- Add ID-group notebook filtering with accepted precedence, empty-group
  normalization, fail-closed unknown IDs, descendant expansion, canonical
  deduplication, and existing 64/256/900 bounds.
- Add ID-first Kanban assignment and effective-status lookup while preserving
  legacy name fields only through the unambiguous generic adapter.
- Prove stable hydration/display ordering for duplicate names using ancestry
  and `tag_id` tie-breaks.

**Deliverables**:

- One canonical tag-ID service layer with deterministic compatibility adapters
  and no arbitrary name selection.
- Service coverage for cross-parent duplicates, sibling/root duplicates,
  cross-class collisions, concurrency, exact assignment/removal, filtering,
  ambiguity, and Kanban ancestry.

**Verification**:

```bash
swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests'
rg -n "ON CONFLICT\\(name\\)|WHERE name = .*LIMIT 1|requireTag\\(name" Sources/RielaNote
```

### T4. Atomic GraphQL schema, parser, DTO, and dispatch update

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaGraphQL/GraphQLContracts.swift`
- `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift`
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift`
- `Sources/RielaGraphQL/NoteGraphQLDocumentVariables.swift`
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- focused files under `Tests/RielaGraphQLTests/`, including
  `Tests/RielaGraphQLTests/NoteGraphQLDocumentParsingRegressionTests.swift`

**Depends on**: T3
**Parallelizable**: no; all GraphQL layers must change atomically

**Tasks**:

- Add the accepted `ApplyNotebookTagIdsInput`, `applyNotebookTagIds`,
  `removeNotebookTagById`, `tagFilterIdGroups`,
  `effectiveKanbanStatusesByTagId`, and `assignKanbanStatusSetByTagId` contracts
  to both SDL owners and the typed DTO surface.
- Update parser supported-field/type tables, nested ID-variable validation,
  result projection, service forwarding, and dispatch in one change set.
- Preserve legacy fields and exact precedence: at least one normalized ID group
  overrides grouped/flat name filters; otherwise existing name behavior remains.
- Reject malformed nested variables through the existing invalid-variable
  response so malformed input can never become an unfiltered request.
- Test SDL parity, parser projection, mutations, grouped descendant filtering,
  unknown IDs, bounds, deduplication, Kanban ID scope, legacy compatibility, and
  controlled ambiguity.

**Deliverables**:

- A backward-compatible GraphQL surface whose schema, parser, DTOs, and service
  dispatch agree exactly.

**Verification**:

```bash
swift test --filter 'NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'
rg -n "ApplyNotebookTagIdsInput|applyNotebookTagIds|removeNotebookTagById|tagFilterIdGroups|effectiveKanbanStatusesByTagId|assignKanbanStatusSetByTagId" Sources/RielaGraphQL Tests/RielaGraphQLTests
```

### T5. CLI document compatibility and realistic duplicate-folder scenarios

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaCLI/NoteCommandGraphQLDocuments.swift`
- `Sources/RielaCLI/NoteCommandModels.swift` and
  `Sources/RielaCLI/NoteCommands.swift` only where current document wiring
  requires additive ID fields
- `Tests/RielaCLITests/NoteCommandTests.swift` and focused CLI fixtures

**Depends on**: T4
**Parallelizable**: yes, with T6 and T8 after T4; scopes are disjoint

**Tasks**:

- Update consumed GraphQL documents/models for additive ID fields without
  introducing new public CLI flags not required by the accepted design.
- Exercise schema creation, nested same-name folder creation, exact ID
  assignment/removal/filtering, sibling rejection, ambiguous legacy failure,
  and workflow-history folder reuse through actual command/document execution.
- Keep existing name options compatible for unambiguous non-folder callers.

**Deliverables**:

- Realistic CLI regression evidence rather than service-only coverage.

**Verification**:

```bash
swift test --filter NoteCommandTests
```

### T6. Web client, state, tree, and path-label primitives

**Status**: COMPLETED
**Write scope**:

- `web/src/notes/client.ts`
- `web/src/notes/types.ts`
- `web/src/notes/controller.ts`
- `web/src/notes/tree.ts`
- `web/src/notes/paging.ts`
- focused `web/src/notes/*.test.ts` files

**Depends on**: T4
**Parallelizable**: yes, with T5 and T8 after T4; scopes are disjoint

**Tasks**:

- Add Web client methods for notebook assignment/removal and Kanban operations
  by tag ID, and send grouped filters through `tagFilterIdGroups`.
- Retain filter, catalog, picker, mutation, and Board scope identity by `tagId`;
  reconcile refreshed names/ancestry by ID without silently changing selection.
- Replace global folder-name collision detection with a normalized sibling-only
  `(parentTagId, name)` helper while keeping server constraints authoritative.
- Implement one ID-based qualified-path helper with visited-ID cycle protection,
  hierarchy-depth bound, deterministic ID fallback, and visible incomplete-path
  output for missing/cyclic ancestry.
- Preserve generation and stale-completion guards while converting payloads.

**Deliverables**:

- Tested ID-first Web transport/state primitives and deterministic qualified
  folder labels.

**Verification**:

```bash
(
  cd web
  bun test src/notes
  ./node_modules/.bin/tsc --noEmit
)
```

### T7. Web selection, search, filter, and Kanban UI adoption

**Status**: COMPLETED
**Write scope**:

- `web/src/views/NotesView.tsx`
- `web/src/components/NoteSearchPopup.tsx`
- directly affected Web styles and focused component/e2e tests

**Depends on**: T6
**Parallelizable**: no; it consumes T6's stable client and helper contracts

**Tasks**:

- Route folder assignment, removal, filtering, effective Kanban lookup, and
  Kanban-set assignment through captured tag IDs.
- Display `Parent / Child / Leaf` labels in folder pickers, tag selection,
  filter chips, breadcrumbs, tree disambiguation, Kanban selectors, search
  matched tags, success/error context, and matching accessibility labels.
- Pass the current catalog/path resolver into `NoteSearchPopup`; never recover
  ancestry by global name.
- Make folder creation preflight sibling-scoped, refresh after authoritative
  server conflicts, and never select or reparent an arbitrary duplicate.
- Cover duplicate names in different branches, incomplete ancestry, catalog
  refresh, stale operations, payload IDs, and keyboard/accessibility labels.

**Deliverables**:

- End-to-end Web ID usage and visibly unambiguous folder presentation.

**Verification**:

```bash
(
  cd web
  bun test src
  ./node_modules/.bin/tsc --noEmit
  bun run lint
  bun run build
  bun run test:e2e
)
```

### T8. Workflow-run history notebook convention

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaApp/EntryPoint+Assistant.swift`
- directly affected RielaApp workflow instruction/composition files
- `README.md`
- focused files under `Tests/RielaAppSupportTests/`

**Depends on**: T4 for the stable public contract; may begin in parallel with
T5 and T6
**Parallelizable**: yes, with T5 and T6 after T4; scopes are disjoint

**Tasks**:

- Replace globally collision-safe date-child guidance with folder components
  `[<workflow-id>, history-YYYY-MM-DD]` and use parent-scoped folder creation.
- Reuse the same leaf for repeated workflow/date runs and obtain a distinct
  leaf ID for the same date beneath another workflow parent.
- Update README examples and assertions without disturbing unrelated existing
  README or RielaApp changes.

**Deliverables**:

- Consistent runtime instruction, user documentation, and regression coverage
  for the accepted notebook convention.

**Verification**:

```bash
swift test --filter RielaAppSupportTests
rg -n "history-YYYY-MM-DD|workflow-id" Sources/RielaApp README.md Tests/RielaAppSupportTests
```

### T9. Cross-layer regression matrix and repository documentation review

**Status**: COMPLETED
**Write scope**:

- focused tests not already owned by T2-T8
- `README.md` only through coordination with T8
- `.codex/skills/riela-impl-workflow/SKILL.md` only if review proves its
  user-facing contract is directly affected
- applicable `riela-package.json` metadata only if a workflow, prompt, script,
  or skill edit requires digest refresh under repository rules
- this plan's progress log

**Depends on**: T2-T8
**Parallelizable**: no; this is the integrated coverage and documentation gate

**Tasks**:

- Run the accepted migration/service/GraphQL/CLI/Web matrix and add only the
  missing focused coverage needed to prove its scenarios.
- Verify no identity-sensitive name query retains arbitrary `LIMIT 1`, no bare
  `ON CONFLICT(name)` remains, and no Web folder/Kanban mutation or filter sends
  a display name where the new ID field is available.
- Review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`; update only
  directly affected user-facing contracts. If a skill/workflow asset changes,
  refresh and validate the required package digests.
- Record pre-existing failures separately from introduced failures with exact
  commands, output locations, and ownership evidence.

**Deliverables**:

- A complete scenario-to-test map and refreshed directly affected docs.
- Digest validation evidence when repository package metadata is touched.

**Verification**:

```bash
rg -n "ON CONFLICT\\(name\\)|WHERE name = .*LIMIT 1" Sources/RielaNote
rg -n "applyNotebookTags|removeNotebookTag|tagFilterGroups|effectiveKanbanStatuses\\(|assignKanbanStatusSet\\(" web/src
git diff --check
```

### T10. Final verification and implementation handoff

**Status**: COMPLETED
**Write scope**: this plan's task statuses/progress log and scratch evidence only
**Depends on**: T9
**Parallelizable**: no

**Tasks**:

- Run every required command from a cleanly understood dirty-worktree baseline.
- Inspect the final diff for unintended changes, missing tests, stale SDL/parser
  tables, package digest drift, scratch artifacts, and user-change damage.
- Record exact pass/fail/blocked outcomes, test counts, residual risks, and
  verification gaps; never report an unrun or timed-out command as passed.
- Hand off for adversarial implementation review with issue references,
  communications, changed/reviewed paths, findings, commands, and gaps.
- Do not commit or push.

**Deliverables**:

- Evidence-backed implementation handoff ready for independent review.

## Dependencies and execution order

```text
comm-000373 accepted design
  -> T1 baseline/caller audit
  -> T2 schema v7 + connection quarantine
  -> T3 service identity and ID APIs
  -> T4 atomic GraphQL surface
  -> [T5 CLI, T6 Web primitives, T8 workflow convention]
  -> T7 Web UI (after T6)
  -> T9 integrated regressions/docs (after T5, T7, T8)
  -> T10 final verification/handoff
```

Only T5, T6, and T8 are marked parallelizable, and only after T4. Their write
scopes are disjoint. Any newly discovered overlap, including shared tests or
README edits, removes parallel eligibility until one owner is assigned.

## Full verification gate

```bash
swift build
swift test --filter NoteStoreSchemaTests
swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests'
swift test --filter 'NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'
swift test --filter NoteCommandTests
swift test --filter RielaAppSupportTests
(
  cd web
  bun test src
  ./node_modules/.bin/tsc --noEmit
  bun run lint
  bun run build
  bun run test:e2e
)
git status --short
git diff --stat
git diff --check
```

If an applicable package digest is refreshed, also run the repository's
package validation/packing command discovered in T1 and record the exact
command and output in the progress log.

## Completion criteria

- [x] Fresh and migrated stores enforce all three v7 uniqueness domains while
  retaining every existing tag ID, ancestry/status reference, and assignment.
- [x] Every migration exit restores and verifies foreign-key enforcement; a thrown
  database body cannot return the failed handle to the connection cache.
- [x] Folder lookup/creation is parent-scoped, duplicate siblings are controlled
  failures, and no name-only identity path selects an arbitrary row.
- [x] Notebook assignment/removal, ID-group filtering, and Kanban scope are ID-first
  in services, GraphQL, CLI scenarios, and Web consumers; legacy name behavior
  remains only where accepted and unambiguous.
- [x] Both GraphQL SDL layers, parser tables, DTOs, nested-variable validation, and
  service dispatch expose the same additive contract.
- [x] Web selection/search surfaces show complete qualified paths or a visible
  incomplete-path state, with accessibility labels and stale-state protections.
- [x] Workflow histories use `<workflow-id>/history-YYYY-MM-DD` and reuse/isolate
  leaves according to parent identity.
- [x] All required tests and static checks pass, or any environment-owned block is
  explicitly evidenced without hiding an introduced failure.
- [x] Existing user changes remain preserved; scratch artifacts exist only under
  `tmp/`; no commit or push has occurred.
- [x] The progress log and final handoff contain exact changed paths, commands,
  results, residual risks, and adversarial review readiness.

## Progress-log expectations

Update this file after every task or correction pass. Each dated entry must
record:

- task IDs and status transitions;
- files inspected and changed;
- how overlapping pre-existing changes were preserved;
- verification commands with pass/fail/blocked outcomes and test counts;
- discovered risks, regressions, and follow-up ownership;
- any Step 5 or later high/mid finding and the task(s) reopened to address it;
- package digest refresh evidence when applicable; and
- confirmation that scratch files remain under the required `tmp/` directory
  and that no commit or push occurred.

Do not mark a task complete until its deliverables and focused verification are
recorded. Do not mark the plan implementation-complete until T10 satisfies the
full completion criteria.

## Risks and required mitigations

- **Foreign-key enforcement escape**: restoration can fail after a committed
  rebuild. Mitigate with double verification, markerless recovery, fault
  injection, and mandatory thrown-handle eviction.
- **Migration data loss or repeated rebuild**: table replacement can orphan or
  duplicate identity. Mitigate with exact pre/post identity checks, explicit
  orphan queries, index-shape validation, and restart tests.
- **Incomplete caller conversion**: a shared name resolver change can alter
  unrelated semantics. Mitigate with T1 classification and purpose-specific
  adapters before replacement.
- **GraphQL layer drift**: either SDL, parser tables, DTOs, or dispatch can lag.
  Mitigate with atomic T4 ownership and parsing regression tests.
- **Cross-class/name ambiguity**: folders and non-folders may share a name.
  Mitigate with domain-specific lookup and controlled generic ambiguity.
- **Concurrent sibling creation**: preflight cannot prevent a race. Mitigate
  with database uniqueness, exact-identity conflict translation, and re-query
  only where idempotent reuse is allowed.
- **Incomplete catalog ancestry**: qualified labels can fabricate the wrong
  path. Mitigate with ID traversal, cycle/depth guards, and visible incomplete
  output.
- **Stale Web completions**: ID conversion can weaken existing race guards.
  Mitigate by preserving generation/snapshot checks and testing refresh and
  mutation interleavings.
- **Dirty-worktree damage**: accepted target files already overlap user work.
  Mitigate with per-task diff inspection, narrow patches, recorded ownership,
  and final damage review.
- **Verification environment limits**: long Swift/Web commands may time out or
  depend on unavailable GUI/browser state. Mitigate by retaining exact logs,
  separating environment blocks from product failures, and never inferring a
  pass.

## Progress log

### 2026-08-03 — Plan creation

- Step 3 `comm-000373` accepted the adversarial design review with zero
  remaining high- or mid-severity findings.
- Created the active plan from
  `design-docs/specs/design-riela-note-parent-scoped-folder-identity.md`.
- Step 4 self-review of `comm-000374` removed overlapping
  `Tests/RielaCLITests/` ownership from T8;
  T5 exclusively owns CLI regressions, so the T5/T6/T8 parallel group now has
  disjoint write scopes.
- Self-review added `web/src/notes/paging.ts` to T6 because grouped filter IDs
  traverse that current loading boundary, and made Web verification blocks
  safe to run as complete shell blocks without nested `web/web` paths.
- No Codex-agent references, Cursor adapter work, or open user-QA decisions are
  present.
- Implementation has not started. No source, test, README, workflow, skill, or
  package metadata file was changed by this planning step.
- Existing dirty work remains user-owned. No commit or push was performed.

### 2026-08-04 — T1-T10 implementation and correction pass

- T1 captured and preserved the dirty baseline, including overlapping RielaApp,
  CLI, GraphQL, Note, README, test, and Web edits. Later unrelated Apple Mail,
  persona-addon, and private-workflow changes also remained untouched. No reset,
  commit, push, or branch-history operation was performed.
- T2 implemented schema v7, the three partial uniqueness indexes, identity and
  assignment preservation checks, markerless recovery, foreign-key restoration,
  and thrown-handle eviction. Deterministic pre-commit, post-commit, and
  restoration-verification checkpoints now prove rollback/recovery and new-handle
  enforcement; local LibSQL inherits and conditionally tests the same lifecycle.
  Final self-review strengthened markerless detection to validate table columns,
  references, unique/partial flags, index columns, and predicates rather than
  trusting index names alone; the 13-test schema suite still passed.
- T3 replaced arbitrary name selection with exact ID, exact sibling,
  unambiguous non-folder, and unambiguous generic resolution; added ID-first
  membership/filter/Kanban operations; removed bare-name conflict targets; and
  added concurrent exact-sibling reuse coverage. Grouped notebook filtering was
  extracted to `Sources/RielaNote/NoteService+NotebookFiltering.swift`, reducing
  the touched `NoteService.swift` below the Swift size guideline.
- T4 updated both SDL surfaces, typed input, parser tables, nested variable
  validation, service forwarding, and dispatch atomically. Added executor-level
  coverage for duplicate folder names, ID apply/filter/remove, Kanban ID scope,
  controlled legacy ambiguity, and cross-domain `createOnly` behavior.
- T5 added `parentTagId` to consumed CLI tag projections and realistic command
  coverage proving workflow/date leaf reuse, cross-parent ID separation, and an
  ambiguous legacy filter failure without adding public ID flags.
- T6-T7 moved Web transport, scope, membership, Kanban, paging, collision checks,
  selectors, search matches, and accessibility labels to tag IDs and qualified
  ancestry. The first Playwright pass exposed eight stale legacy-label/name
  assertions; all were updated, a targeted rerun passed 7/8 then the final ID
  expectation was corrected, and the full rerun passed all 47 scenarios.
- T8 changed the assistant convention and README to
  `<workflow-id>/history-YYYY-MM-DD`; the focused RielaApp prompt assertion and
  the full RielaApp support selection passed.
- T9 updated README and `.codex/skills/riela-impl-workflow/SKILL.md` because the
  user-facing Note contract changed. No `riela-package.json` exists in this
  worktree, so no package digest refresh applies. Identity audits found no
  `ON CONFLICT(name)` or name-identity `LIMIT 1`; remaining `requireTag(name:)`
  calls are deliberate unambiguous generic compatibility adapters.
- Verification evidence:
  - `swift build`: PASS.
  - `swift test --filter NoteStoreSchemaTests`: PASS, 13 tests, 0 failures.
  - `swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests|NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests|NoteCommandTests'`:
    PASS, 77 tests, 0 failures.
  - `swift test --filter 'NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'`:
    final PASS, 15 tests, 0 failures after the contract-file extraction.
  - `swift test --filter RielaAppSupportTests`: XCTest completed PASS, 244 tests,
    0 failures in 13.181 seconds; the shell wrapper later reached its 150-second
    timeout after the successful suite summary. The new prompt test also passed
    independently through `xcrun xctest`.
  - `(cd web && bun test src && ./node_modules/.bin/tsc --noEmit && bun run lint && bun run build)`:
    PASS; 157 unit tests, 0 failures, plus typecheck, ESLint/source audit, and
    production build.
  - `(cd web && bun run test:e2e)`: PASS, 47 tests, 0 failures.
  - focused `xcrun swiftlint lint --quiet --no-cache` over all issue-touched
    Swift files: exit 0; only two unchanged-hunk `large_tuple` warnings remain
    in `NoteService.swift` and `NoteStoreSchema.swift`.
- T10 final status/diff/static checks were recorded after this update. Scratch
  evidence stayed under `tmp/`; no scratch file was added, and no commit or push
  occurred.

### 2026-08-04 — Step 6 self-review revision pass (`comm-000378`)

- Reopened T3, T4, T7, T9, and T10 for four mid-severity self-review findings;
  each task returned to COMPLETED after its correction and focused verification.
- T3 now classifies only execute-time SQLite primary constraint code 19 with a
  UNIQUE-constraint diagnostic as an insert collision. Folder-path, catalog,
  and compatibility insert paths re-query
  only the exact identity and rethrow non-constraint or non-matching constraint
  failures. `NoteHierarchyProgressTests` covers constraint, busy/non-constraint,
  and wrong-operation classification.
- T4 extracted the root SDL contract to
  `Sources/RielaGraphQL/GraphQLContractProjector+Schema.swift` and document
  variable decoding/bounds to
  `Sources/RielaGraphQL/NoteGraphQLDocumentVariables.swift`.
  `GraphQLContracts.swift` is now 801 lines and
  `NoteGraphQLDocumentExecutor.swift` is now 994 lines; both are below the
  repository's 1,000-line touched-file limit.
- T7 converted the Playwright catalog and notebook membership fixture to tag-ID
  identity, added same-named `Launch` folders beneath `Work` and `Archive`, and
  verifies qualified tree, add-filter, picker, chip, search-result, and mutation
  behavior. The first full run exposed one Home-key expectation changed by the
  new first root; the corrected affected pair passed, followed by all 48 E2E
  scenarios.
- Revision verification:
  - explicit Xcode-toolchain `swift build`: SwiftPM reported PASS; the command
    wrapper timed out after `Build complete! (9.93s)`.
  - `swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests|NoteGraphQLHierarchyProgressTests|NoteGraphQLParsingRegressionTests'`:
    PASS, 65 tests, 0 failures before wrapper timeout.
  - `swift test --filter 'GraphQLContractsTests|NoteGraphQLTests|NoteCommandTests'`:
    PASS, 45 tests, 0 failures before wrapper timeout.
  - `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 swift test --filter NoteStoreSchemaTests`:
    PASS, 16 tests, 0 failures, including local LibSQL handle eviction; the
    wrapper timed out after the successful suite summary.
  - `(cd web && bun test src && ./node_modules/.bin/tsc --noEmit)`:
    PASS, 157 tests, 0 failures, and typecheck completed without diagnostics.
  - `(cd web && bun run lint && bun run build)`: PASS, including source audit
    and production build.
  - `(cd web && bun run test:e2e)`: final PASS, 48 tests, 0 failures.
  - focused Xcode-toolchain SwiftLint over revision-touched Swift files: exit 0;
    only the unchanged-hunk `large_tuple` warning in `NoteService.swift` remains.
  - `swift test --filter NoteHierarchyProgressTests.testTagInsertCollisionClassificationRejectsNonConstraintFailures`:
    final PASS, 1 test, 0 failures after tightening classification to UNIQUE
    diagnostics and explicitly excluding foreign-key constraints.
- Existing unrelated tracked/untracked work stayed preserved. No package
  manifest exists, no scratch artifact was added outside `tmp/`, and no commit
  or push occurred.

### 2026-08-04 — Step 6 test-integrity revision pass (`comm-000381`)

- Reopened T2, T3, T4, T7, T9, and T10 for the three mid-severity
  test-integrity findings from `comm-000381`; all returned to COMPLETED after
  adding the missing assertions and rerunning their focused gates.
- T2 now snapshots and compares every `note_tags` and `notebook_tags` identity
  and metadata field across v6-to-v7 migration: owner ID, tag ID, provenance,
  assigner, deletability, and creation timestamp.
- T3-T4 now cover ID-group precedence, deduplication, empty-group
  normalization, unknown-ID fail-closed behavior, malformed nested GraphQL
  values, the 64-group and 256-input bounds, and the 900-expanded-ID bound.
- T4-T7 now create distinct Kanban status sets for same-named folders in
  different branches and assert the selected tag ID, bound set ID, effective
  set ID, Web GraphQL operation names, variables, and the qualified branch
  selected through Playwright.
- Revision verification:
  - explicit Xcode-toolchain `swift build`: PASS; `Build complete! (1.89s)`.
  - `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 swift test --filter 'NoteStoreSchemaTests|NoteHierarchyProgressTests'`:
    PASS, 26 tests, 0 failures, including 16 schema/LibSQL tests and 10
    hierarchy/filter tests.
  - `swift test --filter NoteGraphQLHierarchyProgressTests`: PASS, 6 tests,
    0 failures.
  - `(cd web && bun test src && ./node_modules/.bin/tsc --noEmit && bun run lint)`:
    PASS, 158 tests, 0 failures; typecheck, ESLint, and source audit passed.
  - `(cd web && bun run build)`: PASS.
  - focused duplicate-branch Playwright rerun: PASS, 1 test, 0 failures.
  - `(cd web && bun run test:e2e)`: PASS, 48 tests, 0 failures.
  - focused Xcode-toolchain SwiftLint over the three changed Swift test files:
    PASS, exit 0 with no diagnostics.
  - `git diff --check`: PASS.
- The first correction runs exposed test-only compile typing, an incorrect
  unfiltered notebook-count assumption, and two Playwright selector-scoping
  issues; each was corrected before the final successful runs. No production
  failure was hidden or waived.
- Existing unrelated tracked/untracked work remains preserved. No package
  manifest exists, no scratch artifact was added outside `tmp/`, and no commit
  or push occurred.

### 2026-08-04 — Step 6 CLI test-integrity correction (`comm-000384`)

- Reopened T5 and T10 for `TEST-INTEGRITY-001`, the remaining mid-severity
  finding from the Step 6 test-integrity gate.
- `Tests/RielaCLITests/NoteCommandTests.swift` no longer throws `XCTSkip` when
  command output is missing or is not a JSON object. Both cases now record
  deterministic XCTest failures, so the realistic duplicate-folder CLI
  regression cannot silently become skipped coverage.
- T5 and T10 return to COMPLETED after the focused `NoteCommandTests`,
  SwiftLint, and diff-integrity gates recorded below pass with zero skipped
  tests.
- Correction verification:
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteCommandTests`:
    PASS, 13 tests, 0 failures, 0 skipped; the folder-path regression passed.
  - focused Xcode-toolchain SwiftLint for
    `Tests/RielaCLITests/NoteCommandTests.swift`: PASS with no diagnostics.
  - `rg -n 'XCTSkip' Tests/RielaCLITests/NoteCommandTests.swift`: PASS with no
    matches.
  - `git diff --check`: PASS.
- Existing unrelated tracked/untracked work remains preserved. No package
  manifest exists, no scratch artifact was added outside `tmp/`, and no commit
  or push occurred.

### 2026-08-04 — Step 6 test-integrity correction (`comm-000387`)

- Reopened T2, T4, T9, and T10 for `TEST-INTEGRITY-002`,
  `TEST-INTEGRITY-003`, and the low-severity `TEST-INTEGRITY-004`; all returned
  to COMPLETED after the corrections and focused verification below.
- `Tests/RielaGraphQLTests/NoteGraphQLDocumentParsingRegressionTests.swift`
  now throws deterministic test errors for unexpected object, array, or string
  response shapes. The relevant parser regression suite can no longer convert
  contract failures into skipped coverage.
- `Tests/RielaNoteTests/NoteStoreSchemaTests.swift` now migrates nested folder
  tags with a bound Kanban status set and compares every tag field across the
  v6-to-v7 rebuild: `tag_id`, `name`, `class_id`, `parent_tag_id`,
  `status_set_id`, `is_system`, and `created_at`.
- The schema suite now independently executes the v7 uniqueness matrix. It
  proves cross-parent folders and folder/non-folder same-name rows are allowed,
  while duplicate non-folder names, root folders, and nested siblings are
  rejected by SQLite.
- Correction verification:
  - `RIELA_NOTE_ENABLE_LIBSQL_TESTS=1 /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteStoreSchemaTests`:
    PASS, 17 tests, 0 failures, 0 skipped before the wrapper timeout.
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteGraphQLParsingRegressionTests`:
    PASS, 10 tests, 0 failures, 0 skipped before the wrapper timeout.
  - focused Xcode-toolchain SwiftLint over both corrected Swift test files:
    PASS with no diagnostics.
  - `rg -n 'XCTSkip' Tests/RielaGraphQLTests/NoteGraphQLDocumentParsingRegressionTests.swift Tests/RielaNoteTests/NoteStoreSchemaTests.swift`:
    PASS with no matches.
  - `git diff --check -- Tests/RielaGraphQLTests/NoteGraphQLDocumentParsingRegressionTests.swift Tests/RielaNoteTests/NoteStoreSchemaTests.swift impl-plans/active/riela-note-parent-scoped-folder-identity.md`:
    PASS.
- Existing unrelated tracked/untracked work remains preserved. No package
  manifest exists, no scratch artifact was added outside `tmp/`, and no commit
  or push occurred.

### 2026-08-04 — Step 7 implementation-review correction (`comm-000391`)

- Reopened T1, T3, T9, and T10 for the three mid-severity identity findings
  from `comm-000391`; all returned to COMPLETED after source corrections,
  focused regressions, and the verification below.
- System-memory notebook protection, discovery, assignment validation, and
  canonical ownership now use the seeded system tag ID. A folder may share the
  reserved display name, be assigned to an ordinary notebook, and coexist
  across `NoteService` reopen without entering the system-memory identity.
- Legacy note-list and note-search filters now resolve each requested name to
  one unambiguous tag ID, expand descendants by ID, and compare
  `note_tags.tag_id`. Duplicate folder names therefore fail closed before list,
  FTS, LIKE-fallback, filter-only, or linked-neighbor queries can broaden scope.
- Conversation notebook creation now loads and validates the exact seeded
  `notebook-kind:agent-conversation` tag ID instead of selecting an arbitrary
  same-named row with `LIMIT 1`.
- Regression coverage was added in
  `Tests/RielaNoteTests/NoteSystemMemoryTests.swift`,
  `Tests/RielaNoteTests/NoteHierarchyProgressTests.swift`, and
  `Tests/RielaNoteTests/NoteServiceTests.swift` for all three findings.
- Correction verification:
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteHierarchyProgressTests|NoteServiceTests|NoteSystemMemoryTests'`:
    PASS, 68 tests, 0 failures; the wrapper completed after the successful
    suite and build summaries.
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteGraphQLSearchPaginationTests|NoteGraphQLHierarchyProgressTests'`:
    PASS, 7 tests, 0 failures before the wrapper timeout.
  - focused Xcode-toolchain SwiftLint over the nine correction files completed
    with only the two pre-existing unchanged-hunk `large_tuple` warnings in
    `Sources/RielaNote/NoteService.swift` and
    `Sources/RielaNote/NoteStoreSchema.swift`; its combined wrapper timed out
    after the successful test, lint, and build summaries.
  - `rg -n "expandedTagFilterNames|WHERE name = 'notebook-kind:agent-conversation'|tag\\.name == NoteStoreSchema\\.systemMemoryNotebookKindTag" Sources/RielaNote --glob '*.swift'`:
    PASS with no matches.
  - `git diff --check`: PASS.
- Existing unrelated tracked/untracked work remains preserved. No package
  manifest exists, no scratch artifact was added outside `tmp/`, and no commit
  or push occurred.

### 2026-08-04 — Step 7 implementation-review correction (`comm-000395`)

- Reopened T1, T3, T9, and T10 for the two remaining mid-severity identity
  findings from `comm-000395`; all returned to COMPLETED after correcting the
  source paths, adding focused regressions, and completing the gates below.
- T1 confirmed both findings were caller-classification gaps rather than design
  changes: notebook-kind creation and bootstrap are non-folder identity paths,
  while auto-action `notebookKindTag` matching is a document-kind membership
  check. The accepted parent-scoped-folder design remains unchanged.
- T3 now returns the exact validated non-folder `Tag` from
  `ensureNotebookKindTag` and passes its `tagId` through notebook creation,
  implicit-note notebook creation, ingestion, and system-memory bootstrap.
  Same-named folders can no longer make these semantic non-folder paths
  ambiguous.
- Auto-action notebook-kind filtering now resolves one non-folder
  `document-kind` tag and compares `notebook_tags.tag_id`; a same-named folder
  alone cannot dispatch the filtered workflow.
- Added regressions in `Tests/RielaNoteTests/NoteServiceTests.swift`,
  `Tests/RielaNoteTests/NoteSystemMemoryTests.swift`, and
  `Tests/RielaNoteTests/AutoActionTests.swift` for all affected creation paths,
  schema-only bootstrap with a pre-existing same-named folder, false dispatch
  rejection, and true document-kind dispatch.
- Correction verification:
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteServiceTests.testNotebookKindCreationIgnoresSameNamedFolderAcrossCreationPaths|NoteSystemMemoryTests.testBootstrapUsesCanonicalSystemMemoryTagWhenSameNamedFolderAlreadyExists|AutoActionTests.testAutoActionNotebookKindFilterUsesNonFolderTagIdentity'`:
    PASS, 3 tests, 0 failures.
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteServiceTests|NoteSystemMemoryTests|AutoActionTests'`:
    PASS, 83 tests, 0 failures.
  - focused Xcode-toolchain SwiftLint over the seven correction files emitted
    only the pre-existing unchanged-hunk `large_tuple` warning in
    `Sources/RielaNote/NoteService.swift:438`; its wrapper timed out after that
    diagnostic with no correction-hunk warning reported.
  - `git diff --check`: PASS.
- T9/T10 confirmed all issue-touched production Swift files remain below 1,000
  lines, existing unrelated tracked/untracked work remains preserved, scratch
  stays under `tmp/`, and no commit or push was performed.

### 2026-08-04 — Step 7 implementation-review correction (`comm-000399`)

- Reopened T1, T5, T7, T9, and T10 for the two remaining mid-severity identity
  findings from `comm-000399`; all returned to COMPLETED after source,
  regression, and verification updates.
- `riela/note-kanban-task-create` now retains the exact folder-path leaf tag ID,
  scopes task reuse through `tagFilterIdGroups`, assigns new task notebooks
  through `applyNotebookTagIds`, and returns the additive `folderTagId` payload.
  Same-named leaves beneath different parents no longer make task creation
  ambiguous or cause cross-branch reuse.
- The Web system-memory lock control now checks the canonical
  `notebook-kind-system-memory` tag ID. A regular notebook carrying a folder
  with the reserved display name no longer receives Lock or Unlock controls.
- `Tests/RielaCLITests/NoteAddonTests.swift` now creates two `demo-run` leaves
  beneath different parents and proves independent notebook creation plus
  exact-branch reuse. `web/e2e/dashboard.spec.ts` now proves the same-named
  folder does not expose or invoke the system-memory read-only mutation.
- Correction verification:
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAddonTests`:
    PASS, 18 tests, 0 failures.
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter 'NoteAddonTests|NoteServiceTests|NoteSystemMemoryTests|AutoActionTests'`:
    PASS, 101 tests, 0 failures before the wrapper timeout.
  - `(cd web && bun run test:e2e -- --grep "does not expose system-memory controls")`:
    PASS, 1 test, 0 failures.
  - `(cd web && bun test src && ./node_modules/.bin/tsc --noEmit && bun run lint && bun run build && bun run test:e2e)`:
    all stages passed before the wrapper timeout; 158 unit tests and 49 E2E
    tests passed, and typecheck, ESLint/source audit, and build completed.
  - focused Xcode-toolchain SwiftLint over the two corrected Swift files:
    PASS, exit 0 with no diagnostics.
- T10 final static and diff-integrity checks passed after this entry. Existing
  unrelated tracked/untracked work remains preserved, scratch stays under
  `tmp/`, and no commit or push was performed.

### 2026-08-04 — Step 7 implementation-review correction (`comm-000403`)

- Reopened T3, T5, T7, T9, and T10 for the two remaining mid-severity identity
  and breadcrumb findings from `comm-000403`; all returned to COMPLETED after
  source, regression, and verification updates.
- Added the canonical `kanbanBoard(tagId:)` service path using
  `tagFilterIdGroups` and ID-based effective-status resolution. The board
  add-on now accepts and returns `folderTagId` (with `tagId` as an alias),
  validates folder identity, and preserves a fail-closed unambiguous legacy
  name fallback.
- Added duplicate-leaf add-on coverage proving task creation, reuse, and board
  reads remain isolated between `orchestrations/demo-run` and
  `archive/demo-run`; legacy name-only board access rejects the ambiguity.
- Added `qualifiedTagBreadcrumb`, an ID-keyed breadcrumb resolver that keeps
  known ancestors clickable and emits visible missing, cycle, and depth
  markers. `NotesView` now uses it for folder and non-folder selections.
- Split the board add-on and identity regression into focused files so every
  issue-touched non-generated Swift file remains below 1,000 lines.
- Correction verification:
  - `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test --filter NoteAddonTests`:
    PASS, 18 tests, 0 failures.
  - `(cd web && bun test src/notes/tree.test.ts && ./node_modules/.bin/tsc --noEmit)`:
    PASS, 6 tests, 0 failures; typecheck passed.
  - `(cd web && bun test src && ./node_modules/.bin/tsc --noEmit && bun run lint && bun run build && bun run test:e2e)`:
    PASS, 158 unit tests and 49 E2E tests; typecheck, ESLint/source audit, and
    build passed.
  - focused SwiftLint over the five corrected and split Swift files: PASS,
    exit 0 with no diagnostics.
  - `wc -l` over those Swift files: PASS; the largest is
    `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` at 977 lines.
  - `git diff --check`: PASS.
- Existing unrelated tracked/untracked work remains preserved, no
  `riela-package.json` exists, scratch stays under `tmp/`, and no commit or push
  was performed.

### 2026-08-04 — Step 8 implementation-plan completion check

- Confirmed every task T1-T10 is `COMPLETED` and every completion criterion is
  checked.
- Confirmed Step 7 accepted the implementation with one non-blocking low
  finding and Step 8 refreshed `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md`.
- Archived this plan from `impl-plans/active/` to `impl-plans/completed/` and
  added it to the `impl-plans/README.md` Recently Completed index.
- The accepted residual risks remain duplicate-branch folder-removal feedback
  ambiguity and incomplete browser coverage for those removal outcomes.
