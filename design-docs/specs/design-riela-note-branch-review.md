# Design Review: `feature/riela-note` Branch — Findings and Improvement Plan

- Date: 2026-07-05
- Scope: full branch diff `main...feature/riela-note` (7 commits, ~184 files, +32k lines): RielaNote core, Note GraphQL layer, CLI/addons, server/auth/persistence, macOS UI, AgentRuntimeKit, loop session overview CLI, specs/impl-plans/examples.
- Method: six parallel area reviews, each verifying findings against the actual code (not the diff alone), followed by cross-area deduplication. All file:line anchors were confirmed on the working tree.
- Relation to prior docs: this doc supersedes the open-items view of `design-riela-note-review-improvements.md` §8.3/§8.5 (see finding H-10 — that section is stale) and complements `design-riela-architecture-review.md`.

## 1. Verdict summary

The branch is substantial and much of it is genuinely well built: parameterized SQL throughout, a transactional-outbox shape for auto-actions, hashed API tokens with single-use scoped registration codes, fail-closed GraphQL auth routing, a byte-level JSONL splitter fixing a real UTF-8 corruption bug, and example workflows that run as real fixtures against SQLite with row-level assertions.

The dominant problems cluster into five themes:

1. **The auto-action pipeline does not actually deliver** — the CLI drops dispatched workflows at process exit while marking them `dispatched`, retry has no production caller, and the served note API constructs `NoteService` without a dispatcher at all (H-1).
2. **The GraphQL executor validates but never applies selection sets**, and the CLI's own documents rely on that bug — a paired time bomb for any spec-conformant client or future real server (H-3), plus an unauthenticated parser DoS (H-4).
3. **The remote Note API is advertised but does not exist** — no socket is ever bound, while README, spec D14, and the impl plan present `riela serve --note-api` as a network endpoint (H-5).
4. **Silent data loss paths in core and UI** — explicit note titles destroyed on body update (H-6), unsaved edits discarded by the Preview toggle (H-8), a persistence backfill that can permanently brick all runtime-snapshot saves (H-2).
5. **The branch's own documentation is stale against its own code** — the review-improvements doc instructs the next implementer to re-fix already-fixed critical defects, and impl-plan statuses overstate completion (H-10, M-D1..D3).

## 2. Findings index

| ID | Severity | Area | Summary |
| --- | --- | --- | --- |
| H-1 | High | Core/CLI/Server | Auto-action dispatch: fire-and-forget lost at exit, premature `dispatched`, no claim step, no retry caller, server drops dispatch entirely |
| H-2 | High | Persistence | `backfillSummaryColumns` bricks all `save()` on one undecodable legacy row |
| H-3 | High | GraphQL/CLI | Executor never projects selection sets; CLI documents under-select fields their renderers consume |
| H-4 | High | GraphQL/Server | Unbounded recursive parsing runs pre-auth → unauthenticated stack-overflow DoS |
| H-5 | High | Server/Docs | `riela serve --note-api` binds no socket; README/spec/impl-plan claim a remote API |
| H-6 | High | Core | `updateNoteBody` silently destroys explicit note titles |
| H-7 | High | UI | Store-change watcher permanently stops watching delete-recreated files (WAL checkpoint case) |
| H-8 | High | UI | Edit/Preview toggle silently discards unsaved body edits |
| H-9 | High | UI | No overlap guard on view-model async ops: watcher refresh reverts user selection; keystroke searches race |
| H-10 | High | Docs | `design-riela-note-review-improvements.md` §8.3/§8.5 asserts C1–C5 are open; commit 24ab520 fixed most of them |
| M-* | Medium | (per area) | §4 |
| L-* | Low | (per area) | §5 |

## 3. High-severity findings

### H-1. Auto-action pipeline: enqueued but never reliably delivered

Composite of five verified defects that together mean the flagship "note created → AI tagging workflow" path effectively does not run from the CLI, and cannot run at all through the served API:

1. **Fire-and-forget dispatch is killed at process exit, after being marked `dispatched`.** `NoteAutoActionWorkflowDispatcher.dispatch` launches the workflow run in an unstructured `Task(priority: .background)` and returns immediately (`Sources/RielaCLI/NoteAutoActionWorkflowDispatcher.swift:171-181`). The caller then runs `markAutoActionDispatchDispatched` (`Sources/RielaNote/AutoActionDispatching.swift:243-251`) — the outbox row flips to `dispatched` before the run starts. `EntryPoint.main` calls `Foundation.exit(...)` as soon as the command result renders, killing the pending task. The record claims success; the workflow never ran; retry only scans `pending` so it never recovers.
2. **`retryPendingAutoActionDispatches()` has zero production callers** — only a test invokes it (`Tests/RielaNoteTests/AutoActionTests.swift:98`). The durable-outbox design has no drain loop.
3. **Enqueue failures are swallowed.** `dispatchAutoActions(for:)` wraps the enqueue in `try? ... ?? []` (`Sources/RielaNote/AutoActionDispatching.swift:135-145`) — a locked/full database silently loses the event with no diagnostic, defeating the outbox.
4. **No claim step → duplicate dispatch and unbounded retries.** `beginAutoActionDispatchAttempt` runs a conditional UPDATE but never checks affected-row count (`SQLiteDatabase` exposes none), so concurrent callers both dispatch the same row; there is no `max_attempts` cap (`AutoActionDispatching.swift:169-192, 292-309`).
5. **The served note API constructs `NoteService` with no `autoActionDispatcher` and no diagnostic recorder** (`Sources/RielaServer/WorkflowServingController.swift:404`), so `enqueueAutoActions` early-returns: notes created via the API enqueue nothing — not even `pending` rows for later retry — while the same mutation via `riela note add` does. CLI/server behavioral drift.

**Recommendation (WP-1):** make `dispatch` async and awaited (or return a handle the command runner drains before exit); move the `dispatched` transition after a successful run; add an `in_flight` status or lease claimed via conditional UPDATE with `sqlite3_changes` exposed from `SQLiteSQLiteDatabase`; add `max_attempts`; make `dispatchAutoActions` throw or record diagnostics; wire a dispatcher (or explicit documented opt-out) into the serve path; add a production drain point for retry (e.g. on CLI startup or in serve). Tests: concurrent double-dispatch, permanently-failing dispatcher, CLI-exit semantics with a real async launcher.

### H-2. Persistence: summary-column backfill can permanently brick runtime-snapshot writes

`ensureSchema` runs `backfillSummaryColumns` on every write-open, and the backfill decodes each legacy row with `try decoder.decode(WorkflowSession.self, ...)` and no per-row error handling (`Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift:281,348,351`). One legacy row whose `session_json` no longer decodes (older enum raw value — a known historical gap in this codebase) makes `save()` throw; the row stays un-backfilled, so it re-fails on every subsequent save. Persistence for **all** sessions is dead until manual row deletion. Notably the read path ships a poisoned-blob tolerance test; the write path has no equivalent.

**Recommendation (WP-2):** wrap the per-row decode in `do/catch` (skip + log, optionally stamp a sentinel so the row is not re-selected); add a test with an undecodable legacy row present during `save()`.

### H-3. GraphQL executor ignores selection sets — and the CLI depends on the bug

Two sides of one defect:

- **Executor:** `execute(_:)` calls `validateSelections(...)` then returns the full encoded DTO — `rootField.selections` is never applied (`Sources/RielaGraphQL/NoteGraphQLDocumentExecutor.swift:88-147`). `query { notes { result { accepted } } }` still returns every note's full `bodyMarkdown`/`tags`/`metaJSON`; aliases parse but have no effect; empty selection sets on object types are accepted (spec violation). Every list query over-fetches note bodies, and any client that decodes strictly by requested shape breaks.
- **CLI:** the note command documents select *fewer* fields than their renderers consume — `createNote` selects `{ noteId title bodyMarkdown }` but prints `notebookId`; `note show` selects `{ noteId }` but prints `title`/`bodyMarkdown`; likewise `notes`, `searchNotes`, `notebooks` (`Sources/RielaCLI/NoteCommands.swift:52-354`, `NoteCommandGraphQLDocuments.swift:4-20`). This works **only because** the executor returns full objects. Fixing the executor without fixing the documents breaks every note command; a future real server that projects correctly breaks them too.

Related: `__typename` hard-fails validation (`NoteGraphQLDocumentExecutor.swift:425-446`), which breaks Apollo/urql default behavior; and request variables are merged into the argument namespace so `mutation { deleteNote { accepted } }` with variables `{"noteId": "n1"}` deletes a note the document never named (`NoteGraphQLDocumentExecutor.swift:91-94, 916-965`).

**Recommendation (WP-3):** implement a projection pass walking `ParsedNoteGraphQLSelectionField` over the encoded `JSONValue` keyed by `responseKey`; reject empty selection sets on object types; allow `__typename`; execute from `rootField.arguments` only (stop merging raw variables); fix all CLI documents to select exactly what renderers/DTOs consume, in the same change; add a drift test asserting document selections ⊇ rendered fields, and tests asserting *unselected* fields are absent from responses.

### H-4. Unauthenticated DoS: unbounded recursive parsing before auth

`parseGraphQLSelectionSet` recurses per `{` and `parseGraphQLValue` per nested `[`/`{`, with no depth or document-size limit (`Sources/RielaGraphQL/NoteGraphQLDocumentParsing.swift:248-295, 351-443`). `routeGraphQL` fully parses the document in `noteGraphQLRequiresAuthentication(...)` **before** the authenticator runs, and the envelope/telemetry parse it up to two more times per request (`Sources/RielaServer/ServerContracts.swift:180, 197-200, 286-310`). An unauthenticated `POST /graphql` with deeply nested braces overflows the stack and kills the process. Latent today (no socket binds — see H-5), live the moment a real listener lands.

**Recommendation (WP-4):** enforce a max document length (e.g. 512 KB) in `parseGraphQLEnvelope`; thread a depth counter (≈20 selections / 10 values) through the recursive parsers; cache the parse so the envelope is parsed once per request. Add adversarial parser tests (deep nesting, giant documents).

### H-5. `riela serve --note-api` advertises a server that never listens

No socket is bound anywhere: `InProcessWorkflowServeListenerFactory.startListener` fabricates `endpoint = "http://\(host):\(port)"` without listening (`Sources/RielaServer/WorkflowServingController.swift:369-388`; `Sources/RielaCLI/ScopedParityCommands+Serve.swift:48-74`). The CLI prints the dead endpoint plus a QR registration challenge pointing at it, then exits — burning the single-use code. Meanwhile README ("Start the server with `riela serve --note-api` to expose note GraphQL routes… binds to 127.0.0.1"), spec D14 (`design-docs/specs/design-riela-note.md:156-162, 479-501`), and impl-plan TASK-009 (`[x] QR-registered client flow verified`) all present this as a working remote API.

**Recommendation (WP-5):** either land a real listener (the review doc's WP-E), or — immediately — amend README + spec D14 to "in-process/local only; remote exposure not yet shipped", label the serve output as a dry-run descriptor, and stop minting a challenge against a dead endpoint. When the listener lands: require TLS or loopback for `noteAPIEnabled`, move the registration code out of the URL query string (`QRClientRegistrationAuthenticator.swift:254-258`), and add rate limiting on redemption/bearer auth.

### H-6. `updateNoteBody` silently destroys explicit note titles

`createNote` accepts an explicit `title` (`NoteService.swift:116`), but `updateNoteBody` unconditionally rewrites `title` from the new body (`SET title = ?` bound to `noteTitle(from: bodyMarkdown)`, `Sources/RielaNote/NoteService.swift:404-430`). A note created with an explicit title and a heading-less body loses its title (→ NULL) on the first body update; the update API offers no way to prevent it. Creation-side behavior is tested; update-side title behavior is not.

**Recommendation (WP-6):** preserve the existing title when derivation returns nil (or only re-derive when the body has a `# ` heading, or add an optional `title` parameter). Add an update-path title-preservation test.

### H-7. UI: store-change watcher permanently stops after delete-recreate

`installWatcherLocked` guards on `targets[key] == nil` and `handleEventLocked` never prunes targets whose fd received `.delete`/`.rename`/`.revoke` (`Sources/RielaNoteUI/RielaNoteStoreChangeWatcher.swift:76-105`). When a watched file is deleted and recreated at the same path — exactly what a WAL checkpoint-truncate does to `note-store.sqlite-wal` — the stale target holds the dead inode and its key blocks re-installation, so the Notes window quietly stops auto-refreshing.

**Recommendation (WP-7):** on `.delete/.rename/.revoke`, cancel and remove the target, then re-run `installExistingFileWatchersLocked()`. Test: delete + recreate `-wal`, assert a second change event.

### H-8. UI: Preview toggle discards unsaved body edits

The Edit/Preview button unconditionally runs `draftBodyMarkdown = note.bodyMarkdown` before toggling (`Sources/RielaNoteUI/RielaNoteDetailView.swift:73-82`). Clicking "Preview" mid-edit overwrites the draft with the persisted body — silent loss of typed content, and the preview renders the stale body so there is no visual signal.

**Recommendation (WP-8):** seed the draft only when entering edit mode for a different note; render the preview from `draftBodyMarkdown` while a draft exists. Cover the Edit → type → Preview → Edit lifecycle with a test.

### H-9. UI: no overlap guard on view-model async operations

Every public method of `RielaNoteLibraryViewModel` is a multi-await main-actor sequence with no generation token or task cancellation (`Sources/RielaNoteUI/RielaNoteLibraryViewModel.swift:176-218, 280-296`). Two routine races: (a) a watcher/scenePhase `refresh()` captures `selectedNoteId` at entry and re-assigns `selectedDetail` at the end, snapping selection back if the user selected another note mid-refresh — and since every local mutation triggers a watcher refresh ~250 ms later, this interleaving is common; (b) `updateSearchText` fires an un-debounced full search per keystroke with no stale-response guard, so out-of-order completions show results for an older query. Notably `updateLinkTargetSearchText` already implements the correct token pattern (`:244-272`) — it just wasn't generalized.

**Recommendation (WP-9):** per-concern generation tokens (refresh/search/selection) checked after each `await`; debounce search ~200 ms; tests with a delayed-response fake client asserting the newer operation wins.

### H-10. The branch's own review doc instructs re-fixing already-fixed critical defects

`design-riela-note-review-improvements.md` §8.3/§8.5 asserts C1–C5 are open, and §8.5's "revised priority" directs the next implementer at them — but the same commit that added §8 (24ab520) fixed most: C1 multi-op auth bypass (operation-aware fail-closed gate, `ServerContracts.swift:197-211` + regression tests), C2 GET-register oracle (403 + TTL pruning + 128-code cap), C3 parser corruption (block strings/escapes/multi-op rules + `NoteGraphQLDocumentParsingRegressionTests`), C5 unredeemable QR (shared scoped challenge store). C4 is mostly fixed (missing env creds skip the profile; malformed endpoint/region still throws from `init`, `NoteWindowController.swift:106-107`). The closing claim "every C1–C5 anchor confirmed" (line 935-937) is false against the tree. Left as-is, this causes wasted re-work and a false standing "critical auth bypass" alarm.

**Recommendation (WP-10):** add a §8.6 verification pass to that doc marking C1–C3/C5 closed (with the regression-test names) and C4 residual; same treatment for `design-riela-architecture-review.md` IP-1..IP-4, which partially landed in 24ab520 but are presented as future work.

## 4. Medium-severity findings

### Core (RielaNote)

- **M-C1. Connection churn and re-probing.** Every operation opens a fresh connection and re-runs the full capability probe (WAL pragma, JSONB probe, FTS5 create/drop probe) despite `NoteService.init` having already verified capabilities; one `createNote` with one auto action performs ~5 open/probe cycles, and dispatch bookkeeping uses 3 connections per record (`NoteDatabaseDriving.swift:33-36`, `SQLiteDatabase.swift:260-276`, `AutoActionDispatching.swift:292-347`). Pass `requireFTS5:false` on per-op opens after `prepare`, and/or pool a long-lived connection; batch dispatch status updates.
- **M-C2. N+1 queries.** `note(from:)` issues a tags query per note (`listNotes` = 1+N); search is worse — per hit row a full `requireNote` fetch (including `body_markdown`) plus tags (`NoteService.swift:820-887`, `NoteSearch.swift:71-83, 148-159, 234-246`). Batch tag loads with `IN (...)`; join note columns into the search SELECT.
- **M-C3. LIKE fallback ≈ full-table scan on nearly every search.** The fallback fires whenever FTS returns fewer than `limit + offset` rows — i.e. almost always — scanning all bodies with a leading-wildcard LIKE; `fetchLimit = limit + offset` also makes deep pagination O(offset) (`NoteSearch.swift:84-95, 162-233`). Restrict the fallback to zero-FTS-match or sub-trigram queries; consider keyset pagination.
- **M-C4. Deleted default auto-actions resurrect.** `seedAutoActions` re-inserts the default AI-tagging actions on every `prepare` with `ON CONFLICT DO NOTHING` (`NoteStoreSchema.swift:74-91`); a user who *deletes* them gets them silently re-enabled on the next `NoteService.init`. Seed only on first schema creation, or record applied seeds.

### GraphQL

- **M-G1. Schema knowledge triplicated** across the SDL string, the executor's selection map, and Codable DTOs, with only root-field drift protection (`GraphQLNoteSchemaContract.swift` vs `NoteGraphQLDocumentExecutor.swift:448-598`). Add a test parsing each SDL `type` block and asserting equality with `noteGraphQLSelectionFields`; longer term derive the map from the SDL.
- **M-G2. Unknown fields fall through to an unauthenticated debug echo** that includes the full schema and `sanitizedEnvironmentKeys` (every inherited env-var name) (`GraphQLContracts.swift:800-838`, `ServerContracts.swift:224-237`). Return a proper GraphQL error on `.notHandled` instead.
- **M-G3. Hidden raw-S3 input fields are an env-var exfiltration primitive** when `allowRawS3ProfileInput: true`: a client can name any server env var as `s3AccessKeyIdEnv` and point `s3Endpoint` at a host they control (`NoteGraphQLDocumentExecutor.swift:760-896`). Default-off and tested-off today; if ever needed, allowlist env-name prefixes (`RIELA_NOTE_S3_*`) and endpoints, or delete the raw path.

### CLI / addons

- **M-L1. No size/count limits in file-ingestion paths.** Addon attach does unbounded `Data(contentsOf:)`; GraphQL `attachNoteFile` decodes unbounded base64; `notePageInputs` accepts unbounded page arrays (`ProductionNodeAdapter+NoteAddons.swift:367-373, 453-478`, `NoteService+Files.swift:6-111`, `NoteGraphQLService.swift:281-289`). Add configurable caps (pre-read via file attributes; decoded-length checks).
- **M-L2. Addon local-file references allow arbitrary filesystem reads** into the note store: `filePath`/`sourceDocumentRef`/`pageImageRef` accept any path, so a package-installed workflow can copy `~/.ssh/id_ed25519` into the store (and onward to S3) (`ProductionNodeAdapter+NoteAddons.swift:367-397, 413-418`). Constrain to the workflow working directory / allowlisted roots by default with explicit `addon.config` opt-out.

### Server / runtime

- **M-S1. `RielaServerConfiguration` gained three non-optional Codable properties**, breaking decode of previously persisted payloads that *contain* a `server` object (`RielaServer.swift:3-27`; only the absent-key case is tested, `ServerContractsTests.swift:42`). Custom `init(from:)` with `decodeIfPresent` + defaults; add a legacy-object test.
- **M-S2. Error detail leakage** (cross-cutting): 500/401 responses interpolate `"\(error)"`, GraphQL errors use `String(describing:)`, the UI renders raw error dumps — and SQLite errors include absolute DB paths (`QRClientRegistrationAuthenticator.swift:123,160`, `NoteGraphQLDocumentExecutor.swift:76-105`, `RielaNoteLibraryViewModel.swift:172 et al.`). Map to clean messages at each boundary; log detail via telemetry.
- **M-S3. SIGKILL escalation can be silently skipped**: `killScheduledProcess` gates on a *weak* `process?.isRunning ?? false`, so if the owning object is released after `terminate()`, SIGKILL is never sent; the post-exec `setpgid` failure also silently degrades to single-pid signaling, leaving grandchildren alive (`AgentProcessSignalController.swift:30, 72-80`, `AgentManagedProcess.swift:202`). Gate on a retained pid cleared by `markExited`; surface group-signal fallback as a diagnostic; make the 1 s TERM→KILL delay configurable.
- **M-S4. Rollout watcher stat/read race**: file size is captured before `readDataToEndOfFile()`, so appends between the two calls corrupt the stored offset and re-emit consumed bytes as garbage/duplicate lines (`AgentRolloutWatcher.swift:118-151`). Compute the offset from bytes actually consumed.

### UI

- **M-U1. Unbounded caches**: `resolvedFileCache` (full file `Data`, incl. S3 downloads) and `decodedSourceImageCache` (`CGImage` up to ~23 MB each) never evict; prefetch populates them for every note paged past (`RielaNoteLibraryViewModel.swift:53-54, 766-789`). Use `NSCache`/small LRU (3-5 decoded entries cover the prefetch window).
- **M-U2. Selection blocks on prefetch**: `.loaded` is only set after `prefetchAdjacentSourceImages()` — up to two serial S3 downloads gate selection latency (`RielaNoteLibraryViewModel.swift:315-334, 703-744`). Fire-and-forget the prefetch after `.loaded`, cancellable on next selection.
- **M-U3. `applicationShouldTerminate` can hang quit forever**: `.terminateLater` waits on `daemonRuntime.stopAll()` with no timeout (`EntryPoint.swift:102-115`). Bound the shutdown (~5 s) and reply regardless.

### Docs / plans / packaging

- **M-D1. `impl-plans/active/riela-note.md` overstates completion**: TASK-009 (remote QR flow "verified" — no socket exists), TASK-012 (Note Agent "RAG chat" — shipped agent is one FTS query + template, `RielaNoteUIClient.swift:230-244`), TASK-015 (libsql test-matrix — `LibSQLNoteDatabaseDriver` contains no libsql code; `.embeddedReplica` throws, `.local` opens plain SQLite, `LibSQLNoteDatabaseDriver.swift:127-140`). Downgrade to PARTIAL with pointers.
- **M-D2. `impl-plans/README.md`**: "including optional libsql driver" repeats the stub-driver claim; the loop-engineering row says "Planning" though LA1a shipped in 5263160. Reword both.
- **M-D3. Spec staleness**: spec says `unicode61` tokenizer, ships trigram + v2 migration; `auto_action_dispatches` absent from the spec's data model; mutation surface diverges (`configureAutoAction` vs shipped `configureNoteAutoAction`, plus 5 unlisted mutations) (`design-riela-note.md:312-315, 442-447` vs `NoteStoreSchema.swift:437-441`, `GraphQLNoteSchemaContract.swift`). Regenerate the spec's surface from the contract or reference it.
- **M-D4. `RielaNoteLibSQL` target is vestigial**: name promises libsql, contains none; `RIELA_NOTE_ENABLE_LIBSQL_TESTS` toggles linking a stub; the embedded-replica config type accepts credentials whose every use throws (`LibSQLNoteDatabaseDriver.swift:101-140`). Remove or mark experimental; fail fast in the `embeddedReplica` initializer.
- **M-D5. Served note API silently drops auto-actions** — see H-1 item 5 (listed there; tracked here for the serve-path docs).

## 5. Low-severity findings (abridged)

- **Core:** blob "sharding" dir is constantly `fi/` because all file IDs start with `file-` (`LocalNoteFileStore.swift:112-115`) — shard by hash. Global capability-probe cache keyed per process, not per driver/library (`NoteStoreSchema.swift:182-235`). Sync S3 client parks a thread on a semaphore — unsafe inside Swift-concurrency tasks (`S3NoteFileStore.swift:240-246`). Two `listNotes` overloads with different sort orders resolvable by label spelling (`NoteService.swift:340-402`). No GC for orphaned file rows/blobs; crash between blob write and DB commit leaks blobs (`NoteService+Files.swift:14-57`) — add `pruneOrphanedFiles()`.
- **GraphQL:** surrogate-pair `\u` escapes rejected (valid GraphQL 😀 fails) (`NoteGraphQLDocumentParsing.swift:661-695`); loose scalar coercion (`2.9 → 2`; empty string reported as "missing") (`NoteGraphQLDocumentExecutor.swift:916-945`).
- **CLI:** usage-error exit codes inconsistent (note=1, loop/parser=2); `note tag` half-applied on mixed apply/remove failure (`NoteCommands.swift:220-274`); `--output table` help drift and note "table" rendering identical to text; `note search --offset` parsed but never sent, `notebook list --tag` ignored, `note add` positional silently dropped; `loop list --limit` silently clamped to 200; `note edit --append` is an unversioned read-modify-write race; challenge URL hardcoded to `http://127.0.0.1:8787` (`NoteCommands.swift:508`); note-root resolution copy-pasted in four places; `pageMetaJSON` discards author-supplied meta when synthesized keys are present (`ProductionNodeAdapter+NoteAddons.swift:480-495`).
- **Server/runtime:** registration code travels in a plaintext-HTTP query string once a listener exists; no rate limiting on redemption/bearer auth (hygiene — entropy is adequate); the 128-code challenge cap is global across note roots. JSONL splitter: unbounded `pending` growth on newline-less streams; invalid-UTF-8 complete lines silently dropped (`AgentJSONLByteLineSplitter.swift:23-31`); each timed `waitUntilExit` parks a global-queue thread (`AgentManagedProcessLauncher.swift:12-22`).
- **UI:** endpoint validation accepts any parseable string (`NoteSettingsWindowController.swift:575`); raw ISO8601 UTC strings in detail view vs relative timestamps in lists (`RielaNoteDetailView.swift:86, 351`); raw `"N bytes"` counts (use `ByteCountFormatter`); two `ISO8601DateFormatter` allocations per row render (`RielaNoteTimestampText.swift:36-44`); `selectNotebook` failure leaves sidebar/content inconsistent; client revoke without confirmation; settings window does synchronous main-thread SQLite.
- **Docs/examples:** `note-quick-memo/mock-scenario.json` is intentionally `{}` (no agent nodes) but looks truncated — add one sentence to its EXPECTED_RESULTS.md; `note-agent`/`note-config-agent` EXPECTED_RESULTS.md lack the Validate/Run command blocks the other examples use; `riela-note-design.md` (Japanese requirements memo) sits at `design-docs/` root one hyphen away from the spec — consider `specs/requirements-riela-note.md`.

## 6. Test-coverage gaps worth closing (highest value first)

1. Auto-action: CLI-exit dispatch semantics with an async launcher; concurrent double-dispatch of one outbox row; permanently-failing dispatcher (retry cap).
2. Persistence: `save()` with an undecodable legacy `session_json` row present (H-2); `loadSessionOverviews` against a genuinely pre-summary-column DB (legacy N+1 fallback branch).
3. GraphQL: assertions that *unselected* fields are absent (would have caught H-3); adversarial parser input (depth/size, H-4); unused request variable must not act as an argument; `__typename`/fragment/subscription handling.
4. Core: title preservation across `updateNoteBody` (H-6); delete-then-reinit of seeded auto-actions; FTS+LIKE fallback interleaving across pages; `migrateFileStorage` failure between S3 PUT and DB update.
5. UI: watcher delete/recreate (H-7); interleaved VM operations with delayed fake client (H-9); Edit→type→Preview→Edit lifecycle (H-8).
6. Server: legacy `WorkflowServeStartRequest` containing a pre-branch `server` object (M-S1); concurrent double redemption of one code; error responses do not leak paths; `AgentProcessSupervisor` timeout path.

## 7. What is done well (keep these patterns)

- **SQL discipline:** consistently parameterized; the LIKE fallback correctly escapes `%`/`_`/`\` with `ESCAPE`; contentless-FTS delete payloads reconstructed byte-identically with a regression test.
- **Auth by construction:** bearer tokens stored only as SHA-256 hashes, minted from `SecRandomCopyBytes` (256-bit), returned exactly once; single-use scope-bound TTL'd registration codes with atomic redemption; fail-closed GraphQL auth (parse error ⇒ auth required; aliases resolved to real field names before the check); `allowUnauthenticatedNoteAPI` defaults false. S3 settings persist env-var *names*, never credential values.
- **Remediation with regression tests:** the operation-aware auth gate, trigram FTS migration with legacy rebuild, and parser hardening all landed with targeted regression suites.
- **Examples as real fixtures:** all six note workflows run deterministically in tests against real SQLite/FTS with row-level assertions — stronger than most example suites in the repo.
- **Loop overview denormalization:** additive migrations, write-time-frozen `loop_summary_json`, a poisoned-blob test proving the hot path never decodes `session_json`, windowed batch scanning with correct limit semantics.
- **Byte-level JSONL splitter** fixes a real UTF-8-across-chunks corruption bug with targeted CJK-scalar tests.

## 8. Recommended remediation order

| Order | Work package | Contents | Why first |
| --- | --- | --- | --- |
| 1 | WP-1 auto-action delivery | H-1 (all five parts) | Flagship feature silently non-functional; data marked delivered that never ran |
| 2 | WP-2 backfill tolerance | H-2 | One bad row bricks all persistence for every session |
| 3 | WP-6/7/8 data-loss trio | H-6, H-7, H-8 | Silent user data loss; each is a small, isolated fix |
| 4 | WP-3 selection projection + CLI docs | H-3 (executor + documents in one change) | Must land together; unblocks any real client |
| 5 | WP-4 parser limits | H-4 | Cheap; must precede any real socket |
| 6 | WP-5 honest serve story | H-5 + M-D1..D3, H-10 | Doc/product integrity; prevents user-facing false claims and internal re-work |
| 7 | WP-9 VM concurrency | H-9 + M-U1/U2 | Generalize the already-proven token pattern |
| 8 | Medium batch | M-C1..C4, M-G1..G3, M-L1/L2, M-S1..S4, M-U3 | Performance, hardening, drift protection |
