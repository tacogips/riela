import Foundation
import RielaCore

func sessionJSON(_ session: ClaudeCodeSession) -> JSONValue {
  var object: JSONObject = [
    "id": .string(session.id),
    "rolloutPath": .string(session.rolloutPath),
    "createdAt": .string(isoString(session.createdAt)),
    "updatedAt": .string(isoString(session.updatedAt)),
    "source": .string(session.source.rawValue),
    "modelProvider": session.modelProvider.map(JSONValue.string) ?? .null,
    "cwd": .string(session.cwd),
    "cliVersion": .string(session.cliVersion),
    "title": .string(session.title),
    "firstUserMessage": session.firstUserMessage.map(JSONValue.string) ?? .null,
    "archivedAt": session.archivedAt.map { .string(isoString($0)) } ?? .null,
    "forkedFromId": session.forkedFromId.map(JSONValue.string) ?? .null
  ]
  if let git = session.git {
    object["git"] = .object([
      "branch": git.branch.map(JSONValue.string) ?? .null,
      "sha": git.sha.map(JSONValue.string) ?? .null,
      "originURL": git.originURL.map(JSONValue.string) ?? .null
    ])
  } else {
    object["git"] = .null
  }
  return .object(object)
}

func activityEntryJSON(_ entry: ClaudeCodeStoredActivityEntry) -> JSONValue {
  var object: JSONObject = [
    "sessionId": .string(entry.sessionId),
    "status": .string(entry.status.rawValue),
    "updatedAt": .string(entry.updatedAt),
    "lastUpdated": .string(entry.updatedAt)
  ]
  if let projectPath = entry.projectPath {
    object["projectPath"] = .string(projectPath)
  }
  return .object(object)
}

let activityHookEvents = ["UserPromptSubmit", "PermissionRequest", "Stop"]
let activityHookCommand = "claude-code-agent activity update"

func activityCleanupCutoff(from text: String?) -> Date? {
  guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    return Date().addingTimeInterval(-24 * 60 * 60)
  }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  if let hours = Double(trimmed), hours >= 0 {
    return Date().addingTimeInterval(-hours * 60 * 60)
  }
  return parseLegacyTimestamp(trimmed)
}

func activitySetupJSON(variables: JSONObject) throws -> JSONObject {
  let settingsURL = activitySettingsURL(variables: variables)
  let dryRun = claudeCodeBoolValue(variables["dryRun"]) ?? false
  var settings = try readActivitySettingsObject(from: settingsURL)
  var hooks = settings["hooks"] as? [String: Any] ?? [:]
  for event in activityHookEvents {
    var entries = hooks[event] as? [Any] ?? []
    if !activityHookEntries(entries, containCommand: activityHookCommand) {
      entries.append([
        "matcher": "",
        "hooks": [
          [
            "type": "command",
            "command": activityHookCommand
          ]
        ]
      ])
    }
    hooks[event] = entries
  }
  settings["hooks"] = hooks
  if !dryRun {
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL, options: .atomic)
  }
  return [
    "ok": .bool(true),
    "dryRun": .bool(dryRun),
    "settingsPath": .string(settingsURL.path),
    "hooks": .array(activityHookEvents.map(JSONValue.string)),
    "settings": try claudeCodeJSONValue(fromFoundation: settings)
  ]
}

func activitySettingsURL(variables: JSONObject) -> URL {
  if claudeCodeBoolValue(variables["global"]) == true {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".claude", isDirectory: true)
      .appendingPathComponent("settings.json")
  }
  let projectPath = claudeCodeStringValue(variables["projectPath"]) ?? claudeCodeStringValue(variables["cwd"]) ?? FileManager.default.currentDirectoryPath
  return URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".claude", isDirectory: true)
    .appendingPathComponent("settings.json")
}

func readActivitySettingsObject(from url: URL) throws -> [String: Any] {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return [:]
  }
  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw ClaudeCodeGraphQLError.invalidParam("settings.json must contain a JSON object")
  }
  return object
}

func activityHookEntries(_ entries: [Any], containCommand command: String) -> Bool {
  entries.contains { entry in
    guard let object = entry as? [String: Any], let hooks = object["hooks"] as? [Any] else {
      return false
    }
    return hooks.contains { hook in
      guard let hookObject = hook as? [String: Any] else {
        return false
      }
      return hookObject["type"] as? String == "command" && hookObject["command"] as? String == command
    }
  }
}

func bookmarkContentJSON(_ bookmark: ClaudeCodeBookmark, claudeCodeHome: String?) throws -> JSONValue {
  var object = try jsonObjectValue(claudeCodeJSONValue(bookmark))
  object["bookmark"] = try claudeCodeJSONValue(bookmark)
  object["content"] = .string(bookmark.text ?? bookmark.description ?? bookmark.name ?? "")
  if let session = ClaudeCodeSessionIndex.findSession(id: bookmark.sessionId, claudeCodeHome: claudeCodeHome) {
    object["session"] = sessionJSON(session)
  }
  return .object(object)
}

func inferredBookmarkType(from variables: JSONObject) -> ClaudeCodeBookmarkType? {
  if let rawType = claudeCodeStringValue(variables["type"]) {
    return ClaudeCodeBookmarkType(rawValue: rawType)
  }
  if claudeCodeStringValue(variables["messageId"]) != nil {
    return .message
  }
  if claudeCodeStringValue(variables["fromMessageId"]) != nil, claudeCodeStringValue(variables["toMessageId"]) != nil {
    return .range
  }
  return .session
}

func jsonObjectValue(_ value: JSONValue) throws -> JSONObject {
  guard case let .object(object) = value else {
    throw ClaudeCodeGraphQLError.invalidParam("object")
  }
  return object
}

func isoString(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}

func extractLegacyCommandInvocation(from document: String, variables: JSONObject) -> (commandName: String?, variables: JSONObject) {
  guard document.contains("command(") else {
    return (nil, variables)
  }
  let commandName = extractGraphQLStringArgument(named: "name", from: document, variables: variables)
  if
    let variableName = firstRegexCapture(in: document, pattern: #"\bparams\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#),
    case let .object(params)? = variables[variableName] {
    return (commandName, params)
  }
  if case let .object(params)? = variables["param"] {
    return (commandName, params)
  }
  if case let .object(params)? = variables["params"] {
    return (commandName, params)
  }
  if let params = extractInlineGraphQLParams(from: document) {
    return (commandName, params)
  }
  return (commandName, variables)
}

func extractGraphQLStringArgument(named argumentName: String, from document: String, variables: JSONObject) -> String? {
  let escapedName = NSRegularExpression.escapedPattern(for: argumentName)
  if let literal = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*"([^"]+)""#) {
    return literal
  }
  guard let variableName = firstRegexCapture(in: document, pattern: #"\b"# + escapedName + #"\s*:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#) else {
    return nil
  }
  return claudeCodeStringValue(variables[variableName])
}
