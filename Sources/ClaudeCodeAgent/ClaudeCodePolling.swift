import Foundation
import RielaCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ClaudeCodeDurationParser {
  public static func seconds(_ text: String) throws -> Int {
    guard let match = text.firstMatch(of: /^([1-9][0-9]*)([mhdwy])$/) else {
      throw ClaudeCodeDurationError.invalid(text)
    }
    let value = Int(match.1) ?? 0
    let multiplier: Int
    switch match.2 {
    case "m": multiplier = 60
    case "h": multiplier = 60 * 60
    case "d": multiplier = 60 * 60 * 24
    case "w": multiplier = 60 * 60 * 24 * 7
    case "y": multiplier = 60 * 60 * 24 * 365
    default: throw ClaudeCodeDurationError.invalid(text)
    }
    guard value <= Int.max / multiplier else {
      throw ClaudeCodeDurationError.tooLarge(text)
    }
    return value * multiplier
  }
}

public enum ClaudeCodeDurationError: Error, Equatable {
  case invalid(String)
  case tooLarge(String)
}

public struct ClaudeCodeTranscriptEvent: Equatable, Sendable {
  public var type: String
  public var uuid: String?
  public var timestamp: String?
  public var content: String?
  public var raw: [String: String]
  public var rawJSON: JSONValue

  public init(type: String, uuid: String? = nil, timestamp: String? = nil, content: String? = nil, raw: [String: String] = [:], rawJSON: JSONValue = .object([:])) {
    self.type = type
    self.uuid = uuid
    self.timestamp = timestamp
    self.content = content
    self.raw = raw
    self.rawJSON = rawJSON
  }
}

public struct ClaudeCodeJsonlStreamParser: Sendable {
  private var buffer = ""

  public init() {}

  public mutating func feed(_ chunk: String) -> [ClaudeCodeTranscriptEvent] {
    buffer += chunk
    var events: [ClaudeCodeTranscriptEvent] = []
    while let newline = buffer.firstIndex(of: "\n") {
      let line = String(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if let event = Self.parse(line) {
        events.append(event)
      }
    }
    return events
  }

  public mutating func flush() -> [ClaudeCodeTranscriptEvent] {
    guard !buffer.isEmpty else {
      return []
    }
    defer { buffer = "" }
    return Self.parse(buffer).map { [$0] } ?? []
  }

  public static func parse(_ line: String) -> ClaudeCodeTranscriptEvent? {
    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = object["type"] as? String
    else {
      return nil
    }
    let message = object["message"] as? [String: Any]
    let content = object["content"] as? String ?? message?["content"] as? String
    return ClaudeCodeTranscriptEvent(
      type: type,
      uuid: object["uuid"] as? String,
      timestamp: object["timestamp"] as? String,
      content: content,
      raw: object.compactMapValues { value in
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
      },
      rawJSON: jsonValue(from: object)
    )
  }
}

public enum ClaudeCodeMonitorEventType: String, Equatable, Sendable {
  case toolStart = "tool_start"
  case toolEnd = "tool_end"
  case subagentStart = "subagent_start"
  case subagentEnd = "subagent_end"
  case message
  case taskUpdate = "task_update"
}

public struct ClaudeCodeMonitorEvent: Equatable, Sendable {
  public var type: ClaudeCodeMonitorEventType
  public var id: String?
  public var name: String?
  public var durationMs: Int?
  public var content: String?

  public init(type: ClaudeCodeMonitorEventType, id: String? = nil, name: String? = nil, durationMs: Int? = nil, content: String? = nil) {
    self.type = type
    self.id = id
    self.name = name
    self.durationMs = durationMs
    self.content = content
  }
}

public struct ClaudeCodePollingEventParser: Sendable {
  private var activeTools: [String: Date] = [:]
  private var now: @Sendable () -> Date

  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.now = now
  }

  public mutating func map(_ event: ClaudeCodeTranscriptEvent) -> ClaudeCodeMonitorEvent? {
    let id = event.uuid
    switch event.type {
    case "tool_use":
      guard let toolName = toolName(from: event) else {
        return nil
      }
      activeTools[toolName] = eventDate(event) ?? now()
      return ClaudeCodeMonitorEvent(type: .toolStart, id: id, name: toolName, content: event.content)
    case "tool_result":
      guard let toolName = toolName(from: event) else {
        return nil
      }
      let endDate = eventDate(event) ?? now()
      let duration = activeTools.removeValue(forKey: toolName).map { Int(max(0, endDate.timeIntervalSince($0) * 1000)) }
      return ClaudeCodeMonitorEvent(type: .toolEnd, id: id, name: toolName, durationMs: duration, content: event.content)
    case "task":
      if event.raw["subagent_type"] != nil {
        return ClaudeCodeMonitorEvent(type: .subagentStart, id: id, name: event.raw["subagent_type"], content: event.content)
      }
      if ["completed", "failed"].contains(event.raw["status"]) {
        return ClaudeCodeMonitorEvent(type: .subagentEnd, id: id, name: event.raw["status"], content: event.content)
      }
      return ClaudeCodeMonitorEvent(type: .taskUpdate, id: id, content: event.content)
    case "user", "assistant":
      return ClaudeCodeMonitorEvent(type: .message, id: id, name: event.type, content: event.content)
    case "todo_write":
      return ClaudeCodeMonitorEvent(type: .taskUpdate, id: id, content: event.content)
    default:
      return nil
    }
  }

  private func eventDate(_ event: ClaudeCodeTranscriptEvent) -> Date? {
    event.timestamp.flatMap { ISO8601DateFormatter().date(from: $0) }
  }

  private func toolName(from event: ClaudeCodeTranscriptEvent) -> String? {
    if let direct = event.raw["name"] {
      return direct
    }
    guard case let .object(object) = event.rawJSON,
      case let .object(content)? = object["content"],
      case let .string(name)? = content["name"]
    else {
      return nil
    }
    return name
  }
}

private func jsonValue(from value: Any) -> JSONValue {
  switch value {
  case let string as String:
    return .string(string)
  case let number as NSNumber:
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return .bool(number.boolValue)
    }
    return .number(number.doubleValue)
  case let object as [String: Any]:
    return .object(object.mapValues(jsonValue))
  case let array as [Any]:
    return .array(array.map(jsonValue))
  default:
    return .null
  }
}

public struct ClaudeCodePollingSessionState: Equatable, Sendable {
  public var activeToolIds: Set<String> = []
  public var activeSubagentIds: Set<String> = []
  public var messageCount = 0
  public var lastUpdated: String?
}

public struct ClaudeCodePollingStateManager: Sendable {
  private var states: [String: ClaudeCodePollingSessionState] = [:]

  public init() {}

  public mutating func apply(sessionId: String, event: ClaudeCodeMonitorEvent, timestamp: String? = nil) {
    var state = states[sessionId] ?? ClaudeCodePollingSessionState()
    switch event.type {
    case .toolStart:
      if let id = event.id { state.activeToolIds.insert(id) }
    case .toolEnd:
      if let id = event.id { state.activeToolIds.remove(id) }
    case .subagentStart:
      if let id = event.id { state.activeSubagentIds.insert(id) }
    case .subagentEnd:
      if let id = event.id { state.activeSubagentIds.remove(id) }
    case .message:
      state.messageCount += 1
    case .taskUpdate:
      break
    }
    state.lastUpdated = timestamp ?? ISO8601DateFormatter().string(from: Date())
    states[sessionId] = state
  }

  public func state(sessionId: String) -> ClaudeCodePollingSessionState? {
    states[sessionId]
  }
}

public enum ClaudeCodeActivityStatusValue: String, Codable, Equatable, Sendable {
  case idle
  case working
  case waitingUserResponse = "waiting_user_response"
}

public struct ClaudeCodeStoredActivityEntry: Codable, Equatable, Sendable {
  public var sessionId: String
  public var status: ClaudeCodeActivityStatusValue
  public var updatedAt: String
  public var projectPath: String?

  public init(sessionId: String, status: ClaudeCodeActivityStatusValue, updatedAt: String, projectPath: String? = nil) {
    self.sessionId = sessionId
    self.status = status
    self.updatedAt = updatedAt
    self.projectPath = projectPath
  }

  private enum CodingKeys: String, CodingKey {
    case sessionId
    case status
    case updatedAt
    case lastUpdated
    case projectPath
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.sessionId = try container.decode(String.self, forKey: .sessionId)
    self.status = try container.decode(ClaudeCodeActivityStatusValue.self, forKey: .status)
    self.updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
      ?? container.decodeIfPresent(String.self, forKey: .lastUpdated)
      ?? ""
    self.projectPath = try container.decodeIfPresent(String.self, forKey: .projectPath)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(status, forKey: .status)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(updatedAt, forKey: .lastUpdated)
    try container.encodeIfPresent(projectPath, forKey: .projectPath)
  }
}

public struct ClaudeCodeActivityStore: Sendable {
  public var url: URL

  public init(dataDir: String) {
    self.url = URL(fileURLWithPath: dataDir, isDirectory: true).appendingPathComponent("activity.json")
  }

  public static func defaultDataDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("claude-code-agent", isDirectory: true).path
    }
    let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".local/share/claude-code-agent", isDirectory: true).path
  }

  public func load() throws -> [ClaudeCodeStoredActivityEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    let data = try Data(contentsOf: url)
    if let array = try? JSONDecoder().decode([ClaudeCodeStoredActivityEntry].self, from: data) {
      return array
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return []
    }
    if let sessions = object["sessions"] as? [String: [String: Any]] {
      return sessions.keys.sorted().compactMap { sessionId in
        guard let entry = sessions[sessionId],
          let rawStatus = entry["status"] as? String,
          let status = ClaudeCodeActivityStatusValue(rawValue: rawStatus)
        else {
          return nil
        }
        let updatedAt = entry["updatedAt"] as? String ?? entry["lastUpdated"] as? String ?? ""
        return ClaudeCodeStoredActivityEntry(sessionId: sessionId, status: status, updatedAt: updatedAt, projectPath: entry["projectPath"] as? String)
      }
    }
    return []
  }

  public func save(_ entries: [ClaudeCodeStoredActivityEntry]) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var sessions: [String: Any] = [:]
    for entry in entries {
      var object: [String: Any] = [
        "status": entry.status.rawValue,
        "updatedAt": entry.updatedAt,
        "lastUpdated": entry.updatedAt
      ]
      if let projectPath = entry.projectPath {
        object["projectPath"] = projectPath
      }
      sessions[entry.sessionId] = object
    }
    let data = try JSONSerialization.data(withJSONObject: ["version": "1.0", "sessions": sessions], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
  }

  @discardableResult
  public func mutate(_ body: (inout [ClaudeCodeStoredActivityEntry]) throws -> Void) throws -> [ClaudeCodeStoredActivityEntry] {
    try withLock {
      var entries = try load()
      try body(&entries)
      try save(entries)
      return entries
    }
  }

  public func cleanup(olderThan cutoff: Date) throws -> [ClaudeCodeStoredActivityEntry] {
    try mutate { entries in
      entries = entries.filter { entry in
        parseActivityTimestamp(entry.updatedAt).map { $0 >= cutoff } ?? true
      }
    }
  }

  private func parseActivityTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) {
      return date
    }
    return ISO8601DateFormatter().date(from: text)
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let lockPath = url.deletingLastPathComponent().appendingPathComponent("activity.json.lock").path
    let descriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw ClaudeCodeActivityStoreError.lockOpenFailed(lockPath)
    }
    defer {
      _ = close(descriptor)
    }
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw ClaudeCodeActivityStoreError.lockFailed(lockPath)
    }
    defer {
      _ = flock(descriptor, LOCK_UN)
    }
    return try body()
  }
}

public enum ClaudeCodeActivityStoreError: Error, Equatable, Sendable {
  case lockOpenFailed(String)
  case lockFailed(String)
}

public enum ClaudeCodeActivityAnalyzer {
  public static func hasAskUserQuestion(transcriptTail: String) -> Bool {
    transcriptTail.contains(#""name":"AskUserQuestion""#)
      || transcriptTail.contains(#""name": "AskUserQuestion""#)
      || transcriptTail.contains("AskUserQuestion")
  }

  public static func status(hookEventName: String, transcriptTail: String? = nil) -> ClaudeCodeActivityStatusValue {
    switch hookEventName {
    case "UserPromptSubmit":
      return .working
    case "PermissionRequest":
      return .waitingUserResponse
    case "Stop":
      return hasAskUserQuestion(transcriptTail: transcriptTail ?? "") ? .waitingUserResponse : .idle
    default:
      return .idle
    }
  }
}

public struct ClaudeCodeAccountInfo: Equatable, Sendable {
  public var accountUuid: String
  public var emailAddress: String
  public var displayName: String
  public var organizationName: String

  public init(accountUuid: String, emailAddress: String, displayName: String, organizationName: String) {
    self.accountUuid = accountUuid
    self.emailAddress = emailAddress
    self.displayName = displayName
    self.organizationName = organizationName
  }
}

public enum ClaudeCodeConfigReader {
  public static func defaultConfigPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    URL(fileURLWithPath: environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true).appendingPathComponent(".claude.json").path
  }

  public static func account(path: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ClaudeCodeAccountInfo? {
    let resolved = path ?? defaultConfigPath(environment: environment)
    guard FileManager.default.fileExists(atPath: resolved) else {
      return nil
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: resolved))
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    guard let oauth = object["oauthAccount"] as? [String: Any] else {
      return nil
    }
    guard let accountUuid = oauth["accountUuid"] as? String,
      let emailAddress = oauth["emailAddress"] as? String,
      let displayName = oauth["displayName"] as? String,
      let organizationName = oauth["organizationName"] as? String
    else {
      return nil
    }
    return ClaudeCodeAccountInfo(accountUuid: accountUuid, emailAddress: emailAddress, displayName: displayName, organizationName: organizationName)
  }
}
