import CodexAgent
import Foundation

@main
struct CodexAgentSwiftCLI {
  static func main() {
    let result = CodexAgentCLIApplication.run(arguments: Array(CommandLine.arguments.dropFirst()))
    if !result.stdout.isEmpty {
      FileHandle.standardOutput.write(Data(result.stdout.utf8))
    }
    if !result.stderr.isEmpty {
      FileHandle.standardError.write(Data(result.stderr.utf8))
    }
    Foundation.exit(result.exitCode)
  }
}
