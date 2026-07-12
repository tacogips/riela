import Foundation
import RielaAddons
import RielaMemory

extension RielaArgumentParser {
  func parseWorkflowVersionCommand(_ arguments: [String]) throws -> WorkflowVersionCommandOptions? {
    switch arguments[1] {
    case "versions":
      guard arguments.count >= 3, !arguments[2].hasPrefix("--") else {
        throw CLIUsageError("workflow versions requires a workflow name")
      }
      return WorkflowVersionCommandOptions(
        kind: .list,
        workflowName: arguments[2],
        arguments: Array(arguments.dropFirst(3))
      )
    case "version":
      guard arguments.count >= 5 else {
        throw CLIUsageError("workflow version requires show|diff, a workflow name, and snapshot reference(s)")
      }
      switch arguments[2] {
      case "show":
        return WorkflowVersionCommandOptions(
          kind: .show,
          workflowName: arguments[3],
          firstReference: arguments[4],
          arguments: Array(arguments.dropFirst(5))
        )
      case "diff":
        guard arguments.count >= 6 else {
          throw CLIUsageError("workflow version diff requires a workflow name and two snapshot references")
        }
        return WorkflowVersionCommandOptions(
          kind: .diff,
          workflowName: arguments[3],
          firstReference: arguments[4],
          secondReference: arguments[5],
          arguments: Array(arguments.dropFirst(6))
        )
      default:
        throw CLIUsageError("unsupported workflow version operation '\(arguments[2])'")
      }
    case "restore":
      guard arguments.count >= 4, !arguments[2].hasPrefix("--"), !arguments[3].hasPrefix("--") else {
        throw CLIUsageError("workflow restore requires a workflow name and snapshot id")
      }
      return WorkflowVersionCommandOptions(
        kind: .restore,
        workflowName: arguments[2],
        firstReference: arguments[3],
        arguments: Array(arguments.dropFirst(4))
      )
    default:
      return nil
    }
  }

  func parseMemoryOptions(memoryId: String, tokens: [String]) throws -> MemoryCommandOptions {
    var workflowId: String?
    var allWorkflows = false
    var nodeId: String?
    var recordId: Int64?
    var payloadJSON: String?
    var payloadFile: String?
    var registeredAt: String?
    var matchPatterns: [String] = []
    var tags: [String] = []
    var relatedRecordIds: [Int64] = []
    var filePaths: [String] = []
    var clearFiles = false
    var sortOrder: MemoryValueSortOrder = .valueAsc
    var limit = 30
    var offset = 0
    var databaseRoot: String?
    var workingDirectory = FileManager.default.currentDirectoryPath
    var output: WorkflowOutputFormat = .jsonl
    var index = 0
    while index < tokens.count {
      let token = tokens[index]
      guard token.hasPrefix("-") else { throw CLIUsageError("unexpected positional argument '\(token)'") }
      if let value = inlineOptionValue(token, prefix: "--output=") {
        output = try parseOutputValue(value, allowTableOutput: false)
        index += 1
        continue
      }
      if let value = inlineOptionValue(token, prefix: "--sort=") {
        sortOrder = try parseMemoryValueSort(value)
        index += 1
        continue
      }
      let value: () throws -> String = {
        guard index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") else {
          throw CLIUsageError("\(token) requires a value")
        }
        index += 1
        return tokens[index]
      }
      switch token {
      case "--all-workflows": allWorkflows = true
      case "--workflow-id": workflowId = try value()
      case "--node-id": nodeId = try value()
      case "--record-id":
        guard let parsed = Int64(try value()), parsed > 0 else { throw CLIUsageError("--record-id must be a positive integer") }
        recordId = parsed
      case "--payload-json": payloadJSON = try value()
      case "--payload-file": payloadFile = try value()
      case "--registered-at": registeredAt = try value()
      case "--match", "-e": matchPatterns.append(try value())
      case "--tag": tags.append(try value())
      case "--related-id", "--related-record-id":
        guard let parsed = Int64(try value()), parsed > 0 else { throw CLIUsageError("\(token) must be a positive integer") }
        relatedRecordIds.append(parsed)
      case "--file", "--file-path": filePaths.append(try value())
      case "--clear-files": clearFiles = true
      case "--sort": sortOrder = try parseMemoryValueSort(try value())
      case "--limit":
        guard let parsed = Int(try value()), parsed > 0 else { throw CLIUsageError("--limit must be a positive integer") }
        limit = parsed
      case "--offset":
        guard let parsed = Int(try value()), parsed >= 0 else { throw CLIUsageError("--offset must be zero or a positive integer") }
        offset = parsed
      case "--database-root", "--memory-root": databaseRoot = try value()
      case "--working-dir", "--working-directory": workingDirectory = try value()
      case "--output": output = try parseOutputValue(try value(), allowTableOutput: false)
      default: throw CLIUsageError("unsupported memory option '\(token)'")
      }
      index += 1
    }
    return MemoryCommandOptions(
      memoryId: memoryId,
      workflowId: workflowId,
      allWorkflows: allWorkflows,
      nodeId: nodeId,
      recordId: recordId,
      payloadJSON: payloadJSON,
      payloadFile: payloadFile,
      registeredAt: registeredAt,
      matchPatterns: matchPatterns,
      tags: tags,
      relatedRecordIds: relatedRecordIds,
      filePaths: filePaths,
      clearFiles: clearFiles,
      sortOrder: sortOrder,
      limit: limit,
      offset: offset,
      databaseRoot: databaseRoot,
      workingDirectory: workingDirectory,
      output: output
    )
  }

  func parseScoped(kind: ScopedCommandKind, arguments: [String]) throws -> ScopedCommand {
    if kind == .callStep || kind == .workflowCall {
      guard arguments.count >= 3,
            !arguments[0].hasPrefix("--"),
            !arguments[1].hasPrefix("--"),
            !arguments[2].hasPrefix("--") else {
        throw CLIUsageError("\(kind.rawValue) requires <workflow-id> <workflow-run-id> <step-id>")
      }
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: arguments[0],
          target: arguments[1],
          arguments: Array(arguments.dropFirst(2))
        )
      )
    }
    let command = arguments.first?.hasPrefix("--") == false ? arguments.first : nil
    let targetIndex = command == nil ? 0 : 1
    let target = arguments.count > targetIndex && !arguments[targetIndex].hasPrefix("--") ? arguments[targetIndex] : nil
    let optionStart = target == nil ? targetIndex : targetIndex + 1
    return ScopedCommand(
      kind: kind,
      options: try parseGeneric(
        scope: kind.rawValue,
        command: command,
        target: target,
        arguments: Array(arguments.dropFirst(optionStart))
      )
    )
  }

  func parseValidate(target: String, tokens: [String]) throws -> WorkflowValidateOptions {
    let parsed = try ParsedWorkflowOptions(tokens)
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
    try rejectRemoteResolutionOptions(parsed, subcommand: "validate")
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowValidateOptions(
      workflowName: target,
      resolution: resolution,
      output: parsed.output,
      executable: parsed.executable,
      nodePatch: parsed.nodePatch
    )
  }

  func parseInspect(target: String, tokens: [String]) throws -> WorkflowInspectOptions {
    let parsed = try ParsedWorkflowOptions(tokens)
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
    try rejectRemoteResolutionOptions(parsed, subcommand: "inspect")
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowInspectOptions(
      workflowName: target,
      resolution: resolution,
      output: parsed.output,
      structure: parsed.structure
    )
  }

  func parseRun(target: String, tokens: [String]) throws -> WorkflowRunOptions {
    let parsed = try ParsedWorkflowOptions(tokens, allowRunOptions: true)
    if !parsed.fromRegistry { try rejectUnsafeScopedRunTarget(target, parsed: parsed) }
    let resolution = WorkflowResolutionOptions(
      workflowName: target,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    )
    return WorkflowRunOptions(
      target: target,
      resolution: resolution,
      variables: parsed.variablesReference,
      nodePatch: parsed.nodePatch,
      instance: parsed.instance,
      instanceScope: parsed.instanceScope,
      saveInstance: parsed.saveInstance,
      mockScenarioPath: parsed.mockScenarioPath,
      output: parsed.output,
      maxSteps: parsed.maxSteps,
      maxConcurrency: parsed.maxConcurrency,
      maxLoopIterations: parsed.maxLoopIterations,
      defaultTimeoutMs: parsed.defaultTimeoutMs,
      timeoutMs: parsed.timeoutMs,
      agentSilenceWarningMs: parsed.agentSilenceWarningMs,
      agentSilenceMonitorIntervalMs: parsed.agentSilenceMonitorIntervalMs,
      artifactRoot: parsed.artifactRoot,
      sessionStore: parsed.sessionStore,
      workingDirectory: resolution.workingDirectory,
      explicitWorkingDirectory: parsed.workingDirectory != nil,
      endpoint: parsed.endpoint,
      authToken: parsed.authToken,
      authTokenEnv: parsed.authTokenEnv,
      fromRegistry: parsed.fromRegistry,
      autoImprove: parsed.autoImprove,
      autoImprovePolicy: parsed.autoImprovePolicy
    )
  }

  private func rejectRemoteResolutionOptions(_ parsed: ParsedWorkflowOptions, subcommand: String) throws {
    if parsed.endpoint != nil || parsed.fromRegistry {
      throw CLIUsageError("remote workflow \(subcommand) is not supported by the local CLI runner")
    }
  }

  private func rejectUnsafeScopedWorkflowName(_ target: String, parsed: ParsedWorkflowOptions) throws {
    guard parsed.workflowDefinitionDir == nil,
          !isSafeScopedWorkflowName(target),
          !WorkflowPackageManifestValidator.isSafePackageName(target) else { return }
    throw CLIUsageError("invalid scoped workflow or package name '\(target)'")
  }

  private func rejectUnsafeScopedRunTarget(_ target: String, parsed: ParsedWorkflowOptions) throws {
    guard parsed.workflowDefinitionDir == nil,
          !isTemporaryWorkflowRunTarget(target, workingDirectory: parsed.workingDirectory) else { return }
    try rejectUnsafeScopedWorkflowName(target, parsed: parsed)
  }

  private func isTemporaryWorkflowRunTarget(_ target: String, workingDirectory: String?) -> Bool {
    if target.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { return true }
    let directory = URL(fileURLWithPath: workingDirectory ?? FileManager.default.currentDirectoryPath)
    let url = absoluteURL(target, relativeTo: directory)
    return FileManager.default.fileExists(atPath: url.path) && url.pathExtension == "json"
  }
}
