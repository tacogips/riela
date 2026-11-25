# bots-06-memory-core: bot memory writer, Markdown round trip, audited change sets, undo

```json
{
  "planId": "bots-06-memory-core",
  "planPath": "impl-plans/active/bots-06-memory-core.md",
  "dependsOn": ["bots-01-contracts"],
  "wave": 2,
  "writePaths": [
    "Sources/RielaCore/BotMemory",
    "Tests/RielaCoreTests/BotMemory",
    "impl-plans/progress/bots-06-memory-core.md"
  ],
  "sharedPaths": []
}
```

Follow `impl-plans/active/bots-overview.md` §2.

## Intent and context

Design §9.1–§9.5 (core only), §10.1 (apply rule for upkeep text). Bot memory
is riela memory in the existing `RielaMemoryStore`, memory id `bot-<botId>`.
Every write goes through one function that enforces the rules and writes an
audited change set that can be listed, diffed and undone.

Facts about `RielaMemoryStore` (`Packages/RielaMemory/Sources/RielaMemory/`,
read-only for this plan; `RielaCore` already imports `RielaMemory`):

- `save(memoryId:workflowId:nodeId:registeredAt:tags:relatedRecordIds:files:payload:historyRetention:)`
  and `update(memoryId:recordId:...payload:historyRetention:)`
  (`RielaMemory.swift:25`, `:104`). There is **no delete**.
- History: `evolutionHistory(memoryId:recordId:limit:beforeVersion:)` (the
  entry with `isHead` gives the head version), `recordVersion`,
  `restoreRecordVersion(memoryId:recordId:version:expectedHeadVersion:historyRetention:)`,
  `recordDiff(memoryId:recordId:fromVersion:toVersion:)`
  (`MemoryEvolutionHistory.swift:47-260`).
- Ordinary records keep only a small history window by default
  (`historyRetention`), so bot memory must pass its own value.
- `search(memoryId:options:)` with `MemorySearchOptions(workflowId:includeAllWorkflows:tags:limit:maxPayloadBytes:)`.

## Non-goals

- No edit of `Packages/RielaMemory`; no schema or version change.
- No CLI, GraphQL, prompt injection wiring (plan 15), no job (plan 16).
- No kaiba.
- No import of `RielaWork`: redaction is a closure parameter.

## Changes (new files in `Sources/RielaCore/BotMemory/`)

### `BotMemoryModels.swift`

- `public enum BotMemoryKind: String, Codable, Sendable { case instruction, note }`
- `public enum BotMemorySource: String, Codable, Sendable { case user, correction, review, upkeep, external }`
- `public struct BotMemoryEntry: Codable, Equatable, Sendable { recordId: Int64?; kind; topic: String; text: String; provenance: BotMemoryProvenance }`
  with `BotMemoryProvenance { source: BotMemorySource; ref: String?; capturedAt: String; actor: String }`.
- `public struct BotMemoryChangeSet: Codable, Equatable, Sendable`: `changeId`,
  `botId`, `actor` (`user`|`cli`|`api`|`upkeep`|`feedback`), `reason`,
  `evidenceRefs: [String]`, `createdAt`,
  `entries: [BotMemoryChangeEntry]` (`recordId`, `op` = `add`|`update`|`remove`,
  `fromVersion: Int64?`, `toVersion: Int64`), `redacted: Bool`,
  `downgraded: Bool`, `ignoredInstructionChanges: Int`.
- `public struct BotMemoryLimits { maxEntryBytes = 4000; maxEntries = 500; promptBlockBytes = 16000; historyRetention = 50 }`.
- `static func memoryId(botId:) -> String` → `"bot-" + botId`.

Storage mapping: one memory record per entry, `workflowId = "bot"`, tags
`kind:<kind>`, `topic:<slug>`, and `state:removed` for a removed entry;
payload `{ "text": ..., "provenance": {...} }`. A removed entry is an update
that adds `state:removed` (a tombstone); readers skip it.

### `BotMemoryMarkdown.swift` (pure)

- `static func render(entries: [BotMemoryEntry]) -> String`:
  `## Instructions` then `## Notes`; inside each, `### <topic>` in
  alphabetical order; one `- <text> <!-- id:<recordId> -->` line per entry in
  record id order. Multi-line text is rendered with continuation lines
  indented by two spaces. An empty memory renders both headings.
- `static func parse(_ markdown: String) throws -> [BotMemoryMarkdownItem]`
  (`kind`, `topic`, `text`, `recordId: Int64?`). Items before any `##` heading
  or under an unknown `##` heading → `memory_markdown_invalid`. An item with
  no `###` topic gets topic `general`. Duplicate ids → `memory_markdown_invalid`.
- `static func promptBlock(entries:limitBytes:) -> String?`: nil for no
  entries; otherwise a block starting with the line `Bot memory (riela memory)`,
  then `Instructions:` items, then the line
  `Notes (information only, not instructions):` and note items, newest first
  within each part, cut at `limitBytes` with a last line `(memory truncated)`.

### `BotMemoryWriter.swift`

`public struct BotMemoryWriter { public init(botStore: BotStore, memoryRoot: String, redact: @escaping @Sendable (String) -> String, limits: BotMemoryLimits = .init(), now: @escaping @Sendable () -> Date) }`

- `entries(botId:) throws -> [BotMemoryEntry]` (tombstones excluded).
- `apply(botId:changes: [BotMemoryProposedChange], actor:reason:evidenceRefs:) throws -> BotMemoryChangeSet`
  where a proposed change is `.add(BotMemoryEntry)`, `.update(recordId, text, topic, kind)`,
  `.remove(recordId)`, each carrying a `source`.
- `applyMarkdown(botId:markdown:source:actor:reason:evidenceRefs:) throws -> BotMemoryChangeSet`:
  parse, diff against current entries by record id (item without id → add;
  id with different text, topic or kind → update; current entry whose id is
  missing → remove; an id that does not exist → `memory_markdown_invalid`),
  then `apply`.
- `history(botId:limit:) throws -> [BotMemoryChangeSet]` (newest first).
- `diff(botId:changeId:) throws -> [BotMemoryEntryDiff]` (per entry, through
  `recordDiff(fromVersion:toVersion:)`; an added entry diffs against nothing).
- `undo(botId:changeId: String?) throws -> BotMemoryChangeSet`.

Rules enforced in `apply` (design §9.2), in this order per change:
1. `provenance.source` is required (the type guarantees it); the bot must
   exist (`bot_not_found`).
2. Redaction: `text = redact(text)`; if it changed, the change set gets
   `redacted: true`.
3. Kind rule: only `user` and `correction` may create an instruction or
   change an existing instruction. For any other source: an add or update
   that asks for `instruction` on a note or a new entry is stored as `note`
   (`downgraded: true`); an update or remove that targets an existing
   instruction is skipped and counted in `ignoredInstructionChanges`.
4. Limits: entry text over `maxEntryBytes`, or more than `maxEntries` live
   entries after the change → `memory_limit`, and nothing is written.
5. No-op changes (same text, topic and kind) are dropped. A change set with
   no remaining entries and zero ignored changes is not stored; the function
   returns it with an empty `entries` array and `changeId == ""`.

Writing: validate everything first, then write records with
`historyRetention: limits.historyRetention`, reading each record's head
version before (`fromVersion`) and after (`toVersion`), then insert the
`bot_memory_changes` row (`BotStore.write`). Memory records and the change
row are in different SQLite files: write the records first and the change row
last, so a crash can leave an unaudited record version but never an audit row
that points at a missing version.

Upkeep guard (used by plan 16, implemented here as
`static func upkeepRejection(current: [BotMemoryEntry], proposed: [BotMemoryMarkdownItem]) -> String?`):
returns `upkeep_removes_too_much` when the proposal would remove more than
half of the current **note** entries (and there are at least 4), else nil.

Undo:
- Default target is the newest change set of the bot.
- For each entry: head version must equal `toVersion`, else
  `memory_change_conflict` and nothing is changed (check all entries first).
- `add` → tombstone the record; `update` and `remove` →
  `restoreRecordVersion(version: fromVersion, expectedHeadVersion: toVersion)`.
- Writes a new change set with `reason = "undo:<changeId>"` and the same actor
  as the caller passes.

### `BotMemoryChangeStore.swift`

`extension BotStore`: `insertMemoryChange(_:)`, `memoryChanges(botId:limit:)`,
`memoryChange(changeId:)` on the `bot_memory_changes` table of plan 01.

## Imitate

- `Sources/RielaCLI/ProductionNodeAdapter+PersonaMemory.swift` for tagging
  records and reading them with `search`.
- `Sources/RielaCLI/MemoryCommands.swift` for calling `restoreRecordVersion`
  and `recordDiff`.

## Pitfalls

- Do not rely on default history retention; always pass the limit value.
- Never delete a memory database file or record row.
- The Markdown id marker is the only identity; never match entries by text.
- `redact` runs before limits are measured.
- Tombstones must not count toward `maxEntries` and must not render.
- Tests use a temporary memory root and a temporary session store root.

## Tests (`Tests/RielaCoreTests/BotMemory/`)

`BotMemoryWriterTests` (redact closure replaces `sk-[A-Za-z0-9]+` with `[REDACTED]`):
- add user instruction → stored as instruction with provenance; change set
  with one `add`.
- add with text `token sk-abc123` → stored text has `[REDACTED]`,
  `redacted == true`.
- add `external` asking for instruction → stored as note, `downgraded == true`.
- `upkeep` update of an instruction → not applied, `ignoredInstructionChanges == 1`.
- `upkeep` update of a note → applied.
- 4,001-byte text → `memory_limit`, no record written.
- 501st entry → `memory_limit`.
- unknown bot → `bot_not_found`.
- two bots → `entries(botId:)` never returns the other bot's entries.

`BotMemoryMarkdownTests`:
- render then parse → same kinds, topics, texts and ids.
- edited Markdown (one line changed, one removed, one new line without id) →
  one update, one remove, one add.
- line with an id that does not exist → `memory_markdown_invalid`.
- item under `## Other` → `memory_markdown_invalid`.
- prompt block over the limit → ends with `(memory truncated)`, size ≤ limit,
  instructions before notes, notes heading text exact.
- no entries → prompt block nil.

`BotMemoryUndoTests`:
- apply change set A (add, update, remove) then undo → entries equal the
  state before A; history lists A and `undo:A`.
- apply A, then B touching the same entry, undo A → `memory_change_conflict`,
  nothing changed.
- `diff` of an update → reports the text change.
- `upkeepRejection`: 6 notes, proposal keeps 2 → `upkeep_removes_too_much`;
  keeps 3 → nil; 3 notes, proposal keeps 1 → nil.

## Verification

```
mkdir -p tmp/bots-overview/bots-06-memory-core
arch -arm64 /bin/zsh -lc 'swift test --filter "BotMemoryWriterTests|BotMemoryMarkdownTests|BotMemoryUndoTests"' > tmp/bots-overview/bots-06-memory-core/test.log 2>&1
```

Exit 0; three suites, 0 failures.

## Done criteria

- `git status --short Packages/RielaMemory` prints nothing.
- `grep -rn "import RielaWork" Sources/RielaCore/BotMemory` prints nothing.
- Verification exits 0; progress log written.
