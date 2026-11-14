import Foundation

extension RielaArgumentParser {
  func parseSession(_ arguments: [String]) throws -> RielaCommand {
    guard let subcommand = arguments.first else {
      throw CLIUsageError("session command requires a subcommand")
    }
    switch subcommand {
    case "rerun":
      return try parseSessionRerun(arguments)
    case "resume":
      return try parseSessionResume(arguments)
    case "list":
      return .session(.list(try parseSessionDiscovery(subcommand: subcommand, arguments: arguments)))
    case "latest":
      return .session(.latest(try parseSessionDiscovery(subcommand: subcommand, arguments: arguments)))
    case "progress":
      return .session(.progress(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "health":
      return .session(.health(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "status":
      return .session(.status(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "continue":
      return .session(.continueSession(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "step-runs":
      return .session(.stepRuns(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "export":
      return .session(.export(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    case "logs":
      return .session(.logs(try parseSessionGeneric(subcommand: subcommand, arguments: arguments)))
    default:
      throw CLIUsageError("unsupported session subcommand '\(subcommand)'")
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
    guard arguments.count >= 3, !arguments[1].hasPrefix("--"), !arguments[2].hasPrefix("--") else {
      throw CLIUsageError("usage: riela session rerun <session-id> <step-id> [options]")
    }
    let parsed = try ParsedWorkflowOptions(Array(arguments.dropFirst(3)), allowRunOptions: true)
    try rejectRemoteSessionOptions(parsed)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    return .session(.rerun(SessionRerunOptions(
      sessionId: arguments[1],
      stepId: arguments[2],
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
    guard arguments.count >= 2, !arguments[1].hasPrefix("--") else {
      throw CLIUsageError("usage: riela session resume <session-id> [options]")
    }
    let parsed = try ParsedWorkflowOptions(Array(arguments.dropFirst(2)), allowRunOptions: true)
    try rejectRemoteSessionOptions(parsed)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    return .session(.resume(SessionResumeOptions(
      sessionId: arguments[1],
      output: parsed.output,
      scope: parsed.scope,
      workflowDefinitionDir: parsed.workflowDefinitionDir,
      workingDirectory: workingDirectory,
      mockScenarioPath: parsed.mockScenarioPath,
      sessionStore: parsed.sessionStore,
      maxSteps: parsed.maxSteps,
      variables: parsed.variables
    )))
  }

  private func parseSessionGeneric(subcommand: String, arguments: [String]) throws -> CLICommandOptions {
    let target = arguments.count >= 2 && !arguments[1].hasPrefix("--") ? arguments[1] : nil
    let optionStart = target == nil ? 1 : 2
    if target == nil {
      throw CLIUsageError("session \(subcommand) requires a session id")
    }
    return try parseGeneric(
      scope: "session",
      command: subcommand,
      target: target,
      arguments: Array(arguments.dropFirst(optionStart))
    )
  }

  private func parseSessionDiscovery(subcommand: String, arguments: [String]) throws -> CLICommandOptions {
    try parseGeneric(
      scope: "session",
      command: subcommand,
      target: nil,
      arguments: Array(arguments.dropFirst()),
      allowTableOutput: true
    )
  }

  private func rejectRemoteSessionOptions(_ parsed: ParsedWorkflowOptions) throws {
    if parsed.endpoint != nil || parsed.fromRegistry {
      throw CLIUsageError("remote session commands are not supported by the local CLI runner")
    }
  }
}
