import Foundation
import RielaMemory

extension BotMemoryWriter {
  public func history(botId: String, limit: Int = 50) throws -> [BotMemoryChangeSet] {
    try requireBot(botId)
    return try botStore.memoryChanges(botId: botId, limit: limit)
  }

  public func diff(botId: String, changeId: String) throws -> [BotMemoryEntryDiff] {
    try requireBot(botId)
    guard let change = try botStore.memoryChange(changeId: changeId), change.botId == botId else {
      throw changeNotFound(botId)
    }
    let memory = storage(botId)
    return try change.entries.map { entry in
      let changes: [VersionedHistoryDiffEntry]
      if let fromVersion = entry.fromVersion {
        changes = try memory.store.recordDiff(
          memoryId: memory.memoryId, recordId: entry.recordId, fromVersion: fromVersion, toVersion: entry.toVersion
        )
      } else {
        let added = try memory.record(recordId: entry.recordId, version: entry.toVersion)
        changes = VersionedHistoryDiff.diff(before: Data("{}".utf8), after: try JSONEncoder().encode(added))
      }
      return BotMemoryEntryDiff(entry: entry, changes: changes)
    }
  }

  @discardableResult
  public func undo(botId: String, changeId: String? = nil, actor: String = "user") throws -> BotMemoryChangeSet {
    try apply(botId: botId, actor: actor, evidenceRefs: []) { memory, _, database in
      let target: BotMemoryChangeSet?
      if let changeId {
        target = try BotStore.memoryChange(changeId: changeId, in: database)
      } else {
        target = try BotStore.memoryChanges(botId: botId, limit: 1, in: database).first
      }
      guard let target, target.botId == botId else { throw changeNotFound(botId) }
      return try prepareUndo(target, memory: memory)
    }
  }

  private func prepareUndo(_ target: BotMemoryChangeSet, memory: BotMemoryStorage) throws -> BotMemoryWriteBatch {
    var batch = BotMemoryWriteBatch(reason: "undo:\(target.changeId)", forceAudit: true)
    var count = try memory.entries().count
    for entry in target.entries {
      let head = try memory.head(recordId: entry.recordId)
      guard head.version == entry.toVersion, head.revision == entry.toVersion else {
        throw BotMemoryError.conflict(entry.recordId)
      }
      let current = try memory.record(recordId: entry.recordId, version: head.version)
      let wasLive = memory.isRemoved(current) ? 0 : 1
      if let fromVersion = entry.fromVersion {
        let restored = try memory.record(recordId: entry.recordId, version: fromVersion)
        let removed = memory.isRemoved(restored)
        if !removed, try memory.entry(restored).text.utf8.count > limits.maxEntryBytes {
          throw BotMemoryError.limit("Restored memory entry exceeds \(limits.maxEntryBytes) bytes")
        }
        count += (removed ? 0 : 1) - wasLive
        batch.mutations.append(.restore(recordId: entry.recordId, version: fromVersion, head: head.version, op: removed ? .remove : .update))
      } else {
        count -= wasLive
        batch.mutations.append(.save(try memory.entry(current), removed: true))
      }
    }
    try validateCount(count)
    return batch
  }

  private func changeNotFound(_ botId: String) -> BotStoreError {
    BotStoreError(code: "memory_change_not_found", message: "Memory change was not found for bot '\(botId)'")
  }
}
