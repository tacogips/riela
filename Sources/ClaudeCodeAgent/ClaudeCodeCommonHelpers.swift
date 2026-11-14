import Foundation
import RielaCore

func rolloutLineJSON(_ line: ClaudeCodeRolloutLine) -> JSONValue {
  .object([
    "timestamp": .string(line.timestamp),
    "type": .string(line.type),
    "payload": line.payload
  ])
}

func toolVersionsJSON(variables: JSONObject) -> JSONObject {
  let claudeCode = probeToolVersion(executableName(from: variables), arguments: ["--version"])
  let includeGit = claudeCodeBoolValue(variables["includeGit"]) ?? true
  return [
    "version": .string("swift"),
    "claudeCode": .object(claudeCode),
    "git": includeGit ? .object(probeToolVersion(claudeCodeStringValue(variables["gitBinary"]) ?? "git", arguments: ["--version"])) : .null
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

func processExecutionJSON(process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) -> JSONObject {
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

func processHandleJSON(_ process: ClaudeCodeProcessRecord) -> JSONObject {
  [
    "processId": .string(process.id),
    "pid": .number(Double(process.pid)),
    "command": .string(process.command),
    "status": .string(process.status.rawValue),
    "arguments": .array(process.arguments.map(JSONValue.string))
  ]
}

func sessionExecutionJSON(process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) -> JSONObject {
  let lines = result.stdout.split(separator: "\n").compactMap { ClaudeCodeRolloutReader.parseRolloutLine(String($0)) }
  var object = processExecutionJSON(process: process, result: result)
  object["sessionId"] = extractSessionId(from: lines).map(JSONValue.string) ?? .null
  object["lines"] = .array(lines.map(rolloutLineJSON))
  return object
}

func extractSessionId(from lines: [ClaudeCodeRolloutLine]) -> String? {
  for line in lines {
    guard let payload = fileChangeObject(line.payload) else {
      continue
    }
    if let sessionId = fileChangeString(payload["session_id"]) ?? fileChangeString(payload["sessionId"]) {
      return sessionId
    }
    if let meta = fileChangeObject(payload["meta"]), let id = fileChangeString(meta["id"]) {
      return id
    }
  }
  return nil
}

func claudeCodeJSONValue<Value: Encodable>(_ value: Value?) throws -> JSONValue {
  guard let value else {
    return .null
  }
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func claudeCodeJSONValue<Value: Encodable>(_ value: Value) throws -> JSONValue {
  let data = try JSONEncoder().encode(value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func claudeCodeJSONValue(fromFoundation value: Any) throws -> JSONValue {
  let data = try JSONSerialization.data(withJSONObject: value)
  return try JSONDecoder().decode(JSONValue.self, from: data)
}

func requiredString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = claudeCodeStringValue(object[key]), !value.isEmpty else {
    throw ClaudeCodeGraphQLError.missingVariable(key)
  }
  return value
}

func requiredString(_ object: JSONObject, _ key: String, fallback: String) throws -> String {
  if let value = claudeCodeStringValue(object[key]), !value.isEmpty {
    return value
  }
  if let value = claudeCodeStringValue(object[fallback]), !value.isEmpty {
    return value
  }
  throw ClaudeCodeGraphQLError.missingVariable(key)
}

func requiredNonBlankString(_ object: JSONObject, _ key: String) throws -> String {
  guard let value = claudeCodeStringValue(object[key])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
    throw ClaudeCodeGraphQLError.missingVariable(key)
  }
  return value
}

func tokenExpiresAt(from object: JSONObject) throws -> String? {
  if let expiresAt = claudeCodeStringValue(object["expiresAt"]), !expiresAt.isEmpty {
    return expiresAt
  }
  guard let expiresIn = claudeCodeStringValue(object["expiresIn"]) ?? claudeCodeStringValue(object["expires"]) else {
    return nil
  }
  do {
    let seconds = try ClaudeCodeDurationParser.seconds(expiresIn)
    return legacyTokenTimestamp(Date().addingTimeInterval(TimeInterval(seconds)))
  } catch {
    throw ClaudeCodeGraphQLError.invalidParam("--expires=\(expiresIn)")
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
  try ClaudeCodeQueuePersistence.findQueue(idOrName, configDir: configDir)?.id ?? idOrName
}

func resolveExistingQueueId(_ idOrName: String, configDir: String) throws -> String {
  guard let queue = try ClaudeCodeQueuePersistence.findQueue(idOrName, configDir: configDir) else {
    throw ClaudeCodeGraphQLError.missingVariable("Queue not found")
  }
  return queue.id
}

func resolveGroupId(_ idOrName: String, configDir: String) throws -> String {
  try ClaudeCodeGroupPersistence.findGroup(idOrName, configDir: configDir)?.id ?? idOrName
}

func groupSession(from variables: JSONObject) throws -> ClaudeCodeGroupSession {
  if let sessionObject = claudeCodeObjectValue(variables["session"]) {
    return ClaudeCodeGroupSession(
      id: try requiredString(sessionObject, "id"),
      projectPath: claudeCodeStringValue(sessionObject["projectPath"]),
      prompt: claudeCodeStringValue(sessionObject["prompt"]),
      status: claudeCodeStringValue(sessionObject["status"]),
      dependsOn: claudeCodeStringArray(sessionObject["dependsOn"]),
      createdAt: claudeCodeStringValue(sessionObject["createdAt"])
    )
  }
  return ClaudeCodeGroupSession(
    id: try requiredString(variables, "sessionId"),
    projectPath: claudeCodeStringValue(variables["projectPath"]),
    prompt: claudeCodeStringValue(variables["prompt"]),
    status: claudeCodeStringValue(variables["status"]),
    dependsOn: claudeCodeStringArray(variables["dependsOn"]),
    createdAt: claudeCodeStringValue(variables["createdAt"])
  )
}

func resolveExistingGroupId(_ idOrName: String, configDir: String) throws -> String {
  guard let group = try ClaudeCodeGroupPersistence.findGroup(idOrName, configDir: configDir) else {
    throw ClaudeCodeGraphQLError.missingVariable("Group not found")
  }
  return group.id
}

func defaultClaudeCodeAgentConfigDir() -> String {
  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/claude-code-agent", isDirectory: true).path
}

func defaultClaudeCodeAgentDataDir() -> String {
  FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/claude-code-agent", isDirectory: true).path
}

func claudeConfigPath(for context: ClaudeCodeAgentCompatibilityContext) -> String? {
  guard let claudeCodeHome = context.claudeCodeHome else {
    return nil
  }
  return URL(fileURLWithPath: claudeCodeHome, isDirectory: true).appendingPathComponent(".claude.json").path
}

func claudeCredentialsPath(for context: ClaudeCodeAgentCompatibilityContext) -> String {
  let home = context.claudeCodeHome ?? resolveClaudeCodeHome()
  return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".credentials.json").path
}

func claudeReadiness(context: ClaudeCodeAgentCompatibilityContext, model: String?) -> JSONObject {
  let credentialsPath = claudeCredentialsPath(for: context)
  let credentials = readClaudeCredentials(path: credentialsPath)
  let now = Date()
  let state: String
  let available: Bool
  let message: String
  if let credentials {
    available = credentials.expiresAt > now
    state = available ? "configured" : "expired"
    message = available ? "Stored credentials are configured." : "Stored credentials are expired."
  } else {
    available = false
    state = "missing"
    message = "No stored Claude Code credentials were found."
  }
  var auth: JSONObject = [
    "state": .string(state),
    "available": .bool(available),
    "storageLocation": .string(credentialsPath),
    "message": .string(message)
  ]
  if let credentials {
    auth["expiresAt"] = .string(isoString(credentials.expiresAt))
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
      "command": .string("claude")
    ]),
    "model": .object([
      "requested": model.map(JSONValue.string) ?? .null,
      "checked": .bool(false),
      "available": .bool(false),
      "timedOut": .bool(false),
      "stdout": .string(""),
      "stderr": .string(""),
      "commandArgs": .array(model.map { ["-p", "--model", $0] }?.map(JSONValue.string) ?? []),
      "message": .string(model != nil && !available ? "Skipping model probe because credentials are unavailable." : "")
    ])
  ]
}

struct ClaudeCredentialsReadiness {
  var expiresAt: Date
  var subscriptionType: String?
  var scopes: [String]
  var rateLimitTier: String?
}

func readClaudeCredentials(path: String) -> ClaudeCredentialsReadiness? {
  guard
    let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
    let value = try? JSONDecoder().decode(JSONValue.self, from: data),
    case let .object(object) = value,
    let oauth = claudeCodeObjectValue(object["claudeAiOauth"]),
    let expiresMs = claudeCodeNumberValue(oauth["expiresAt"])
  else {
    return nil
  }
  return ClaudeCredentialsReadiness(
    expiresAt: Date(timeIntervalSince1970: expiresMs / 1000),
    subscriptionType: claudeCodeStringValue(oauth["subscriptionType"]),
    scopes: claudeCodeStringArray(oauth["scopes"]),
    rateLimitTier: claudeCodeStringValue(oauth["rateLimitTier"])
  )
}

func authorizationError(commandName: String, rawToken: String?, configDir: String) throws -> String? {
  if commandName.hasPrefix("token."), let rawToken, !rawToken.isEmpty {
    return "Token management commands are not available in token-authenticated GraphQL contexts"
  }
  guard let rawToken, !rawToken.isEmpty, let permission = requiredPermission(for: commandName) else {
    return nil
  }
  guard try ClaudeCodeTokenPersistence.verify(rawToken: rawToken, permission: permission, configDir: configDir) != nil else {
    return "Missing permission: \(permission)"
  }
  return nil
}

func requiredPermission(for commandName: String) -> String? {
  switch commandName {
  case "session.run", "session.fork", "session.create", "session.cancel", "session.pause", "session.resume":
    return "session:create"
  case let command where command.hasPrefix("session.") || command.hasPrefix("files.") || command.hasPrefix("activity."):
    return "session:read"
  case "group.create":
    return "group:create"
  case "group.list", "group.show":
    return "session:read"
  case "group.add", "group.remove", "group.delete":
    return "group:create"
  case "group.pause", "group.resume", "group.run":
    return "group:run"
  case let command where command.hasPrefix("queue."):
    return "queue:*"
  case let command where command.hasPrefix("bookmark."):
    return "bookmark:*"
  default:
    return nil
  }
}
