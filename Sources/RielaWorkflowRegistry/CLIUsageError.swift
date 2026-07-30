import Foundation

public struct CLIUsageError: Error, Equatable, Sendable {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }
}

func isSafeScopedWorkflowName(_ value: String) -> Bool {
  guard !value.isEmpty, value != ".", value != ".." else { return false }
  return value.unicodeScalars.allSatisfy { scalar in
    CharacterSet.alphanumerics.contains(scalar)
      || scalar == "-"
      || scalar == "_"
      || scalar == "."
  }
}
