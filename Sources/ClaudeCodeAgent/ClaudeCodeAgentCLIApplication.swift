import Foundation
import RielaCore

public struct ClaudeCodeAgentCLIApplicationResult: Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  public init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

public enum ClaudeCodeAgentCLIApplication {
  public static func runActivityHookUpdate(
    stdin: Data,
    context: ClaudeCodeAgentCompatibilityContext = ClaudeCodeAgentCompatibilityContext()
  ) -> ClaudeCodeAgentCLIApplicationResult {
    do {
      guard !stdin.isEmpty,
        let payload = try JSONSerialization.jsonObject(with: stdin) as? [String: Any]
      else {
        return ClaudeCodeAgentCLIApplicationResult(exitCode: 0)
      }
      guard let sessionId = claudeCodeStringValue(payload["session_id"]) ?? claudeCodeStringValue(payload["sessionId"]), !sessionId.isEmpty else {
        return ClaudeCodeAgentCLIApplicationResult(exitCode: 0)
      }
      let hookEventName = claudeCodeStringValue(payload["hook_event_name"]) ?? claudeCodeStringValue(payload["hookEventName"]) ?? ""
      let transcriptPath = claudeCodeStringValue(payload["transcript_path"]) ?? claudeCodeStringValue(payload["transcriptPath"])
      let transcriptTail = transcriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
      let entry = ClaudeCodeStoredActivityEntry(
        sessionId: sessionId,
        status: ClaudeCodeActivityAnalyzer.status(hookEventName: hookEventName, transcriptTail: transcriptTail),
        updatedAt: isoString(Date()),
        projectPath: claudeCodeStringValue(payload["cwd"]) ?? claudeCodeStringValue(payload["projectPath"])
      )
      let store = ClaudeCodeActivityStore(dataDir: context.configDir ?? ClaudeCodeActivityStore.defaultDataDir())
      try store.mutate { entries in
        if let index = entries.firstIndex(where: { $0.sessionId == sessionId }) {
          entries[index] = entry
        } else {
          entries.append(entry)
        }
      }
    } catch {
      return ClaudeCodeAgentCLIApplicationResult(exitCode: 0)
    }
    return ClaudeCodeAgentCLIApplicationResult(exitCode: 0)
  }

  public static func run(
    arguments: [String],
    context: ClaudeCodeAgentCompatibilityContext = ClaudeCodeAgentCompatibilityContext()
  ) -> ClaudeCodeAgentCLIApplicationResult {
    let result = ClaudeCodeCLICommandExecutor.execute(arguments: arguments, context: context)
    if !result.errors.isEmpty {
      let exitCode: Int32 = result.errors.contains { $0.contains("invalidFormat") || $0.contains("Invalid format") } ? 2 : 1
      return ClaudeCodeAgentCLIApplicationResult(
        stderr: encodeCLIJSON(.object(["errors": .array(result.errors.map(JSONValue.string))])),
        exitCode: exitCode
      )
    }
    if requestedFormat(arguments) == "table", let text = legacyTableOutput(arguments: arguments, value: result.data ?? .null) {
      return ClaudeCodeAgentCLIApplicationResult(stdout: text, exitCode: 0)
    }
    return ClaudeCodeAgentCLIApplicationResult(stdout: encodeCLIJSON(result.data ?? .null), exitCode: 0)
  }

  private static func requestedFormat(_ arguments: [String]) -> String {
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--json" {
        return "json"
      }
      if argument == "--format" || argument == "-f", index + 1 < arguments.count {
        return arguments[index + 1] == "json" ? "json" : "table"
      }
      index += 1
    }
    return "table"
  }

  private static func legacyTableOutput(arguments: [String], value: JSONValue) -> String? {
    let stripped = (try? ClaudeCodeCLICompatibility.stripRootOptions(arguments)) ?? arguments
    guard let family = stripped.first else {
      return nil
    }
    let action = stripped.dropFirst().first
    switch (family, action) {
    case ("version", _):
      guard let object = try? jsonObjectValue(value) else {
        return nil
      }
      let version = claudeCodeStringValue(object["version"]) ?? "unknown"
      let claude = (try? jsonObjectValue(object["claudeCode"] ?? .null)).flatMap { claudeCodeStringValue($0["version"]) } ?? "unavailable"
      let git = (try? jsonObjectValue(object["git"] ?? .null)).flatMap { claudeCodeStringValue($0["version"]) } ?? "unavailable"
      return "Tool\tversion\nagent\t\(version)\nclaude\t\(claude)\ngit\t\(git)\n"
    case ("queue", "list"), ("group", "list"):
      guard case let .array(items) = value else {
        return nil
      }
      let rows = items.compactMap { try? jsonObjectValue($0) }.map { object in
        "\(claudeCodeStringValue(object["id"]) ?? "")\t\(claudeCodeStringValue(object["name"]) ?? "")"
      }
      return "ID\tName\n" + rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")
    case ("queue", "show"), ("queue", "get"), ("group", "show"), ("group", "get"):
      guard let object = try? jsonObjectValue(value) else {
        return nil
      }
      return "ID\tName\n\(claudeCodeStringValue(object["id"]) ?? "")\t\(claudeCodeStringValue(object["name"]) ?? "")\n"
    default:
      return nil
    }
  }

  private static func encodeCLIJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
      return "null\n"
    }
    return text + "\n"
  }
}
