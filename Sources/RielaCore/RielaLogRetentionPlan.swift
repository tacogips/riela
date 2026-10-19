import Foundation

public struct RielaLogFileEntry: Equatable, Sendable {
  public enum Kind: String, Sendable {
    case regular
    case symlink
    case directory
    case other
  }

  public var name: String
  public var kind: Kind
  public var size: Int64
  public var modifiedAt: Date
  public var device: UInt64
  public var inode: UInt64

  public init(name: String, kind: Kind, size: Int64, modifiedAt: Date, device: UInt64, inode: UInt64) {
    self.name = name
    self.kind = kind
    self.size = size
    self.modifiedAt = modifiedAt
    self.device = device
    self.inode = inode
  }
}

public struct RielaLogRetentionPlan: Equatable, Sendable {
  public static let graceInterval: TimeInterval = 86_400

  public var selected: [RielaLogFileEntry]
  public var protected: [String: Int]
  public var beforeBytes: Int64
  public var projectedRemainingBytes: Int64
  public var capAchieved: Bool
  public var workLimitReached: Bool

  public static func make(entries: [RielaLogFileEntry], now: Date, maxAge: TimeInterval?, maxBytes: Int64?,
                          removalLimit: Int = 1000) throws -> Self {
    let validAge = maxAge.map { $0 > 0 && $0 <= 36_500 * 86_400 } ?? true
    let validBytes = maxBytes.map { $0 >= 1 && $0 <= (1 << 50) } ?? true
    guard maxAge != nil || maxBytes != nil, validAge, validBytes, removalLimit >= 1,
          entries.allSatisfy({ $0.size >= 0 }) else {
      throw TerminalRetentionPlanError.invalidPolicyOrMetadata
    }

    var managed: [RielaLogFileEntry] = []
    var protected: [String: Int] = [:]
    for entry in entries {
      let reason: String?
      switch entry.kind {
      case .symlink: reason = "symlink"
      case .directory, .other: reason = "notRegularFile"
      case .regular: reason = entry.name.hasPrefix(".") ? "hidden" : nil
      }
      if let reason {
        protected[reason, default: 0] += 1
      } else {
        managed.append(entry)
        if now.timeIntervalSince(entry.modifiedAt) < graceInterval {
          protected["withinGraceWindow", default: 0] += 1
        }
      }
    }

    var before: Int64 = 0
    for entry in managed {
      let sum = before.addingReportingOverflow(entry.size)
      guard !sum.overflow else { throw TerminalRetentionPlanError.invalidPolicyOrMetadata }
      before = sum.partialValue
    }
    let candidates = managed.filter { now.timeIntervalSince($0.modifiedAt) >= graceInterval }.sorted {
      $0.modifiedAt == $1.modifiedAt ? $0.name < $1.name : $0.modifiedAt < $1.modifiedAt
    }
    var remaining = before
    var selected: [RielaLogFileEntry] = []
    var workLimitReached = false
    let cutoff = maxAge.map { now.addingTimeInterval(-$0) }
    for entry in candidates {
      let shouldSelect = (cutoff.map { entry.modifiedAt <= $0 } ?? false) ||
        (maxBytes.map { remaining > $0 } ?? false)
      guard shouldSelect else { continue }
      guard selected.count < removalLimit else { workLimitReached = true; break }
      selected.append(entry)
      remaining -= entry.size
    }
    return .init(selected: selected, protected: protected, beforeBytes: before,
      projectedRemainingBytes: remaining, capAchieved: maxBytes.map { remaining <= $0 } ?? true,
      workLimitReached: workLimitReached)
  }
}
