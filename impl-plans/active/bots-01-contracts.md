# bots-01-contracts: bot record, store, generation 13, activity and adapter contracts

```json
{
  "planId": "bots-01-contracts",
  "planPath": "impl-plans/active/bots-01-contracts.md",
  "dependsOn": [],
  "wave": 1,
  "writePaths": [
    "Sources/RielaCore/Bots",
    "Tests/RielaCoreTests/Bots",
    "Sources/RielaCore/AdapterContracts.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+Fanout.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+CrossWorkflow.swift",
    "Sources/RielaCore/DeterministicWorkflowRunner+DynamicWorkflow.swift",
    "Sources/RielaCore/RoutineStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore.swift",
    "Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift",
    "Sources/RielaCore/SurfaceCatalog+Rows.swift",
    "Sources/RielaCore/SurfaceCatalog+RowsBots.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeSchemaMigrationTests.swift",
    "Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift",
    "Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift",
    "Tests/RielaCoreTests/SQLiteWorkflowMessageLogTests.swift",
    "Tests/RielaWorkTests/WorkStoreTests.swift",
    "impl-plans/progress/bots-01-contracts.md"
  ],
  "sharedPaths": [],
  "sharedPathNotes": [
    {"path": "Sources/RielaCore/DeterministicWorkflowRunner.swift", "intendedEdit": "Add two stored properties to DeterministicWorkflowRunRequest only (botContext, activityRecorder), default nil. No behaviour change. bots-03 edits the adapter call site of this file in wave 2."},
    {"path": "Sources/RielaCore/SurfaceCatalog+Rows.swift", "intendedEdit": "ONE edit: append `+ botFamilyRows` to the aggregate expression at lines 8-15."},
    {"path": "Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift", "intendedEdit": "Only testCachedSchemaRejectsDatabaseMigratedByNewerBuild (line 65-75): replace the literal 13 with a value derived from SQLiteWorkflowRuntimePersistenceStore.schemaGeneration + 1, both in the `PRAGMA user_version` statement and in the expected 'generation N' message. The test keeps asserting that a newer-build store is rejected."},
    {"path": "Tests/RielaCoreTests/WorkflowDefinitionStoreTests.swift", "intendedEdit": "Only the literal generation expectation (line 36: 12 becomes 13)."},
    {"path": "Tests/RielaCoreTests/WorkflowDefinitionRetentionTests.swift", "intendedEdit": "Only literal generation-12 expectations, if any."},
    {"path": "Tests/RielaCoreTests/SQLiteWorkflowMessageLogTests.swift", "intendedEdit": "Only literal generation-12 expectations, if any."},
    {"path": "Tests/RielaWorkTests/WorkStoreTests.swift", "intendedEdit": "Only literal generation-12 expectations, if any."}
  ]
}
```

Follow `impl-plans/active/bots-overview.md` §2 (rules) for every step.

## Intent and context

Design §4, §5.1, §5.2, §6.1, §6.2 (types only), §6.6 (types only). This plan
pins every type, table and field that the eight wave-2 plans share, so they
can run side by side. It adds no user-visible behaviour.

Current code:

- Session store generation is 12
  (`SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:125`), with
  migrations `fromGeneration: 2, 3, 9, 10, 11` (`:137-156`). Fresh stores are
  built in `ensureSchema` (`SQLiteWorkflowRuntimePersistenceStore.swift:697-`).
- `WorkStore.prepareSchema(in:)` (`Sources/RielaWork/WorkStore+Schema.swift:17-21`)
  is the pattern for extra tables behind the same guard.
- `RoutineStore` (`Sources/RielaCore/RoutineStore.swift`) is the pattern for a
  JSON-record store with generated columns and per-operation connections.
- `AdapterBackendEvent` and `AdapterExecutionContext` are in
  `Sources/RielaCore/AdapterContracts.swift:160-213`.

## Non-goals

- No reducer, recorder, projector, CLI, GraphQL or web code.
- No queries for `bot_list_state`, `bot_suggestions`, `bot_job_runs`,
  `bot_memory_changes`, `activity_*`, `provider_*` (their owning plans add
  them as `extension BotStore` in their own directories).
- No catalog rows yet (`botFamilyRows` is empty).

## Changes

### `Sources/RielaCore/Bots/BotRecord.swift` (new)

- `public enum BotJobSchedule: String, Codable, CaseIterable, Sendable { case off, nightly, weekly }`
- `public struct BotRecord: Codable, Equatable, Sendable` with exactly the
  fields of design §5.1: `botId`, `name`, `purpose: String?`,
  `personaId: String?`, `defaultBackend: String?`, `defaultModel: String?`,
  `providerInstanceId: String?`, `workspace: String?`, `paused: Bool`,
  `memoryUpkeep: BotJobSchedule` (default `.nightly`),
  `lookAround: BotJobSchedule` (default `.off`), `permissionWaitMs: Int`
  (default 300_000), `createdAt: String`, `updatedAt: String` (same timestamp
  format as `RoutineStore.timestamp`).
- `public static func validate(_:) throws` : `botId` matches
  `^[a-z0-9][a-z0-9-]{0,62}$`; `name` 1...200 characters with no control
  characters; `permissionWaitMs` in 0...3_600_000; `defaultBackend`, when set,
  is a `NodeExecutionBackend` raw value. Failure throws
  `BotStoreError(code: "bot_invalid", ...)`.
- `public static func slug(from name: String) -> String`: lowercase, runs of
  other characters become `-`, trimmed of `-`, cut to 63; empty result → `bot`.
- `public enum ModelSentinel { public static let defaultModel = "default" }`

### `Sources/RielaCore/Bots/BotStore.swift`, `BotStoreSchema.swift` (new)

- `public struct BotStoreError: Error, Equatable, Sendable, CustomStringConvertible { public var code: String; public var message: String }`
- `public struct BotSessionLink: Codable, Equatable, Sendable { sessionId, botId, source, sourceRef: String?, linkedAt: String }`;
  `source` is one of `run`, `routine`, `job`.
- `public struct BotStore: Sendable { public var sessionStoreRoot: String; public init(sessionStoreRoot: String) }`
  - `databasePath` = `SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory:)`.
  - `public func read<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T?`
    returns nil when the database file does not exist (never creates it).
  - `public func write<T>(_ body: (SQLiteDatabase) throws -> T) throws -> T`
    opens with `.writableRuntimeStoreDefault`, calls
    `BotStoreSchema.prepare(in:)`, runs `body` in one transaction.
  - `create(_:)` (`bot_exists` on duplicate), `load(botId:)`, `list()`
    (ordered by `bot_id`), `update(botId:_ mutate:)` (`bot_not_found`),
    `setPaused(botId:paused:)`.
  - `remove(botId:)`: deletes the bot row and its rows in
    `bot_session_links`, `bot_list_state`, `bot_suggestions`, `bot_job_runs`
    in one transaction. It refuses with `bot_busy` when a pending row exists
    in `activity_requests` for a linked session. The "linked session still
    running" check and the routine `botId` clearing need other stores; they
    are done by the caller in plan 10 (routines first, then this call).
  - `linkSession(sessionId:botId:source:sourceRef:at:)`: insert; a second
    call for the same session with the same bot is a no-op, with a different
    bot throws `bot_link_conflict`. Throws `bot_not_found` for an unknown bot.
  - `link(forSession:)`, `links(botId:)` (newest first).
- `enum BotStoreSchema`: `static func prepare(in db:)` (JSONB check +
  `requireCompatibleSchemaGeneration` + `createTables`), and
  `static func createTables(in db:)` with `CREATE TABLE IF NOT EXISTS` for:

```
bots(bot_id TEXT PRIMARY KEY, record_json BLOB NOT NULL CHECK (json_valid(record_json, 8)),
     name TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.name')) STORED,
     paused INTEGER GENERATED ALWAYS AS (json_extract(record_json,'$.paused')) STORED,
     updated_at TEXT NOT NULL)
bot_session_links(session_id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, source TEXT NOT NULL,
     source_ref TEXT, linked_at TEXT NOT NULL)            -- index on (bot_id, linked_at)
bot_list_state(bot_id TEXT NOT NULL, item_kind TEXT NOT NULL, item_id TEXT NOT NULL,
     state_json BLOB NOT NULL, updated_at TEXT NOT NULL, PRIMARY KEY (bot_id, item_kind, item_id))
bot_suggestions(suggestion_id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, record_json BLOB NOT NULL,
     status TEXT GENERATED ALWAYS AS (json_extract(record_json,'$.status')) STORED,
     created_at TEXT NOT NULL)                             -- index on (bot_id, status)
bot_job_runs(bot_id TEXT NOT NULL, job TEXT NOT NULL, period_key TEXT NOT NULL, status TEXT NOT NULL,
     session_id TEXT, detail TEXT, started_at TEXT NOT NULL, finished_at TEXT,
     PRIMARY KEY (bot_id, job, period_key))
bot_memory_changes(change_id TEXT PRIMARY KEY, bot_id TEXT NOT NULL, record_json BLOB NOT NULL,
     created_at TEXT NOT NULL)                             -- index on (bot_id, created_at)
activity_events(session_id TEXT NOT NULL, seq INTEGER NOT NULL, execution_id TEXT, at TEXT NOT NULL,
     kind TEXT NOT NULL, payload_json BLOB NOT NULL, PRIMARY KEY (session_id, seq)) WITHOUT ROWID
activity_state(session_id TEXT PRIMARY KEY, state_json BLOB NOT NULL, last_seq INTEGER NOT NULL,
     first_retained_seq INTEGER NOT NULL, source TEXT NOT NULL, updated_at TEXT NOT NULL)
activity_requests(request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL, execution_id TEXT,
     tool_call_id TEXT, title TEXT, options_json BLOB NOT NULL, status TEXT NOT NULL,
     outcome_option_id TEXT, resolved_by TEXT, created_at TEXT NOT NULL, expires_at TEXT NOT NULL,
     resolved_at TEXT)                                     -- index on (session_id, status)
provider_instances(instance_id TEXT PRIMARY KEY, record_json BLOB NOT NULL, updated_at TEXT NOT NULL)
provider_reports(instance_id TEXT PRIMARY KEY, report_json BLOB NOT NULL, observed_at TEXT NOT NULL)
```

`activity_requests.status` values: `pending`, `answered`, `cancelled`.

### Generation 13

- `schemaGeneration = 13`; append
  `SQLiteSchemaMigration(fromGeneration: 12) { try BotStoreSchema.createTables(in: $0) }`.
  Extend the doc comment ("Generation 13 adds the bot, activity and provider tables.").
- `ensureSchema` calls `BotStoreSchema.createTables(in: db)` next to
  `SQLiteRuntimeExecutionRowsSchema.create(in: db)` (`:733`).
- Update the literal generation expectations in the listed test files.
- `SQLiteRuntimeExecutionRowsTests.testCachedSchemaRejectsDatabaseMigratedByNewerBuild`
  (`Tests/RielaCoreTests/SQLiteRuntimeExecutionRowsTests.swift:65-75`) stamps
  `PRAGMA user_version = 13` as a "newer build" store and expects an error
  containing `generation 13`. After the bump 13 is the current generation and
  the test would fail. Change it to use `schemaGeneration + 1` for both the
  stamp and the expected message. Any test that hard-codes a future
  generation must derive it from the constant; do not delete or weaken the
  rejection assertion.

### `Sources/RielaCore/AdapterContracts.swift`

- `public enum AdapterActivityUpdate: Codable, Equatable, Sendable` with cases
  (associated values are small Codable structs defined beside it):
  `message(messageId: String?, text: String, replace: Bool)`,
  `thought(text: String)`,
  `toolCall(AdapterActivityToolCall)` — `toolCallId`, `title: String?`,
  `toolKind: String?`, `status: String?`, `locations: [AdapterActivityLocation]?`
  (`path`, `line: Int?`); nil means "field not carried by this update",
  `plan(planId: String, entries: [AdapterActivityPlanEntry])` — `content`,
  `status`, `priority` (raw strings),
  `planRemoved(planId: String)`, `mode(modeId: String)`,
  `commands(names: [String])`, `configOptions(options: [JSONObject])`,
  `sessionInfo(title: String?)`, `usage(JSONObject)`,
  `notice(severity: String, title: String, description: String?)`,
  `subagent(subSessionId: String, title: String?, state: String?)`,
  `stop(stopReason: String, limited: Bool, limitedResetAt: Date?)`,
  `reportedModel(String)`, `other(updateKind: String)`.
- `public struct AdapterPermissionOption { optionId, name, kind: String }`,
  `public struct AdapterPermissionRequest { toolCallId: String?, title: String?, options: [AdapterPermissionOption] }`,
  `public enum AdapterPermissionOutcome { case selected(optionId: String), cancelled }`
  (all `Codable, Equatable, Sendable`),
  `public typealias AdapterPermissionRequestHandler = @Sendable (AdapterPermissionRequest) async -> AdapterPermissionOutcome`.
- `AdapterBackendEvent.activity: AdapterActivityUpdate?` (new last init
  parameter, default nil; decoded with `decodeIfPresent`).
- `AdapterExecutionContext.permissionRequestHandler: AdapterPermissionRequestHandler?`
  (new last init parameter, default nil).

### `Sources/RielaCore/Bots/ActivityModels.swift` (new)

- `public enum ActivityEventKind: String, Codable, CaseIterable, Sendable`
  with the 19 kinds of design §6.1 (`stepStarted` … `other`).
- `public struct ActivityEvent: Codable, Equatable, Sendable { sessionId, seq: Int, executionId: String?, at: Date, kind: ActivityEventKind, payload: JSONObject }`
- `public struct ActivityState: Codable, Equatable, Sendable`:
  `source: String` (`acp` | `session`), `currentExecutionId`, `currentStepId`,
  `currentNodeId`, `backend`, `requestedModel`, `reportedModel` (all
  optional strings), `toolCalls: [ActivityToolCall]` (`toolCallId`, `title`,
  `toolKind`, `status`, `locations`, `updatedAt`), `plans: [ActivityPlan]`
  (`planId`, `entries`), `mode: String?`, `commands: [String]`,
  `configOptions: [JSONObject]`, `usage: JSONObject?`,
  `subagents: [ActivitySubagent]`, `pendingRequestIds: [String]`,
  `lastStop: ActivityStop?` (`stopReason`, `limited`, `limitedResetAt`),
  `lastMessageLine: String?`, `lastEventAt: Date?`. `public init()` gives an
  empty state with `source = "session"`.
- `public enum ActivitySettleReason: String, Codable, Sendable { case completed, cancelled, timeout, providerError, processExit }`
- `public protocol WorkflowActivityRecording: Sendable`:

```
func stepStarted(sessionId: String, executionId: String, stepId: String, nodeId: String,
                 backend: String?, requestedModel: String?, at: Date) async
func record(sessionId: String, executionId: String, update: AdapterActivityUpdate, at: Date) async
func requestPermission(sessionId: String, executionId: String, request: AdapterPermissionRequest,
                       waitMs: Int, deadline: Date?) async -> AdapterPermissionOutcome
func settle(sessionId: String, executionId: String, reason: ActivitySettleReason,
            stepStatus: String, at: Date) async
```

### Other files

- `Sources/RielaCore/Bots/BotRunContext.swift`:
  `public struct BotRunContext: Equatable, Sendable { botId: String; permissionWaitMs: Int; memoryBlock: String?; forceReadOnlySandbox: Bool }`.
- `Sources/RielaCore/Bots/BotOrigin.swift`:
  `public struct BotOrigin: Codable, Equatable, Sendable { remote: String; serverId: String?; serverName: String?; verified: Bool; connection: String; observedAt: Date }`
  with `static func local(serverId:serverName:at:)` (`remote = "local"`,
  `verified = true`, `connection = "connected"`).
- `DeterministicWorkflowRunRequest`: `public var botContext: BotRunContext?`
  and `public var activityRecorder: (any WorkflowActivityRecording)?`, both
  nil by default and not added to `init`. Every place that builds a child
  `DeterministicWorkflowRunRequest` in `+Fanout.swift`, `+CrossWorkflow.swift`
  and `+DynamicWorkflow.swift` copies both from the parent request.
- `RoutineRecord.botId: String?` (stored property, init parameter default
  nil). The routine store generation stays 1.
- `Sources/RielaCore/SurfaceCatalog+RowsBots.swift`:
  `extension SurfaceCatalog { static let botFamilyRows: [SurfaceOperation] = [] }`.

## Imitate

- `Sources/RielaCore/RoutineStore.swift:save/load/list/ensureSchema` for JSON
  record rows (`jsonb(?)`, `json(record_json)` on read) and timestamps.
- `Sources/RielaWork/WorkStore+Schema.swift:prepareSchema` and
  `Sources/RielaWork/WorkStore.swift:openWritable` (`:384-392`) for opening.
- `SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift:153-155` for
  the migration entry.

## Pitfalls

- Do not call the current-schema builder of another schema from the 12→13
  migration; only `BotStoreSchema.createTables`.
- `BotStore.read` must not create the database or directory.
- `AdapterBackendEvent` is `Equatable` and compared in existing tests; the new
  field defaults to nil so every existing call site compiles unchanged.
- Do not add the two request fields to `DeterministicWorkflowRunRequest.init`;
  dozens of call sites exist.
- An older JSON `RoutineRecord` without `botId` must still decode.
- `record_json` generated column `paused` is 0/1; compare with integers.
- Before finishing, run
  `grep -rnE "user_version = 1[2-9]|generation 1[2-9]" Tests` and reconcile
  every hit: a literal current generation becomes 13 (or the constant), a
  literal "newer build" generation becomes `schemaGeneration + 1`. A hit in a
  file outside this plan's writePaths is recorded in the progress log as
  `BLOCKED: scope` with the path and line; do not edit it.

## Tests (`Tests/RielaCoreTests/Bots/`)

`BotStoreTests`:
- create then load → equal record; list is ordered by id.
- create duplicate id → `bot_exists`.
- invalid id `Bad_ID` or empty name → `bot_invalid`.
- `slug(from: "Release Bot #1")` → `release-bot-1`.
- linkSession unknown bot → `bot_not_found`; same link twice → one row;
  different bot → `bot_link_conflict`.
- remove with a pending `activity_requests` row for a linked session →
  `bot_busy`; without it → bot, links, list state, suggestions, job rows gone.
- `read` on a missing root → nil and no file created.

`BotStoreMigrationTests`:
- a generation-12 database (create it with the frozen statements used by the
  existing `SQLiteRuntimeSchemaMigrationTests` helpers, stamp
  `user_version = 12`, insert one snapshot row) opened by `BotStore.write` →
  `user_version` 13, the snapshot row still present, all eleven tables exist.
- a fresh store opened by `SQLiteWorkflowRuntimePersistenceStore` → the eleven
  tables exist.

`ActivityContractTests`:
- every `AdapterActivityUpdate` case round-trips through JSON.
- `AdapterBackendEvent` JSON without `activity` decodes with `activity == nil`.
- `RoutineRecord` JSON without `botId` decodes.

## Verification

```
mkdir -p tmp/bots-overview/bots-01-contracts
arch -arm64 /bin/zsh -lc 'swift build' > tmp/bots-overview/bots-01-contracts/build.log 2>&1
arch -arm64 /bin/zsh -lc 'swift test --filter "BotStoreTests|BotStoreMigrationTests|ActivityContractTests|SQLiteRuntimeSchemaMigrationTests|SQLiteRuntimeExecutionRowsTests|WorkflowDefinitionStoreTests|WorkflowDefinitionRetentionTests|SQLiteWorkflowMessageLogTests|RoutineStoreTests|WorkStoreTests|SurfaceCatalogTests"' > tmp/bots-overview/bots-01-contracts/test.log 2>&1
grep -rnE "user_version = 1[2-9]|generation 1[2-9]" Tests > tmp/bots-overview/bots-01-contracts/generation-literals.log
```

The build and test commands exit 0. The test log shows the three new suites
executed with 0 failures and every existing suite whose generation
expectation this plan owns still passing, including
`SQLiteRuntimeExecutionRowsTests` (evidence that generation 13 did not break
migration, execution rows, definitions, retention, the message log,
routines, the Work store or the catalog). Every line left in
`generation-literals.log` is explained in the progress log.

## Done criteria

- `grep -n "schemaGeneration: Int64 = 13" Sources/RielaCore/SQLiteWorkflowRuntimePersistenceStore+SchemaMigrations.swift` prints one line.
- `grep -rn "botFamilyRows" Sources/RielaCore` prints the definition and the aggregator use.
- `git diff --stat 7f04f6e6 -- Package.swift Package.resolved` prints nothing.
- Both verification commands exit 0; progress log written.
