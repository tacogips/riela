import Foundation
import RielaCore

func sessionJSON(_ session: CursorCLISession) -> JSONValue {
  var object: JSONObject = [
    "id": .string(session.id),
    "rolloutPath": .string(session.rolloutPath),
    "createdAt": .string(cursorOperationISOString(session.createdAt)),
    "updatedAt": .string(cursorOperationISOString(session.updatedAt)),
    "source": .string(session.source.rawValue),
    "modelProvider": session.modelProvider.map(JSONValue.string) ?? .null,
    "cwd": .string(session.cwd),
    "cliVersion": .string(session.cliVersion),
    "title": .string(session.title),
    "firstUserMessage": session.firstUserMessage.map(JSONValue.string) ?? .null,
    "archivedAt": session.archivedAt.map { .string(cursorOperationISOString($0)) } ?? .null,
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

func activityEntryJSON(_ entry: CursorCLIStoredActivityEntry) -> JSONValue {
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
let activityHookCommand = "cursor-cli-agent activity update"

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
  let dryRun = cursorOperationBoolValue(variables["dryRun"]) ?? false
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
    "settings": try cursorOperationJSONValue(fromFoundation: settings)
  ]
}

func activitySettingsURL(variables: JSONObject) -> URL {
  if cursorOperationBoolValue(variables["global"]) == true {
    let home = ProcessInfo.processInfo.environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent(".cursor", isDirectory: true)
      .appendingPathComponent("settings.json")
  }
  let projectPath = cursorOperationStringValue(variables["projectPath"]) ?? cursorOperationStringValue(variables["cwd"]) ?? FileManager.default.currentDirectoryPath
  return URL(fileURLWithPath: projectPath, isDirectory: true)
    .appendingPathComponent(".cursor", isDirectory: true)
    .appendingPathComponent("settings.json")
}

func readActivitySettingsObject(from url: URL) throws -> [String: Any] {
  guard FileManager.default.fileExists(atPath: url.path) else {
    return [:]
  }
  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw CursorCLIGraphQLError.invalidParam("settings.json must contain a JSON object")
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

func bookmarkContentJSON(_ bookmark: CursorCLIBookmark, cursorCLIHome: String?) throws -> JSONValue {
  var object = try cursorOperationJSONObjectValue(cursorOperationJSONValue(bookmark))
  object["bookmark"] = try cursorOperationJSONValue(bookmark)
  object["content"] = .string(bookmark.text ?? bookmark.description ?? bookmark.name ?? "")
  if let session = CursorCLISessionIndex.findSession(id: bookmark.sessionId, cursorCLIHome: cursorCLIHome) {
    object["session"] = sessionJSON(session)
  }
  return .object(object)
}

func inferredBookmarkType(from variables: JSONObject) -> CursorCLIBookmarkType? {
  if let rawType = cursorOperationStringValue(variables["type"]) {
    return CursorCLIBookmarkType(rawValue: rawType)
  }
  if cursorOperationStringValue(variables["messageId"]) != nil {
    return .message
  }
  if cursorOperationStringValue(variables["fromMessageId"]) != nil, cursorOperationStringValue(variables["toMessageId"]) != nil {
    return .range
  }
  return .session
}

func cursorOperationJSONObjectValue(_ value: JSONValue) throws -> JSONObject {
  guard case let .object(object) = value else {
    throw CursorCLIGraphQLError.invalidParam("object")
  }
  return object
}

func cursorOperationISOString(_ date: Date) -> String {
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
  return cursorOperationStringValue(variables[variableName])
}

func isPingDocument(_ document: String) -> Bool {
  let stripped = document
    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  return stripped == "query { ping }" || stripped == "{ ping }"
}

func executeTypedSessionGraphQLDocument(_ document: String, variables: JSONObject, context: CursorCLIAgentCompatibilityContext) -> CursorCLIGraphQLCommandExecutor.Result? {
  guard document.contains("sessions") || document.contains("session(") || document.contains("searchSessions") else {
    return nil
  }
  guard !document.contains("command(") else {
    return nil
  }
  let explicitConfigDir = cursorOperationStringValue(variables["configDir"]) ?? context.configDir
  let configDir = explicitConfigDir ?? defaultCursorCLIAgentConfigDir()
  let cursorCLIHome = cursorOperationStringValue(variables["cursorCLIHome"]) ?? context.cursorCLIHome
  let authToken = cursorOperationStringValue(variables["authToken"]) ?? cursorOperationStringValue(variables["token"]) ?? context.authToken
  do {
    if let authError = try authorizationError(commandName: "session.list", rawToken: authToken, configDir: configDir) {
      return CursorCLIGraphQLCommandExecutor.Result(errors: [authError])
    }
    if document.contains("searchSessions") {
      let args = graphQLArguments(field: "searchSessions", document: document, variables: variables)
      let query = cursorOperationStringValue(args["query"]) ?? ""
      let listOptions = CursorCLISessionListOptions(
        cursorCLIHome: cursorCLIHome,
        source: cursorOperationStringValue(args["source"]).flatMap { source in
          switch source.lowercased() {
          case "uuid", "cli":
            return .cli
          case "vscode":
            return .vscode
          case "exec":
            return .exec
          default:
            return CursorCLISessionSource(rawValue: source.lowercased())
          }
        },
        cwd: cursorOperationStringValue(args["projectPath"]) ?? cursorOperationStringValue(args["cwd"]),
        branch: cursorOperationStringValue(args["branch"]),
        limit: Int.max,
        offset: 0,
        sortBy: "createdAt",
        sortOrder: "desc"
      )
      let searchOptions = CursorCLISessionTranscriptSearchOptions(
        caseSensitive: cursorOperationBoolValue(args["caseSensitive"]) ?? false,
        role: cursorOperationStringValue(args["role"])?.lowercased() ?? "both",
        maxBytes: cursorOperationIntValue(args["maxBytes"]),
        maxEvents: nil,
        maxSessions: cursorOperationIntValue(args["maxSessions"]),
        timeoutMs: cursorOperationIntValue(args["timeoutMs"]),
        limit: cursorOperationIntValue(args["limit"]) ?? 50,
        offset: cursorOperationIntValue(args["offset"]) ?? 0
      )
      let result = try CursorCLISessionIndex.searchSessions(query: query, options: listOptions, searchOptions: searchOptions)
      return CursorCLIGraphQLCommandExecutor.Result(data: .object([
        "searchSessions": .object([
          "sessionIds": .array(result.sessionIds.map(JSONValue.string)),
          "total": .number(Double(result.total)),
          "offset": .number(Double(result.offset)),
          "limit": .number(Double(result.limit)),
          "scannedSessions": .number(Double(result.scannedSessions)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut)
        ])
      ]))
    }
    if document.contains("session(") {
      let args = graphQLArguments(field: "session", document: document, variables: variables)
      guard let id = cursorOperationStringValue(args["id"]), let session = CursorCLISessionIndex.findSession(id: id, cursorCLIHome: cursorCLIHome) else {
        return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .null]))
      }
      var sessionObject = typedSessionJSON(session)
      if document.contains("history") {
        sessionObject["history"] = typedSessionHistoryJSON(session: session, args: graphQLArguments(field: "history", document: document, variables: variables))
      }
      if document.contains("grep") {
        let grepArgs = graphQLArguments(field: "grep", document: document, variables: variables)
        let query = cursorOperationStringValue(grepArgs["query"]) ?? ""
        let searchOptions = CursorCLISessionTranscriptSearchOptions(
          caseSensitive: cursorOperationBoolValue(grepArgs["caseSensitive"]) ?? false,
          role: cursorOperationStringValue(grepArgs["role"])?.lowercased() ?? "both",
          maxBytes: cursorOperationIntValue(grepArgs["maxBytes"]),
          timeoutMs: cursorOperationIntValue(grepArgs["timeoutMs"]),
          limit: cursorOperationIntValue(grepArgs["maxMatches"]) ?? 50
        )
        let result = try CursorCLISessionIndex.searchSessionTranscriptDetailed(session: session, query: query, options: searchOptions)
        sessionObject["grep"] = .object([
          "sessionId": .string(session.id),
          "matched": .bool(result.matched),
          "matchCount": .number(Double(result.matchCount)),
          "scannedBytes": .number(Double(result.scannedBytes)),
          "scannedLines": .number(Double(result.scannedEvents)),
          "scannedEvents": .number(Double(result.scannedEvents)),
          "truncated": .bool(result.truncated),
          "timedOut": .bool(result.timedOut)
        ])
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object(["session": .object(sessionObject)]))
    }
    if document.contains("sessions") {
      let args = graphQLArguments(field: "sessions", document: document, variables: variables)
      let options = sessionListOptions(from: args, cursorCLIHome: cursorCLIHome)
      var sessions = CursorCLISessionIndex.listSessions(options: options).sessions
      if let status = cursorOperationStringValue(args["status"]), status != "completed" {
        sessions = []
      }
      return CursorCLIGraphQLCommandExecutor.Result(data: .object([
        "sessions": .object([
          "total": .number(Double(sessions.count)),
          "nodes": .array(sessions.map { .object(typedSessionJSON($0)) })
        ])
      ]))
    }
    return nil
  } catch {
    return CursorCLIGraphQLCommandExecutor.Result(errors: [String(describing: error)])
  }
}

func typedSessionJSON(_ session: CursorCLISession) -> JSONObject {
  [
    "id": .string(session.id),
    "projectPath": .string(session.cwd),
    "cwd": .string(session.cwd),
    "status": .string("completed"),
    "createdAt": .string(cursorOperationISOString(session.createdAt)),
    "updatedAt": .string(cursorOperationISOString(session.updatedAt)),
    "messageCount": .number(Double((try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath).count) ?? 0))
  ]
}

func typedSessionHistoryJSON(session: CursorCLISession, args: JSONObject) -> JSONValue {
  let offset = max(0, cursorOperationIntValue(args["offset"]) ?? 0)
  let limit = max(0, cursorOperationIntValue(args["limit"]) ?? 50)
  let messages = (try? CursorCLIRolloutReader.getSessionMessages(path: session.rolloutPath)) ?? []
  let start = min(offset, messages.count)
  let end = min(start + limit, messages.count)
  let events = messages[start..<end].map { message -> JSONValue in
    .object([
      "type": .string(message.role),
      "uuid": .null,
      "timestamp": .string(message.timestamp),
      "content": message.text.map(JSONValue.string) ?? .null,
      "raw": message.line.payload
    ])
  }
  return .object([
    "total": .number(Double(messages.count)),
    "offset": .number(Double(offset)),
    "limit": .number(Double(limit)),
    "events": .array(Array(events)),
    "tokenUsage": .object(["input": .number(0), "output": .number(0)])
  ])
}

func graphQLArguments(field: String, document: String, variables: JSONObject) -> JSONObject {
  let escapedField = NSRegularExpression.escapedPattern(for: field)
  guard let argumentText = firstRegexCapture(in: document, pattern: #"\b"# + escapedField + #"\s*\(([^)]*)\)"#) else {
    return [:]
  }
  var result: JSONObject = [:]
  let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*("[^"]*"|\$[A-Za-z_][A-Za-z0-9_]*|-?[0-9]+|true|false|[A-Za-z_][A-Za-z0-9_]*)"#
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return result
  }
  let nsRange = NSRange(argumentText.startIndex..<argumentText.endIndex, in: argumentText)
  for match in regex.matches(in: argumentText, range: nsRange) {
    guard
      let nameRange = Range(match.range(at: 1), in: argumentText),
      let valueRange = Range(match.range(at: 2), in: argumentText)
    else {
      continue
    }
    let name = String(argumentText[nameRange])
    let rawValue = String(argumentText[valueRange])
    if rawValue.hasPrefix("$") {
      result[name] = variables[String(rawValue.dropFirst())] ?? .null
    } else if rawValue.hasPrefix("\""), rawValue.hasSuffix("\"") {
      result[name] = .string(String(rawValue.dropFirst().dropLast()))
    } else if rawValue == "true" || rawValue == "false" {
      result[name] = .bool(rawValue == "true")
    } else if let cursorOperationIntValue = Int(rawValue) {
      result[name] = .number(Double(cursorOperationIntValue))
    } else {
      result[name] = .string(rawValue.lowercased())
    }
  }
  return result
}

func extractInlineGraphQLParams(from document: String) -> JSONObject? {
  guard let paramsRange = document.range(of: "params") else {
    return nil
  }
  guard let colon = document[paramsRange.upperBound...].firstIndex(of: ":") else {
    return nil
  }
  guard let open = document[colon...].firstIndex(of: "{") else {
    return nil
  }
  guard let close = matchingBrace(in: document, open: open) else {
    return nil
  }
  let literal = String(document[open...close])
  let jsonText = quoteGraphQLObjectKeys(literal)
  guard
    let data = jsonText.data(using: .utf8),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value
  else {
    return nil
  }
  return object
}

func matchingBrace(in text: String, open: String.Index) -> String.Index? {
  var depth = 0
  var inString = false
  var escaped = false
  var index = open
  while index < text.endIndex {
    let character = text[index]
    if inString {
      if escaped {
        escaped = false
      } else if character == "\\" {
        escaped = true
      } else if character == "\"" {
        inString = false
      }
    } else if character == "\"" {
      inString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return index
      }
    }
    index = text.index(after: index)
  }
  return nil
}

func quoteGraphQLObjectKeys(_ literal: String) -> String {
  literal.replacingOccurrences(
    of: #"([,{]\s*)([A-Za-z_][A-Za-z0-9_]*)\s*:"#,
    with: #"$1"$2":"#,
    options: .regularExpression
  )
}

func firstRegexCapture(in text: String, pattern: String) -> String? {
  guard let regex = try? NSRegularExpression(pattern: pattern) else {
    return nil
  }
  let range = NSRange(text.startIndex..<text.endIndex, in: text)
  guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else {
    return nil
  }
  return String(text[capture])
}

func shorthandOperation(for command: String) -> String {
  if command == "session.watch" {
    return "subscription"
  }
  return mutationCommandNames.contains(command) ? "mutation" : "query"
}

func escapeGraphQLString(_ value: String) -> String {
  value
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

let mutationCommandNames: Set<String> = [
  "session.run",
  "session.resume",
  "session.fork",
  "group.create",
  "group.add",
  "group.remove",
  "group.pause",
  "group.resume",
  "group.delete",
  "group.run",
  "queue.create",
  "queue.add",
  "queue.pause",
  "queue.resume",
  "queue.delete",
  "queue.update",
  "queue.remove",
  "queue.move",
  "queue.mode",
  "queue.run",
  "bookmark.add",
  "bookmark.delete",
  "token.create",
  "token.revoke",
  "token.rotate",
  "files.rebuild"
]

func rolloutLineJSON(_ line: CursorCLIRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload
  ])
}

func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let cursorCLI = probeToolVersion(cursorOperationExecutableName(from: variables), arguments: ["--version"])
  let includeGit = cursorOperationBoolValue(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "cursorCLI": .object(cursorCLI),
    "git": includeGit ? .object(probeToolVersion(cursorOperationStringValue(variables["gitBinary"]) ?? "git", arguments: ["--version"])) : .null
  ]
}

func probeToolVersion(_ executable: String, arguments: [String]) -> JSONObject {
  let process = Process()
  process.executableURL = resolveExecutableURL(executable)
  process.arguments = arguments
  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  do {
    try process.run()
    process.waitUntilExit()
    let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return [
      "available": .bool(process.terminationStatus == 0),
      "version": .string(out.trimmingCharacters(in: .whitespacesAndNewlines)),
      "exitCode": .number(Double(process.terminationStatus)),
      "stderr": .string(err.trimmingCharacters(in: .whitespacesAndNewlines))
    ]
  } catch {
    return [
      "available": .bool(false),
      "version": .null,
      "error": .string(String(describing: error))
    ]
  }
}

func resolveExecutableURL(_ executable: String) -> URL {
  if executable.contains("/") {
    return URL(fileURLWithPath: executable)
  }
  let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  for directory in environmentPath.split(separator: ":").map(String.init) {
    let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(executable)
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  return URL(fileURLWithPath: executable)
}

func processExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "stdout": .string(result.stdout),
    "stderr": .string(result.stderr),
    "exitCode": .number(Double(result.exitCode)),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func processHandleJSON(_ process: CursorCLIProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func sessionExecutionJSON(process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

func extractSessionId(from lines: [CursorCLIRolloutLine]) -> String? {
  for line in lines {
    guard let payload = cursorOperationFileChangeObject(line.payload) else {
      continue
    }
    if let sessionId = cursorOperationFileChangeString(payload["session_id"]) ?? cursorOperationFileChangeString(payload["sessionId"]) {
      return sessionId
    }
    if let meta = cursorOperationFileChangeObject(payload["meta"]), let id = cursorOperationFileChangeString(meta["id"]) {
      return id
    }
  }
  return nil
}

func cursorOperationJSONValue<Value: Encodable>(_ value: Value?) throws -> JSONValue {
  guard let value else {
    return .null
  }
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationJSONValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationJSONValue(fromFoundation value: Any) throws -> JSONValue {
  let data = try JSONSerialization.data(withJSONObject: value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func cursorOperationRequiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = cursorOperationStringValue(object[key]), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
  }
  return value
}

func cursorOperationRequiredString(_ object: JSONObject, _ key: String, fallback: String) throws -> String {
  if let value = cursorOperationStringValue(object[key]), !value.isEmpty {
    return value
  }
  if let value = cursorOperationStringValue(object[fallback]), !value.isEmpty {
    return value
  }
  throw CursorCLIGraphQLError.missingVariable(key)
}

func cursorOperationRequiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = cursorOperationStringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw CursorCLIGraphQLError.missingVariable(key)
  }
  return value
}

func tokenExpiresAt(from object: JSONObject) throws -> String? {
  if let expiresAt = cursorOperationStringValue(object["expiresAt"]), !expiresAt.isEmpty {
    return expiresAt
  }
  guard let expiresIn = cursorOperationStringValue(object["expiresIn"]) ?? cursorOperationStringValue(object["expires"]) else {
    return nil
  }
  do {
    let seconds = try CursorCLIDurationParser.seconds(expiresIn)
    return legacyTokenTimestamp(Date().addingTimeInterval(TimeInterval(seconds)))
  } catch {
    throw CursorCLIGraphQLError.invalidParam("--expires=\(expiresIn)")
  }
}

func legacyTokenTimestamp(_ date: Date) -> String {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter.string(from: date)
}

func parseLegacyTimestamp(_ text: String) -> Date? {
  let fractional = ISO8601DateFormatter()
  fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  if let date = fractional.date(from: text) {
    return date
  }
  return ISO8601DateFormatter().date(from: text)
}

func resolveQueueId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try CursorCLIQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw CursorCLIGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try CursorCLIGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

func groupSession(from variables: JSONObject) throws -> CursorCLIGroupSession {
  if let sessionObject = cursorOperationObjectValue(variables["session"]) {
    return CursorCLIGroupSession(
      id: try cursorOperationRequiredString(sessionObject, "id"),
      projectPath: cursorOperationStringValue(sessionObject["projectPath"]),
      prompt: cursorOperationStringValue(sessionObject["prompt"]),
      status: cursorOperationStringValue(sessionObject["status"]),
      dependsOn: cursorOperationStringArray(sessionObject["dependsOn"]),
      createdAt: cursorOperationStringValue(sessionObject["createdAt"])
    )
  }
  return CursorCLIGroupSession(
    id: try cursorOperationRequiredString(variables, "sessionId"),
    projectPath: cursorOperationStringValue(variables["projectPath"]),
    prompt: cursorOperationStringValue(variables["prompt"]),
    status: cursorOperationStringValue(variables["status"]),
    dependsOn: cursorOperationStringArray(variables["dependsOn"]),
    createdAt: cursorOperationStringValue(variables["createdAt"])
  )
}

func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
  guard let group = try CursorCLIGroupPersistence.findGroup(idOrName, configDir: configDir) else {
    throw CursorCLIGraphQLError.missingVariable("Group not found")
  }
  return group.id
}

func defaultCursorCLIAgentConfigDir() -> String {
  if let override = ProcessInfo.processInfo.environment["CURSOR_CLI_AGENT_CONFIG_DIR"], !override.isEmpty {
    return expandHomePath(override)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cursor-cli-agent", isDirectory: true).path
}

func defaultCursorCLIAgentDataDir() -> String {
  if let override = ProcessInfo.processInfo.environment["CURSOR_CLI_AGENT_DATA_DIR"], !override.isEmpty {
    return expandHomePath(override)
  }
  return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/cursor-cli-agent", isDirectory: true).path
}

func expandHomePath(_ path: String) -> String {
  if path == "~" {
    return FileManager.default.homeDirectoryForCurrentUser.path
  }
  if path.hasPrefix("~/") {
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2))).path
  }
  return path
}

func cursorConfigPath(for context: CursorCLIAgentCompatibilityContext) -> String? {
  guard let cursorCLIHome = context.cursorCLIHome else {
    return nil
  }
  return URL(fileURLWithPath: cursorCLIHome, isDirectory: true)
    .appendingPathComponent("account.json")
    .path
}

func cursorCredentialsPath(for context: CursorCLIAgentCompatibilityContext) -> String {
  let home = context.cursorCLIHome ?? resolveCursorCLIHome()
  return URL(fileURLWithPath: home, isDirectory: true)
    .appendingPathComponent("credentials.json")
    .path
}

func cursorReadiness(context: CursorCLIAgentCompatibilityContext, model: String?) -> JSONObject {
  let credentialsPath = cursorCredentialsPath(for: context)
  let credentials = readCursorCredentials(path: credentialsPath)
  let hasEnvToken = !(ProcessInfo.processInfo.environment["CURSOR_API_KEY"] ?? "").isEmpty || !(ProcessInfo.processInfo.environment["CURSOR_AUTH_TOKEN"] ?? "").isEmpty
  let now = Date()
  let state: String
  let available: Bool
  let message: String
  if hasEnvToken {
    available = true
    state = "configured"
    message = "Cursor API credentials are configured in the environment."
  } else if let credentials {
    available = credentials.expiresAt > now
    state = available ? "configured" : "expired"
    message = available ? "Stored credentials are configured." : "Stored credentials are expired."
  } else {
    available = false
    state = "missing"
    message = "No Cursor API credentials were found."
  }
  var auth: JSONObject = [
    "state": .string(state),
    "available": .bool(available),
    "storageLocation": .string(credentialsPath),
    "message": .string(message)
  ]
  if let credentials {
    auth["expiresAt"] = .string(cursorOperationISOString(credentials.expiresAt))
    auth["subscriptionType"] = credentials.subscriptionType.map(JSONValue.string) ?? .null
    auth["scopes"] = .array(credentials.scopes.map(JSONValue.string))
    auth["rateLimitTier"] = credentials.rateLimitTier.map(JSONValue.string) ?? .null
  }
  return [
    "ready": .bool(available),
    "auth": .object(auth),
    "cli": .object([
      "checked": .bool(false),
      "available": .bool(false),
      "command": .string("cursor-agent")
    ]),
    "model": .object([
      "requested": model.map(JSONValue.string) ?? .null,
      "checked": .bool(false),
      "available": .bool(false),
      "timedOut": .bool(false),
      "stdout": .string(""),
      "stderr": .string(""),
      "commandArgs": .array(model.map { ["--print", "--model", $0] }?.map(JSONValue.string) ?? []),
      "message": .string(model != nil && !available ? "Skipping model probe because credentials are unavailable." : "")
    ])
  ]
}

struct CursorCredentialsReadiness {
  var expiresAt: Date
  var subscriptionType: String?
  var scopes: [String]
  var rateLimitTier: String?
}

func readCursorCredentials(path: String) -> CursorCredentialsReadiness? {
  guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value,
    let oauth = cursorOperationObjectValue(object["cursorOauth"]),
    let expiresMs = cursorOperationNumberValue(oauth["expiresAt"])
  else {
    return nil
  }
  return CursorCredentialsReadiness(
    expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
    subscriptionType: cursorOperationStringValue(oauth["subscriptionType"]),
    scopes: cursorOperationStringArray(oauth["scopes"]),
    rateLimitTier: cursorOperationStringValue(oauth["rateLimitTier"])
  )
}

func authorizationError(commandName: String, rawToken: String?, configDir: String) throws -> String? {
  if commandName.hasPrefix("token."), let rawToken, !rawToken.isEmpty {
    return "Token management commands are not available in token-authenticated GraphQL contexts"
  }
  guard let rawToken, !rawToken.isEmpty, let permission = requiredPermission(for: commandName) else {
    return nil
  }
  guard try CursorCLITokenPersistence.verify(rawToken: rawToken, permission: permission, configDir: configDir) != nil else {
    return "Missing permission: \(permission)"
  }
  return nil
}

func requiredPermission(for commandName: String) -> String? {
  switch commandName {
  case "session.run", "session.fork", "session.create", "session.pause", "session.resume":
    return "session:create"
  case "session.cancel":
    return "session:cancel"
  case let command where command.hasPrefix("session.") || command.hasPrefix("activity."):
    return "session:read"
  case "group.run":
    return "group:run"
  case let command where command.hasPrefix("group."):
    return "group:*"
  case let command where command.hasPrefix("queue."):
    return "queue:*"
  case let command where command.hasPrefix("bookmark."):
    return "bookmark:*"
  case let command where command.hasPrefix("files."):
    return "files:*"
  case let command where command.hasPrefix("skill.") || command.hasPrefix("server.") || command.hasPrefix("daemon."):
    return "server:read"
  default:
    return nil
  }
}
