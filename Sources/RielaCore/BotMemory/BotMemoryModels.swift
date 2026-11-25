import RielaMemory

public enum BotMemoryKind: String, Codable, CaseIterable, Sendable {
  case instruction, note
}

public enum BotMemorySource: String, Codable, Sendable {
  case user, correction, review, upkeep, external

  var canEditInstructions: Bool { self == .user || self == .correction }
}

public struct BotMemoryProvenance: Codable, Equatable, Sendable {
  public let source: BotMemorySource
  public let ref: String?
  public let capturedAt: String
  public let actor: String

  public init(source: BotMemorySource, ref: String? = nil, capturedAt: String, actor: String) {
    self.source = source
    self.ref = ref
    self.capturedAt = capturedAt
    self.actor = actor
  }
}

public struct BotMemoryEntry: Codable, Equatable, Sendable {
  public var recordId: Int64?
  public var kind: BotMemoryKind
  public var topic: String
  public var text: String
  public var provenance: BotMemoryProvenance

  public init(recordId: Int64? = nil, kind: BotMemoryKind, topic: String, text: String, provenance: BotMemoryProvenance) {
    self.recordId = recordId
    self.kind = kind
    self.topic = topic
    self.text = text
    self.provenance = provenance
  }
}

public enum BotMemoryProposedChange: Equatable, Sendable {
  case add(BotMemoryEntry)
  case update(recordId: Int64, text: String, topic: String, kind: BotMemoryKind, source: BotMemorySource)
  case remove(recordId: Int64, source: BotMemorySource)
}

public enum BotMemoryChangeOperation: String, Codable, Sendable {
  case add, update, remove
}

public enum BotMemoryActor: String, Codable, Sendable {
  case user, cli, api, upkeep, feedback
}

public struct BotMemoryChangeEntry: Codable, Equatable, Sendable {
  public let recordId: Int64
  public let op: BotMemoryChangeOperation
  public let fromVersion: Int64?
  public let toVersion: Int64
}

public struct BotMemoryChangeSet: Codable, Equatable, Sendable {
  public let changeId: String
  public let botId: String
  public let actor: BotMemoryActor
  public let reason: String
  public let evidenceRefs: [String]
  public let createdAt: String
  public let entries: [BotMemoryChangeEntry]
  public let redacted: Bool
  public let downgraded: Bool
  public let ignoredInstructionChanges: Int
}

public struct BotMemoryEntryDiff: Codable, Equatable, Sendable {
  public let entry: BotMemoryChangeEntry
  public let changes: [VersionedHistoryDiffEntry]
}

public struct BotMemoryLimits: Sendable {
  public let maxEntryBytes: Int
  public let maxEntries: Int
  public let promptBlockBytes: Int
  public let historyRetention: Int

  public init(maxEntryBytes: Int = 4_000, maxEntries: Int = 500, promptBlockBytes: Int = 16_000, historyRetention: Int = 50) {
    self.maxEntryBytes = maxEntryBytes
    self.maxEntries = maxEntries
    self.promptBlockBytes = promptBlockBytes
    self.historyRetention = historyRetention
  }
}

enum BotMemoryError {
  static func invalidMarkdown(_ message: String) -> BotStoreError {
    BotStoreError(code: "memory_markdown_invalid", message: message)
  }

  static func limit(_ message: String) -> BotStoreError {
    BotStoreError(code: "memory_limit", message: message)
  }

  static func conflict(_ recordId: Int64) -> BotStoreError {
    BotStoreError(code: "memory_change_conflict", message: "Memory record \(recordId) has a different head version")
  }
}
