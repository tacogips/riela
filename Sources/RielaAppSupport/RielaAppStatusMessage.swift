#if os(macOS)
import Foundation

public struct RielaAppStatusMessage: Equatable, Sendable {
  public enum Severity: Equatable, Sendable {
    case info
    case error
  }

  public var severity: Severity
  public var text: String

  public init(severity: Severity, text: String) {
    self.severity = severity
    self.text = text
  }

  public static func classified(_ text: String) -> RielaAppStatusMessage {
    let lowercased = text.localizedLowercase
    let severity: Severity = lowercased.hasPrefix("failed")
      || lowercased.contains("could not")
      || lowercased.contains("already exists")
      || lowercased.contains("invalid")
      || lowercased.contains("is required")
      || lowercased.contains("cannot be removed")
      ? .error
      : .info
    return RielaAppStatusMessage(severity: severity, text: text)
  }
}

public struct SequencedRielaAppStatusMessage: Equatable, Sendable {
  public var sequence: Int
  public var message: RielaAppStatusMessage

  public init(sequence: Int, message: RielaAppStatusMessage) {
    self.sequence = sequence
    self.message = message
  }
}
#endif
