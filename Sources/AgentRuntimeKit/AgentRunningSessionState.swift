import Foundation

public struct AgentRunningSessionCompletion<Line>: Sendable where Line: Sendable {
  public var success: Bool
  public var exitCode: Int32
  public var startedAt: String
  public var completedAt: String
  public var messageCount: Int
  public var lines: [Line]

  public init(
    success: Bool,
    exitCode: Int32,
    startedAt: String,
    completedAt: String,
    messageCount: Int,
    lines: [Line]
  ) {
    self.success = success
    self.exitCode = exitCode
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.messageCount = messageCount
    self.lines = lines
  }
}

public final class AgentRunningSessionState<Line: Sendable>: @unchecked Sendable {
  public typealias ResumeBackfill = @Sendable (_ includeFinalBackfill: Bool) -> [Line]
  public typealias SessionIdResolver = @Sendable (_ lines: [Line]) -> String?
  public typealias LineDeduplicator = @Sendable (_ lines: [Line]) -> [Line]
  public typealias StreamChunker = @Sendable (_ lines: [Line], _ granularity: String, _ sessionId: String) -> [Line]

  private let lock = NSLock()
  private var currentSessionId: String
  private let processRecord: AgentProcessRecord
  private let streamResult: AgentExecStreamResult<Line>
  private let existingLines: [Line]
  private let streamGranularity: String
  private let resumeBackfill: ResumeBackfill?
  private let terminateProcess: @Sendable () -> Bool
  private let sessionIdResolver: SessionIdResolver
  private let lineDeduplicator: LineDeduplicator
  private let streamChunker: StreamChunker
  private var collectedLines: [Line]?
  private var closed = false

  public init(
    sessionId: String,
    processRecord: AgentProcessRecord,
    streamResult: AgentExecStreamResult<Line>,
    existingLines: [Line] = [],
    streamGranularity: String = "event",
    resumeBackfill: ResumeBackfill? = nil,
    terminateProcess: @escaping @Sendable () -> Bool = { false },
    sessionIdResolver: @escaping SessionIdResolver,
    lineDeduplicator: @escaping LineDeduplicator,
    streamChunker: @escaping StreamChunker
  ) {
    self.currentSessionId = sessionId
    self.processRecord = processRecord
    self.streamResult = streamResult
    self.existingLines = existingLines
    self.streamGranularity = streamGranularity
    self.resumeBackfill = resumeBackfill
    self.terminateProcess = terminateProcess
    self.sessionIdResolver = sessionIdResolver
    self.lineDeduplicator = lineDeduplicator
    self.streamChunker = streamChunker
  }

  public var sessionId: String {
    lock.lock()
    defer { lock.unlock() }
    return currentSessionId
  }

  public func getState() -> [String: String] {
    let sessionId = refreshSessionId(from: streamLines(includeFinalBackfill: false))
    lock.lock()
    defer { lock.unlock() }
    return [
      "sessionId": sessionId,
      "processId": processRecord.id,
      "status": closed ? "completed" : "running"
    ]
  }

  public func messages() -> [Line] {
    lock.lock()
    if let collectedLines {
      lock.unlock()
      return collectedLines
    }
    lock.unlock()
    let mergedLines = streamLines(includeFinalBackfill: false)
    let sessionId = refreshSessionId(from: mergedLines)
    return streamChunker(mergedLines, streamGranularity, sessionId)
  }

  public func waitForCompletion() -> AgentRunningSessionCompletion<Line> {
    let exitCode = streamResult.waitForCompletion()
    return close(exitCode: exitCode, success: exitCode == 0)
  }

  public func cancel() -> AgentRunningSessionCompletion<Line> {
    _ = terminateProcess()
    _ = streamResult.waitForCompletion()
    return close(exitCode: 130, success: false)
  }

  private func close(exitCode: Int32, success: Bool) -> AgentRunningSessionCompletion<Line> {
    let mergedLines = streamLines(includeFinalBackfill: true)
    let sessionId = refreshSessionId(from: mergedLines)
    let lines = streamChunker(mergedLines, streamGranularity, sessionId)
    lock.lock()
    collectedLines = lines
    closed = true
    lock.unlock()
    return AgentRunningSessionCompletion(
      success: success,
      exitCode: exitCode,
      startedAt: processRecord.startedAt,
      completedAt: agentRuntimeISO8601Now(),
      messageCount: mergedLines.count,
      lines: lines
    )
  }

  private func streamLines(includeFinalBackfill: Bool) -> [Line] {
    var lines = existingLines + streamResult.lines.snapshot()
    if let resumeBackfill {
      lines.append(contentsOf: resumeBackfill(includeFinalBackfill))
    }
    return lineDeduplicator(lines)
  }

  @discardableResult
  private func refreshSessionId(from lines: [Line]) -> String {
    let resolved = sessionIdResolver(lines)
    lock.lock()
    if let resolved {
      currentSessionId = resolved
    }
    let value = currentSessionId
    lock.unlock()
    return value
  }
}
