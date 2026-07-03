import Foundation
import RielaMemory

func parseOutputOnly(
  _ tokens: [String],
  allowTableOutput: Bool,
  defaultOutput: WorkflowOutputFormat = .jsonl
) throws -> WorkflowOutputFormat {
  var output = defaultOutput
  var index = 0
  while index < tokens.count {
    let token = tokens[index]
    if token == "--output" {
      guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
        throw CLIUsageError("--output requires a value")
      }
      guard let value = WorkflowOutputFormat(rawValue: tokens[index + 1]) else {
        throw CLIUsageError("invalid --output value '\(tokens[index + 1])'; expected text, json, jsonl, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, session list, session latest, package search, and package list")
      }
      output = value
      index += 2
      continue
    }
    if token.hasPrefix("--output=") {
      let raw = String(token.dropFirst("--output=".count))
      guard let value = WorkflowOutputFormat(rawValue: raw) else {
        throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, jsonl, or table")
      }
      if value == .table && !allowTableOutput {
        throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, session list, session latest, package search, and package list")
      }
      output = value
    }
    index += 1
  }
  return output
}

func inlineOptionValue(_ token: String, prefix: String) -> String? {
  guard token.hasPrefix(prefix) else {
    return nil
  }
  return String(token.dropFirst(prefix.count))
}

func parseOutputValue(_ raw: String, allowTableOutput: Bool) throws -> WorkflowOutputFormat {
  guard let value = WorkflowOutputFormat(rawValue: raw) else {
    throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, jsonl, or table")
  }
  if value == .table && !allowTableOutput {
    throw CLIUsageError("`--output table` is only supported for workflow list, workflow status, session list, session latest, package search, and package list")
  }
  return value
}

func parseMemoryValueSort(_ raw: String) throws -> MemoryValueSortOrder {
  guard let value = MemoryValueSortOrder(rawValue: raw) else {
    throw CLIUsageError("invalid --sort value '\(raw)'; expected value-asc or value-desc")
  }
  return value
}

func requireRunOption(_ token: String, allowRunOptions: Bool) throws {
  if !allowRunOptions {
    throw CLIUsageError("\(token) is supported only by workflow run")
  }
}

func readOptionValue(_ token: String, tokens: [String], index: inout Int) throws -> String {
  guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
    throw CLIUsageError("\(token) requires a value")
  }
  index += 1
  return tokens[index]
}

func positiveInt(_ token: String, _ raw: String) throws -> Int {
  guard let value = Int(raw), value > 0 else {
    throw CLIUsageError("\(token) requires a positive integer")
  }
  return value
}

func nonNegativeInt(_ token: String, _ raw: String) throws -> Int {
  guard let value = Int(raw), value >= 0 else {
    throw CLIUsageError("\(token) must be a non-negative integer")
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
