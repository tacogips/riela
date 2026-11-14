import Foundation
import RielaCore

public struct InstanceCommandRunner: Sendable {
  public var resolver: any WorkflowBundleResolving
  public var jsonLoader: JSONReferenceLoader

  public init(
    resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
    jsonLoader: JSONReferenceLoader = JSONReferenceLoader()
  ) {
    self.resolver = resolver
    self.jsonLoader = jsonLoader
  }

  public func run(_ options: CLICommandOptions) -> CLICommandResult {
    do {
      switch options.command {
      case "list":
        return try list(options)
      case "show":
        return try show(options)
      case "create":
        return try create(options)
      case "update":
        return try update(options)
      case "remove":
        return try remove(options)
      default:
        throw CLIUsageError("unsupported instance subcommand '\(options.command ?? "")'")
      }
    } catch let error as CLIUsageError {
      return failure(options: options, exitCode: .usage, error: error.message)
    } catch {
      return failure(options: options, exitCode: .failure, error: instanceErrorDescription(error))
    }
  }

  private func list(_ options: CLICommandOptions) throws -> CLICommandResult {
    let parsed = try InstanceCommandOptions(options.arguments, defaultScope: .all, defaultOutput: options.output)
    let stores = ScopedWorkflowInstanceStore(workingDirectory: parsed.workingDirectory)
    let records = try stores.listRecords(scope: parsed.scope, workflowId: parsed.workflowId)
      .map { InstanceRecord(scope: $0.0, instance: $0.1) }
    return CLICommandResult(exitCode: .success, stdout: try render(records, output: parsed.output))
  }

  private func show(_ options: CLICommandOptions) throws -> CLICommandResult {
    guard let identity = options.target else {
      throw CLIUsageError("instance show requires an instance identity")
    }
    let parsed = try InstanceCommandOptions(options.arguments, defaultScope: nil, defaultOutput: options.output)
    let stores = ScopedWorkflowInstanceStore(workingDirectory: parsed.workingDirectory)
    guard let resolved = try stores.find(identity: identity, workflowId: parsed.workflowId, scope: parsed.scope) else {
      throw WorkflowInstanceStoreError.notFound(identity)
    }
    let record = InstanceRecord(scope: resolved.0.rawValue, instance: resolved.1)
    return CLICommandResult(exitCode: .success, stdout: try render(record, output: parsed.output))
  }

  private func create(_ options: CLICommandOptions) throws -> CLICommandResult {
    guard let identity = options.target else {
      throw CLIUsageError("instance create requires an instance identity")
    }
    let parsed = try InstanceCommandOptions(options.arguments, defaultScope: .project, defaultOutput: options.output)
    guard let workflowName = parsed.workflowId else {
      throw CLIUsageError("instance create requires --workflow <id>")
    }
    let resolvedWorkflow = try resolveWorkflow(
      workflowName: workflowName,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory
    )
    let instance = try materializedInstance(
      identity: identity,
      workflowId: resolvedWorkflow.workflow.workflowId,
      sourceIdentity: workflowName,
      base: nil,
      parsed: parsed,
      nodePayloads: resolvedWorkflow.nodePayloads
    )
    let stores = ScopedWorkflowInstanceStore(workingDirectory: parsed.workingDirectory)
    try stores.save(instance, scope: parsed.scope)
    return CLICommandResult(exitCode: .success, stdout: try render(
      InstanceRecord(scope: parsed.scope.rawValue, instance: instance),
      output: parsed.output
    ))
  }

  private func update(_ options: CLICommandOptions) throws -> CLICommandResult {
    guard let identity = options.target else {
      throw CLIUsageError("instance update requires an instance identity")
    }
    let parsed = try InstanceCommandOptions(options.arguments, defaultScope: .project, defaultOutput: options.output)
    let stores = ScopedWorkflowInstanceStore(workingDirectory: parsed.workingDirectory)
    guard let existing = try stores.find(identity: identity, workflowId: parsed.workflowId, scope: parsed.scope) else {
      throw WorkflowInstanceStoreError.notFound(identity)
    }
    let resolvedWorkflow = try resolveWorkflow(
      workflowName: parsed.workflowId ?? existing.1.workflowId,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory
    )
    let updated = try materializedInstance(
      identity: identity,
      workflowId: existing.1.workflowId,
      sourceIdentity: existing.1.sourceIdentity,
      base: existing.1,
      parsed: parsed,
      nodePayloads: resolvedWorkflow.nodePayloads
    )
    try stores.save(updated, scope: existing.0)
    return CLICommandResult(exitCode: .success, stdout: try render(
      InstanceRecord(scope: existing.0.rawValue, instance: updated),
      output: parsed.output
    ))
  }

  private func remove(_ options: CLICommandOptions) throws -> CLICommandResult {
    guard let identity = options.target else {
      throw CLIUsageError("instance remove requires an instance identity")
    }
    let parsed = try InstanceCommandOptions(options.arguments, defaultScope: .project, defaultOutput: options.output)
    let stores = ScopedWorkflowInstanceStore(workingDirectory: parsed.workingDirectory)
    try stores.remove(identity: identity, workflowId: parsed.workflowId, scope: parsed.scope)
    let result = InstanceRemovalResult(identity: identity, scope: parsed.scope.rawValue, removed: true)
    return CLICommandResult(exitCode: .success, stdout: try render(result, output: parsed.output))
  }

  private func resolveWorkflow(
    workflowName: String,
    workflowDefinitionDir: String?,
    workingDirectory: String
  ) throws -> ResolvedWorkflowBundle {
    try resolver.resolve(WorkflowResolutionOptions(
      workflowName: workflowName,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory
    ))
  }

  private func materializedInstance(
    identity: String,
    workflowId: String,
    sourceIdentity: String?,
    base: WorkflowInstanceDefinition?,
    parsed: InstanceCommandOptions,
    nodePayloads: [String: AgentNodePayload]
  ) throws -> WorkflowInstanceDefinition {
    let nodePatches = try parsed.nodePatch.map {
      try WorkflowInstanceResolver.nodePatches(from: jsonLoader.object(from: $0, workingDirectory: parsed.workingDirectory))
    }
    let defaultVariables = try parsed.variables.map {
      try jsonLoader.object(from: $0, workingDirectory: parsed.workingDirectory)
    }
    var configuration = base?.configuration ?? WorkflowInstanceConfiguration()
    if parsed.didSetWorkingDirectory {
      configuration.workingDirectory = parsed.workingDirectoryOverride
    }
    if parsed.didSetEnvironmentFilePath {
      configuration.environmentFilePath = parsed.environmentFilePath
    }
    for (key, value) in parsed.environmentVariables {
      configuration.environmentVariables[key] = value
    }
    if let defaultVariables {
      for (key, value) in defaultVariables {
        configuration.defaultVariables[key] = value
      }
    }
    if let nodePatches {
      for (key, value) in nodePatches {
        configuration.nodePatches[key] = value
      }
    }
    _ = try WorkflowInstanceResolver.resolve(
      workflowId: workflowId,
      base: WorkflowInstanceDefinition(identity: identity, workflowId: workflowId, configuration: configuration),
      nodePayloads: nodePayloads
    )
    return WorkflowInstanceDefinition(
      identity: identity,
      workflowId: workflowId,
      sourceIdentity: sourceIdentity,
      displayName: parsed.displayName ?? base?.displayName,
      configuration: configuration
    )
  }

  private func render(_ records: [InstanceRecord], output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(InstanceListResult(instances: records))
    case .text, .table:
      guard !records.isEmpty else {
        return "No instances.\n"
      }
      var lines = ["SCOPE\tWORKFLOW\tIDENTITY\tDISPLAY NAME"]
      lines.append(contentsOf: records.map {
        "\($0.scope)\t\($0.instance.workflowId)\t\($0.instance.identity)\t\($0.instance.displayName ?? "")"
      })
      return lines.joined(separator: "\n") + "\n"
    }
  }

  private func render<T: Encodable>(_ value: T, output: WorkflowOutputFormat) throws -> String {
    switch output {
    case .json, .jsonl:
      return try jsonString(value)
    case .text, .table:
      return try jsonString(value)
    }
  }

  private func failure(options: CLICommandOptions, exitCode: CLIExitCode, error: String) -> CLICommandResult {
    guard options.output.isStructured else {
      return CLICommandResult(exitCode: exitCode, stderr: error)
    }
    let result = InstanceFailureResult(error: error, exitCode: exitCode.rawValue)
    return CLICommandResult(
      exitCode: exitCode,
      stdout: (try? jsonString(result)) ?? #"{"error":"failed to encode instance failure","exitCode":1}"# + "\n"
    )
  }
}

private struct InstanceCommandOptions {
  var workflowId: String?
  var scope: WorkflowInstanceScope
  var output: WorkflowOutputFormat
  var variables: String?
  var nodePatch: String?
  var workingDirectory: String
  var workflowDefinitionDir: String?
  var workingDirectoryOverride: String?
  var didSetWorkingDirectory = false
  var environmentFilePath: String?
  var didSetEnvironmentFilePath = false
  var environmentVariables: [String: String] = [:]
  var displayName: String?

  init(
    _ tokens: [String],
    defaultScope: WorkflowInstanceScope?,
    defaultOutput: WorkflowOutputFormat
  ) throws {
    scope = defaultScope ?? .all
    output = defaultOutput
    workingDirectory = FileManager.default.currentDirectoryPath
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      func value() throws -> String {
        guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
          throw CLIUsageError("\(token) requires a value")
        }
        index += 1
        return tokens[index]
      }
      switch token {
      case "--workflow":
        workflowId = try value()
      case "--scope", "--instance-scope":
        let raw = try value()
        guard let parsedScope = WorkflowInstanceScope(rawValue: raw),
              defaultScope == .all || parsedScope != .all else {
          throw CLIUsageError("invalid \(token) value '\(raw)'; expected project or user")
        }
        scope = parsedScope
      case "--output":
        let raw = try value()
        guard let parsedOutput = WorkflowOutputFormat(rawValue: raw) else {
          throw CLIUsageError("invalid --output value '\(raw)'; expected text, json, jsonl, or table")
        }
        output = parsedOutput
      case "--variables":
        variables = try value()
      case "--node-patch":
        nodePatch = try value()
      case "--working-dir", "--working-directory":
        workingDirectoryOverride = try value()
        didSetWorkingDirectory = true
      case "--cwd":
        workingDirectory = try value()
      case "--workflow-definition-dir":
        workflowDefinitionDir = try value()
      case "--env-file":
        environmentFilePath = try value()
        didSetEnvironmentFilePath = true
      case "--env":
        let assignment = try value()
        guard let separator = assignment.firstIndex(of: "="), separator != assignment.startIndex else {
          throw CLIUsageError("--env expects KEY=VALUE")
        }
        let key = String(assignment[..<separator])
        let value = String(assignment[assignment.index(after: separator)...])
        environmentVariables[key] = value
      case "--display-name":
        displayName = try value()
      default:
        throw CLIUsageError("unsupported instance option '\(token)'")
      }
      index += 1
    }
  }
}

private struct InstanceRecord: Codable, Equatable, Sendable {
  var scope: String
  var instance: WorkflowInstanceDefinition
}

private struct InstanceListResult: Codable, Equatable, Sendable {
  var instances: [InstanceRecord]
}

private struct InstanceRemovalResult: Codable, Equatable, Sendable {
  var identity: String
  var scope: String
  var removed: Bool
}

private struct InstanceFailureResult: Codable, Equatable, Sendable {
  var error: String
  var exitCode: Int32
}

private func instanceErrorDescription(_ error: Error) -> String {
  switch error {
  case let error as WorkflowInstanceStoreError:
    switch error {
    case let .duplicateIdentity(identity):
      return "duplicate instance identity: \(identity)"
    case let .notFound(identity):
      return "instance not found: \(identity)"
    case let .ambiguousIdentity(identity, workflows):
      return "instance identity '\(identity)' is ambiguous across workflows: \(workflows.joined(separator: ", "))"
    case let .unsupportedScope(scope):
      return "unsupported instance scope: \(scope)"
    case let .invalidIdentity(identity):
      return "invalid instance identity: \(identity)"
    case let .io(message):
      return message
    }
  case let error as WorkflowInstanceResolutionError:
    switch error {
    case let .nodePatchMustBeObject(nodeId):
      return "node patch for '\(nodeId)' must be an object"
    case let .unknownNodeId(nodeId):
      return "unknown node id in instance node patch: \(nodeId)"
    case let .unsupportedField(field):
      return "unsupported node patch field: \(field)"
    case let .invalidFieldValue(field):
      return "invalid node patch field value: \(field)"
    case let .modelChangeFrozen(nodeId):
      return "node '\(nodeId)' has modelFreeze enabled"
    }
  default:
    return "\(error)"
  }
}
