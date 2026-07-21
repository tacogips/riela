import Foundation
import ArgumentParser

private let tableOutputSupportMessage = [
  "`--output table` is only supported for workflow list, workflow status,",
  "session list, session latest, package search, package list, node search,",
  "node list, note list, note search, and note notebook list"
].joined(separator: " ")

private struct ParsedOutputProjection: RielaClientFamilyArguments {
  @Option(name: .customLong("output")) var outputs: [String] = []
  @Argument(parsing: .allUnrecognized) var remaining: [String] = []
}

func argumentParserUsageMessage(_ message: String) -> String {
  if message.hasPrefix("Unknown option ") {
    return message.prefix(1).lowercased() + message.dropFirst()
  }
  let missingValuePrefix = "Missing value for '"
  if message.hasPrefix(missingValuePrefix) {
    let remainder = message.dropFirst(missingValuePrefix.count)
    if let separator = remainder.firstIndex(of: " ") {
      return "\(remainder[..<separator]) requires a value"
    }
  }
  return message
}

func parseOutputOnly(
  _ tokens: [String],
  allowTableOutput: Bool,
  defaultOutput: WorkflowOutputFormat = .jsonl
) throws -> WorkflowOutputFormat {
  let outputTokens = tokens.filter { $0 != "--help" && $0 != "-h" }
  let parsed = try ParsedOutputProjection.parseCLI(outputTokens)
  guard let raw = parsed.outputs.last else {
    return defaultOutput
  }
  return try parseOutputValue(raw, allowTableOutput: allowTableOutput)
}

func parseOutputValue(_ raw: String, allowTableOutput: Bool) throws -> WorkflowOutputFormat {
  guard let value = WorkflowOutputFormat(rawValue: raw) else {
    throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, jsonl, or table")
  }
  if value == .table && !allowTableOutput {
    throw CLIUsageError(tableOutputSupportMessage)
  }
  return value
}

func isSafeScopedWorkflowName(_ value: String) -> Bool {
  let scalars = Array(value.unicodeScalars)
  guard (1...64).contains(scalars.count), let first = scalars.first, isASCIIAlphaNumeric(first) else {
    return false
  }
  return scalars.allSatisfy { scalar in
    isASCIIAlphaNumeric(scalar) || scalar == "-" || scalar == "_"
  }
}

func isASCIIAlphaNumeric(_ scalar: UnicodeScalar) -> Bool {
  let value = scalar.value
  return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
}
