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
  case undo
  case redo
  case `import`
  case export
  case prune
  case purgeHistory = "purge-history"
}

struct ParsedWorkflowDefinitionCommand {
  var operation: WorkflowDefinitionCommandOperation
  var workflowName: String
  var values: [String: [String]]
  var flags: Set<String>

  static let valueOptions: Set<String> = [
    "--node", "--limit", "--version", "--from", "--to", "--patch", "--from-file", "--reason",
    "--expected-version", "--evidence", "--actor", "--actor-kind", "--field", "--text", "--text-file",
    "--workflow-definition-dir", "--session-store", "--scope", "--working-dir", "--output", "--history-retention",
    "--expected-revision", "--keep"
  ]
  static let flagOptions: Set<String> = [
    "--authored", "--file", "--force", "--to-source", "--overwrite", "--all-workflows", "--dry-run", "--yes"
  ]

  init(_ arguments: [String]) throws {
    guard let first = arguments.first, let operation = WorkflowDefinitionCommandOperation(rawValue: first) else {
      throw WorkflowDefinitionCLIError.usage(
        "workflow definition requires history|show|diff|update|update-prompt|restore|undo|redo|import|export|prune|purge-history"
      )
    }
    // prune accepts --all-workflows in place of a workflow name
    let allWorkflows = operation == .prune && arguments.count > 1 && arguments[1] == "--all-workflows"
    guard allWorkflows || (arguments.count > 1 && !arguments[1].hasPrefix("--")) else {
      throw WorkflowDefinitionCLIError.usage("workflow definition \(operation.rawValue) requires a workflow name")
    }
    self.operation = operation
    workflowName = allWorkflows ? "" : arguments[1]
    var values = [String: [String]]()
    var flags = Set<String>()
    var index = allWorkflows ? 1 : 2
    while index < arguments.count {
      let token = arguments[index]
      if let separator = token.firstIndex(of: "="), Self.valueOptions.contains(String(token[..<separator])) {
        let option = String(token[..<separator])
        values[option, default: []].append(String(token[token.index(after: separator)...]))
        index += 1
      } else if Self.flagOptions.contains(token) {
        guard flags.insert(token).inserted else { throw WorkflowDefinitionCLIError.usage("duplicate option \(token)") }
        index += 1
      } else if Self.valueOptions.contains(token) {
        guard index + 1 < arguments.count,
              !arguments[index + 1].hasPrefix("--"),
              !Self.valueOptions.contains(arguments[index + 1]) else {
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
      if has("--file"), value("--from") != nil || value("--to") != nil {
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
    case .undo, .redo:
      try requireReason()
      if value("--expected-revision") != nil && value("--expected-version") != nil {
        throw WorkflowDefinitionCLIError.usage("--expected-revision and --expected-version cannot be combined")
      }
      if let revision = value("--expected-revision"), Int64(revision).map({ $0 >= 0 }) != true {
        throw WorkflowDefinitionCLIError.usage("--expected-revision must be a non-negative integer")
      }
    case .import:
      if has("--force") { try requireReason() }
    case .export:
      if (value("--to") != nil) == has("--to-source") { throw WorkflowDefinitionCLIError.usage("export requires exactly one of --to or --to-source") }
      if has("--to-source"), !has("--overwrite") { throw WorkflowDefinitionCLIError.usage("--to-source requires --overwrite") }
      if has("--overwrite"), !has("--to-source") { throw WorkflowDefinitionCLIError.usage("--overwrite requires --to-source") }
    case .prune, .purgeHistory:
      try validateRetentionOperation()
    }
    try allowCommon()
  }

  private func validateRetentionOperation() throws {
    switch operation {
    case .prune:
      guard let keep = value("--keep"), Int(keep).map({ $0 > 0 }) == true else {
        throw WorkflowDefinitionCLIError.usage("prune requires --keep with a positive integer")
      }
      if !has("--dry-run") { try requireReason() }
    case .purgeHistory:
      if !has("--dry-run") {
        try requireReason()
        guard has("--yes") else {
          throw WorkflowDefinitionCLIError.usage("purge-history deletes every earlier version and audit record; pass --yes to confirm or --dry-run to preview")
        }
      }
    default:
      break
    }
  }

  private func allowCommon() throws {
    let commonValues: Set<String> = ["--session-store", "--scope", "--working-dir", "--output"]
    let commonFlags = Set<String>()
    let allowedValues = Self.operationValueOptions[operation, default: []].union(commonValues)
    let allowedFlags = Self.operationFlags[operation, default: []].union(commonFlags)
    try allow(allowedValues, flags: allowedFlags)
    if let rawRetention = value("--history-retention"), Int(rawRetention).map({ (0...10_000).contains($0) }) != true {
      throw WorkflowDefinitionCLIError.usage("--history-retention must be between 0 and 10000")
    }
  }

  private static let operationValueOptions: [WorkflowDefinitionCommandOperation: Set<String>] = [
    .history: ["--node", "--limit"], .show: ["--version", "--node"], .diff: ["--from", "--to"],
    .update: ["--patch", "--from-file", "--reason", "--expected-version", "--evidence", "--actor", "--actor-kind", "--history-retention"],
    .updatePrompt: ["--node", "--field", "--text", "--text-file", "--reason", "--expected-version", "--evidence", "--actor", "--actor-kind", "--history-retention"],
    .restore: ["--version", "--reason", "--evidence", "--actor", "--history-retention"],
    .undo: ["--reason", "--expected-revision", "--expected-version", "--evidence", "--actor"],
    .redo: ["--reason", "--expected-revision", "--expected-version", "--evidence", "--actor"],
    .import: ["--workflow-definition-dir", "--reason", "--evidence", "--actor", "--history-retention"],
    .export: ["--version", "--to"],
    .prune: ["--keep", "--reason", "--actor"],
    .purgeHistory: ["--reason", "--actor"]
  ]
  private static let operationFlags: [WorkflowDefinitionCommandOperation: Set<String>] = [
    .show: ["--authored"], .diff: ["--file"], .update: ["--force"], .import: ["--force"],
    .export: ["--to-source", "--overwrite"],
    .prune: ["--all-workflows", "--dry-run"], .purgeHistory: ["--dry-run", "--yes"]
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
