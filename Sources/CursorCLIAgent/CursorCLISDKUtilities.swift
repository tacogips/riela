import Foundation
import RielaCore

public struct CursorCLISessionConfig: Equatable, Sendable {
  public var prompt: String
  public var resumeSessionId: String?
  public var options: CursorCLIProcessOptions

  public init(prompt: String, resumeSessionId: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) {
    self.prompt = prompt
    self.resumeSessionId = resumeSessionId
    self.options = options
  }
}

public struct CursorCLISessionResult: Equatable, Sendable {
  public var success: Bool
  public var exitCode: Int32
  public var startedAt: String
  public var completedAt: String
  public var messageCount: Int

  public init(success: Bool, exitCode: Int32, startedAt: String, completedAt: String, messageCount: Int) {
    self.success = success
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.messageCount = messageCount
  }
}

public protocol CursorCLIRunningSession: AnyObject, Sendable {
  var sessionId: String { get }
  func getState() -> [String: String]
  func pushMessage(_ message: CursorCLIRolloutLine) throws
  func messages() -> [CursorCLIRolloutLine]
  func waitForCompletion() -> CursorCLISessionResult
  func cancel() -> CursorCLISessionResult
}

public protocol CursorCLISessionRunner: AnyObject, Sendable {
  associatedtype Session: CursorCLIRunningSession

  func startSession(config: CursorCLISessionConfig) throws -> Session
  func resumeSession(sessionId: String, prompt: String?, options: CursorCLIProcessOptions) throws -> Session
}

public struct CursorCLIMockStartSessionCall: Equatable, Sendable {
  public var config: CursorCLISessionConfig
}

public struct CursorCLIMockResumeSessionCall: Equatable, Sendable {
  public var sessionId: String
  public var prompt: String?
  public var options: CursorCLIProcessOptions
}

public final class MockCursorCLIRunningSession: CursorCLIRunningSession, @unchecked Sendable {
  private let lock = NSLock()
  public let sessionId: String
  private var queue: [CursorCLIRolloutLine]
  private var closed: Bool
  private let autoComplete: Bool
  private let resultTemplate: CursorCLISessionResult?

  public init(sessionId: String, messages: [CursorCLIRolloutLine] = [], result: CursorCLISessionResult? = nil, autoComplete: Bool = true) {
    self.sessionId = sessionId
    self.queue = messages
    self.closed = false
    self.autoComplete = autoComplete
    self.resultTemplate = result
  }

  public func getState() -> [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return ["status": closed ? "completed" : "running"]
  }

  public func pushMessage(_ message: CursorCLIRolloutLine) throws {
    lock.lock()
    defer { lock.unlock() }
    if closed {
      throw CursorCLIMockSessionError.closed(sessionId)
    }
    queue.append(message)
  }

  public func messages() -> [CursorCLIRolloutLine] {
    lock.lock()
    defer { lock.unlock() }
    if autoComplete {
      closed = true
    }
    return queue
  }

  public func waitForCompletion() -> CursorCLISessionResult {
    lock.lock()
    let messageCount = queue.count
    closed = true
    lock.unlock()
    if let resultTemplate {
      return resultTemplate
    }
    let now = ISO8601DateFormatter().string(from: Date())
    return CursorCLISessionResult(success: true, exitCode: 0, startedAt: now, completedAt: now, messageCount: messageCount)
  }

  public func cancel() -> CursorCLISessionResult {
    lock.lock()
    let messageCount = queue.count
    closed = true
    lock.unlock()
    let now = ISO8601DateFormatter().string(from: Date())
    return CursorCLISessionResult(success: false, exitCode: 130, startedAt: now, completedAt: now, messageCount: messageCount)
  }
}

public final class MockCursorCLISessionRunner: CursorCLISessionRunner, @unchecked Sendable {
  public typealias Session = MockCursorCLIRunningSession
  private let lock = NSLock()
  private var startSessions: [MockCursorCLIRunningSession] = []
  private var resumeSessions: [MockCursorCLIRunningSession] = []
  private var storedStartSessionCalls: [CursorCLIMockStartSessionCall] = []
  private var storedResumeSessionCalls: [CursorCLIMockResumeSessionCall] = []

  public init() {}

  public var startSessionCalls: [CursorCLIMockStartSessionCall] {
    lock.lock()
    defer { lock.unlock() }
    return storedStartSessionCalls
  }

  public var resumeSessionCalls: [CursorCLIMockResumeSessionCall] {
    lock.lock()
    defer { lock.unlock() }
    return storedResumeSessionCalls
  }

  public func enqueueStartSession(_ session: MockCursorCLIRunningSession) {
    lock.lock()
    startSessions.append(session)
    lock.unlock()
  }

  public func enqueueResumeSession(_ session: MockCursorCLIRunningSession) {
    lock.lock()
    resumeSessions.append(session)
    lock.unlock()
  }

  public func startSession(config: CursorCLISessionConfig) throws -> MockCursorCLIRunningSession {
    lock.lock()
    storedStartSessionCalls.append(CursorCLIMockStartSessionCall(config: config))
    guard !startSessions.isEmpty else {
      lock.unlock()
      throw CursorCLIMockSessionError.noQueuedSession("start")
    }
    let session = startSessions.removeFirst()
    lock.unlock()
    return session
  }

  public func resumeSession(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) throws -> MockCursorCLIRunningSession {
    lock.lock()
    storedResumeSessionCalls.append(CursorCLIMockResumeSessionCall(sessionId: sessionId, prompt: prompt, options: options))
    guard !resumeSessions.isEmpty else {
      lock.unlock()
      throw CursorCLIMockSessionError.noQueuedSession("resume")
    }
    let session = resumeSessions.removeFirst()
    lock.unlock()
    return session
  }
}

public enum CursorCLIMockSessionError: Error, Equatable {
  case closed(String)
  case noQueuedSession(String)
}

public func createMockCursorCLISessionRunner(startSessions: [MockCursorCLIRunningSession] = [], resumeSessions: [MockCursorCLIRunningSession] = []) -> MockCursorCLISessionRunner {
  let runner = MockCursorCLISessionRunner()
  startSessions.forEach { runner.enqueueStartSession($0) }
  resumeSessions.forEach { runner.enqueueResumeSession($0) }
  return runner
}

public enum CursorCLISDKEventType: String, Hashable, Sendable {
  case sessionStarted = "session.started"
  case sessionUpdated = "session.updated"
  case sessionCompleted = "session.completed"
  case error
}

public final class BasicCursorCLISDKEventEmitter: @unchecked Sendable {
  public typealias Handler = (JSONObject) -> Void
  private let lock = NSLock()
  private var handlers: [CursorCLISDKEventType: [UUID: Handler]] = [:]

  public init() {}

  @discardableResult
  public func on(_ event: CursorCLISDKEventType, handler: @escaping Handler) -> UUID {
    let id = UUID()
    lock.lock()
    var eventHandlers = handlers[event] ?? [:]
    eventHandlers[id] = handler
    handlers[event] = eventHandlers
    lock.unlock()
    return id
  }

  public func off(_ event: CursorCLISDKEventType, id: UUID) {
    lock.lock()
    handlers[event]?[id] = nil
    lock.unlock()
  }

  public func emit(_ event: CursorCLISDKEventType, payload: JSONObject) {
    lock.lock()
    let eventHandlers = Array((handlers[event] ?? [:]).values)
    lock.unlock()
    for handler in eventHandlers {
      handler(payload)
    }
  }
}

public struct CursorCLIToolRegistry: Equatable, Sendable {
  private var tools: [String: JSONObject]

  public init(tools: [String: JSONObject] = [:]) {
    self.tools = tools
  }

  public mutating func register(name: String, definition: JSONObject) {
    tools[name] = definition
  }

  public func get(_ name: String) -> JSONObject? {
    tools[name]
  }

  public func listNames() -> [String] {
    tools.keys.sorted()
  }
}

public enum CursorCLIAttachmentKind: Equatable, Sendable {
  case path(String)
  case base64(data: String, mediaType: String?, filename: String?)
}

public enum CursorCLIAgentAttachments {
  public static func imagePathArguments(from attachments: [CursorCLIAttachmentKind], tempDirectory: URL) throws -> [String] {
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    return try attachments.map { attachment in
      switch attachment {
      case let .path(path):
        return path
      case let .base64(data, mediaType, filename):
        let decoded = Data(base64Encoded: data) ?? Data()
        let safeName = sanitizedFilename(filename) ?? "attachment.\(extensionForMediaType(mediaType))"
        let url = tempDirectory.appendingPathComponent(safeName)
        try decoded.write(to: url)
        return url.path
      }
    }
  }

  public static func cleanup(paths: [String]) {
    for path in paths {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  private static func sanitizedFilename(_ filename: String?) -> String? {
    guard let filename, !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    let allowed = filename.map { character -> Character in
      character.isLetter || character.isNumber || [".", "-", "_"].contains(character) ? character : "_"
    }
    return String(allowed).split(separator: "/").last.map(String.init)
  }

  private static func extensionForMediaType(_ mediaType: String?) -> String {
    switch mediaType?.lowercased() {
    case "image/png":
      return "png"
    case "image/jpeg", "image/jpg":
      return "jpg"
    case "image/webp":
      return "webp"
    case "image/gif":
      return "gif"
    default:
      return "bin"
    }
  }
}
