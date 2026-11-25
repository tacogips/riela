import Foundation
import RielaSQLite

public struct BotMemoryWriter: Sendable {
  let botStore: BotStore
  let memoryRoot: String
  let redact: @Sendable (String) -> String
  let limits: BotMemoryLimits
  let now: @Sendable () -> Date

  public init(
    botStore: BotStore, memoryRoot: String, redact: @escaping @Sendable (String) -> String,
    limits: BotMemoryLimits = .init(), now: @escaping @Sendable () -> Date
  ) {
    self.botStore = botStore
    self.memoryRoot = memoryRoot
    self.redact = redact
    self.limits = limits
    self.now = now
  }

  public static func memoryId(botId: String) -> String { "bot-" + botId }

  public func entries(botId: String) throws -> [BotMemoryEntry] {
    try requireBot(botId)
    return try storage(botId).entries()
  }

  @discardableResult
  public func apply(
    botId: String, changes: [BotMemoryProposedChange], actor: String, reason: String, evidenceRefs: [String] = []
  ) throws -> BotMemoryChangeSet {
    try apply(botId: botId, actor: actor, evidenceRefs: evidenceRefs) { memory, date, _ in
      try prepare(changes, current: memory.entries(), provenance: .init(actor: actor, date: date, refs: evidenceRefs), reason: reason)
    }
  }

  @discardableResult
  public func applyMarkdown(
    botId: String, markdown: String, source: BotMemorySource, actor: String, reason: String, evidenceRefs: [String] = []
  ) throws -> BotMemoryChangeSet {
    let proposed = try BotMemoryMarkdown.parse(markdown)
    return try apply(botId: botId, actor: actor, evidenceRefs: evidenceRefs) { memory, date, _ in
      let current = try memory.entries()
      let provenance = ProvenanceContext(actor: actor, date: date, refs: evidenceRefs)
      let changes = try markdownChanges(proposed, current: current, provenance: provenance.make(source))
      if source == .upkeep, let code = Self.upkeepRejection(current: current, proposed: proposed) {
        throw BotStoreError(code: code, message: "Upkeep would remove more than half of the notes")
      }
      return try prepare(changes, current: current, provenance: provenance, reason: reason)
    }
  }

  public static func upkeepRejection(current: [BotMemoryEntry], proposed: [BotMemoryMarkdownItem]) -> String? {
    let notes = current.filter { $0.kind == .note }
    let keptIds = Set(proposed.compactMap(\.recordId))
    let removed = notes.filter { note in
      guard let recordId = note.recordId else { return true }
      return !keptIds.contains(recordId)
    }
    return notes.count >= 4 && removed.count > notes.count / 2 ? "upkeep_removes_too_much" : nil
  }

  func storage(_ botId: String) -> BotMemoryStorage {
    BotMemoryStorage(memoryRoot: memoryRoot, memoryId: Self.memoryId(botId: botId), retention: limits.historyRetention)
  }

  func requireBot(_ botId: String) throws {
    guard try botStore.read({ try BotStore.requireMemoryBot(botId, in: $0) }) != nil else {
      throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
    }
  }

  // Session-store locking serializes bot writes across processes. Memory commits
  // precede the audit insert because the two stores use separate databases.
  func apply(
    botId: String, actor: String, evidenceRefs: [String],
    prepare: (BotMemoryStorage, String, SQLiteDatabase) throws -> BotMemoryWriteBatch
  ) throws -> BotMemoryChangeSet {
    try botStore.write { database in
      try BotStore.requireMemoryBot(botId, in: database)
      guard let actor = BotMemoryActor(rawValue: actor) else {
        throw BotStoreError(code: "memory_actor_invalid", message: "Invalid memory audit actor")
      }
      guard (2...1_000).contains(limits.historyRetention) else {
        throw BotMemoryError.limit("Memory history retention must be between 2 and 1000 versions")
      }
      let date = RoutineStore.timestamp(now())
      let memory = storage(botId)
      let batch = try prepare(memory, date, database)
      let entries = try memory.write(batch.mutations)
      let audit = batch.forceAudit || !entries.isEmpty || batch.ignoredInstructionChanges > 0
      let change = BotMemoryChangeSet(
        changeId: audit ? UUID().uuidString.lowercased() : "", botId: botId, actor: actor,
        reason: batch.reason, evidenceRefs: evidenceRefs, createdAt: date, entries: entries,
        redacted: batch.redacted, downgraded: batch.downgraded, ignoredInstructionChanges: batch.ignoredInstructionChanges
      )
      if audit {
        try BotStore.insertMemoryChange(change, in: database)
      }
      return change
    }
  }

  func validateCount(_ count: Int) throws {
    guard count <= limits.maxEntries else {
      throw BotMemoryError.limit("Bot memory exceeds \(limits.maxEntries) live entries")
    }
  }

  private func prepare(
    _ changes: [BotMemoryProposedChange], current: [BotMemoryEntry], provenance: ProvenanceContext, reason: String
  ) throws -> BotMemoryWriteBatch {
    let byId = entriesById(current)
    var seen: Set<Int64> = []
    var batch = BotMemoryWriteBatch(reason: reason)
    var count = current.count
    for change in changes {
      switch change {
      case let .add(entry):
        var entry = entry
        entry.recordId = nil
        entry.text = redactedText(entry.text, batch: &batch)
        let normalized = try normalize(entry, batch: &batch)
        batch.mutations.append(.save(normalized, removed: false))
        count += 1
      case let .update(recordId, text, topic, kind, source):
        let prior = try target(recordId, in: byId, seen: &seen)
        let redacted = redactedText(text, batch: &batch)
        if prior.kind == .instruction, !source.canEditInstructions {
          batch.ignoredInstructionChanges += 1
          continue
        }
        let entry = BotMemoryEntry(recordId: recordId, kind: kind, topic: topic, text: redacted, provenance: provenance.make(source))
        let normalized = try normalize(entry, batch: &batch)
        if normalized.text != prior.text || normalized.topic != prior.topic || normalized.kind != prior.kind {
          batch.mutations.append(.save(normalized, removed: false))
        }
      case let .remove(recordId, source):
        var prior = try target(recordId, in: byId, seen: &seen)
        if prior.kind == .instruction, !source.canEditInstructions {
          batch.ignoredInstructionChanges += 1
          continue
        }
        prior.provenance = provenance.make(source)
        batch.mutations.append(.save(prior, removed: true))
        count -= 1
      }
    }
    try validateCount(count)
    return batch
  }

  private func redactedText(_ text: String, batch: inout BotMemoryWriteBatch) -> String {
    let redacted = redact(text)
    batch.redacted = batch.redacted || redacted != text
    return BotMemoryMarkdown.normalizedText(redacted)
  }

  private func normalize(_ entry: BotMemoryEntry, batch: inout BotMemoryWriteBatch) throws -> BotMemoryEntry {
    var normalized = entry
    normalized.topic = entry.topic.isEmpty ? "general" : BotRecord.slug(from: entry.topic)
    if entry.kind == .instruction, !entry.provenance.source.canEditInstructions {
      normalized.kind = .note
      batch.downgraded = true
    }
    guard normalized.text.utf8.count <= limits.maxEntryBytes else {
      throw BotMemoryError.limit("Memory entry exceeds \(limits.maxEntryBytes) bytes")
    }
    return normalized
  }

  private func target(_ id: Int64, in entries: [Int64: BotMemoryEntry], seen: inout Set<Int64>) throws -> BotMemoryEntry {
    guard let entry = entries[id] else {
      throw BotStoreError(code: "memory_record_not_found", message: "Memory record \(id) was not found")
    }
    guard seen.insert(id).inserted else {
      throw BotMemoryError.conflict(id)
    }
    return entry
  }

  private func markdownChanges(
    _ proposed: [BotMemoryMarkdownItem], current: [BotMemoryEntry], provenance: BotMemoryProvenance
  ) throws -> [BotMemoryProposedChange] {
    let byId = entriesById(current)
    var kept: Set<Int64> = []
    var changes: [BotMemoryProposedChange] = []
    for item in proposed {
      if let id = item.recordId {
        guard let prior = byId[id] else {
          throw BotMemoryError.invalidMarkdown("Unknown memory record id \(id)")
        }
        kept.insert(id)
        if prior.text != item.text || prior.topic != item.topic || prior.kind != item.kind {
          changes.append(.update(recordId: id, text: item.text, topic: item.topic, kind: item.kind, source: provenance.source))
        }
      } else {
        changes.append(.add(.init(kind: item.kind, topic: item.topic, text: item.text, provenance: provenance)))
      }
    }
    for id in byId.keys.sorted() where !kept.contains(id) {
      changes.append(.remove(recordId: id, source: provenance.source))
    }
    return changes
  }

  private func entriesById(_ entries: [BotMemoryEntry]) -> [Int64: BotMemoryEntry] {
    Dictionary(uniqueKeysWithValues: entries.compactMap { entry in entry.recordId.map { ($0, entry) } })
  }

  private struct ProvenanceContext {
    let actor: String
    let date: String
    let refs: [String]

    func make(_ source: BotMemorySource) -> BotMemoryProvenance {
      BotMemoryProvenance(source: source, ref: refs.first, capturedAt: date, actor: actor)
    }
  }
}
