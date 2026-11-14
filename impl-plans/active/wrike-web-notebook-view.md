# Wrike-Style Web Notebook View Implementation Plan

**Status**: Implementation complete; independent review pending
**Workflow Mode**: `issue-resolution`
**Branch**: `feat/riela-note-web-notebook-view`
**Issue Reference**: “Wrike-style web notebook view for Riela Note (folder tree + list/board views + dual-server Note GraphQL)”; no GitHub issue URL, repository, or number supplied
**Design Reference**: `design-docs/specs/design-wrike-web-notebook-view.md`
**Research Reference**: `design-docs/research/wrike-web-notebook-view-brief.md` at `7006afa`
**Accepted Design Review**: `comm-001595`; accepted with no high, mid, or low findings
**Created**: 2026-07-25
**Last Updated**: 2026-07-25

---

## Objective

Implement the accepted Wrike-style Notes feature as one work package:

- a SolidJS Notes view with an arbitrary-depth folder-class tag tree, List and
  Board views, folder scoping, folder creation, notebook details, folder
  membership controls, and bounded read-only note previews;
- real Note GraphQL execution behind RielaApp's existing Host, Origin, CSRF,
  and JSON checks, using the active profile's note root;
- optional same-origin SPA hosting in `riela serve`, with the existing
  `/note/register` bearer flow and no alternate authentication or CORS path;
- additive `DefineNoteTagInput.createOnly` behavior that makes web folder
  creation collision-safe without changing existing upsert callers; and
- deterministic frontend and Swift coverage, documentation refresh, and one
  local commit with no push or pull request.

The accepted design is the source of truth. Implementation discoveries may
refine module placement but must not reopen the accepted behavior, IN/OUT
boundaries, authentication model, or newer-wins convergence contract.

## References and accepted decisions

- Accepted design:
  `design-docs/specs/design-wrike-web-notebook-view.md`.
- Ground-truth intake brief:
  `design-docs/research/wrike-web-notebook-view-brief.md` at `7006afa`.
- Step 3 review:
  `comm-001595`, decision `accepted`, `needs_revision: false`, findings `[]`.
- Codex-agent references: none supplied.
- Cursor adapter boundaries: none required.
- User-QA references: none; the accepted design records no unresolved user
  decision requiring `design-docs/user-qa/`.
- Intentional divergences to preserve:
  no Wrike status sort, tree reorder, rename/delete, extra views, or persistent
  browser bearer; `DefineNoteTagInput.createOnly` is an additive safety
  precondition and defaults to the existing upsert behavior.

## Scope

### Included

- `Notes` shell navigation and CLI-mode shell fallback.
- Folder-class tag tree, deterministic orphan/cycle handling, selection,
  breadcrumb, expansion, and create-folder flow.
- Folder-scoped, bounded notebook pagination using one folder name in
  `tagFilter`.
- Sortable list rows and four-column `none | progress | done | pending` board.
- Shared notebook detail panel with direct folder-chip add/remove and bounded
  read-only note preview.
- Per-notebook optimistic progress controller whose newest desired value
  converges in the database even after view, folder, or selection changes.
- RielaApp Note GraphQL composition over the active profile note root.
- Optional `riela serve --web-root <path>` static hosting, API precedence,
  safe asset resolution, SPA fallback, and browser registration bootstrap.
- Focused Bun, Swift, and existing-harness Playwright tests.
- Directly affected README/design/skill documentation refresh if implementation
  evidence makes it necessary.

### Excluded

- Gantt, Table, Calendar, custom fields, pinned items, spaces, dashboards, WIP
  limits, swimlanes, folder-tree drag/reordering, or per-folder rename/delete.
- Web note creation/edit/delete, notebook rename/delete, offline behavior,
  CORS, or a parallel note REST API.
- Tag rename/delete/reparent/clear-parent operations.
- A second browser authentication system or persistent bearer storage.
- Unrelated source, test, documentation, or workflow changes.

## Task breakdown

### T1. Baseline and integration audit

**Status**: COMPLETED
**Write scope**: this plan's progress log and scratch evidence under
`tmp/wrike-web-notebook-view/` only
**Depends on**: accepted Step 3 review `comm-001595`
**Parallelizable**: no; this establishes the implementation baseline

**Tasks**:

- Confirm branch, dirty-worktree ownership, and that the accepted design and
  research brief are unchanged before editing.
- Trace current Note GraphQL input decoding, schema projection, mutation
  result/error mapping, RielaApp router construction, active-profile changes,
  `riela serve` parsing/composition, static resolver behavior, web bootstrap,
  test harnesses, and packaging of `web/dist`.
- Record exact files selected for new frontend controller/components and any
  existing helpers reused.
- Confirm no implementation discovery conflicts with the accepted design. If
  one does, stop and request design revision rather than silently changing the
  contract.

**Deliverables**:

- A dated progress-log entry with inspected paths, retained user changes,
  concrete test targets, and any blocker.

**Verification**:

```bash
git status --short --branch
git diff --exit-code 7006afa -- design-docs/research/wrike-web-notebook-view-brief.md
test -s design-docs/specs/design-wrike-web-notebook-view.md
rg -n "DefineNoteTagInput|RielaAppWebRouter|noteRootURL|ServeHTTPCommand|RielaStaticAssetResolver|note/register|bootstrap" Sources Tests web/src web/e2e
```

### T2. Add atomic create-only folder-tag semantics

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaNote/NoteService+Catalog.swift`
- `Sources/RielaGraphQL/NoteGraphQLContracts.swift`
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift`
- `Sources/RielaGraphQL/NoteGraphQLService.swift`
- focused files under `Tests/RielaNoteTests/` and `Tests/RielaGraphQLTests/`

**Depends on**: T1
**Parallelizable**: yes, with T3 and T4 after T1; write scopes are disjoint

**Tasks**:

- Add optional `createOnly` to `GraphQLDefineNoteTagInput`, its schema contract,
  decoding/projection, and service call.
- Extend `NoteService.defineTag` with a defaulted create-only parameter so
  existing direct and GraphQL callers preserve the current upsert behavior.
- In the existing database transaction, reject an existing normalized tag name
  before class or parent mutation when create-only is true.
- Return the established `accepted: false`, `invalid_request` mutation result
  through GraphQL without reclassifying or reparenting the existing tag.
- Preserve system-tag protection, parent validation, hierarchy-cycle checks,
  and all omitted/false compatibility behavior.
- Add service and document-executor tests for successful creation, atomic
  collision rejection, unchanged existing class/parent, omitted/false upsert
  compatibility, and projected optional input.

**Deliverables**:

- One additive, backward-compatible create-only GraphQL/service contract with
  deterministic collision evidence.

**Verification**:

```bash
swift test --filter RielaNoteTests
swift test --filter RielaGraphQLTests
```

### T3. Compose active-profile Note GraphQL in RielaApp

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaApp/RielaAppWebRouter.swift`
- `Sources/RielaApp/RielaAppWebServerController.swift`
- `Sources/RielaApp/RielaAppWebAPI.swift` only if profile-root refresh belongs
  at the existing API composition seam
- `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift`
- focused additions under `Tests/RielaAppSupportTests/`

**Depends on**: T1; T2 only for final folder-create integration coverage
**Parallelizable**: yes, with T2 and T4 after T1; write scopes are disjoint

**Tasks**:

- Build `NoteService(SQLiteNoteDatabaseDriver(noteRoot:))` and
  `NoteGraphQLDocumentExecutor` from the same active-profile root returned by
  `noteRootURL(profileName:)`.
- Inject the executor into the deterministic `/graphql` path while allowing
  unauthenticated Note operations only inside the already-authenticated
  RielaApp composition.
- Preserve the outer router's exact Host, Origin, CSRF, and JSON content-type
  checks before parsing/execution.
- Define and implement the active-profile refresh boundary so a bootstrap
  profile and Note executor can never reference different roots.
- Keep non-Note web routes available if executor construction fails and emit a
  sanitized service error without paths or SQLite detail.
- Preserve schema-echo behavior only for operations the injected Note executor
  does not handle.
- Test rejected requests for missing/invalid security headers, successful Note
  GraphQL round trips, real active-root reads, profile/root refresh, sanitized
  construction failure, and unaffected REST/static routes.

**Deliverables**:

- RielaApp `/graphql` executes Note operations against the active profile's
  note database behind existing web security.

**Verification**:

```bash
swift test --filter RielaAppWebAPIRouteTests
swift test --filter RielaAppNotesIntegrationTests
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
```

### T4. Add optional same-origin SPA hosting to `riela serve`

**Status**: COMPLETED
**Write scope**:

- `Sources/RielaCLI/ParityCommandSupport.swift`
- `Sources/RielaCLI/ServeHTTPCommand.swift`
- `Sources/RielaCLI/RielaCLIApplication.swift`
- focused CLI parsing/help files only if required by the existing parser
- `Sources/RielaServer/RielaStaticAssetResolver.swift`
- a focused route-composition type under `Sources/RielaServer/` if needed
- `Tests/RielaServerTests/RielaHTTPRoutingAndStaticAssetTests.swift`
- `Tests/RielaCLITests/ServeHTTPCommandTests.swift`
- focused additions under `Tests/RielaServerTests/` and `Tests/RielaCLITests/`

**Depends on**: T1
**Parallelizable**: yes, with T2 and T3 after T1; write scopes are disjoint

**Tasks**:

- Parse and document optional `--web-root <path>` for bare `riela serve`;
  expand and validate it as a readable directory containing `index.html`
  before listener readiness.
- Keep omitted `--web-root` behavior identical to the current headless server.
- Compose service routes before static fallback so `/graphql`, `/healthz`,
  `/overview`, and POST `/note/register` retain precedence.
- When static hosting is enabled, route GET `/note/register?code=...` to the SPA
  while preserving POST redemption; do not expose HTTP challenge creation.
- Reuse and harden `RielaStaticAssetResolver` for exact MIME responses,
  extensionless SPA fallback, concrete missing-asset 404s, API-prefix
  exclusions, decoded/encoded traversal rejection, NUL rejection, and symlink
  containment.
- Do not add CORS headers, cookies, or another credential.
- Include the effective web root in ready output while retaining the existing
  endpoint, note API, and registration URL records.
- Test option parsing, invalid roots, route/method precedence, GET bootstrap,
  POST redemption, bearer-protected GraphQL, static MIME/index behavior,
  traversal and symlink escapes, unchanged headless behavior, and startup
  output.

**Deliverables**:

- Optional, path-safe, same-origin static hosting next to the current Note API
  and bearer-registration service.

**Verification**:

```bash
swift test --filter RielaServerTests
swift test --filter RielaCLITests
```

### T5. Build the typed web Note transport and data controller

**Status**: COMPLETED
**Write scope**:

- new focused modules under `web/src/notes/`
- `web/src/api.ts` and `web/src/contracts.ts` only for shared host-mode seams
- focused `*.test.ts` files under `web/src/`

**Depends on**: T1; T2 for final create-only variables; T3 and T4 for live
integration, but unit implementation may start against the accepted contracts
**Parallelizable**: no; controller and UI integration in T6 share frontend
contracts and should be implemented serially

**Tasks**:

- Add typed GraphQL envelope, query, mutation, error, notebook, note, tag,
  assignment, tag-class, sort, and progress contracts without production
  fixtures, mocks, or fetch overrides.
- Discover host mode through same-origin `/api/v1/bootstrap`: successful JSON
  selects RielaApp mode, a 404 selects CLI mode, and network/parse failure
  remains a connection error.
- In RielaApp mode, send same-origin credentials and `X-Riela-CSRF`; in CLI
  mode, read the registration code, remove it with `history.replaceState`,
  redeem it through POST `/note/register`, and keep the bearer only in
  `sessionStorage`.
- On CLI 401, clear only the current session bearer and return to registration
  guidance.
- Bound every notebooks/notes request to `limit <= 200`; implement explicit
  offsets and all-page board loading without relying on server clamping.
- Build deterministic folder-tree, breadcrumb, folder-filter, folder-collision,
  and assignment helpers.
- Build a Notes data controller keyed by notebook ID. Serialize writes per
  notebook, retain latest desired progress independently of mounted view/folder,
  ignore stale completions, reconcile current failures from canonical data, and
  replay newer intent until database convergence.
- Add focused tests for host headers/credentials, registration lifecycle,
  GraphQL/result errors, bounded paging, tree orphan/cycle handling, sort/filter
  variables, create-only folder variables, provenance, and context-independent
  newer-wins progress behavior.

**Deliverables**:

- A testable typed transport/controller layer shared by List, Board, and detail
  surfaces.

**Verification**:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
```

### T6. Implement the Notes shell, folder tree, List, Board, and detail panel

**Status**: COMPLETED
**Write scope**:

- `web/src/App.tsx`
- `web/src/styles.css`
- new focused view/component files under `web/src/views/` and
  `web/src/components/`
- focused UI/helper tests under `web/src/`

**Depends on**: T5
**Parallelizable**: no; the view surfaces share controller state and styling

**Tasks**:

- Add `Notes` navigation. Preserve the full existing shell in RielaApp mode and
  present Notes as the available product surface in CLI mode.
- Render the Folder tab/tree from folder-class tags at arbitrary depth with
  deterministic sibling order, roots for invalid parents, cycle guards,
  independent chevron activation, selection, breadcrumb, tree semantics, and
  keyboard navigation.
- Add root/child folder creation with trimmed non-empty input, local collision
  feedback, `createOnly: true`, server-authoritative collision handling,
  returned-folder validation, parent expansion, and no rename/delete/move
  affordance.
- Add content breadcrumb, `List | Board` tabs, refresh, and supported sort
  choices while retaining view/sort during folder navigation.
- Render list rows with title, progress, folder chips, updated time, bounded
  paging, keyboard activation, and distinct empty/loading/partial/error/retry
  states.
- Render fixed Board columns `none`, `progress`, `done`, `pending` with counts,
  visible empty columns, native drag/drop, same-column no-op, and an accessible
  non-drag progress control.
- Render the shared right-side detail panel with title, progress, timestamps,
  direct folder chips, add picker, deletable-only remove controls, and bounded
  sanitized read-only notes.
- Send `provenance: "human"` and `assignedBy: "riela-web"` for additions and
  human provenance for removals. Refresh canonical membership and close the
  panel with a non-destructive message when the notebook leaves scope.
- Preserve focus return, labeled controls, live mutation feedback, and
  control-local disabled states.

**Deliverables**:

- One accessible, information-dense Notes feature satisfying every accepted
  frontend behavior in both host modes.

**Verification**:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
```

### T7. Cross-surface integration, browser coverage, and documentation

**Status**: COMPLETED
**Write scope**:

- `web/e2e/dashboard.spec.ts` or a focused new spec under `web/e2e/`
- directly affected integration tests in the T2-T6 test scopes
- `README.md`
- `.codex/skills/riela-impl-workflow/SKILL.md`
- accepted design/plan progress sections only when implementation evidence
  requires alignment

**Depends on**: T2, T3, T4, T5, T6
**Parallelizable**: no; this validates the integrated result

**Tasks**:

- Exercise RielaApp GraphQL security plus active-root execution through the
  real router composition.
- Exercise CLI static hosting, registration redemption, authenticated GraphQL,
  and browser asset/navigation paths through the real server composition.
- Use existing Playwright infrastructure for Notes navigation, List/Board
  switching, folder scoping, detail opening, and accessible progress movement
  only where possible without new production fixtures or fetch overrides.
- If the existing browser harness cannot supply Note data without forbidden
  production seams, record the exact limitation and retain deterministic Bun
  and Swift integration coverage rather than adding infrastructure outside
  scope.
- Review `README.md` and `.codex/skills/riela-impl-workflow/SKILL.md`; update
  directly affected Note/web/serve usage and verification contracts. Correct
  the stale statement that Note transport is not shipped if still present.
- Run `web/scripts/audit-source.ts` through the normal lint command and confirm
  no production fixture/mock/fetch-override violations.

**Deliverables**:

- Cross-surface evidence for both hosting paths and user-facing documentation
  aligned to shipped behavior.

**Verification**:

```bash
cd web && bun run test:e2e
cd web && bun run lint
swift test --filter RielaAppWebAPIRouteTests
swift test --filter ServeHTTPCommandTests
rg -n "not shipped|note transport|--note-api|--web-root|Notes" README.md .codex/skills/riela-impl-workflow/SKILL.md
```

### T8. Final verification, review handoff, and commit

**Status**: IN_PROGRESS
**Write scope**: this plan's progress log, directly affected docs, and the final
commit metadata only
**Depends on**: T2 through T7
**Parallelizable**: no

**Tasks**:

- Run all required frontend and Swift commands separately so each result is
  attributable.
- Record failures with exact command, test, and evidence. Do not hide failures
  behind the known unrelated `DaemonWorkflowNodePatchTests` event-source
  restart or agent-VM interleaved-submit flakes.
- Confirm implementation respects the accepted OUT list and contains no CORS,
  web note editing, tag rename/delete, parallel note REST API, production web
  fixtures/mocks/fetch overrides, or request limit above 200.
- Run diff hygiene, inspect the complete change set, and update every task
  status and progress-log entry with delivered files and verification evidence.
- Complete implementation self-review and independent review workflow steps;
  address all high/mid findings before commit.
- Run the repository precommit safety skill/check required by the commit
  workflow, then commit all scoped work on
  `feat/riela-note-web-notebook-view`.
- Confirm the worktree is clean, the branch contains the commit, and nothing
  was pushed and no pull request was opened.

**Deliverables**:

- Verified, reviewed, documented, committed implementation with a clean
  worktree and explicit no-push/no-PR handoff.

**Verification**:

```bash
cd web && bun run lint
cd web && bun run typecheck
cd web && bun run test
cd web && bun run build
swift build
swift test --filter RielaServerTests
swift test --filter RielaGraphQLTests
swift test --filter RielaNoteTests
swift test --filter RielaCLITests
git diff --check
git status --short --branch
git log -1 --oneline
```

## Dependency graph

```text
Accepted Step 3 review (comm-001595)
                |
               T1
        +-------+-------+
        |       |       |
       T2      T3      T4
        |       |       |
        +---+---+---+---+
            |       |
            T5      |
             |      |
            T6      |
             +------+
                |
               T7
                |
               T8
```

T2, T3, and T4 may proceed in parallel only after T1 because their write scopes
are disjoint. T5 may begin unit work after T1 against accepted contracts, but
its completion depends on T2-T4. T6-T8 are serial integration stages.

## Completion criteria

- [x] The Notes shell works in RielaApp and CLI serve modes without changing
  their established authentication models.
- [x] Folder tree, descendant scope, create-only folder creation, list, board,
  sort, detail, chips, preview, focus, and error states match the accepted
  design.
- [x] Selecting a successfully created folder clears the previous scope before
  loading, and a failed scoped refresh after folder removal closes the detail
  surface and leaves no stale row or card visible.
- [x] Delayed folder creation and removal completions preserve newer folder
  navigation and notebook-detail selection instead of reporting false failure
  or closing newer context.
- [x] Progress updates converge newest-wins in the database independently of
  mounted board/view/folder context.
- [x] RielaApp `/graphql` uses the active profile note root and preserves Host,
  Origin, CSRF, and JSON checks; direct route tests cover invalid security
  inputs, sanitized Note-executor construction failure, and unaffected
  REST/static routes.
- [x] `riela serve --web-root` safely hosts the SPA, preserves service/POST
  registration precedence, and reuses bearer registration with no CORS or
  alternate auth; reserved service namespaces never fall through to the SPA,
  and startup rejects non-file or escaping `index.html` roots.
- [x] Existing callers retain `defineNoteTag` upsert behavior; create-only
  collision tests prove no class/parent mutation.
- [x] Web source audit, lint, typecheck, tests, and build pass.
- [x] Playwright exercises folder-chip addition and removal through the detail
  controls, including canonical chip updates and active-scope ejection.
- [x] `swift build` and the required RielaServer, RielaGraphQL, RielaNote, and
  RielaCLI suites pass, with any unrelated flakes recorded explicitly.
- [x] Live `ServeHTTPCommand` coverage preserves both headless `--note-api`
  behavior and combined `--note-api --web-root` registration/GraphQL behavior.
- [x] Directly affected README and Riela implementation-workflow skill content
  reflect the shipped behavior.
- [ ] Independent implementation review has no unresolved high/mid findings.
- [ ] All changes are committed on
  `feat/riela-note-web-notebook-view`; the worktree is clean; nothing is pushed;
  no pull request is opened.

## Progress-log expectations

After each task or correction pass, append a dated entry containing:

- task IDs and status transitions;
- files added/changed and behavior delivered;
- dependencies unblocked or blockers introduced;
- tests added and exact commands run with pass/fail counts;
- review communication IDs, finding severities, and dispositions;
- browser/manual verification performed or the exact harness gap;
- known unrelated failures separated from feature failures; and
- commit hash when T8 completes.

Do not mark a task complete from code presence alone. Completion requires its
deliverables, focused verification, and progress evidence.

## Progress log

### 2026-07-25 — Step 4 plan creation

- **Completed**: Converted the accepted design into T1-T8 with explicit write
  scopes, deliverables, dependencies, verification, completion criteria, and
  progress expectations.
- **Review input**: Step 3 `comm-001595` accepted
  `design-docs/specs/design-wrike-web-notebook-view.md` with findings `[]` and
  `needs_revision: false`; no corrective feedback was required.
- **Codex-agent references**: none; no Cursor adapter work planned.
- **Verification**: passed `if rg -n '[[:blank:]]+$'
  impl-plans/active/wrike-web-notebook-view.md; then exit 1; fi`,
  `test -s impl-plans/active/wrike-web-notebook-view.md`,
  the required-section `rg`, and `git diff --check` for the design and plan.
- **Blockers**: none.

### 2026-07-25 — Step 6 implementation

- **Status transitions**: T1-T7 `COMPLETED`; T8 `IN_PROGRESS` pending the
  independent implementation review and later commit gate.
- **Review input**: Step 5 `comm-001598` accepted the design and active plan
  with no high, mid, or low findings. Workflow mode is `issue-resolution`, not
  planning-only. Codex-agent references remain absent.
- **Baseline**: Confirmed branch `feat/riela-note-web-notebook-view`, preserved
  the untracked accepted design/plan, and verified the research brief remains
  unchanged from `7006afa`.
- **T2**: Added default-compatible `DefineNoteTagInput.createOnly` across
  RielaNote and RielaGraphQL. Create-only collisions now reject inside the
  existing transaction before any class/parent mutation; omitted/false callers
  retain upsert behavior.
- **T3**: Added request-time RielaApp Note executor composition in
  `Sources/RielaApp/RielaAppWebNoteGraphQL.swift` and routed authenticated
  `/graphql` requests through it. The active profile and note root are captured
  together per request; outer Host, Origin, CSRF, and JSON checks remain first.
- **T4**: Added optional `--web-root`, ready-output reporting, same-origin
  static SPA routing, GET registration bootstrap, service/POST registration
  precedence, and NUL/traversal/symlink containment.
- **T5-T6**: Added the typed web GraphQL client, session-only CLI registration,
  deterministic folder tree helpers, notebook-keyed newest-wins progress
  controller, and the Notes shell with folder-scoped List/Board views, sort,
  folder creation/chips, accessible progress control, and bounded read-only
  detail preview. Production source contains no fixtures, mocks, or fetch
  overrides.
- **T7**: Added Bun tests and Playwright coverage for transport, tree,
  reconciliation, folder scoping, List/Board/detail, and progress mutation.
  Updated `README.md` and
  `.codex/skills/riela-impl-workflow/SKILL.md` for the dual-host behavior.
- **Correction during verification**: The first Playwright run found the list
  button's semantic role overridden as `listitem`; the role override was
  removed and the folder locator made exact. The first CLI run found that
  inserting `--web-root` into two established help examples broke compatibility
  assertions; those examples were restored and a separate web-root example was
  added. Focused reruns and full gates pass.
- **Web verification**: `cd web && bun run lint && bun run typecheck && bun run
  test && bun run build` passed source audit, ESLint, TypeScript, 8 tests in 4
  files, and Vite build. `cd web && bun run test:e2e` passed 6 tests.
- **Swift verification**: `swift build` passed.
  `swift test --filter RielaServerTests` passed 43 tests;
  `swift test --filter RielaGraphQLTests` passed 104 tests;
  `swift test --filter RielaNoteTests` passed 123 tests; and
  `swift test --filter RielaCLITests` passed 656 tests. Focused
  `RielaAppWebAPIRouteTests` passed 5 tests and `ServeHTTPCommandTests` passed
  4 tests.
- **Lint**: `/usr/bin/xcrun swiftlint --quiet --no-cache` exited successfully
  with seven warning-only findings, all in pre-existing untouched lines/files.
- **Browser evidence**: Existing Playwright infrastructure exercised the full
  Notes interaction without production fixture seams. Screenshot evidence is
  under gitignored `tmp/web-dashboard-e2e/screenshots/`.
- **Blockers**: none. Independent review, precommit safety check, commit, and
  clean-worktree proof intentionally remain in T8.

### 2026-07-25 — Step 6 self-review correction pass

- **Review input**: Step 6 self-review `comm-001600` returned
  `needs_revision: true` with five mid findings and no high findings.
- **Progress reconciliation**: `web/src/notes/controller.ts` now retains the
  last true canonical notebook while another desired value is pending. If both
  the write and canonical refresh fail, it clears only the current failed
  intent, restores the canonical value, reports both failures, and continues
  to replay newer intent. A focused double-failure test covers the fallback.
- **Paging and stale scope**: Added `web/src/notes/paging.ts` with a fixed
  200-record page contract, explicit offsets, per-page generation checks, and
  incremental snapshots. Folder changes clear previous membership before the
  request, list partial pages remain visible and labeled, incomplete Board
  counts remain hidden, and failed retries cannot mark partial content
  complete. Bun and Playwright tests cover bounded offsets, stale generations,
  and previous-scope fail-closed behavior.
- **Focus**: List rows and Board card buttons register per-notebook activators.
  Closing the detail panel restores focus to the current activator when it
  remains mounted; scope-removal closes without targeting a removed control.
  Playwright asserts focus restoration.
- **Frontend test matrix**: Expanded coverage for `createOnly: true`, returned
  folder class/parent validation, trimmed-name collision suppression without a
  request, rejected result and GraphQL errors, HTTP 401 session clearing,
  apply/remove human provenance, bounded paging, double-failure convergence,
  focus restoration, and failed folder scope.
- **Live CLI integration**:
  `Tests/RielaCLITests/ServeHTTPCommandTests.swift` now launches the real
  command with `--note-api --web-root`, loads the SPA registration URL, redeems
  the one-use code through POST `/note/register`, and executes authenticated
  `/graphql` with the returned bearer.
- **Focused verification**: `swift test --filter ServeHTTPCommandTests` passed
  4 tests. `swift test --filter RielaAppNotesIntegrationTests` passed 20 tests.
- **Final web verification**: `cd web && bun run lint && bun run typecheck &&
  bun run test && bun run build && bun run test:e2e` passed production-source
  audit, ESLint, TypeScript, 15 Bun tests with 42 assertions, Vite build, and 7
  Playwright tests.
- **Final Swift verification**: `swift build` passed;
  `swift test --filter RielaCLITests` passed 656 tests; and
  `/usr/bin/xcrun swiftlint --quiet --no-cache` exited successfully with the
  same seven pre-existing warning-only findings. Prior unchanged-surface suite
  evidence remains valid: RielaServer 43, RielaGraphQL 104, and RielaNote 123.
- **Finding disposition**: all five `comm-001600` mid findings are addressed.
  T8 remains `IN_PROGRESS` pending the next self-review, independent review,
  precommit safety check, and commit.

### 2026-07-25 — Step 6 test-integrity correction pass

- **Review input**: Step 6 test-integrity check `comm-001603` returned
  `needs_revision: true` with `TI-001` at mid severity and `TI-002` at low
  severity. Codex-agent references remain absent.
- **TI-001**: `web/e2e/dashboard.spec.ts` now models canonical folder
  membership in the GraphQL harness. The browser test adds Launch through the
  detail picker, verifies the resulting removable chip, removes it, then
  removes Work while scoped to Work and asserts detail closure, scope ejection,
  and both mutation requests.
- **TI-002**: `Tests/RielaCLITests/ServeHTTPCommandTests.swift` restores a
  separate live `--note-api` test without `--web-root`, while retaining the
  combined SPA bootstrap, POST redemption, and bearer GraphQL integration
  test.
- **Verification**: `cd web && bun run lint`, `cd web && bun run typecheck`,
  `cd web && bun run test`, and `cd web && bun run build` completed with the
  production-source audit passing, no ESLint or TypeScript errors, 15 Bun tests
  and 42 assertions passing, and a successful Vite build. The first
  `cd web && bun run test:e2e` exposed an ambiguous `role=status` test locator;
  after scoping it to `.notes-message`, the rerun passed all 7 Playwright
  tests. `swift test --filter ServeHTTPCommandTests` passed 5 tests.
- **Finding disposition**: `TI-001` is addressed with user-visible mutation and
  scope-exit coverage. `TI-002` is also addressed despite its low severity.
  T8 remains `IN_PROGRESS` pending independent review, precommit safety check,
  commit, and clean-worktree proof.

### 2026-07-25 — Step 7 implementation-review correction pass

- **Review input**: Step 7 `comm-001607` returned `needs_revision: true` with
  one mid and two low findings. Workflow mode remains `issue-resolution`;
  issue reference is
  `design-docs/research/wrike-web-notebook-view-brief.md@7006afa`, accepted
  design is `design-docs/specs/design-wrike-web-notebook-view.md`, and
  codex-agent references remain absent.
- **Stale progress snapshots**: `web/src/notes/controller.ts` now exposes
  per-notebook state-version snapshots. Notebook paging captures a snapshot
  before the refresh and rejects any notebook value made stale by a progress
  intent, completion, or reconciliation. A focused Bun regression starts a
  refresh snapshot before a successful progress write and proves the later
  stale response cannot replace `done` with `none`.
- **Preview pagination**: `web/src/views/NotesView.tsx` now tracks whether the
  most recent bounded note page was full. An empty terminal page after exactly
  200 notes clears the Load more control; Playwright covers the two-request
  terminal sequence.
- **Tree accessibility**: Folder selection buttons now use a roving tab stop
  and implement Arrow Up/Down, Arrow Left/Right, Home, and End navigation while
  retaining the separate chevron control. Playwright verifies expansion,
  child/parent traversal, and first/last focus.
- **Web verification**: `cd web && bun run lint && bun run typecheck && bun run
  test && bun run build && bun run test:e2e` passed the production-source
  audit, ESLint, TypeScript, 16 Bun tests with 44 assertions, Vite build, and
  8 Playwright tests.
- **Swift verification**:
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  passed; the same toolchain's `swift test --filter RielaServerTests` passed 43
  tests, `--filter RielaGraphQLTests` passed 104, `--filter RielaNoteTests`
  passed 123, and `--filter RielaCLITests` passed 657, all with zero failures.
- **Finding disposition**: all `comm-001607` findings are addressed. T8 remains
  `IN_PROGRESS` pending repeat independent review, precommit safety check,
  final commit, and clean-worktree proof. Nothing was pushed and no pull
  request was opened.

### 2026-07-25 — Step 6 test-integrity TI-003 correction pass

- **Review input**: Step 6 test-integrity check `comm-001610` returned
  `needs_revision: true` with `TI-003` at mid severity. Workflow mode remains
  `issue-resolution`; the issue reference is
  `design-docs/research/wrike-web-notebook-view-brief.md@7006afa`, the accepted
  design is `design-docs/specs/design-wrike-web-notebook-view.md`, and
  codex-agent references remain absent.
- **Security matrix**:
  `Tests/RielaAppSupportTests/RielaAppWebAPIRouteTests.swift` now directly
  proves that RielaApp `/graphql` rejects invalid Host and Origin, missing and
  invalid CSRF, and missing and invalid JSON content type before attempting
  Note executor construction.
- **Sanitized failure and route isolation**: A blocked Note-root fixture now
  proves valid `/graphql` requests fail with the stable sanitized 503 payload,
  without filesystem or SQLite detail, while representative REST and static
  routes remain available. Test fixtures now bind `appHomeDirectory` to their
  temporary root instead of relying on the developer's home directory.
- **Verification**: The explicit Xcode-toolchain
  `swift test --filter RielaAppWebAPIRouteTests` emitted a successful 7-test,
  zero-failure terminal summary before its command wrapper timed out.
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift build`
  emitted `Build complete!`; its wrapper also timed out afterward.
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
  PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
  /usr/bin/xcrun swiftlint --quiet --no-cache` exited successfully with the
  same seven pre-existing warning-only findings.
- **Finding disposition**: `TI-003` is addressed. No production behavior or
  TypeScript file changed in this pass. T8 remains `IN_PROGRESS` pending repeat
  test-integrity and independent reviews, the precommit safety check, final
  commit, and clean-worktree proof. Nothing was pushed and no pull request was
  opened.

### 2026-07-25 — Step 7 scoped-refresh correction pass

- **Review input**: Step 7 `comm-001614` returned `needs_revision: true` with
  one mid finding in `web/src/views/NotesView.tsx`. Workflow mode remains
  `issue-resolution`; the issue reference is
  `design-docs/research/wrike-web-notebook-view-brief.md@7006afa`, the accepted
  design is `design-docs/specs/design-wrike-web-notebook-view.md`, and
  codex-agent references remain absent.
- **Scope transition**: Folder selection now shares one reset boundary for the
  selected notebook, detail return target, preview, notebook membership, and
  partial-loading state. Successful folder creation uses that boundary before
  loading its new scope, so prior rows and cards cannot render under the new
  breadcrumb.
- **Observable refresh**: Notebook refresh now returns an explicit success
  decision and can clear scoped membership before loading. Folder removal uses
  that result; a failed scoped reload closes the detail surface, retains the
  error, reports that membership could not be refreshed, and leaves no stale
  notebook visible.
- **Regression coverage**: `web/e2e/dashboard.spec.ts` now performs successful
  folder creation with a delayed new-scope response and proves old membership
  is absent, then separately forces a post-removal scoped refresh failure and
  proves the detail, row, and misleading success state remain closed.
- **Verification**: `cd web && bun run lint && bun run typecheck && bun run test
  && bun run build && bun run test:e2e` passed the production-source audit,
  ESLint, TypeScript, 16 Bun tests with 44 assertions, Vite build, and 10
  Playwright tests. No Swift file changed in this correction pass.
- **Finding disposition**: The `comm-001614` mid finding is addressed. T8
  remains `IN_PROGRESS` pending repeat independent review, the required
  adversarial gate if accepted, precommit safety check, final commit, and
  clean-worktree proof. Nothing was pushed and no pull request was opened.

### 2026-07-25 — Step 7 async-context and static-routing correction pass

- **Review input**: Step 7 `comm-001618` returned `needs_revision: true` with
  four mid findings. Workflow mode remains `issue-resolution`; the issue
  reference is
  `design-docs/research/wrike-web-notebook-view-brief.md@7006afa`, the accepted
  design is `design-docs/specs/design-wrike-web-notebook-view.md`, the active
  plan is this file, and codex-agent references remain absent.
- **Folder creation context**: `web/src/views/NotesView.tsx` now captures the
  requested parent and folder-scope generation before awaiting
  `defineNoteTag`. It validates against that immutable request context and
  enters the created scope only when no newer navigation has occurred.
- **Folder removal context**: Delayed removal completion closes detail only
  when the currently selected notebook is still the notebook that was
  mutated. A newer notebook detail survives both scope ejection and failed
  refresh completion from the older operation.
- **Static route isolation**:
  `Sources/RielaServer/RielaStaticAssetResolver.swift` now reserves exact and
  descendant paths for `/api`, `/graphql`, `/healthz`, `/note`, and
  `/overview`; exact GET `/note/register` remains the explicit SPA bootstrap.
- **Web-root validation**: `Sources/RielaCLI/ServeHTTPCommand.swift` now
  resolves `index.html`, requires a readable regular file, and verifies that
  its resolved path remains inside the resolved web root before readiness.
- **Regression coverage**: `web/e2e/dashboard.spec.ts` adds delayed creation
  and removal cases with newer navigation/detail selection.
  `Tests/RielaServerTests/RielaHTTPRoutingAndStaticAssetTests.swift` covers
  reserved namespace descendants, and
  `Tests/RielaCLITests/ServeHTTPCommandTests.swift` rejects an `index.html`
  directory and an escaping symlink before accepting a contained file.
- **Web verification**: `cd web && bun run lint && bun run typecheck && bun run
  test && bun run build` passed production-source audit, ESLint, TypeScript, 16
  Bun tests with 44 assertions, and Vite build. `cd web && bun run test:e2e`
  passed 12 Playwright tests.
- **Swift verification**: The first focused run exposed only a regression-test
  assertion that compared JSON-escaped body text; after changing it to decode
  `JSONValue`,
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  test --filter
  'RielaHTTPRoutingAndStaticAssetTests|ServeHTTPCommandTests'` passed 9 tests
  with zero failures.
  `/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
  build` emitted `Build complete!`.
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
  SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
  TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault
  PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH
  /usr/bin/xcrun swiftlint --quiet --no-cache` emitted the same seven
  pre-existing warning-only findings before its command wrapper timed out.
  `git diff --check` and `git diff --exit-code 7006afa --
  design-docs/research/wrike-web-notebook-view-brief.md` passed.
- **Finding disposition**: All four `comm-001618` mid findings are addressed.
  T8 remains `IN_PROGRESS` pending repeat test-integrity and independent
  reviews, the required adversarial gate if accepted, precommit safety check,
  final commit, and clean-worktree proof. Nothing was pushed and no pull
  request was opened.

## Risks and controls

- **Active-profile mismatch**: bind executor refresh and bootstrap profile to
  the same note-root decision; cover profile changes and construction failure.
- **Registration route regression**: assert GET static bootstrap only when
  configured and preserve POST redemption/service precedence.
- **Static traversal or symlink escape**: validate encoded and decoded paths,
  NULs, standardized containment, and symlink targets with focused tests.
- **Stale optimistic completion**: keep mutation generations in a
  notebook-keyed controller outside view components and test unmount/scope
  changes.
- **Incomplete board counts**: paginate within the 200 maximum until complete
  and label partial loading rather than presenting final counts early.
- **Folder collision mutates existing tag**: use atomic create-only service
  semantics and assert unchanged class/parent after collision.
- **Human action attributed as AI**: pass explicit human provenance and
  `assignedBy: "riela-web"` and assert mutation variables.
- **Production test seam leakage**: rely on Bun unit injection and existing
  test harnesses; keep fixtures, mocks, and fetch overrides out of production
  web source.
- **Unrelated flaky suites**: distinguish the known daemon event-source restart
  and agent-VM interleaved-submit flakes with exact evidence; never use them to
  waive a feature failure.
