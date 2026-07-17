import Foundation
import RielaCore

public enum CodexAgentSDK {
  public enum StreamMode: String, Equatable, Sendable {
    case raw
    case normalized
  }

  public struct Request: Equatable, Sendable {
    public var prompt: String?
    public var sessionId: String?
    public var options: CodexProcessOptions
    public var streamMode: StreamMode

    public init(prompt: String? = nil, sessionId: String? = nil, options: CodexProcessOptions = CodexProcessOptions(), streamMode: StreamMode = .raw) {
      self.prompt = prompt
      self.sessionId = sessionId
      self.options = options
      self.streamMode = streamMode
    }
  }

  public static func runAgent<Runner: CodexSessionRunner>(request: Request, runner: Runner) throws -> [CodexAgentNormalizedEvent] {
    let resumed = request.sessionId != nil
    let session: Runner.Session
    do {
      if let sessionId = request.sessionId {
        session = try runner.resumeSession(sessionId: sessionId, prompt: request.prompt, options: request.options)
      } else {
        session = try runner.startSession(config: CodexSessionConfig(prompt: request.prompt ?? "", options: request.options))
      }
    } catch {
      return [
        CodexAgentNormalizedEvent(
          type: "session.error",
          sessionId: request.sessionId ?? "unknown-session",
          payload: ["message": .string(String(describing: error))]
        )
      ]
    }
    let result = session.waitForCompletion()
    let messages = session.messages()
    let resolvedSessionId = CodexSessionIdExtractor.firstSessionId(from: messages) ?? session.sessionId
    let started = CodexAgentNormalizedEvent(type: "session.started", sessionId: resolvedSessionId, payload: ["resumed": .bool(resumed)])
    let completed = completedEvent(result: result, sessionId: resolvedSessionId, normalized: request.streamMode == .normalized)
    if request.streamMode == .raw {
      return [started] + messages.flatMap { line -> [CodexAgentNormalizedEvent] in
        var events = [rawMessageEvent(from: line, sessionId: resolvedSessionId)]
        if let error = rolloutErrorEvent(from: line, sessionId: resolvedSessionId) {
          events.append(error)
        }
        return events
      } + [completed]
    }
    var normalizer = CodexAgentEventNormalizer()
    let normalized = messages.flatMap { line -> [CodexAgentNormalizedEvent] in
      var chunk: JSONObject = ["type": .string(line.type), "payload": line.payload]
      if line.type == "assistant.snapshot", let content = line.payloadObject?["content"] {
        chunk["content"] = content
      }
      return normalizer.normalize(chunk, fallbackSessionId: resolvedSessionId, includeSessionStarted: false)
    }
    return [started] + normalized + [completed]
  }

  private static func rawMessageEvent(from line: CodexRolloutLine, sessionId: String) -> CodexAgentNormalizedEvent {
    CodexAgentNormalizedEvent(type: "session.message", sessionId: sessionId, payload: ["chunk": rawLineValue(from: line)])
  }

  private static func rolloutErrorEvent(from line: CodexRolloutLine, sessionId: String) -> CodexAgentNormalizedEvent? {
    guard
      line.type == "event_msg",
      let object = line.payloadObject,
      stringValue(object["type"]) == "Error"
    else {
      return nil
    }
    return CodexAgentNormalizedEvent(type: "session.error", sessionId: sessionId, payload: ["message": .string(stringValue(object["message"]) ?? "Unknown rollout error")])
  }

  private static func completedEvent(result: CodexSessionResult, sessionId: String, normalized: Bool) -> CodexAgentNormalizedEvent {
    if normalized {
      return CodexAgentNormalizedEvent(
        type: "session.completed",
        sessionId: sessionId,
        payload: [
          "success": .bool(result.success),
          "exitCode": .number(Double(result.exitCode))
        ]
      )
    }
    return CodexAgentNormalizedEvent(type: "session.completed", sessionId: sessionId, payload: ["result": .object(sessionResultJSON(result))])
  }

  private static func sessionResultJSON(_ result: CodexSessionResult) -> JSONObject {
    [
      "success": .bool(result.success),
      "exitCode": .number(Double(result.exitCode)),
      "stats": .object([
        "startedAt": .string(result.startedAt),
        "completedAt": .string(result.completedAt),
        "messageCount": .number(Double(result.messageCount))
      ])
    ]
  }

  private static func rawLineValue(from line: CodexRolloutLine) -> JSONValue {
    var payload: JSONObject = [
      "timestamp": .string(line.timestamp),
      "type": .string(line.type),
      "payload": line.payload
    ]
    if let object = line.payloadObject {
      payload.merge(object) { current, _ in current }
    }
    return .object(payload)
  }
}

final class CodexResumeRolloutCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let sessionId: String
  private let codexHome: String?
  private let watcher: CodexRolloutWatcher
  private var attachedPath: String?
  private var closed = false

  init(sessionId: String, codexHome: String?, initialSession: CodexSession?) {
    self.sessionId = sessionId
    self.codexHome = codexHome
    self.watcher = CodexRolloutWatcher()
    if let initialSession {
      attachedPath = initialSession.rolloutPath
      watcher.watchFile(path: initialSession.rolloutPath, startOffset: rolloutFileSize(path: initialSession.rolloutPath))
    } else {
      watcher.watchSessionsDirectory(path: CodexRolloutWatcher.sessionsWatchDir(codexHome: codexHome))
    }
  }

  func flush(includeFinalBackfill: Bool) -> [CodexRolloutLine] {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return []
    }
    lock.unlock()

    var lines: [CodexRolloutLine] = []
    for event in watcher.flush() {
      switch event {
      case let .line(_, line):
        lines.append(line)
      case let .newSession(path):
        attachIfMatching(path: path)
      case .error:
        continue
      }
    }
    if includeFinalBackfill {
      lines.append(contentsOf: finalBackfill())
      stop()
    }
    return lines
  }

  private func attachIfMatching(path: String) {
    guard rolloutPath(path, matchesSessionId: sessionId) else {
      return
    }
    lock.lock()
    defer { lock.unlock() }
    guard !closed, attachedPath == nil else {
      return
    }
    attachedPath = path
    watcher.watchFile(path: path, startOffset: 0)
  }

  private func finalBackfill() -> [CodexRolloutLine] {
    let path: String?
    lock.lock()
    path = attachedPath
    lock.unlock()
    if let path {
      return (try? CodexRolloutReader.readRollout(path: path)) ?? []
    }
    guard let session = CodexSessionIndex.findSession(id: sessionId, codexHome: codexHome) else {
      return []
    }
    lock.lock()
    if attachedPath == nil {
      attachedPath = session.rolloutPath
    }
    lock.unlock()
    return (try? CodexRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }

  private func stop() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    watcher.stop()
  }
}

func rolloutFileSize(path: String) -> UInt64 {
  (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
}

func rolloutPath(_ path: String, matchesSessionId sessionId: String) -> Bool {
  if URL(fileURLWithPath: path).lastPathComponent.contains(sessionId) {
    return true
  }
  guard let first = try? CodexRolloutReader.readRollout(path: path).first else {
    return false
  }
  if first.type == "session_meta", let object = first.payloadObject {
    if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
      return id == sessionId
    }
    if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
      return id == sessionId
    }
  }
  return false
}

extension Array where Element == CodexRolloutLine {
  func deduplicatingStableRolloutLines() -> [CodexRolloutLine] {
    var seen = Set<String>()
    var lines: [CodexRolloutLine] = []
    for line in self {
      let key = line.stableLineKey
      guard !seen.contains(key) else {
        continue
      }
      seen.insert(key)
      lines.append(line)
    }
    return lines
  }

  func streamChunks(granularity: String, sessionId: String) -> [CodexRolloutLine] {
    guard granularity == "char" else {
      return self
    }
    return flatMap { line -> [CodexRolloutLine] in
      let segments = line.assistantTextSegments
      guard !segments.isEmpty else {
        return [line]
      }
      return segments.flatMap { segment in
        segment.map { character in
          CodexRolloutLine(
            timestamp: line.timestamp,
            type: "assistant.delta",
            payload: .object([
              "kind": .string("char"),
              "char": .string(String(character)),
              "sessionId": .string(sessionId),
              "sourceType": .string(line.type),
              "source": line.jsonLineValue
            ]),
            provenance: line.provenance
          )
        }
      }
    }
  }
}

extension CodexRolloutLine {
  var payloadObject: JSONObject? {
    guard case let .object(object) = payload else {
      return nil
    }
    return object
  }

  var assistantTextSegments: [String] {
    if type == "event_msg" {
      guard
        let object = payloadObject,
        stringValue(object["type"]) == "AgentMessage",
        let message = stringValue(object["message"]),
        !message.isEmpty
      else {
        return []
      }
      return [message]
    }
    guard
      type == "response_item",
      let object = payloadObject,
      stringValue(object["type"]) == "message",
      stringValue(object["role"]) == "assistant",
      case let .array(content)? = object["content"]
    else {
      return []
    }
    return content.compactMap { entry -> String? in
      guard
        case let .object(item) = entry,
        ["output_text", "input_text"].contains(stringValue(item["type"])),
        let text = stringValue(item["text"]),
        !text.isEmpty
      else {
        return nil
      }
      return text
    }
  }

  var stableLineKey: String {
    jsonString(jsonLineValue)
  }

  var jsonLineValue: JSONValue {
    .object([
      "timestamp": .string(timestamp),
      "type": .string(type),
      "payload": payload
    ])
  }
}

private func jsonString(_ value: JSONValue) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  guard let data = try? encoder.encode(value) else {
    return "\(value)"
  }
  return String(data: data, encoding: .utf8) ?? ""
}

func processOutputString(from data: Data) -> String {
  // Preserve subprocess output with replacement characters instead of dropping invalid chunks.
  // swiftlint:disable:next optional_data_string_conversion
  return String(decoding: data, as: UTF8.self)
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
