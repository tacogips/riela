import CursorCLIAgent
import Foundation

@main
struct CursorCLIAgentSwiftCLI {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let result: CursorCLIAgentCLIApplicationResult
    if arguments == ["activity", "update"] {
      result = CursorCLIAgentCLIApplication.runActivityHookUpdate(stdin: FileHandle.standardInput.readDataToEndOfFile())
    } else {
      result = CursorCLIAgentCLIApplication.run(arguments: arguments)
    }
    if !result.stdout.isEmpty {
      FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
      FileHandle.standardError.write(Data(result.stderr.utf8))
    }
    Foundation.exit(result.exitCode)
  }
}
