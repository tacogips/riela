import ClaudeCodeAgent
import Foundation

@main
struct ClaudeCodeAgentSwiftCLI {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let result: ClaudeCodeAgentCLIApplicationResult
    if arguments == ["activity", "update"] {
      result = ClaudeCodeAgentCLIApplication.runActivityHookUpdate(stdin: FileHandle.standardInput.readDataToEndOfFile())
    } else {
      result = ClaudeCodeAgentCLIApplication.run(arguments: arguments)
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
