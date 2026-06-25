import Foundation
import RielaCore

public enum CursorCLIAgentSDK {
  public enum StreamMode: String, Equatable, Sendable {
    case raw
    case normalized
  }

  public struct Request: Equatable, Sendable {
    public var prompt: String?
    public var sessionId: String?
    public var options: CursorCLIProcessOptions
    public var streamMode: StreamMode

    public init(prompt: String? = nil, sessionId: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions(), streamMode: StreamMode = .raw) {
      self.prompt = prompt
      self.sessionId = sessionId
      self.options = options
      self.streamMode = streamMode
    }
  }

  public static func runAgent<Runner: CursorCLISessionRunner>(request: Request, runner: Runner) throws -> [CursorCLIAgentNormalizedEvent] {
    let resumed = request.sessionId != nil
    let session: Runner.Session
    do {
      if let sessionId = request.sessionId {
        session = try runner.resumeSession(sessionId: sessionId, prompt: request.prompt, options: request.options)
      } else {
        session = try runner.startSession(config: CursorCLISessionConfig(prompt: request.prompt ?? "", options: request.options))
      }
    } catch {
      return [
        CursorCLIAgentNormalizedEvent(
          type: "session.error",
          sessionId: request.sessionId ?? "unknown-session",
          payload: ["message": .string(String(describing: error))]
        )
      ]
    }
    let result = session.waitForCompletion()
    let messages = session.messages()
    let resolvedSessionId = sessionId(from: messages) ?? session.sessionId
    let started = CursorCLIAgentNormalizedEvent(type: "session.started", sessionId: resolvedSessionId, payload: ["resumed": .bool(resumed)])
    let completed = completedEvent(result: result, sessionId: resolvedSessionId, normalized: request.streamMode == .normalized)
    if request.streamMode == .raw {
      return [started] + messages.flatMap { line -> [CursorCLIAgentNormalizedEvent] in
        var events = [rawMessageEvent(from: line, sessionId: resolvedSessionId)]
        if let error = rolloutErrorEvent(from: line, sessionId: resolvedSessionId) {
          events.append(error)
        }
        return events
      } + [completed]
    }
    var normalizer = CursorCLIAgentEventNormalizer()
    let normalized = messages.flatMap { line -> [CursorCLIAgentNormalizedEvent] in
      var chunk: JSONObject = ["type": .string(line.type), "payload": line.payload]
      if line.type == "assistant.snapshot", let content = line.payloadObject?["content"] {
        chunk["content"] = content
      }
      return normalizer.normalize(chunk, fallbackSessionId: resolvedSessionId, includeSessionStarted: false)
    }
    return [started] + normalized + [completed]
  }

  private static func sessionId(from lines: [CursorCLIRolloutLine]) -> String? {
    for line in lines where line.type == "session_meta" {
      guard let object = line.payloadObject else {
        continue
      }
      if case let .object(meta)? = object["meta"], case let .string(id)? = meta["id"] {
        return id
      }
      if case let .string(id)? = object["session_id"] ?? object["sessionId"] ?? object["id"] {
        return id
      }
    }
    return nil
  }

  private static func rawMessageEvent(from line: CursorCLIRolloutLine, sessionId: String) -> CursorCLIAgentNormalizedEvent {
    CursorCLIAgentNormalizedEvent(type: "session.message", sessionId: sessionId, payload: ["chunk": rawLineValue(from: line)])
  }

  private static func rolloutErrorEvent(from line: CursorCLIRolloutLine, sessionId: String) -> CursorCLIAgentNormalizedEvent? {
    guard
      line.type == "event_msg",
      let object = line.payloadObject,
      stringValue(object["type"]) == "Error"
    else {
      return nil
    }
    return CursorCLIAgentNormalizedEvent(type: "session.error", sessionId: sessionId, payload: ["message": .string(stringValue(object["message"]) ?? "Unknown rollout error")])
  }

  private static func completedEvent(result: CursorCLISessionResult, sessionId: String, normalized: Bool) -> CursorCLIAgentNormalizedEvent {
    if normalized {
      return CursorCLIAgentNormalizedEvent(
        type: "session.completed",
        sessionId: sessionId,
        payload: [
          "success": .bool(result.success),
          "exitCode": .number(Double(result.exitCode))
        ]
      )
    }
    return CursorCLIAgentNormalizedEvent(type: "session.completed", sessionId: sessionId, payload: ["result": .object(sessionResultJSON(result))])
  }

  private static func sessionResultJSON(_ result: CursorCLISessionResult) -> JSONObject {
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

  private static func rawLineValue(from line: CursorCLIRolloutLine) -> JSONValue {
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

final class CursorCLIResumeRolloutCapture: @unchecked Sendable {
  private let lock = NSLock()
  private let sessionId: String
  private let cursorCLIHome: String?
  private let watcher: CursorCLIRolloutWatcher
  private var attachedPath: String?
  private var closed = false

  init(sessionId: String, cursorCLIHome: String?, initialSession: CursorCLISession?) {
    self.sessionId = sessionId
    self.cursorCLIHome = cursorCLIHome
    self.watcher = CursorCLIRolloutWatcher()
    if let initialSession {
      attachedPath = initialSession.rolloutPath
      watcher.watchFile(path: initialSession.rolloutPath, startOffset: rolloutFileSize(path: initialSession.rolloutPath))
    } else {
      watcher.watchSessionsDirectory(path: CursorCLIRolloutWatcher.sessionsWatchDir(cursorCLIHome: cursorCLIHome))
    }
  }

  func flush(includeFinalBackfill: Bool) -> [CursorCLIRolloutLine] {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return []
    }
    lock.unlock()

    var lines: [CursorCLIRolloutLine] = []
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

  private func finalBackfill() -> [CursorCLIRolloutLine] {
    let path: String?
    lock.lock()
    path = attachedPath
    lock.unlock()
    if let path {
      return (try? CursorCLIRolloutReader.readRollout(path: path)) ?? []
    }
    guard let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome) else {
      return []
    }
    lock.lock()
    if attachedPath == nil {
      attachedPath = session.rolloutPath
    }
    lock.unlock()
    return (try? CursorCLIRolloutReader.readRollout(path: session.rolloutPath)) ?? []
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
  guard let first = try? CursorCLIRolloutReader.readRollout(path: path).first else {
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

extension Array where Element == CursorCLIRolloutLine {
  func deduplicatingStableRolloutLines() -> [CursorCLIRolloutLine] {
    var seen = Set<String>()
    var lines: [CursorCLIRolloutLine] = []
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

  func streamChunks(granularity: String, sessionId: String) -> [CursorCLIRolloutLine] {
    guard granularity == "char" else {
      return self
    }
    return flatMap { line -> [CursorCLIRolloutLine] in
      let segments = line.assistantTextSegments
      guard !segments.isEmpty else {
        return [line]
      }
      return segments.flatMap { segment in
        segment.map { character in
          CursorCLIRolloutLine(
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

extension CursorCLIRolloutLine {
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
  return String(data: data, encoding: .utf8) ?? "\(value)"
}

private func stringValue(_ value: JSONValue?) -> String? {
  guard case let .string(string)? = value else {
    return nil
  }
  return string
}
