import ArgumentParser
import Foundation

struct CLIHelpRequest: Equatable, Sendable {
  var path: [String]
  var runTarget: String?

  static func detect(_ arguments: [String]) -> CLIHelpRequest? {
    let tokens = Array(arguments.prefix { $0 != "--" })
    guard tokens.contains(where: { $0 == "--help" || $0 == "-h" }),
      let request = resolve(tokens) else { return nil }
    let path = request.path
    if path == ["gc"] || tokens.starts(with: ["session", "prune"]) || tokens.starts(with: ["session", "reconcile"])
      || path.first == "cache" || path.first == "environment" { return nil }
    if tokens.first == "gateway", tokens.count > 1, !tokens[1].hasPrefix("-"), tokens[1] != "list" {
      return nil
    }
    return request
  }

  static func resolve(_ arguments: [String]) -> CLIHelpRequest? {
    let tokens = Array(arguments.prefix { $0 != "--" })
    guard let first = tokens.first else { return nil }
    let paths = CLISurfaceEnumerator.commands().map(\.path) + [["sandbox"], ["sandbox", "run"]]
    let path = paths.filter { tokens.starts(with: $0) }.max { $0.count < $1.count }
      ?? ((CLISurfaceEnumerator.routerCommandNames() + ["sandbox", "auth", "worker"]).contains(first) ? [first] : [])
    guard !path.isEmpty else { return nil }
    let target = path == ["workflow", "run"] && tokens.count > 2 && !tokens[2].hasPrefix("-") ? tokens[2] : nil
    return CLIHelpRequest(path: path, runTarget: target)
  }
}

enum CLISubcommandHelp {
  static func result(for request: CLIHelpRequest) -> CLICommandResult {
    let text = dedicatedText(for: request) ?? usageText(for: request.path)
    return CLICommandResult(exitCode: .success, stdout: text)
  }

  static func result(path: [String]) -> CLICommandResult {
    result(for: CLIHelpRequest(path: path, runTarget: nil))
  }

  static func isCleanExit(_ error: any Error) -> Bool {
    // ArgumentParser's internal help-request error is exposed through exitCode(for:).
    error is CleanExit || ParsedStorageCommandArguments.exitCode(for: error) == .success
  }

  private static func dedicatedText(for request: CLIHelpRequest) -> String? {
    let path = request.path
    if path.first == "package" { return packageHelpText(scope: .package) }
    if path.starts(with: ["workflow", "package"]) { return packageHelpText(scope: .workflowPackage) }
    if path == ["workflow", "run"] { return workflowRunHelpText(target: request.runTarget) }
    if path == ["workflow", "register"] { return workflowRegisterHelpText }
    if path.first == "auth" { return PasskeyCommand.help + "\n" }
    if path.first == "worker" { return DistributedWorkerCommand.helpText }
    if path.first == "sandbox" { return SandboxCommand.helpText }
    if path == ["gateway"] || path == ["gateway", "list"] { return GatewayCommand.help }
    return nil
  }

  private static func usageText(for path: [String]) -> String {
    let lines = rielaCLIHelpText.components(separatedBy: "\n")
    guard let start = lines.firstIndex(of: "Usage:") else { return rielaCLIHelpText }
    let block = Array(lines.dropFirst(start + 1).prefix { !$0.isEmpty })
    var prefix = path
    while !prefix.isEmpty {
      var matches: [String] = []
      var includeContinuation = false
      var entryIndent = 0
      for line in block {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix { $0 == " " }.count
        if trimmed.hasPrefix("riela ") {
          let words = trimmed.split(separator: " ")
          includeContinuation = words.count > prefix.count && prefix.enumerated().allSatisfy { index, word in
            words[index + 1].split(separator: "|").contains(Substring(word))
          }
          entryIndent = indent
          if includeContinuation { matches.append(line) }
        } else if includeContinuation && indent > entryIndent {
          matches.append(line)
        } else {
          includeContinuation = false
        }
      }
      if !matches.isEmpty { return "Usage:\n" + matches.joined(separator: "\n") + "\n" }
      prefix.removeLast()
    }
    return rielaCLIHelpText
  }
}
