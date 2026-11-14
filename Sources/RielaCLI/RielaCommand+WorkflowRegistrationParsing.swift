extension RielaArgumentParser {
  func parseWorkflowRegister(
    _ arguments: [String],
    helpRequested: Bool
  ) throws -> RielaCommand {
    if helpRequested {
      return .workflow(.registerHelp)
    }
    let parsed = try ParsedWorkflowRegisterArguments.parseCLI(arguments)
    return .workflow(.register(WorkflowTemporaryRegistrationOptions(
      inputPath: parsed.inputPath,
      temporary: parsed.temporary,
      overwrite: parsed.overwrite,
      workingDirectory: parsed.workingDirectory,
      output: parsed.output
    )))
  }
}
