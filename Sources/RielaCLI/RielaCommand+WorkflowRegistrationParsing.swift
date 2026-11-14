extension RielaArgumentParser {
  func parseWorkflowRegister(
    _ arguments: [String],
    helpRequested: Bool
  ) throws -> RielaCommand {
    if helpRequested {
      return .workflow(.registerHelp)
    }
    let parsed = try ParsedWorkflowRegisterArguments.parseCLI(arguments)
    return .workflow(.register(WorkflowMutableRegistrationOptions(
      inputPath: parsed.inputPath,
      mutable: parsed.mutable,
      overwrite: parsed.overwrite,
      workingDirectory: parsed.workingDirectory,
      output: parsed.output
    )))
  }
}
