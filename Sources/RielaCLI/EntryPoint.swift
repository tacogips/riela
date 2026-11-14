import Foundation

@main
struct RielaSwiftCLI {
  static func main() async {
    let app = RielaCLIApplication(
      runCommand: WorkflowRunCommand(jsonlRecordWriter: { line in
        FileHandle.standardOutput.write(Data(line.utf8))
      })
    )
    let arguments = Array(CommandLine.arguments.dropFirst())
    let runTask = Task {
      if ServeHTTPCommand.isLongRunningInvocation(arguments) {
        return await ServeHTTPCommand().run(arguments: arguments) { line in
          FileHandle.standardOutput.write(Data(line.utf8))
        }
      }
      return await app.run(arguments)
    }
    let signalCancellation = CLISignalCancellation { _ in
      runTask.cancel()
    }
    let result = await runTask.value
    signalCancellation.cancel()
    if !result.stdout.isEmpty {
      FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
      FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
    }
    Foundation.exit(result.exitCode.rawValue)
  }
}
