import Foundation

@main
struct RielaSwiftCLI {
  static func main() async {
    let result = await RielaCLIApplication(
      runCommand: WorkflowRunCommand(jsonlRecordWriter: { line in
        FileHandle.standardOutput.write(Data(line.utf8))
      })
    ).run(Array(CommandLine.arguments.dropFirst()))
    if !result.stdout.isEmpty {
      FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
      FileHandle.standardError.write(Data((result.stderr + "\n").utf8))
    }
    Foundation.exit(result.exitCode.rawValue)
  }
}
