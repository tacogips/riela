import Foundation
import RielaMemory

struct BotMemoryWriteBatch {
  let reason: String
  var mutations: [BotMemoryMutation] = []
  var redacted = false
  var downgraded = false
  var ignoredInstructionChanges = 0
  var forceAudit = false
}

enum BotMemoryMutation {
  case save(BotMemoryEntry, removed: Bool)
  case restore(recordId: Int64, version: Int64, head: Int64, op: BotMemoryChangeOperation)
}

struct BotMemoryStorage {
  private static let workflowId = "bot"
  private static let removedTag = "state:removed"
  private static let kindPrefix = "kind:"
  private static let topicPrefix = "topic:"

  let store: RielaMemoryStore
  let memoryId: String
  let retention: Int

  init(memoryRoot: String, memoryId: String, retention: Int) {
    self.store = RielaMemoryStore(rootDirectory: memoryRoot)
    self.memoryId = memoryId
    self.retention = retention
  }

  func entries() throws -> [BotMemoryEntry] {
    // Search cannot express a negated tag. A query limit could hide live
    // entries behind tombstones, so apply the live-entry limit in the writer.
    let options = MemorySearchOptions(
      workflowId: Self.workflowId, tags: BotMemoryKind.allCases.map { Self.kindPrefix + $0.rawValue },
      limit: Int.max, maxPayloadBytes: Int.max
    )
    return try store.search(memoryId: memoryId, options: options).compactMap { record in
      try isRemoved(record) ? nil : entry(record)
    }
  }

  func isRemoved(_ record: MemoryRecord) -> Bool {
    record.tags.contains(Self.removedTag)
  }

  func entry(_ record: MemoryRecord) throws -> BotMemoryEntry {
    guard record.workflowId == Self.workflowId,
      let kindTag = record.tags.first(where: { $0.hasPrefix(Self.kindPrefix) }),
      let kind = BotMemoryKind(rawValue: String(kindTag.dropFirst(Self.kindPrefix.count))),
      let topic = record.tags.first(where: { $0.hasPrefix(Self.topicPrefix) })
    else {
      throw BotStoreError(code: "memory_record_invalid", message: "Invalid tags on memory record \(record.recordId)")
    }
    let payload = try JSONDecoder().decode(Payload.self, from: JSONEncoder().encode(record.payload))
    return .init(
      recordId: record.recordId, kind: kind, topic: String(topic.dropFirst(Self.topicPrefix.count)),
      text: payload.text, provenance: payload.provenance
    )
  }

  func head(recordId: Int64) throws -> MemoryEvolutionRevision {
    // Bot history appends versions. A detached head means the underlying
    // record was changed outside the audited writer.
    guard let head = try store.evolutionHistory(memoryId: memoryId, recordId: recordId, limit: 1).first,
      head.isHead == true
    else {
      throw BotMemoryError.conflict(recordId)
    }
    return head
  }

  func record(recordId: Int64, version: Int64) throws -> MemoryRecord {
    try store.recordVersion(memoryId: memoryId, recordId: recordId, version: version)
  }

  func write(_ mutations: [BotMemoryMutation]) throws -> [BotMemoryChangeEntry] {
    let priorVersions: [Int64?] = try mutations.map { mutation in
      switch mutation {
      case let .save(entry, _):
        return try entry.recordId.map { try head(recordId: $0).version }
      case let .restore(_, _, head, _):
        return head
      }
    }
    return try zip(mutations, priorVersions).map { mutation, fromVersion in
      let (id, operation) = try write(mutation)
      return .init(recordId: id, op: operation, fromVersion: fromVersion, toVersion: try head(recordId: id).version)
    }
  }

  private func write(_ mutation: BotMemoryMutation) throws -> (Int64, BotMemoryChangeOperation) {
    switch mutation {
    case let .save(entry, removed):
      var tags = [Self.kindPrefix + entry.kind.rawValue, Self.topicPrefix + entry.topic]
      if removed { tags.append(Self.removedTag) }
      let payload = try JSONDecoder().decode(
        MemoryJSONValue.self, from: JSONEncoder().encode(Payload(text: entry.text, provenance: entry.provenance))
      )
      if let id = entry.recordId {
        try store.update(
          memoryId: memoryId, recordId: id, workflowId: Self.workflowId, tags: tags, payload: payload, historyRetention: retention
        )
        return (id, removed ? .remove : .update)
      }
      let record = try store.save(
        memoryId: memoryId, workflowId: Self.workflowId, registeredAt: entry.provenance.capturedAt,
        tags: tags, payload: payload, historyRetention: retention
      )
      return (record.recordId, .add)
    case let .restore(id, version, head, op):
      try store.restoreRecordVersion(
        memoryId: memoryId, recordId: id, version: version, expectedHeadVersion: head, historyRetention: retention
      )
      return (id, op)
    }
  }

  private struct Payload: Codable {
    let text: String
    let provenance: BotMemoryProvenance
  }
}
