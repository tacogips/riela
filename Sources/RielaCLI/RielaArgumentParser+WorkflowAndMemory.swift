import Foundation
import RielaAddons
import RielaMemory

extension RielaArgumentParser {
  func parseWorkflowVersionCommand(
    subcommand: WorkflowClientSubcommand,
    arguments: [String]
  ) throws -> WorkflowVersionCommandOptions {
    switch subcommand {
    case .versions:
      let parsed = try ParsedWorkflowVersionsArguments.parseCLI(arguments)
      return WorkflowVersionCommandOptions(
        kind: .list,
        workflowName: parsed.workflowName,
        arguments: parsed.options
      )
    case .version:
      let family = try ParsedWorkflowVersionFamily.parseCLI(arguments)
      switch family.operation {
      case .show:
        let parsed = try ParsedWorkflowVersionShowArguments.parseCLI(family.remainder)
        return WorkflowVersionCommandOptions(
          kind: .show,
          workflowName: parsed.workflowName,
          firstReference: parsed.reference,
          arguments: parsed.options
        )
      case .diff:
        let parsed = try ParsedWorkflowVersionDiffArguments.parseCLI(family.remainder)
        return WorkflowVersionCommandOptions(
          kind: .diff,
          workflowName: parsed.workflowName,
          firstReference: parsed.firstReference,
          secondReference: parsed.secondReference,
          arguments: parsed.options
        )
      }
    case .restore:
      let parsed = try ParsedWorkflowRestoreArguments.parseCLI(arguments)
      return WorkflowVersionCommandOptions(
        kind: .restore,
        workflowName: parsed.workflowName,
        firstReference: parsed.snapshotId,
        arguments: parsed.options
      )
    case .package, .manifest, .list, .status, .register, .validate, .inspect, .usage, .run, .checkout, .create, .selfImprove:
      throw CLIUsageError("unsupported workflow version route '\(subcommand.rawValue)'")
    }
  }

  func parseMemoryOptions(memoryId: String, tokens: [String]) throws -> MemoryCommandOptions {
    try ParsedMemoryOptions(tokens).commandOptions(memoryId: memoryId)
  }

  func parseScoped(kind: ScopedCommandKind, arguments: [String]) throws -> ScopedCommand {
    if kind == .callStep || kind == .workflowCall {
      let parsed = try ParsedWorkflowCallArguments.parseCLI(arguments)
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: parsed.workflowId,
          target: parsed.workflowRunId,
          arguments: [parsed.stepId] + parsed.options
        )
      )
    }
    let parsed = try ParsedScopedCommandArguments.parseCLI(arguments)
    if kind == .graphql || kind == .gql, parsed.command != nil {
      let route = try ParsedGraphQLActionRoute.parseCLI(arguments)
      let invocation = try ParsedTargetAndOptions.parseCLI(route.remainder)
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: route.action.rawValue,
          target: invocation.target,
          arguments: invocation.options
        )
      )
    }
    if kind == .events, parsed.command != nil {
      let route = try ParsedEventsActionRoute.parseCLI(arguments)
      if route.action == .schedules {
        let schedules = try ParsedEventSchedulesRoute.parseCLI(arguments)
        let invocation = try ParsedTargetAndOptions.parseCLI(schedules.remainder)
        return ScopedCommand(
          kind: kind,
          options: try parseGeneric(
            scope: kind.rawValue,
            command: route.action.rawValue,
            target: schedules.action.rawValue,
            arguments: invocation.target.map { [$0] + invocation.options } ?? invocation.options
          )
        )
      }
      let invocation = try ParsedTargetAndOptions.parseCLI(route.remainder)
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: route.action.rawValue,
          target: invocation.target,
          arguments: invocation.options
        )
      )
    }
    if kind == .hook, parsed.command != nil {
      let route = try ParsedHookRoute.parseCLI(arguments)
      let invocation = try ParsedTargetAndOptions.parseCLI(route.remainder)
      return ScopedCommand(
        kind: kind,
        options: try parseGeneric(
          scope: kind.rawValue,
          command: route.vendor.rawValue,
          target: invocation.target,
          arguments: invocation.options
        )
      )
    }
    return ScopedCommand(
      kind: kind,
      options: try parseGeneric(
        scope: kind.rawValue,
        command: parsed.command,
        target: parsed.target,
        arguments: parsed.options
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
