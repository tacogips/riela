import Foundation

extension RielaArgumentParser {
  func parseSession(_ arguments: [String]) throws -> RielaCommand {
    let family = try ParsedSessionFamily.parseCLI(arguments)
    switch family.subcommand {
    case .rerun:
      return try parseSessionRerun(family.remainder)
    case .resume:
      return try parseSessionResume(family.remainder)
    case .list:
      return .session(.list(try parseSessionDiscovery(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .latest:
      return .session(.latest(try parseSessionDiscovery(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .progress:
      return .session(.progress(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .health:
      return .session(.health(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .status:
      return .session(.status(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .continueSession:
      return .session(.continueSession(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .stepRuns:
      return .session(.stepRuns(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .export:
      return .session(.export(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    case .logs:
      return .session(.logs(try parseSessionGeneric(
        subcommand: family.subcommand.rawValue,
        arguments: family.remainder
      )))
    }
  }

  func parseGeneric(
    scope: String,
    command: String?,
    target: String? = nil,
    arguments: [String],
    allowTableOutput: Bool = false,
    defaultOutput: WorkflowOutputFormat = .jsonl
  ) throws -> CLICommandOptions {
    let output = try parseOutputOnly(arguments, allowTableOutput: allowTableOutput, defaultOutput: defaultOutput)
    return CLICommandOptions(scope: scope, command: command, target: target, arguments: arguments, output: output)
  }

  private func parseSessionRerun(_ arguments: [String]) throws -> RielaCommand {
    let route = try ParsedSessionRerunArguments.parseCLI(arguments)
    let parsed = try ParsedWorkflowOptions(route.options, allowRunOptions: true)
    try rejectRemoteSessionOptions(parsed)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    return .session(.rerun(SessionRerunOptions(
      sessionId: route.sessionId,
      stepId: route.stepId,
      output: parsed.output,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: parsed.mockScenarioPath,
      sessionStore: parsed.sessionStore,
      nestedSuperviser: parsed.nestedSuperviser
    )))
  }

  private func parseSessionResume(_ arguments: [String]) throws -> RielaCommand {
    let route = try ParsedSessionResumeArguments.parseCLI(arguments)
    let parsed = try ParsedWorkflowOptions(route.options, allowRunOptions: true)
    try rejectRemoteSessionOptions(parsed)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    return .session(.resume(SessionResumeOptions(
      sessionId: route.sessionId,
      output: parsed.output,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: parsed.mockScenarioPath,
      sessionStore: parsed.sessionStore,
      maxSteps: parsed.maxSteps,
      variables: parsed.variablesReference
    )))
  }

  private func parseSessionGeneric(subcommand: String, arguments: [String]) throws -> CLICommandOptions {
    let route = try ParsedTargetAndOptions.parseCLI(arguments)
    guard let target = route.target else {
      throw CLIUsageError("session \(subcommand) requires a session id")
    }
    return try parseGeneric(
      scope: "session",
      command: subcommand,
      target: target,
      arguments: route.options
    )
  }

  private func parseSessionDiscovery(subcommand: String, arguments: [String]) throws -> CLICommandOptions {
    try parseGeneric(
      scope: "session",
      command: subcommand,
      target: nil,
      arguments: arguments,
      allowTableOutput: true
    )
  }

  private func rejectRemoteSessionOptions(_ parsed: ParsedWorkflowOptions) throws {
    if parsed.endpoint != nil || parsed.fromRegistry {
      throw CLIUsageError("remote session commands are not supported by the local CLI runner")
    }
  }
}
