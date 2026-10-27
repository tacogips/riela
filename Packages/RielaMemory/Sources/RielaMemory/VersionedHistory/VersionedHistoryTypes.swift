import Foundation

public enum VersionedHistorySQLValue: Equatable, Sendable {
  case text(String)
  case int(Int64)
  case blob(Data)
  case null
}

public protocol VersionedHistorySQL {
  func execute(_ sql: String, _ values: [VersionedHistorySQLValue]) throws
  func query(_ sql: String, _ values: [VersionedHistorySQLValue]) throws -> [[String: VersionedHistorySQLValue]]
}

public enum VersionedHistoryHeadStorage: Equatable, Sendable {
  case stored
  case external
}

public struct VersionedHistoryHead: Equatable, Sendable {
  public let key: String
  public let revision: Int64
  public let headVersion: Int64
  public let retainedGenerations: Int?

  public init(key: String, revision: Int64, headVersion: Int64, retainedGenerations: Int?) {
    self.key = key
    self.revision = revision
    self.headVersion = headVersion
    self.retainedGenerations = retainedGenerations
  }
}

public struct VersionedHistoryVersionInfo: Codable, Equatable, Sendable {
  public let version: Int64
  public let createdAt: String
  public let isHead: Bool
  public let detached: Bool
  public let encoding: String
  public let codec: String
  public let storedBytes: Int64
  public let byteCount: Int64
  public let sha256: String
}

public struct VersionedHistoryWriteResult: Equatable, Sendable {
  public enum Outcome: Equatable, Sendable { case written, unchanged }
  public let outcome: Outcome
  public let version: Int64
  public let revision: Int64
  public let droppedVersions: [Int64]
  public let freedBytes: Int64
}

public struct VersionedHistoryHeadMove: Equatable, Sendable {
  public let fromVersion: Int64
  public let toVersion: Int64
  public let revision: Int64
  public let value: Data
}

public enum VersionedHistoryError: Error, Equatable, Sendable {
  case staleRevision(expected: Int64, actual: Int64)
  case nothingToUndo(oldestRetained: Int64)
  case nothingToRedo
  case versionNotRetained(version: Int64, retained: [Int64], retainedGenerations: Int?)
  case historyCorrupt(String)
  case invalidRetention(Int)

  public var code: String {
    switch self {
    case .staleRevision: "stale_revision"
    case .nothingToUndo: "nothing_to_undo"
    case .nothingToRedo: "nothing_to_redo"
    case .versionNotRetained: "version_not_retained"
    case .historyCorrupt: "history_corrupt"
    case .invalidRetention: "invalid_retention"
    }
  }
}

public struct VersionedHistoryDiffEntry: Codable, Equatable, Sendable {
  public let path: String
  public let op: String
  public let beforeJSON: Data?
  public let afterJSON: Data?
  public let encoding: String?
  public let beforeSHA256: String?
  public let afterSHA256: String?
  public let beforeByteCount: Int64?
  public let afterByteCount: Int64?
  public let prefixByteCount: Int64?
  public let suffixByteCount: Int64?
}
