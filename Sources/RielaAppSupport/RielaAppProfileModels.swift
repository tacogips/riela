#if os(macOS)
import Foundation

public struct RielaAppProfileName: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
  public static let `default` = RielaAppProfileName(Self.defaultRawValue)
  public static let defaultRawValue = "default"

  public var rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = Self.sanitizedRawValue(rawValue)
  }

  public var description: String {
    rawValue
  }

  public static func sanitizedRawValue(_ rawValue: String) -> String {
    let sanitized = sanitized(rawValue)
    return sanitized.isEmpty ? defaultRawValue : sanitized
  }

  private static func sanitized(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let mapped = trimmed.map { character in
      character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        ? character
        : "-"
    }
    return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
  }
}

public struct RielaAppProfileState: Codable, Equatable, Sendable {
  public var version: Int
  public var activeProfile: String

  public init(version: Int = 1, activeProfile: String = RielaAppProfileName.defaultRawValue) {
    self.version = version
    self.activeProfile = RielaAppProfileName(activeProfile).rawValue
  }

  public var activeProfileName: RielaAppProfileName {
    RielaAppProfileName(activeProfile)
  }
}

public struct RielaAppAssistantSettings: Codable, Equatable, Sendable {
  public var assistance: String

  public init(assistance: String = "") {
    self.assistance = assistance
  }

  public var normalizedAssistance: String {
    assistance.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isEmpty: Bool {
    normalizedAssistance.isEmpty
  }
}
#endif
