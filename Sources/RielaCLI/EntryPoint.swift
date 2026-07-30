import Foundation

public enum RielaCLIMain {
  public static func run() async {
    let jsonlRecordWriter: WorkflowJSONLRecordWriting = { line in
      FileHandle.standardOutput.write(Data(line.utf8))
    }
    let app = RielaCLIApplication(
      runCommand: WorkflowRunCommand(jsonlRecordWriter: jsonlRecordWriter),
      sessionRerunCommand: SessionRerunCommand(jsonlRecordWriter: jsonlRecordWriter),
      sessionResumeCommand: SessionResumeCommand(jsonlRecordWriter: jsonlRecordWriter),
      sessionInspectionCommand: SessionInspectionCommand(followRecordWriter: { line in
        FileHandle.standardOutput.write(Data(line.utf8))
      }),
      loopCommandRunner: LoopCommandRunner(
        sessionRerunCommand: SessionRerunCommand(jsonlRecordWriter: jsonlRecordWriter)
      ),
      sessionContinueCommand: SessionContinueCommand(
        sessionResumeCommand: SessionResumeCommand(jsonlRecordWriter: jsonlRecordWriter)
      )
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
