import Foundation
import RielaCore

public struct WorkflowDefinitionCommandOptions: Equatable, Sendable {
  public var arguments: [String]

  public init(arguments: [String]) {
    self.arguments = arguments
  }
}

enum WorkflowDefinitionCommandOperation: String, CaseIterable {
  case history
  case show
  case diff
  case update
  case updatePrompt = "update-prompt"
  case restore
  case `import`
  case export
}

struct ParsedWorkflowDefinitionCommand {
  var operation: WorkflowDefinitionCommandOperation
  var workflowName: String
  var values: [String: [String]]
  var flags: Set<String>

  static let valueOptions: Set<String> = [
    "--node", "--limit", "--version", "--from", "--to", "--patch", "--from-file", "--reason",
    "--expected-version", "--evidence", "--actor", "--actor-kind", "--field", "--text", "--text-file",
    "--workflow-definition-dir", "--session-store", "--scope", "--working-dir", "--output"
  ]
  static let flagOptions: Set<String> = ["--authored", "--file", "--force", "--to-source", "--overwrite"]

  init(_ arguments: [String]) throws {
    guard let first = arguments.first, let operation = WorkflowDefinitionCommandOperation(rawValue: first) else {
      throw WorkflowDefinitionCLIError.usage("workflow definition requires history|show|diff|update|update-prompt|restore|import|export")
    }
    guard arguments.count > 1, !arguments[1].hasPrefix("--") else {
      throw WorkflowDefinitionCLIError.usage("workflow definition \(operation.rawValue) requires a workflow name")
    }
    self.operation = operation
    workflowName = arguments[1]
    var values = [String: [String]]()
    var flags = Set<String>()
    var index = 2
    while index < arguments.count {
      let token = arguments[index]
      if Self.flagOptions.contains(token) {
        guard flags.insert(token).inserted else { throw WorkflowDefinitionCLIError.usage("duplicate option \(token)") }
        index += 1
      } else if Self.valueOptions.contains(token) {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
          throw WorkflowDefinitionCLIError.usage("\(token) requires a value")
        }
        values[token, default: []].append(arguments[index + 1])
        index += 2
      } else {
        throw WorkflowDefinitionCLIError.usage("unknown option or argument '\(token)'")
      }
    }
    self.values = values
    self.flags = flags
    try validate()
  }

  func value(_ option: String) -> String? { values[option]?.last }
  func all(_ option: String) -> [String] { values[option] ?? [] }
  func has(_ flag: String) -> Bool { flags.contains(flag) }

  var workingDirectory: String { value("--working-dir") ?? FileManager.default.currentDirectoryPath }
  var scope: WorkflowScope { WorkflowScope(rawValue: value("--scope") ?? "auto") ?? .auto }
  var output: WorkflowOutputFormat { WorkflowOutputFormat(rawValue: value("--output") ?? "text") ?? .text }

  private func validate() throws {
    if let scope = value("--scope"), !["project", "user"].contains(scope) {
      throw WorkflowDefinitionCLIError.usage("--scope accepts only project or user")
    }
    if let output = value("--output"), !["text", "json"].contains(output) {
      throw WorkflowDefinitionCLIError.usage("--output accepts only text or json")
    }
    if let limit = value("--limit"), Int(limit).map({ $0 > 0 }) != true {
      throw WorkflowDefinitionCLIError.usage("--limit must be a positive integer")
    }
    switch operation {
    case .history:
      break
    case .show:
      if has("--authored"), value("--node") != nil { throw WorkflowDefinitionCLIError.usage("--authored cannot be combined with --node") }
    case .diff:
      if has("--file"), value("--from") != nil || has("--file"), value("--to") != nil {
        throw WorkflowDefinitionCLIError.usage("--file cannot be combined with --from or --to")
      }
    case .update:
      let hasPatch = value("--patch") != nil
      let hasFile = value("--from-file") != nil
      guard hasPatch != hasFile else { throw WorkflowDefinitionCLIError.usage("update requires exactly one of --patch or --from-file") }
      if has("--force"), !hasFile { throw WorkflowDefinitionCLIError.usage("--force requires --from-file") }
      try requireReason()
      try validateActorKind()
    case .updatePrompt:
      if (value("--text") != nil) == (value("--text-file") != nil) { throw WorkflowDefinitionCLIError.usage("update-prompt requires exactly one of --text or --text-file") }
      try requireReason()
      try validateActorKind()
      guard value("--node") != nil, value("--field") != nil else { throw WorkflowDefinitionCLIError.usage("update-prompt requires --node and --field") }
    case .restore:
      guard value("--version") != nil else { throw WorkflowDefinitionCLIError.usage("restore requires --version") }
      try requireReason()
    case .import:
      if has("--force") { try requireReason() }
    case .export:
      if (value("--to") != nil) == has("--to-source") { throw WorkflowDefinitionCLIError.usage("export requires exactly one of --to or --to-source") }
      if has("--to-source"), !has("--overwrite") { throw WorkflowDefinitionCLIError.usage("--to-source requires --overwrite") }
      if has("--overwrite"), !has("--to-source") { throw WorkflowDefinitionCLIError.usage("--overwrite requires --to-source") }
    }
    try allowCommon()
  }

  private func allowCommon() throws {
    let commonValues: Set<String> = ["--session-store", "--scope", "--working-dir", "--output"]
    let commonFlags = Set<String>()
    let allowedValues = Self.operationValueOptions[operation, default: []].union(commonValues)
    let allowedFlags = Self.operationFlags[operation, default: []].union(commonFlags)
    try allow(allowedValues, flags: allowedFlags)
  }

  private static let operationValueOptions: [WorkflowDefinitionCommandOperation: Set<String>] = [
    .history: ["--node", "--limit"], .show: ["--version", "--node"], .diff: ["--from", "--to"],
    .update: ["--patch", "--from-file", "--reason", "--expected-version", "--evidence", "--actor", "--actor-kind"],
    .updatePrompt: ["--node", "--field", "--text", "--text-file", "--reason", "--expected-version", "--evidence", "--actor", "--actor-kind"],
    .restore: ["--version", "--reason", "--evidence", "--actor"],
    .import: ["--workflow-definition-dir", "--reason", "--evidence", "--actor"],
    .export: ["--version", "--to"]
  ]
  private static let operationFlags: [WorkflowDefinitionCommandOperation: Set<String>] = [
    .show: ["--authored"], .diff: ["--file"], .update: ["--force"], .import: ["--force"],
    .export: ["--to-source", "--overwrite"]
  ]

  private func allow(_ names: Set<String>, flags allowedFlags: Set<String> = []) throws {
    for key in values.keys where !names.contains(key) { throw WorkflowDefinitionCLIError.usage("\(key) is not valid for \(operation.rawValue)") }
    for flag in flags where !allowedFlags.contains(flag) { throw WorkflowDefinitionCLIError.usage("\(flag) is not valid for \(operation.rawValue)") }
  }

  private func requireReason() throws {
    guard let reason = value("--reason"), !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowDefinitionCLIError(code: "reason_required", message: "--reason is required and must not be blank", isUsage: true)
    }
  }

  private func validateActorKind() throws {
    guard [nil, "cli", "improvementNode"].contains(value("--actor-kind")) else {
      throw WorkflowDefinitionCLIError.usage("--actor-kind accepts only cli or improvementNode")
    }
  }
}

struct WorkflowDefinitionCLIError: Error {
  var code: String
  var message: String
  var isUsage: Bool

  init(code: String = "usage_error", message: String, isUsage: Bool = true) {
    self.code = code
    self.message = message
    self.isUsage = isUsage
  }

  static func usage(_ message: String) -> Self { Self(message: message) }
}
