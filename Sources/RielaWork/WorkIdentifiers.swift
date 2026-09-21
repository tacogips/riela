import Foundation

/// Shared shape of the Work Runtime's string-backed identifiers. Each kind
/// carries its own prefix so an identifier is self-describing in a log line,
/// an evidence edge, or a SQLite row.
public protocol WorkIdentifier:
  RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible
where RawValue == String {
  /// Lowercase kebab prefix, without the trailing hyphen.
  static var prefix: String { get }
  init(_ rawValue: String)
}

public extension WorkIdentifier {
  init(_ rawValue: String) {
    self.init(rawValue: rawValue)!
  }

  /// A fresh identifier: `<prefix>-<lowercase uuid>`.
  static func generate() -> Self {
    Self("\(prefix)-\(UUID().uuidString.lowercased())")
  }

  var description: String { rawValue }
}

public struct IntentID: WorkIdentifier {
  public static let prefix = "intent"
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct TaskID: WorkIdentifier {
  public static let prefix = "task"
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct AttemptID: WorkIdentifier {
  public static let prefix = "attempt"
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct DecisionID: WorkIdentifier {
  public static let prefix = "decision"
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct EvidenceID: WorkIdentifier {
  public static let prefix = "evidence"
  public var rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }
}
