extension RielaArgumentParser {
  func parseWorkflowRegister(
    _ arguments: [String],
    helpRequested: Bool
  ) throws -> RielaCommand {
    if helpRequested {
      return .workflow(.registerHelp)
    }
    let parsed = try ParsedWorkflowRegisterArguments.parseCLI(arguments)
    if parsed.mutable && parsed.temporary {
      throw CLIUsageError("--mutable and --temporary are mutually exclusive")
    }
    return .workflow(.register(WorkflowMutableRegistrationOptions(
      inputPath: parsed.inputPath,
      mutable: parsed.mutable || parsed.temporary,
      usedDeprecatedTemporaryAlias: parsed.temporary,
      overwrite: parsed.overwrite,
      workingDirectory: parsed.workingDirectory,
      output: parsed.output
    )))
  }
}
