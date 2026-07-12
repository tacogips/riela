# Riela Note Adversarial Review Fixes Implementation Plan

**Status**: Planning
**Design Reference**: design-docs/specs/design-riela-note-adversarial-review-2026-07-12.md
**Created**: 2026-07-12
**Last Updated**: 2026-07-12

---

## Design Document Reference

**Source**: design-docs/specs/design-riela-note-adversarial-review-2026-07-12.md
(themes T1–T12; findings F1–F66 in `design-docs/references/riela-note-adversarial-review-findings-2026-07-12.json`)

### Summary

Fix all 66 confirmed findings from the 2026-07-12 adversarial review of the
note feature: GraphQL argument crashes and contract drift, auth error leaks
and forgeable identity, auto-action dispatch races and missing app wiring,
UI async-state races, draft-destroying mutation flows, load-state error
conflation, unsafe AI translation/rewrite execution, agent conversation
integrity, file-blob leaks, store semantics, the regressed edit-agent UI,
and driver/UI point fixes.

### Scope

**Included**: `Sources/RielaNote`, `Sources/RielaNoteUI`,
`Sources/RielaGraphQL`, `Sources/RielaServer`, `Sources/RielaCLI`,
`Sources/RielaApp`, `Sources/RielaNoteLibSQL`, plus tests.

**Excluded**: CJK FTS segmentation and other 2026-07-04-register items not
re-confirmed; iOS clients; note revision history/general undo; blob dedup;
new product features.

**Compatibility**: none. Schemas, APIs, storage layouts, and signatures are
replaced outright; the note DB is recreated (no migrations). Legacy shapes
named below are deleted, not shimmed.

---

## Task Breakdown

### TASK-001: Strict GraphQL argument handling + multi-root execution (T1)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F2 F3 F22 F23 F54 F55 F56
**Affected files**:
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` (`optionalInt` :772-783, `optionalString` :752, `boundedLimit`/`boundedOffset` :785-789, single-root execution :75-114)
- `Sources/RielaGraphQL/NoteGraphQLDocumentParsing.swift` (root-selection guard :44-48, directive handling :328, `parseGraphQLNumber` :529-557)
- `Sources/RielaNote/NoteSearch.swift` (:25 `fetchLimit`)
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift` (document limit/offset bounds)

**Deliverables**:
- `optionalInt`: accept `.integer` and integral `.number` via `Int(exactly:)`
  only; any other present value throws `invalidVariable`. Delete the silent
  `return nil` fallbacks.
- Delete `boundedLimit`/`boundedOffset`. Validate instead: `limit` in
  `0...200` (`0` returns empty list), `offset` in `0...1_000_000`;
  out-of-range throws `invalidVariable`. Document both bounds in the SDL
  contract text.
- `searchNotesInDatabase` computes `fetchLimit` with
  `addingReportingOverflow` (clamped) so the library API is safe for
  non-executor callers.
- `optionalString` throws `invalidVariable` for present-but-empty strings
  (notebookId, provenance, createdAfter/Before); empty→nil coercion deleted.
- Multi-root documents execute: parser returns all root selections, executor
  merges results into one `data` object. Delete the single-selection guard
  and its pinning test (`NoteGraphQLDocumentParsingRegressionTests.swift:194`).
- Any directive (root or nested) is rejected at parse time with an explicit
  "directives not supported" error.

**Tests**: `Tests/RielaGraphQLTests/NoteGraphQLStrictArgumentTests.swift`
(new): `limit: 1e300`, `offset: 9223372036854775807`, `limit: "5"`,
`notebookId: ""` each → `invalidVariable`, for inline literals and
`variables`; `limit: 0` → empty list; `limit: 201` / `offset` above bound →
`invalidVariable`. Multi-root `{ tags {...} tagClasses {...} }` returns both
fields; any directive → explicit error. Update
`NoteGraphQLDocumentParsingRegressionTests.swift`. Overflow-safe
`fetchLimit` unit test in `Tests/RielaNoteTests/NoteServiceTests.swift`.

**Checklist**:
- [ ] Strict `optionalInt`/`optionalString`; silent fallbacks deleted
- [ ] Bounds validation replaces clamping; SDL documents bounds
- [ ] Overflow-safe `fetchLimit`
- [ ] Multi-root execution; directive rejection
- [ ] `boundedLimit`/`boundedOffset` grep-clean; tests pass

---

### TASK-002: Auth error redaction + verified identity (T2)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F21 F24 F25 F26
**Affected files**:
- `Sources/RielaServer/QRClientRegistrationAuthenticator.swift` (`authenticate()` catch :160, registration 500 :122-124)
- `Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift` (`noteFileMigrationControlResult` :702, `assignedBy`/`author` precedence :326)

**Deliverables**:
- `authenticate()` catch returns a fixed-message 401/503 ("note API
  authentication is unavailable"); registration generic catch returns fixed
  "registration failed". Underlying errors go to the server log only; no
  `"\(error)"` interpolation reaches a response body.
- `noteFileMigrationControlResult` maps each failure to the redacted form
  `"<fileId>: note file migration failed"` (same constant as the `failures`
  list).
- When `request.authenticatedClientId` is non-nil, `assignedBy`/`author` are
  always derived as `client:<id>`; explicit input values are rejected with
  `invalidVariable`. Explicit values remain valid only when
  `authenticatedClientId` is nil (local CLI/operator path). Delete the
  `explicit ?? verified` precedence.

**Tests**: `Tests/RielaServerTests` — DB failure during
authenticate/register yields bodies with no path/SQL/endpoint substrings.
`Tests/RielaGraphQLTests` — failing-file `migrateAllNoteFiles` diagnostics
equal the redacted constant; authenticated
`applyNoteTags(assignedBy: "client:other")` rejected; unspecified
`assignedBy` persists `client:<verified-id>`.

**Checklist**:
- [ ] Fixed-message auth/registration bodies; errors logged not echoed
- [ ] Redacted migration diagnostics
- [ ] Verified-identity derivation; explicit override rejected when authenticated
- [ ] Tests pass

---

### TASK-003: Auto-action dispatch leases + async dispatch (T3 core)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F1 F11 F50/F60
**Affected files**:
- `Sources/RielaNote/AutoActionDispatching.swift` (recovery :208-227, `enqueueAutoActions` guard :231-236, `dispatchAutoActions(for:)` :149)
- `Sources/RielaNote/NoteService.swift` (init recovery calls :26-29)
- `Sources/RielaNote/NoteStoreSchema.swift` (dispatch table)
- `Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift` (semaphore :18-25, :175-188)
- `Sources/RielaCLI/NoteCommands.swift` (:582-590 CLI drain + retry command)
- `Sources/RielaCLI/ProductionNodeAdapter+NoteAddons.swift` (:108-112 addon fire-and-record)

**Deliverables**:
- Dispatch table gains `lease_token`/`leased_at` (DB recreated, schema
  replaced). Claiming a row sets both atomically; recovery reclaims only
  rows whose lease is older than a staleness window (default 15 min).
  Completion updates keyed on `dispatch_id AND lease_token` so a superseded
  attempt cannot mis-attribute completion.
- `NoteService.init` no longer calls
  `recoverInterruptedAutoActionDispatches`/`retryPendingAutoActionDispatches`;
  recovery+retry becomes an explicit entry point invoked by a new
  `riela note auto-action retry` subcommand (app-side tick is TASK-004).
- Delete the `DispatchSemaphore` in `NoteAutoActionTaskLauncher` and the
  test pinning blocking behavior
  (`Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift`
  `testDefaultTaskLauncherBlocksCallerUntilOperationCompletes`). Dispatch
  becomes an `async` API; CLI commands `await` a drain of their own
  dispatches before exit; note-addon nodes fire-and-record.
- `enqueueAutoActions` inserts pending rows regardless of dispatcher
  presence; delete the `dispatcher == nil → []` guard.
- Delete the zero-caller `dispatchAutoActions(for:)`.

**Tests**: `Tests/RielaNoteTests/AutoActionTests.swift` — second
`NoteService` never resets/re-runs a fresh in-flight row; expired lease
reclaimed exactly once; stale-lease completion does not mark dispatched;
enqueue-with-nil-dispatcher inserts a pending row.
`Tests/RielaCLITests/NoteAutoActionWorkflowDispatcherTests.swift` — async
dispatch and drain-before-exit.

**Checklist**:
- [ ] Lease columns + atomic claim + staleness-gated recovery
- [ ] Lease-keyed completion
- [ ] Recovery out of `init`; `riela note auto-action retry` added
- [ ] Async dispatch; no `DispatchSemaphore` remains
- [ ] Always-enqueue; `dispatchAutoActions(for:)` deleted
- [ ] Tests pass

---

### TASK-004: App-side auto-action dispatcher wiring (T3 app)
**Status**: NOT_STARTED
**Depends On**: TASK-003
**Findings**: F15
**Affected files**:
- New shared target `Sources/RielaNoteDispatch` (dispatcher moved out of `RielaCLI`), `Package.swift`
- `Sources/RielaApp/NoteWindowController.swift` (:31)
- `Sources/RielaApp/NoteSettingsWindowController.swift` (:135)

**Deliverables**:
- Move `NoteAutoActionWorkflowDispatcher` (and its launcher) from `RielaCLI`
  into `RielaNoteDispatch`, consumable by both `RielaCLI` and `RielaApp`.
- `NoteWindowController` and `NoteSettingsWindowController` construct
  `NoteService` with the dispatcher.
- Periodic app-side maintenance tick invoking the TASK-003 recovery+retry
  entry point, respecting the lease window.

**Tests**: `Tests/RielaNoteDispatchTests` (new target) — app-configuration
service enqueues a pending row on note creation and, with the dispatcher
wired, launches a workflow run (stub launcher); existing
`RielaCLITests` dispatcher tests migrate here as appropriate.

**Checklist**:
- [ ] Dispatcher re-homed to shared target; CLI still builds
- [ ] Both app window controllers wire the dispatcher
- [ ] Maintenance tick invokes recovery with lease window
- [ ] Tests pass

---

### TASK-005: Generation-guarded async UI state (T4)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F4 F5 F27 F28 F29 F37
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` (`load()` :193, `selectNote` tail :373-383, `loadMoreSearchResults` :610, `loadMoreNotebookNotes` :636, `appendNotebookNotesPage` :765-774, `resolveSourceImageAttachment` :819-832, `canLoadMore*` :160)
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+SelectionQA.swift` (:40)
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+EditRewrite.swift` (stale-return paths)

**Deliverables** (invariant: every post-`await` write to selection- or
search-scoped state guards on a generation captured at entry):
- `resolveSourceImageAttachment(generation:)` takes the caller's generation
  (all four callers pass it); stale results — success or failure — are
  dropped; a stale failure never sets global `state = .failed`.
- `loadMoreNotebookNotes`/`appendNotebookNotesPage` and
  `loadMoreSearchResults` capture generation and gain reentrancy flags
  checked by `canLoadMore*`; offsets advance only from the actual
  post-write count.
- In `selectNote`, `loadNotebookNotesFirstPage` runs under the caller's
  generation guard (not only after the write).
- `load()` captures `searchGeneration` at entry; search-state reset and
  first-notebook autoselect are skipped when a newer search exists.
- Mutation `replaceSelectedDetail`/`selectedDetail` writes guard on the
  generation captured at entry; create flows advance `selectionGeneration`
  when they change selection.
- Stale-return paths in `+SelectionQA`/`+EditRewrite` reset their
  `is*Loading` flag before returning; only the result is dropped.

**Tests**: `Tests/RielaNoteUITests/RielaNoteGenerationGuardTests.swift`
(new, controllable-latency mock client): design AC scenarios (a)–(f) —
stale image drop, notebook load-more vs selectNotebook race, search
load-more vs new query, empty-query `load()` vs new search, double-invoked
load-more single page, stale SelectionQA/EditRewrite leaves
`is*Loading == false`. Extend `RielaNoteLibraryNotebookPaginationTests.swift`
and `RielaNoteLibrarySearchPaginationTests.swift` for offset invariants.

**Checklist**:
- [ ] Generation parameter on image resolution; stale results dropped
- [ ] Load-more guards + reentrancy flags (notebook and search)
- [ ] `selectNote`/`load()` guards
- [ ] Guarded mutation `selectedDetail` writes
- [ ] Loading flags reset on stale returns
- [ ] Race tests pass

---

### TASK-006: Throwing mutations + draft preservation (T5)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F7/F13 F8/F14 F9/F44 F31/F45 F32
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` (`createUserMemo`/`createNoteInSelectedNotebook` :392-452, `saveSelectedNoteBody` :512-532, comment/tag/link mutation methods)
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` (`.onChange(of: noteId)` :54-57, pager shortcuts :237/:252, Save handler :379-386, comment/tag add :528)
- `Sources/RielaNoteUI/RielaNoteRootView.swift` (compose onSave :195-206)
- `Sources/RielaNoteUI/RielaNoteComposeView.swift` (`isSaving`)
- `Sources/RielaNoteUI/RielaNoteLinkSearchSheet.swift` (:60)

**Deliverables**:
- `async throws` replaces `async -> Void` for `saveSelectedNoteBody`,
  `createUserMemo`, `createNoteInSelectedNotebook`,
  `addCommentToSelectedNote`, `applyTagToSelectedNote`,
  `removeTagFromSelectedNote`, `linkSelectedNote`, `acceptLinkProposal`.
  Guard-fail paths (`expectedNoteId` mismatch, no selection) also throw.
  Old signatures and all `state = .failed` writes in mutation catch blocks
  are deleted (error destinations are TASK-007).
- Views branch on outcome: drafts reset only on success; on `catch` keep
  the draft, keep editor/sheet/compose open, reset `isSaving`, show an
  inline error next to the control (detail view gains error slots under
  the editor, comment box, and tag field; compose view and link sheet
  reuse local error text). Link sheet calls `onLinked` only on success.
- Edit-mode navigation guard: while `bodyDraft.isEditingBody`, pager
  buttons and their Cmd+Left/Right key equivalents are disabled; selecting
  another note/notebook presents a keep-editing/discard confirmation before
  `selectNote` runs. The unconditional `resetEditingState()` in
  `.onChange(of: noteId)` remains only as the post-confirmation path.

**Tests**: `Tests/RielaNoteUITests/RielaNoteMutationFailureTests.swift`
(new, failing mock client): failed body save keeps editor + draft; failed
create keeps compose state with `isSaving == false`; failed comment/tag add
keeps draft strings; failed link never calls `onLinked`; each mutation
rethrows and leaves `state == .loaded`.

**Checklist**:
- [ ] All eight mutations throw; guard failures throw
- [ ] Views preserve drafts and surface inline errors on failure
- [ ] Pager + shortcuts disabled while editing; discard confirmation
- [ ] Tests pass

---

### TASK-007: Load-state separation + failure degradation (T6)
**Status**: NOT_STARTED
**Depends On**: TASK-006
**Findings**: F36 F39 F40 F64
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` (`refresh` :249, `.failed` payload construction)
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+LinkProposals.swift` (:61)
- `Sources/RielaNoteUI/RielaNoteNotebookListView.swift` (:94-96)

**Deliverables**:
- `state: LoadState` reserved for list lifecycle only (`load`, `refresh`,
  `selectNotebook`/`selectNote` fetches, search). `acceptLinkProposal`
  failures set a new `linkProposalError` published property and never leave
  `.loaded`.
- Load-failure messages come from a human-readable `NoteServiceError`
  mapping; `String(describing:)` in `.failed` payloads is deleted.
- `refresh()` and `selectNote` catch `notFound` for the selected
  note/notebook, clear the stale selection, and fall back to the first
  available note with `state = .loaded`.
- List view renders `ProgressView` when `state == .loading` and the list is
  empty; "No notes" empty state gated on `state == .loaded`.

**Tests**: extend `Tests/RielaNoteUITests/RielaNoteLibraryRefreshTests.swift` —
refresh with externally deleted selected note ends `state == .loaded` with
new/nil selection; `acceptLinkProposal` failure sets `linkProposalError`,
`state == .loaded`. Grep criterion: no mutation path writes
`state = .failed`.

**Checklist**:
- [ ] `linkProposalError`; mutations never touch `LoadState`
- [ ] Human-readable load-error mapping
- [ ] `notFound` degrades to selection change
- [ ] Loading branch precedes empty state
- [ ] Tests pass

---

### TASK-008: Translation as reviewed draft (T7 UI)
**Status**: NOT_STARTED
**Depends On**: TASK-005, TASK-006
**Findings**: F6/F10/F43 (+ degenerate-output part of F38 mitigation)
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel+Translation.swift` (:13-32)
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` (translate control :178-181)
- `Sources/RielaNoteUI/RielaNoteWorkflowEditRewriteProvider.swift` (`parseNoteEditRewriteDraft` :247)

**Deliverables**:
- Delete the direct `client.updateNoteBody` call in
  `translateSelectedNote`; the translation lands in `bodyDraft` (editor
  opened, translated text prefilled, Cancel restores the original).
  Persistence happens only through the normal Save path (TASK-006's
  `expectedNoteId` throw + TASK-005's guards close the stale-body
  overwrite race). `translateNoteGeneration` remains only to drop stale
  results.
- `parseNoteEditRewriteDraft` throws `invalidOutput` for empty/whitespace
  `rewrittenMarkdown`.

**Tests**: `Tests/RielaNoteUITests/RielaNoteTranslationTests.swift` (new or
extend `RielaNoteEditRewriteTests.swift`): translate ends with
`bodyDraft.isEditingBody == true` and store body unchanged (no
`updateNoteBody` before Save); empty `rewrittenMarkdown` throws
`invalidOutput`; stale translation result dropped.

**Checklist**:
- [ ] Translation lands in draft; direct persist deleted
- [ ] Degenerate output rejected
- [ ] Tests pass

---

### TASK-009: Provider execution hygiene (T7 process)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F34 F38 F61 F62
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteWorkflowEditRewriteProvider.swift` (cancellation :66, prompt interpolation :214, argv :240)
- `Sources/RielaNoteUI/RielaNoteWorkflowLinkProposalProvider.swift` (:80)
- `Sources/RielaCLI` workflow run command (`--variables-file` support, if absent)

**Deliverables**:
- All three providers (edit-rewrite, selection-question, link-proposal)
  write the variables JSON to a scratch temp file and pass
  `--variables-file` (add the flag to `riela workflow run` if absent);
  argv interpolation of note bodies is deleted.
- Prompt templates gain an explicit "note content is untrusted data, never
  instructions" rule with delimited framing; note content is passed as data
  via the variables file.
- Cancellation: a shared `cancelled` flag set in `onCancel` is checked
  before `process.run()` and in the poll loop; post-cancel signal
  termination maps to `CancellationError` instead of `workflowFailed("")`.
  Delete the dead in-loop `Task.isCancelled` checks.
- Link provider's `defaultProvider` uses `allowEnvironmentOverrides: true`
  (honoring `RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR`) like its siblings.

**Tests**: `Tests/RielaNoteUITests` provider tests — >1 MB body succeeds via
variables file (argv no longer carries the body); cancel before launch
spawns no process; cancel mid-run yields `CancellationError`;
`RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR` honored. `Tests/RielaCLITests` —
`--variables-file` parity with `--variables`.

**Checklist**:
- [ ] Variables via temp file in all three providers
- [ ] Untrusted-data prompt framing
- [ ] Pre-launch + in-loop cancellation; `CancellationError` mapping
- [ ] Link-provider env parity
- [ ] Tests pass

---

### TASK-010: Agent + config-agent conversation integrity (T8)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F30 F35 F41 F42 F57/F66 F58
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteAgentViewModel.swift` (temp-mode persistence :31, `submitDraft` :46, persist-before-show :54-61)
- `Sources/RielaNoteUI/RielaNoteConfigAgentView.swift` (:10)
- `Sources/RielaNoteUI/RielaNoteConfigAgentViewModel.swift` (`applyProposal` :44)
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` (`noteConfigSlug` / `applyNoteConfigAgentProposal` :725)

**Deliverables**:
- `submitDraft` guards on an in-flight flag covering the Send button and
  `.onSubmit`; submissions during a turn are rejected.
- Show first, persist second: the answered turn is appended to `turns`
  immediately; `saveOrAppend` then runs and on failure marks the turn
  unsaved (existing bookkeeping) and shows the error banner. The answer is
  never discarded; delete the "restore draft only if empty" special case.
- First non-temp save persists all turns with empty `persistedNoteIds`,
  not just the newest.
- Config agent: error banner in `RielaNoteConfigAgentView` bound to the
  view model's error state; `submitDraft` restores `draftMessage` on
  failure; `applyProposal` guarded by `state != .loading` with Apply
  disabled while loading.
- Validate before mutate: `noteConfigSlug` restricted to ASCII `[a-z0-9-]`
  (non-ASCII falls back to the default slug);
  `applyNoteConfigAgentProposal` validates the workflow id via
  `isSafeWorkflowId` before any DB write.

**Tests**: `Tests/RielaNoteUITests/RielaNoteAgentViewModelTests.swift` —
interleaved `submitDraft` produces one notebook with ordered turns; answer
+ failing save leaves the turn visible/unsaved/saveable; temp turns 1–3 +
toggle off + turn 4 persist all four in order. New
`RielaNoteConfigAgentViewModelTests.swift` — Japanese request uses default
slug; injected scaffold failure leaves no tag/auto-action rows; failed
submit/apply restores draft and surfaces error; double-apply blocked.

**Checklist**:
- [ ] Submit reentrancy guard
- [ ] Show-first-persist-second; unsaved-turn banner
- [ ] Full-history persist on leaving temp mode
- [ ] Config-agent error banner, draft restore, apply guard
- [ ] Slug/workflow-id validation before any DB write
- [ ] Tests pass

---

### TASK-011: File blob GC + migration result honesty (T9)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F18 F19/F65 F51 F52
**Affected files**:
- `Sources/RielaNote/NoteService.swift` (`deleteNotebook` :639, `deleteNoteRows` :903)
- `Sources/RielaNote/NoteService+Files.swift` (:19 attach crash window)
- `Sources/RielaNote/NoteFileMigration.swift` (S3 compensation :56-83, post-commit delete :84, result type)
- `Sources/RielaCLI/NoteCommands.swift` (`riela note storage gc`)
- `Sources/RielaGraphQL/GraphQLNoteSchemaContract.swift` + `NoteGraphQLDocumentExecutor.swift` (GC control-plane mutation)

**Deliverables**:
- `NoteService.reclaimUnreferencedFiles(olderThan:)`: deletes `files` rows
  with no `note_files`/`notebook_files` references, best-effort deletes
  their local/S3 blobs, then sweeps the local files tree for blobs and
  `.file-*.tmp-*` entries with no DB row older than the grace period
  (default 24 h). Exposed as `riela note storage gc` and a GraphQL
  control-plane mutation. Referenced files keep survive-note-deletion
  semantics.
- `migrateFileStorage`: post-commit local-delete failure is caught; the
  migration returns success with the leftover path recorded in a new
  `cleanupFailures` list on `NoteFileMigrationResult` (surfaced in
  CLI/GraphQL diagnostics, redacted per TASK-002). Pre-commit failures (DB
  update or `verifyRemoteRead`) trigger a best-effort `s3Store.delete` of
  the just-uploaded object before rethrowing.

**Tests**: `Tests/RielaNoteTests/NoteFileStoreTests.swift` +
`NoteFileReclamationTests.swift` (new): attach → delete note → GC removes
row and blob while a referenced file survives; stray blobs/`.tmp` older
than grace swept, younger kept; post-commit delete failure reports migrated
with cleanup warning (rerun skips it); injected DB failure after S3 PUT
attempts S3 delete and leaves the record `local`.

**Checklist**:
- [ ] GC service method + sweep with grace period
- [ ] CLI command + GraphQL mutation
- [ ] `cleanupFailures` on migration result; S3 compensation
- [ ] Tests pass

---

### TASK-012: Store semantics — ordering, titles, ingest, search fallbacks (T10)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F16 F17 F48 F49 F63
**Affected files**:
- `Sources/RielaNote/NoteService.swift` (generic `listNotes` ordering :532, `updateNoteBody` title :555)
- `Sources/RielaNote/NoteStoreSchema.swift` (`title_source` column; DB recreated)
- `Sources/RielaNote/NoteService+Rows.swift` (page-number collision :144)
- `Sources/RielaNote/NoteSearch.swift` (nil-`ftsMatchQuery` branch :29)
- `Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift` (`hasSearchFilters` :124)

**Deliverables**:
- Generic `listNotes` delegates to notebook-scoped ordering
  (`note_number, note_id`) whenever `notebookId` is given; `created_at
  DESC` remains only for the cross-notebook feed.
- `notes` gains `title_source` (`'derived' | 'explicit'`); `updateNoteBody`
  re-derives the title only when `title_source = 'derived'`. Rewrite the
  pinning test (`Tests/RielaNoteTests/NoteServiceTests.swift:38-46`).
- Ingest validation computes the effective number for every page (explicit
  or positional) and rejects collisions with
  `NoteServiceError.invalidInput` naming the colliding pages.
- Nil-`ftsMatchQuery` branch: a non-empty trimmed query runs
  `searchNotesByTextLike` (same filters) instead of the filters-only path.
- Remove `includeLinked` from `hasSearchFilters`.

**Tests**: `Tests/RielaNoteTests/NoteServiceTests.swift` — explicit title
survives body edits, derived titles re-derive; page collisions →
`invalidInput`; query `"→"` matches `A → B`.
`Tests/RielaGraphQLTests` — `notes(notebookId:)` returns bulk-ingested
pages in `note_number` order. `Tests/RielaNoteUITests` — toggling
`includeLinked` with empty query/filters leaves the notebook list untouched.

**Checklist**:
- [ ] Notebook-scoped ordering delegation
- [ ] `title_source` column + conditional re-derivation; pinning test rewritten
- [ ] Page-collision validation
- [ ] LIKE fallback for symbol-only queries
- [ ] `includeLinked` no longer a standalone filter
- [ ] Tests pass

---

### TASK-013: Restore the edit-agent + selection Q&A UI (T11, F12)
**Status**: NOT_STARTED
**Depends On**: TASK-006, TASK-008
**Findings**: F12
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` (bodyEditor :366; restore from commit `2c9a892`)
- `Sources/RielaNoteUI/RielaNoteSelectableTextEditor.swift` (existing, currently unreachable)
- `Sources/RielaApp/NoteWindowController.swift` (:36-43 provider wiring, already present)

**Deliverables**:
- Restore the edit-agent UI from commit `2c9a892`'s `RielaNoteDetailView`
  (header "Ask for changes" pill, `RielaNoteSelectableTextEditor` with
  selection chips, Cmd-K selection rewrite, Shift-Cmd-K question mode,
  "Saved as comment" feedback), reconciled with the translation control
  added in `c91f8dc` and with TASK-006's draft guards / TASK-008's
  draft-landing behavior. README stays authoritative
  (`README.md:104-137`).
- The restored UI makes `proposeBodyRewrite`/`askSelectionQuestion`
  (`RielaNoteLibraryViewModel+EditRewrite/+SelectionQA`) and the wired
  providers reachable again.

**Tests**: existing `Tests/RielaNoteUITests/RielaNoteEditRewriteTests.swift`
and `RielaNoteSelectionQATests.swift` cover the view-model layer; add a
view-level assertion (grep criterion in CI: UI callers of
`proposeBodyRewrite`, `askSelectionQuestion`, and
`RielaNoteSelectableTextEditor` exist in `Sources/RielaNoteUI`).

**Checklist**:
- [ ] Agent pill + Cmd-K / Shift-Cmd-K flows restored in edit mode
- [ ] Reconciled with translation control and draft guards
- [ ] View-model APIs have UI callers (grep)
- [ ] Existing edit-rewrite/selection-QA tests still pass

---

### TASK-014: Memo kind tag + non-image attachment open (T11, F46/F47)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F46 F47
**Affected files**:
- `Sources/RielaNoteUI/RielaNoteUIClient.swift` (`createUserMemo` :338)
- `Sources/RielaNote/NoteService.swift` (implicit-notebook branch of `createNote`)
- `Sources/RielaNoteUI/RielaNoteDetailView.swift` (non-image attachment handling :404)
- `Sources/RielaApp/NoteWindowController.swift` (open-file callback injection)

**Deliverables**:
- `createUserMemo` and the implicit-notebook branch of
  `NoteService.createNote` apply `notebook-kind:user-memo` as a system,
  non-deletable notebook tag on notebook auto-creation.
- Resolved non-image files get an open path: bytes written to a scratch
  temp file, opened via an `onOpenFile` callback injected from
  `NoteWindowController` (`NSWorkspace.open`/QuickLook stay in `RielaApp`
  so `RielaNoteUI` remains AppKit-free), plus a `fileExporter` save
  affordance matching the markdown download.

**Tests**: `Tests/RielaNoteTests` — `createUserMemo` notebooks carry
`notebook-kind:user-memo` and match kind-tag filters and kind-filtered
auto-actions. `Tests/RielaNoteUITests` — tapping a non-image attachment
invokes the open callback with the resolved temp file / offers save.

**Checklist**:
- [ ] Kind tag on memo-notebook auto-creation
- [ ] Non-image open + save affordance; RielaNoteUI AppKit-free
- [ ] Tests pass

---

### TASK-015: Point fixes — driver parity + UI polish (T12)
**Status**: NOT_STARTED
**Depends On**: —
**Findings**: F20 F33 F53 F59
**Affected files**:
- `Sources/RielaNoteLibSQL/LibSQLNoteDatabaseDriver.swift` (:133)
- `Sources/RielaNote/NoteDatabaseDriving.swift` (:11)
- `Sources/RielaNoteUI/RielaNoteMarkdownBodyView.swift` (:7)
- `Sources/RielaNoteUI/RielaNoteQuickCreateButton.swift` (:36)

**Deliverables**:
- `LibSQLNoteDatabaseDriver` holds one lock-guarded lazily-opened cached
  connection for `.local` (mirroring `SQLiteNoteDatabaseDriver`); the
  per-call `SQLiteDatabase.open` is deleted.
- `databasePath`/`openOptions` become `let` on both drivers.
- Markdown block parsing memoized keyed on the markdown string; identical
  bodies skip the parse; collapsed comment groups don't parse eagerly.
- Quick-create button `.accessibilityLabel("New memo")`.

**Tests**: `Tests/RielaNoteTests/NoteStoreSchemaTests.swift` (env-gated
LibSQL section) — concurrent writes through one driver serialize without
"database is locked" and run one configure/probe cycle.
`Tests/RielaNoteUITests` — memo-cache unit test: re-render with unchanged
markdown skips the parse.

**Checklist**:
- [ ] Cached serialized `.local` connection; single probe cycle
- [ ] Immutable driver path/options
- [ ] Memoized block parsing
- [ ] Accessibility label fixed
- [ ] Tests pass

---

## Module Status

| Task | Module | Key Files | Status |
|------|--------|-----------|--------|
| TASK-001 | Strict GraphQL arguments + multi-root | `NoteGraphQLDocumentExecutor.swift`, `NoteGraphQLDocumentParsing.swift`, `NoteSearch.swift` | NOT_STARTED |
| TASK-002 | Auth redaction + verified identity | `QRClientRegistrationAuthenticator.swift`, `NoteGraphQLDocumentExecutor.swift` | NOT_STARTED |
| TASK-003 | Dispatch leases + async dispatch | `AutoActionDispatching.swift`, `NoteStoreSchema.swift`, `NoteAutoActionWorkflowDispatcher.swift` | NOT_STARTED |
| TASK-004 | App dispatcher wiring | `Sources/RielaNoteDispatch` (new), `NoteWindowController.swift`, `NoteSettingsWindowController.swift` | NOT_STARTED |
| TASK-005 | Generation-guarded UI state | `RielaNoteLibraryViewModel.swift` (+SelectionQA/+EditRewrite) | NOT_STARTED |
| TASK-006 | Throwing mutations + draft preservation | `RielaNoteLibraryViewModel.swift`, `RielaNoteDetailView.swift`, `RielaNoteRootView.swift`, `RielaNoteLinkSearchSheet.swift` | NOT_STARTED |
| TASK-007 | Load-state separation | `RielaNoteLibraryViewModel.swift`, `+LinkProposals.swift`, `RielaNoteNotebookListView.swift` | NOT_STARTED |
| TASK-008 | Translation as draft | `RielaNoteLibraryViewModel+Translation.swift`, `RielaNoteWorkflowEditRewriteProvider.swift` | NOT_STARTED |
| TASK-009 | Provider execution hygiene | `RielaNoteWorkflowEditRewriteProvider.swift`, `RielaNoteWorkflowLinkProposalProvider.swift`, CLI run command | NOT_STARTED |
| TASK-010 | Agent conversation integrity | `RielaNoteAgentViewModel.swift`, `RielaNoteConfigAgentView(Model).swift`, `RielaNoteUIClient.swift` | NOT_STARTED |
| TASK-011 | Blob GC + migration honesty | `NoteService.swift`, `NoteService+Files.swift`, `NoteFileMigration.swift` | NOT_STARTED |
| TASK-012 | Store semantics | `NoteService.swift`, `NoteService+Rows.swift`, `NoteSearch.swift`, `NoteStoreSchema.swift` | NOT_STARTED |
| TASK-013 | Edit-agent UI restore | `RielaNoteDetailView.swift`, `RielaNoteSelectableTextEditor.swift` | NOT_STARTED |
| TASK-014 | Memo kind tag + attachment open | `RielaNoteUIClient.swift`, `NoteService.swift`, `RielaNoteDetailView.swift` | NOT_STARTED |
| TASK-015 | Driver parity + UI polish | `LibSQLNoteDatabaseDriver.swift`, `NoteDatabaseDriving.swift`, `RielaNoteMarkdownBodyView.swift`, `RielaNoteQuickCreateButton.swift` | NOT_STARTED |

## Dependencies

| Task | Depends On | Reason |
|------|------------|--------|
| TASK-004 | TASK-003 | App wiring consumes the re-homed async, lease-aware dispatcher |
| TASK-007 | TASK-006 | State separation assumes mutations throw instead of writing `.failed` |
| TASK-008 | TASK-005, TASK-006 | Translation draft relies on generation guards and the throwing `expectedNoteId` Save path |
| TASK-013 | TASK-006, TASK-008 | Restored editor must carry the draft guards and reconcile the translation control |
| All others | — | Independent; parallelizable |

## Completion Criteria

- [ ] All 15 tasks implemented; `swift build` and `swift test` pass
- [ ] Design-doc acceptance criteria for T1–T12 verified (including the
      grep criteria: no `boundedLimit`/`boundedOffset`, no
      `dispatchAutoActions(for:)`, no mutation `state = .failed`,
      UI callers of `proposeBodyRewrite`/`askSelectionQuestion`)
- [ ] No `DispatchSemaphore` in dispatch code; dispatch API is `async`
- [ ] Note DB recreated cleanly with the new schema (`lease_token`/`leased_at`,
      `title_source`); no migration code added
- [ ] `RielaNoteUI` remains AppKit-free

## Progress Log

### Session: 2026-07-12
**Tasks Completed**: None yet
**Tasks In Progress**: Plan created from
design-docs/specs/design-riela-note-adversarial-review-2026-07-12.md
**Blockers**: None

## Related Plans

- **Related**: `impl-plans/active/riela-note-ui-refinements.md` (prior UI
  work these fixes build on)
- **Related**: `design-docs/specs/design-riela-note-review-improvements.md`
  (older 2026-07-04 register; separate scope)
