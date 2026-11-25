import RielaCore

extension AskCommands {
  func runToolServer(arguments: [String]) async -> CLICommandResult {
    do {
      try await AskToolServer.run(arguments: arguments)
      return CLICommandResult(exitCode: .success)
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message)
    } catch let error as AskError {
      return CLICommandResult(exitCode: .failure, stderr: error.description)
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "ask_io_failure: Ask tool server failed")
    }
  }
}
