import Foundation
import RielaCore

public enum CodexSessionIdObservation: Equatable, Sendable {
  case none
  case identified(String)
  case ambiguous
}

public enum CodexSessionIdExtractor {
  public static func observation(from stdout: String) -> CodexSessionIdObservation {
    var ids: Set<String> = []
    for line in stdout.split(whereSeparator: \.isNewline) {
      ids.formUnion(sessionIds(fromJSONLine: String(line)))
    }
    return observation(from: ids)
  }

  public static func sessionIds(fromJSONLine line: String) -> Set<String> {
    guard
      let data = line.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case let .object(object) = value
    else {
      return []
    }
    return sessionIds(from: object, eventType: string(object["type"]))
  }

  static func firstSessionId(from lines: [CodexRolloutLine]) -> String? {
    for line in lines {
      let ids = sessionIds(from: line.payloadObject ?? [:], eventType: line.type)
      if let id = ids.sorted().first {
        return id
      }
    }
    return nil
  }

  private static func sessionIds(from object: JSONObject, eventType: String?) -> Set<String> {
    var ids: Set<String> = []
    switch eventType {
    case "thread.started":
      append(string(object["thread_id"]), to: &ids)
      if let payload = objectValue(object["payload"]) {
        append(string(payload["thread_id"]), to: &ids)
      }
    case "session_meta":
      appendSessionMetaIds(from: object, to: &ids)
      if let payload = objectValue(object["payload"]) {
        appendSessionMetaIds(from: payload, to: &ids)
      }
    default:
      break
    }
    return ids
  }

  private static func appendSessionMetaIds(from object: JSONObject, to ids: inout Set<String>) {
    if let meta = objectValue(object["meta"]) {
      append(string(meta["id"]), to: &ids)
    }
    append(string(object["session_id"]), to: &ids)
    append(string(object["sessionId"]), to: &ids)
    append(string(object["id"]), to: &ids)
  }

  private static func append(_ candidate: String?, to ids: inout Set<String>) {
    guard let candidate else {
      return
    }
    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      ids.insert(trimmed)
    }
  }

  private static func observation(from ids: Set<String>) -> CodexSessionIdObservation {
    switch ids.count {
    case 0:
      return CodexSessionIdObservation.none
    case 1:
      return ids.first.map(CodexSessionIdObservation.identified) ?? CodexSessionIdObservation.none
    default:
      return .ambiguous
    }
  }

  private static func string(_ value: JSONValue?) -> String? {
    guard case let .string(text) = value else {
      return nil
    }
    return text
  }

  private static func objectValue(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object) = value else {
      return nil
    }
    return object
  }
}

final class CodexSessionIdCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: Set<String> = []
  private var processSucceeded = false

  func observe(_ line: String) {
    let observed = CodexSessionIdExtractor.sessionIds(fromJSONLine: line)
    lock.lock()
    ids.formUnion(observed)
    lock.unlock()
  }

  func markProcessSucceeded() {
    lock.lock()
    processSucceeded = true
    lock.unlock()
  }

  func successfulObservation() -> CodexSessionIdObservation? {
    lock.lock()
    defer { lock.unlock() }
    guard processSucceeded else {
      return nil
    }
    switch ids.count {
    case 0:
      return CodexSessionIdObservation.none
    case 1:
      return ids.first.map(CodexSessionIdObservation.identified) ?? CodexSessionIdObservation.none
    default:
      return .ambiguous
    }
  }
}
