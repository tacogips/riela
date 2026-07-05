# Riela Architecture Review — Bugs, Maintainability, Performance, Readability

## Scope and Method

Repository-wide architecture review conducted 2026-07-04 on branch
`feature/riela-note` (~100k lines Swift across 24 targets). Four
subsystem passes: the workflow runtime core (`RielaCore` +
`RielaAdapters` + `AgentRuntimeKit` + `RielaAddons` + `RielaSQLite`);
the CLI (`RielaCLI`); the three agent backends (`CodexAgent`,
`ClaudeCodeAgent`, `CursorCLIAgent`); and the app/server/events layer
(`RielaApp`, `RielaAppSupport`, `RielaServer`, `RielaGraphQL`,
`RielaEvents`, `RielaObservability`, `RielaJavaScript`).

Riela Note-specific findings live in
`design-docs/specs/design-riela-note-review-improvements.md`; this
document covers the pre-existing architecture and the cross-cutting
patterns. Module line counts (source only):

| Module | Lines | Module | Lines |
| --- | --- | --- | --- |
| RielaCLI | 20,991 | RielaGraphQL | 3,506 |
| RielaCore | 13,974 | RielaNoteUI | 3,374 |
| RielaApp | 12,841 | RielaAdapters | 2,953 |
| CursorCLIAgent | 9,734 | RielaAddons | 2,932 |
| ClaudeCodeAgent | 9,297 | AgentRuntimeKit | 1,859 |
| CodexAgent | 7,578 | RielaServer | 1,724 |
| RielaNote | 4,927 | RielaEvents | 1,555 |
| RielaAppSupport | 3,712 | RielaObservability | 885 |

## Executive Summary

The codebase has genuinely strong bones: a protocol-seamed workflow
runner with a runtime-owned-record discipline, one carefully engineered
child-process lifecycle (`FoundationLocalAgentProcessRunner`),
atomic/quarantining state stores, and a broad test surface (~53k lines
of tests). The improvement opportunities cluster into five themes that
recur across every subsystem:

1. **Two parallel process runtimes and ~16k lines of copy-paste.** The
   robust process lifecycle in `LocalAgentProcess.swift` is not shared
   with `AgentRuntimeKit`, and the three agent backends plus the three
   chat gateways are provider-name-substituted forks. Security and
   correctness fixes land in one copy and miss the others.
2. **Hand-rolled parsers and envelopes that drift.** Two independent
   GraphQL lexers (whose disagreement is a live auth bypass), 6+
   option-parsing loops, 9 failure-envelope implementations, four JSONL
   incremental parsers — each with its own bugs.
3. **Process/connection lifecycle gaps.** No timeout / kill-escalation
   in the `AgentRuntimeKit` path, orphaned daemon children on app quit,
   per-call SQLite connection opens with DDL on hot paths, undrained
   pipes that deadlock.
4. **Main-thread and O(n²) hot paths.** A 2-second main-thread timer
   that re-parses each row's `.env` file (not, as first stated, a full
   filesystem rescan — corrected below), whole-transcript double reads
   on session listing, full-store loads to return bounded summaries,
   per-poll whole-file re-reads.
5. **Stringly-typed contracts and god objects.** `RielaApp` as a
   distributed 25-property god object, `RielaNoteLibraryViewModel` at
   826 lines, stringly event kinds and statuses throughout.

`swift build` and `swift test` pass (1179 tests, 0 failures); every
finding below is latent behavior, structural debt, or performance —
not a broken build.

## Cross-Cutting Theme 1 — Duplication (~16k lines)

**Agent backends (~6k duplicated of 26.6k).** CursorCLIAgent is >90%
identical to ClaudeCodeAgent, both derived from CodexAgent's shape.
Identifier-normalized diffs (verified against the working tree —
figures corrected from the first draft):
- `*SDKUtilities.swift` is **byte-identical (304 lines) across all
  three** after identifier normalization — the strongest case for
  extraction.
- `*Polling.swift` exists only for **two** backends (Cursor 469 lines,
  Claude 466; Codex has no equivalent file) and, after normalization,
  differs in **~3 meaningful locations** (directory/config paths), not
  the single line first reported — still near-duplicate, but not
  1-line-identical.
- `*ProcessManager.swift` (Codex 301, Cursor 287, Claude 287) diverges
  in a handful of spots (executable name, home-path vars) but the
  backends carry genuinely different architectures, not a mechanical
  3–21-line delta.
- `runXDefaultAuthPreflight` is **68 / 87 / 70 lines** respectively —
  the same concern re-implemented three ways, *not* an identical
  ~70-line block.
- `private func jsonString` is redefined 9× across the modules.
Concrete smells that hold exactly as stated: `sessionId(from:)`
duplicated twice within one file (`CodexProcessManager.swift:201-214,
272-285`, differing only by `static`); `ManagedXProcess` delegation
wrappers (77 lines × 3). The extraction case stands; the precise
line-deltas above are the accurate figures.

**Chat gateways (~450–500 duplicated of 2,076).** Telegram/Discord/Slack
bindings in `RielaCLI` triplicate the poll skeleton, reply dispatch,
offset/history/dedupe stores, `safeXStorageComponent` (byte-identical
×3), `compactXObject`, and env lookup. This is where the event-serve
correctness bugs (Theme 3 H5/H4) and the path-traversal security gap
(only Slack validates) come from — the fix exists in one copy each.

**GraphQL surface (quadruple-maintained).** Core models ↔ ~27 mirror
DTOs ↔ 180-line SDL string literal ↔ 133-line selection-validation
table, kept in sync only by tests, plus two independent hand-rolled
GraphQL lexers.

**Recommendation.** `AgentRuntimeKit` is already the intended shared
seam (generic over `RolloutLine`, with typealias re-exports that
preserve public API) — the extraction stopped ~40% in. Finish it:
promote the `LocalAgentProcess` lifecycle, the `*SDKUtilities` triplet,
session-index scaffolding, rollout parsing, and JSON helpers into a
shared **AgentProcessKit**, leaving only argv builders and event-schema
mapping backend-specific (target: eliminate >10k lines). Introduce a
`ChatGatewayBinding` protocol + one generic poll driver so a new
platform is a ~200-line adapter. Generate the SDL and selection tables
from the DTOs (or add a round-trip conformance test) and unify the two
GraphQL tokenizers into one.

## Cross-Cutting Theme 2 — Hand-Rolled Parsers and Envelopes

- **Unify the GraphQL front door (security-critical).** The server
  auth gate (`ServerContracts.swift:302-417`) and the note document
  parser (`NoteGraphQLDocumentParsing.swift`) are two independent
  lexers; their disagreement is the live multi-operation auth bypass
  (Note review §8.3 C1). The note parser also mis-handles block
  strings and `\u` escapes (data corruption) and silently drops all
  but the first root field. One tokenizer, one operation-resolution
  path, shared by gate and executor, closes this class.
- **Extract an `OptionTable` shared by parse + help (CLI).** Option
  parsing is re-implemented ~6 ways (`ParsedWorkflowOptions`,
  `ParsedParityOptions`, `NoteCommandOptions`, `parseMemoryOptions`, +
  inline loops); the `!hasPrefix("--")` value guard appears in 32
  places across 10 files; three different "read option value" helpers
  coexist; values beginning with `--` are unpassable in some
  subcommands but consumed in others. One declarative spec per command
  (flag, alias, value kind, inline `=`, default, help line) drives
  parsing, generated usage text, and the table-output allowlist —
  removing the drift and the `--value` bug in one move.
- **Extract one `OutputRenderer` / failure envelope (CLI).** Output-
  format branching occurs 46 times across 11 files; there are 9
  distinct failure-envelope implementations plus two more, and the
  exit-code matrix is inconsistent (manifest-invalid = 2, workflow-
  invalid = 1; memory usage errors = 1 vs siblings' 2; several
  encode-failure fallbacks emit exit 0 with fabricated `[]`/`{}`).
  Route all rendering through one helper with a typed exit code.
- **One Data-based JSONL line splitter.** Four incremental JSONL
  parsers exist (`AgentProcessOutputBuffers`, `ClaudeCodeJsonlStreamParser`,
  `LocalProcessPipeReader`, `AgentRolloutWatcher`); the string-based
  ones corrupt multi-byte UTF-8 split across chunk boundaries (Theme 3).
  Only `LocalProcessPipeReader` splits on the `\n` byte in `Data`
  first — make it the shared implementation.

## Cross-Cutting Theme 3 — Process & Connection Lifecycle

- **HIGH — `AgentRuntimeKit` process path has no timeout, no kill
  escalation, no process group.** `AgentProcessSupervisor.run`
  (`AgentProcessSupervisor.swift:56-84`) calls `waitUntilExit()`
  unconditionally; the kill path is `Process.terminate()` only
  (SIGTERM to the direct child, no group, no SIGKILL). A child that
  ignores SIGTERM or spawned grandchildren leaks orphans and
  `AgentRunningSessionState.cancel()` then blocks forever. The
  workflow path (`LocalAgentProcess.swift`) does this correctly
  (`POSIX_SPAWN_SETPGROUP`, `terminateGroupOrProcess()` +
  `scheduleKillIfRunning(after: 1)`, `waitpid` reaping); promote that
  machinery into the shared kit and add a deadline to `run`/`stream`.
- **HIGH — UTF-8 chunk-boundary corruption** in
  `AgentProcessOutputBuffers.appendStdout`
  (`AgentManagedProcess.swift:32-38`): decoding each arbitrary pipe
  chunk as UTF-8 yields U+FFFD on any multi-byte character split
  across reads — every non-ASCII streamed assistant message is
  corrupted. Split on `\n` in `Data` first (Theme 2).
- **HIGH — orphaned daemon children on app quit.**
  `applicationWillTerminate` (`EntryPoint.swift:101-107`) only
  invalidates a timer and fires a `Task { telemetry.flush }` that never
  runs before exit; it never stops `daemonRuntime`, so every
  `riela events serve` child keeps polling and firing workflows after
  the app quits. Use `applicationShouldTerminate` → `.terminateLater`,
  stop synchronously, then reply; put children in a process group.
- **HIGH — event-serve loop dies on any transient failure.**
  `EventLiveServe.swift:110-135` has no per-source catch/backoff; a
  single 429/5xx or one poison message unwinds the whole loop and
  terminates the daemon, which RielaApp then tight-restarts against
  rate-limited APIs. Per-source do/catch + exponential backoff +
  `Retry-After`.
- **MEDIUM — pipe-drain deadlocks and missing timeouts in CLI
  subprocesses.** `runCommand` calls `waitUntilExit()` before draining
  pipes (`ProductionNodeAdapter+GmailDigest.swift:814-834`); >64KB of
  child output hangs the CLI. `runGit` never drains stdout and
  `git clone` has no timeout. One shared `SubprocessRunner` with async
  draining + timeout + terminate-on-cancel.
- **MEDIUM — per-call SQLite connection + schema DDL on hot paths.**
  `SQLiteWorkflowMessageLog`/`SQLiteWorkflowRuntimePersistenceStore`
  open a fresh connection and run `ensureSchema` (2 CREATE TABLE + 6
  CREATE INDEX + probes + WAL switch) on every call; `save` uses
  `replaceMessages` (delete + reinsert all messages per snapshot) →
  O(n²) writes. The CLI already had to build a cached-connection
  workaround (`WorkflowRunLivePersistenceConnection`), proving the core
  API shape is wrong. Add a prepared-handle type (open once, schema
  once, reuse). The note store repeats this pattern
  (`NoteDatabaseDriving.withDatabase` opens per operation with probe
  overhead).
- **MEDIUM — `SQLiteDatabase: @unchecked Sendable` with zero
  synchronization** (`SQLiteDatabase.swift:96`): the annotation invites
  unsafe cross-task sharing of a raw sqlite3 handle. Add an internal
  lock, open `SQLITE_OPEN_FULLMUTEX`, or drop `Sendable` and force
  actor ownership.
- **MEDIUM — daemon double-start race** (`DaemonWorkflowSupport.swift:743-824`):
  the start guard checks only `.running`, so a re-entrant start during
  the `.starting` suspension overwrites `runningWorkflows[id]` without
  stopping the previous controller — leaked generation + orphaned
  child on the same hashed port. Treat `.starting/.stopping/.reloading`
  as busy or serialize per-identity operations.

## Cross-Cutting Theme 4 — Performance Hot Paths

- **MEDIUM — per-row `.env` parse on the 2s main-thread timer**
  (corrected after code verification; the earlier "full-filesystem
  rescan per row" claim was **overstated**). The RielaApp refresh timer
  calls `refreshDaemonWorkflowWindow(refreshesInstanceCache: false)`
  (`EntryPoint.swift:344-350`), so it does **not** re-run
  `discoverUserDaemonWorkflows` each tick — the expensive workflow/
  package walk only happens on cache-refreshing paths. What *does* run
  per row per tick is `environmentColumnStatus(candidate)` →
  `hasMissingRequiredEnvironment`, which re-parses the candidate's
  `.env` file. Still wasteful on the main thread, and window
  controllers are never nil'd after close so the timer keeps firing
  with the window shut. Fix: compute environment status once per cycle
  (cache with invalidation), and pause/tear down the timer when no
  window is visible. (The full-discovery cost is real but lives on the
  cache-refresh path, not the 2s tick — cache that separately with an
  invalidation event or FSEvents.)
- **HIGH — session listing reads every transcript fully, twice.**
  `buildSession` calls `parseSessionMeta` (whole-file read) then
  `extractFirstUserMessage` (whole-file read again) per rollout;
  `session list` is O(2 × total transcript bytes). Bounded `FileHandle`
  reads, stop at first match.
- **HIGH — `AgentRolloutWatcher` re-reads the whole rollout per poll**
  (`Data(contentsOf:)` + `dropFirst(offset)`) → O(n²) over a session's
  life. `FileHandle.seek(toOffset:)` + read appended bytes only.
- **MEDIUM — full-store loads for bounded results.**
  `workflowSessions` GraphQL calls `store.loadAll()` to return ≤100
  summaries; `seedRuntimeStoreFromPersistedCLIState` is O(all sessions)
  with N+1 connection opens on every run/rerun/resume;
  `loadRuntimeSnapshot(containingCommunicationId:)` loads every
  snapshot to find one. Add summary-level SQL and seed only the target
  session + lineage.
- **MEDIUM — `messages()` O(n²) dedup** re-encoding every line with a
  fresh `JSONEncoder` per poll; **auth preflight spawns 2 extra child
  processes per node execution** uncached; **`char`-granularity streams
  embed the full source line in every per-character event** (O(k²)
  payload). Cache dedup keys, cache preflight per adapter with a TTL,
  drop the source line from char events.
- **MEDIUM — unbounded `_rielaInput` history in prompts.** The message
  resolver embeds every delivered message (full payload, duplicated
  under `latest`) into the system prompt, and the message lifecycle
  never advances to `.consumed`/`.superseded` — a loop that revisits a
  step grows its prompt linearly per iteration (token cost, eventual
  context overflow, nondeterministic agent behavior). Cap
  `_rielaInput.messages` at latest-N or strip `messages` from prompt
  serialization.

## Cross-Cutting Theme 5 — Maintainability & Readability

- **`RielaApp` is a distributed god object** — one `@MainActor` class
  across 13 `EntryPoint+*` files with 23 mutable stored properties
  (verified count);
  state ownership is implicitly "cache of disk," and because the caches
  aren't trusted the resolver re-scans the filesystem on every lookup
  (the direct cause of the Theme 4 hot path). Extract a
  `DaemonInstanceStore` model owning state + persistence + invalidation;
  the delegate keeps only UI wiring.
- **Constructor-injection blow-up.** `DaemonWorkflowWindowController.init`
  takes 29 closure/parameter arguments
  (`DaemonWorkflowWindowController.swift:198-228`);
  `WorkflowViewerWindowController.show` takes 15
  (`WorkflowViewerWindowController.swift:118-134`). Replace with a
  delegate protocol or a single `handle(_ action:)` intent enum.
- **Window-controller duplication.** 6 controllers each hand-roll
  `NSWindow(...)` + `showWindow`/`makeKeyAndOrderFront`/`NSApp.activate`
  + `windowWillClose`; only one restores activation policy. A shared
  `RielaAppWindowController` base removes 5 copies.
- **RielaCore leaks non-runtime concerns (~1,100 lines).**
  `SwiftDeletionReadiness.swift` (749) and `SwiftPackagingReadiness.swift`
  (242) model TypeScript-migration gates and Homebrew archive plans —
  release tooling, not runtime. Core also hardcodes CLI usage strings
  into prompts and reads `ProcessInfo` env directly. Move to a
  release-tooling/CLI module; inject help text and env lookups.
- **Stringly-typed contracts.** Event kinds
  (`"session_meta"`, `"item.completed"`, `"AgentMessage"`…) pervade the
  backend mappers; `WorkflowNodeExecutionPolicy.mode/decisionBy` are
  `String?` in an otherwise enum-disciplined model; receipt/serve
  statuses, notification/menu plumbing, and
  `ScopedParityCommandResult.records` ("key=value" lines inside JSON)
  are all stringly. `EventContracts.swift` is ~40% open-enum
  boilerplate collapsible to a generic `OpenEnum<Known>`. Introduce
  per-backend `RawEventKind: String` + one shared normalized event enum
  (the vocabulary already exists implicitly in three places).
- **Monster functions.** `DeterministicWorkflowRunner.run` (194),
  `publishAcceptedOutput` (195), `ScopedParityCommandRunner.eventResult`
  (~187-line switch), `NoteGraphQLDocumentExecutor.executeMutation`
  (~146-line string switch → table-driven), `pollTelegramSource` (127,
  5-deep), `WorkflowRunCommand.run` (~185). Extract by concern.

## Correctness Findings Worth Individual Attention

- **Runner never checks cancellation between steps**
  (`DeterministicWorkflowRunner.run` loop): a cancelled run keeps
  advancing and can spawn the next agent process; the cancellation
  predicate is also `error is CancellationError` only. Add
  `try Task.checkCancellation()` at loop top and each attempt; broaden
  the predicate.
- **Unknown `riela/*` addon names silently succeed** — the builtin
  resolver falls through to `{status:"ok"}, completionPassed:true`
  (`ProductionNodeAdapter.swift:241-252`); a typo'd addon passes the
  workflow. Throw for unmatched `riela/` names.
- **Event offset/ack semantics diverge**: Telegram/Discord save the
  offset before dispatch (at-most-once, drop on crash), Slack saves
  after with no dedupe store (at-least-once, duplicate replies); first
  run with no offset replays backlog as fresh events on all three. One
  shared mark + content-dedupe journal; bootstrap to "newest, process
  nothing."
- **JavaScriptCore filter sets no execution-time limit and
  string-splices the expression** — the input filter wraps the raw
  expression as `"(function() { return (\(expression)); })()"`
  (`JavaScriptCoreBooleanEvaluator.swift:47`) with no
  `JSContextGroupSetExecutionTimeLimit`, so a `while(true){}` hangs the
  evaluator, and because the expression is spliced into the wrapper
  unescaped a payload like `)); f(); ((true` can break out of the
  intended slot. (The specific escape was reasoned from the splicing,
  not exercised by a test — treat as a hardening item, not a proven
  live exploit.) Add an execution time limit and stop string-splicing
  (compile the expression as a function argument instead).
- **No request/attachment size limits** — the server decodes unbounded
  bodies and base64-decodes unbounded `contentBase64` into memory
  (~2.3× amplification into SQLite). Enforce caps at envelope
  construction and in `attachFile`.
- **Fake timestamps/checksums persisted** — `send-manager-message`
  writes `createdAt` from an order counter; event receipts write
  1970-01-01; self-improve backup uses a hardcoded stamp and overwrites
  the prior backup with the already-mutated file (rollback impossible
  after a second run); publish lock records a constant fake checksum.
- **Telemetry data loss** — `flush` clears buffers before send (export
  failure discards the batch), the watchdog `cancelAll()` kills sibling
  exports on one failure, and `autoFlushTask` is never cancelled in
  `deinit`; combined with the fire-and-forget flush at app exit,
  telemetry is best-effort at best.
- **Single-tenant data compiled into builtins** — persona aliases
  (`yui`/`mika`/`rina`, `if id == "mika" { aliases.append("maki") }`),
  default X account `"@tacogips"`, Japanese fallback replies. Move to
  config/defaults.
- **Stale `AGENTS.md`** at the repo root describes a different project
  ("Source Security Check Loop Package"), misleading contributors and
  agents. Rewrite for this repository.

## Architecturally Good — Preserve and Extend

1. **`FoundationLocalAgentProcessRunner` lifecycle** — posix_spawn with
   process-group SIGTERM→delayed SIGKILL, idempotent continuation
   resume, cancel-before-configure handling, `waitpid` reaping,
   SIGPIPE-safe chunked stdin writes. The template for the shared
   process kit and the fix for the watcher/supervisor gaps.
2. **Runner decomposition + protocol seams** — a struct composed of
   injected store/adapter/publisher/addon/input-resolver/loop-policy/
   telemetry protocols across 12 focused extension files, enabling the
   large test surface. Extend, don't inline.
3. **Runtime-owned record discipline** — adapters return candidates
   only; ids, publication, root-output selection, and routing
   normalization are centralized and enforced.
4. **Corrupt-state quarantine + atomic writes + defensive Codable**
   (daemon store), **containment-validated installers** (checksum +
   refuse-outside-profile-root), and **secrets-by-reference + redaction
   at construction** (env-var names in contracts, hashed revocable
   tokens, telemetry redactor).
5. **Bounded buffers with loss accounting** — 16KB process-output trim,
   telemetry `appendBounded` + `dropped.*` attributes, dedupe/history
   caps, fingerprint-gated table reloads, and the actor store's bounded
   live-tail projection with correct UTF-8 boundary handling.
6. **`@TaskLocal` `CLIRuntimeEnvironment`** for race-free env injection
   in tests/embedding, and the **typed `RielaCommand` AST + exhaustive
   dispatch** enabling `CommandParsingTests` — both deserve consistent
   adoption (the note-root default currently bypasses the former).

## Prioritized Recommendations

| Priority | Item | Theme |
| --- | --- | --- |
| **P0** | Unify the GraphQL front door (one tokenizer + operation-resolution) — closes the multi-operation auth bypass and parser corruption | 2 |
| **P0** | Timeout + process-group kill escalation in the shared agent process path; stop daemon children on app quit | 3 |
| **P0** | UTF-8 chunk-boundary safe JSONL splitter (one shared impl) | 2/3 |
| **P0** | Per-source event-serve error isolation + backoff; unify offset/dedupe semantics | 3 |
| **P1** | Finish the `AgentRuntimeKit` → AgentProcessKit extraction (~10k lines); `ChatGatewayBinding` protocol | 1 |
| **P1** | Cache per-row env status + pause timers when hidden (kills the 2s main-thread `.env` re-parse); cache daemon-workflow discovery off the refresh path; bounded `FileHandle` reads for session listing/watcher | 4 |
| **P1** | Prepared-handle SQLite store API (open once, schema once); fix `save` O(n²) `replaceMessages`; `SQLiteDatabase` synchronization | 3/4 |
| **P1** | `OptionTable` + `OutputRenderer` for the CLI; throw on unknown `riela/*` addon; `SubprocessRunner` with pipe drain + timeout | 2/3 |
| **P1** | Runner cancellation checks between steps; cap `_rielaInput` prompt history | 4 |
| **P2** | Extract `DaemonInstanceStore`; shared window-controller base; delegate/intent enums replacing 28-closure init | 5 |
| **P2** | Move release-tooling out of RielaCore; normalized event-kind enums; open-enum generic; request size limits; JS watchdog | 5 |
| **P2** | Remove single-tenant builtin data; fix fake timestamps/checksums; telemetry flush durability; rewrite `AGENTS.md` | — |

Note review cross-reference: the Riela Note remediation review
(`design-riela-note-review-improvements.md`, §8) shares the P0 GraphQL
front-door item (its C1/C3), the per-call SQLite pattern, the outbox
dispatch lifecycle (same fire-and-forget `Task` failure mode as the CLI
subprocess and auto-action dispatch), and the god-object/ViewModel
split. Fixing the front door and the shared process/SQLite seams
resolves findings in both documents at once.

## Verification Note

Every finding above was re-checked against the working tree on
2026-07-04 by four independent code-derived passes. Two corrections
resulted and are already folded into the text: (1) the "2-second
full-filesystem rescan per table row" was **overstated** — the 2s timer
re-parses each row's `.env` file but does *not* re-run
`discoverUserDaemonWorkflows` (downgraded to MEDIUM); (2) several
duplication line-deltas were tightened (`*Polling.swift` exists for two
backends and differs in ~3 spots; `runXDefaultAuthPreflight` is
68/87/70 lines, not an identical ~70-line block; god object is 13 files
/ 23 properties; the two constructors take 29 and 15 arguments). All
other Theme 1–5 and correctness findings were **confirmed** at the
cited file:line.

## Detailed Implementation Plan (P0 items)

The P0 rows in the table above are expanded here into concrete work
packages (IP-1 … IP-4). Each lists **goal / files / change / signatures
/ tests / acceptance / sequencing**. IP-1 is shared with the Note
review's WP-A — implement once.

### IP-1 — One GraphQL tokenizer + operation-resolution path

Shared with **Note review §9 WP-A** (see there for the full step list).
Summary of the architecture-level obligation:
- Delete the second lexer `graphqlTokens` in
  `ServerContracts.swift:337-416`; the server gate calls the same
  tokenizer as `NoteGraphQLDocumentParsing.swift`.
- Thread `operationName` into the gate at `ServerContracts.swift:197`
  and resolve auth against **all** root selections of the *named*
  operation (closes the C1 multi-operation bypass).
- Generate the SDL string (`GraphQLContracts.swift:662-842`), the
  routable set, and executor dispatch from one field table.
- **Acceptance:** `ServerContracts.swift` contains zero tokenizing
  code; gate and executor provably resolve the same field for any
  `operationName`. **Sequencing:** the C1 hotfix (thread `operationName`)
  ships first; full unification follows.

### IP-2 — Shared agent process kit with timeout + kill escalation

**Goal.** The `AgentRuntimeKit` process path gets the same lifecycle
guarantees the workflow path already has, eliminating orphaned children
and unbounded `cancel()` blocks.

**Files.**
- `Sources/AgentRuntimeKit/AgentProcessSupervisor.swift:56-84` (the
  `run`/`waitUntilExit` path) and its `kill()` (~line 167,
  `terminate()`-only).
- `Sources/AgentRuntimeKit/AgentManagedProcess.swift:32-38` (the UTF-8
  chunk decode — see IP-3).
- Template to promote: `LocalAgentProcess.swift:390-391, 589, 696`
  (`terminateGroupOrProcess`, `scheduleKillIfRunning(after: 1)`,
  `POSIX_SPAWN_SETPGROUP`, `waitpid` reaping).
- `Sources/RielaApp/EntryPoint.swift:101-107` (`applicationWillTerminate`).

**Change.**
1. Extract the `LocalAgentProcess` spawn/terminate/reap machinery into a
   shared `AgentProcessKit` primitive; have `AgentProcessSupervisor.run`
   use it with a **deadline** and process-group `SIGTERM → delayed
   SIGKILL` escalation. Replace the bare `waitUntilExit()` with a
   deadline-bounded wait so `AgentRunningSessionState.cancel()` cannot
   block forever.
2. Put daemon children in a process group and, in
   `applicationShouldTerminate` (not `applicationWillTerminate`), return
   `.terminateLater`, stop `daemonRuntime` synchronously, then reply —
   so `riela events serve` children are reaped on app quit.

**Signatures.**
```swift
func run(_ spec: AgentProcessSpec, deadline: Duration) async throws -> AgentProcessResult
func terminateGroup(escalateAfter: Duration)   // SIGTERM group → SIGKILL
```

**Tests.** `testSupervisorKillsProcessGroupOnCancel`,
`testRunHonorsDeadlineAndSIGKILLs`,
`testAppQuitStopsDaemonChildren` (assert no surviving child PIDs).

**Acceptance.** A child ignoring SIGTERM is SIGKILLed within the grace
window; no `riela events serve` child survives app quit; `cancel()`
returns promptly.

**Sequencing.** Independent P0; do alongside IP-3 (same file).

### IP-3 — UTF-8-safe JSONL line splitter (one shared impl)

**Goal.** Stop corrupting multi-byte assistant output split across pipe
reads; collapse four incremental JSONL parsers to one.

**Files.** `Sources/AgentRuntimeKit/AgentManagedProcess.swift:32-38`
(`appendStdout`, decodes each chunk independently → U+FFFD);
`ClaudeCodeJsonlStreamParser`, `AgentRolloutWatcher`, and
`LocalProcessPipeReader` (the one that already splits on the `\n` byte
in `Data`).

**Change.** Promote `LocalProcessPipeReader`'s `Data`-level newline
split into a shared `JSONLByteSplitter` that buffers bytes, emits
complete `\n`-delimited lines, and decodes each *line* (never a raw
chunk) as UTF-8. Re-point the other three parsers at it.

**Tests.** `testMultibyteCharSplitAcrossChunksDecodesIntact` (feed a
CJK line split mid-codepoint across two chunks), `testPartialLineBuffered`.

**Acceptance.** No U+FFFD for any input that is valid UTF-8 once
reassembled; one JSONL splitter in the tree.

**Sequencing.** Independent P0; pairs with IP-2.

### IP-4 — Per-source event-serve isolation + backoff + unified offset/dedupe

**Goal.** A transient failure or poison message on one chat source no
longer unwinds the whole daemon; offset/ack semantics are consistent
across Telegram/Discord/Slack.

**Files.** `Sources/RielaCLI/EventLiveServe.swift:110-135` (the
per-source loop with no catch/backoff); `EventLiveServe+Telegram.swift`,
`+Discord.swift`, `+Slack.swift` (triplicated poll skeleton,
byte-identical `safeXStorageComponent`, only Slack validates path
traversal).

**Change.**
1. Wrap each source poll in per-source `do/catch` with exponential
   backoff honoring `Retry-After`; a failing source is skipped that
   cycle, not fatal to the loop.
2. Extract a `ChatGatewayBinding` protocol + one generic poll driver
   (also Theme 1 dedup) so offset/dedupe is defined **once**: mark +
   content-dedupe journal, save offset *after* successful dispatch, and
   bootstrap first-run to "newest, process nothing" (fixes the
   backlog-replay and at-most-once/at-least-once divergence). Apply the
   Slack path-traversal validation to all three.

**Signatures.**
```swift
protocol ChatGatewayBinding { func poll(since: Offset) async throws -> [InboundEvent]
                              func markProcessed(_ event: InboundEvent) async throws }
func runGatewayLoop(_ bindings: [ChatGatewayBinding], backoff: BackoffPolicy) async
```

**Tests.** `testOneSourceFailureDoesNotStopLoop`,
`testBackoffHonorsRetryAfter`, `testFirstRunProcessesNoBacklog`,
`testDuplicateInboundDeduped`, `testAllGatewaysRejectPathTraversal`.

**Acceptance.** A 429/5xx on one source degrades only that source; no
duplicate replies; no backlog storm on first run; path traversal
rejected uniformly.

**Sequencing.** Independent P0. The generic driver (step 2) also
retires ~450–500 lines of Theme 1 duplication, so it doubles as the
first slice of the P1 `ChatGatewayBinding` extraction.

### P1/P2 follow-on (pointers, not full plans)

- **AgentProcessKit completion** (Theme 1): once IP-2 extracts the
  process primitive, promote `*SDKUtilities` (byte-identical ×3),
  session-index scaffolding, rollout parsing, and JSON helpers; target
  >10k lines removed. Leave argv builders + event-schema mapping
  backend-specific.
- **Prepared-handle SQLite store** (Theme 3/4): add an open-once /
  schema-once handle type to replace the per-call
  `openDatabase`+`ensureSchema` in `SQLiteWorkflowMessageLog` /
  `SQLiteWorkflowRuntimePersistenceStore`; fix `save`'s O(n²)
  `replaceMessages`; the note store's `NoteDatabaseDriving.withDatabase`
  shares this fix.
- **OptionTable / OutputRenderer** (Theme 2): one declarative command
  spec drives parsing, usage text, and the table allowlist; route all
  rendering through one typed-exit-code helper.
- **god-object / window-controller** work (Theme 5): extract
  `DaemonInstanceStore`; shared `RielaAppWindowController` base;
  delegate/intent enum replacing the 29-argument init.
