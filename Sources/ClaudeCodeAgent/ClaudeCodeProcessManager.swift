import AgentRuntimeKit
import Foundation
import RielaCore

public typealias ClaudeCodeProcessStatus = AgentProcessStatus
public typealias ClaudeCodeProcessRecord = AgentProcessRecord
public typealias ClaudeCodeProcessExecution = AgentProcessExecution
public typealias ClaudeCodeExecStreamResult = AgentExecStreamResult<ClaudeCodeRolloutLine>
public typealias ClaudeCodeRolloutLineStream = AgentRolloutLineStream<ClaudeCodeRolloutLine>
public typealias ClaudeCodeProcessCompletion = AgentProcessCompletion

public final class ClaudeCodeProcessManager: @unchecked Sendable {
  public typealias Executor = @Sendable ([String], String, [String: String]) -> ClaudeCodeProcessExecution
  private let supervisor: AgentProcessSupervisor<ManagedClaudeCodeProcess>

  public init(executableName: String = "claude", executor: Executor? = nil) {
    self.supervisor = AgentProcessSupervisor(executableName: executableName, executor: executor)
  }

  public func spawnExec(prompt: String, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: prompt, arguments: ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResume(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: prompt ?? "", arguments: ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func spawnResumeProcess(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeProcessRecord {
    let arguments = ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
    return supervisor.startProcess(
      prompt: prompt ?? "",
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      closeInputAfterPrompt: false,
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  public func spawnFork(sessionId: String, nthMessage: Int? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    run(prompt: "", arguments: ClaudeCodeProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options), options: options)
  }

  public func spawnForkProcess(sessionId: String, nthMessage: Int? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeProcessRecord {
    let arguments = ClaudeCodeProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options)
    return supervisor.startProcess(
      prompt: "",
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      closeInputAfterPrompt: false,
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  public func spawnExecStream(prompt: String, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeExecStreamResult {
    stream(prompt: prompt, arguments: ClaudeCodeProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResumeStream(sessionId: String, prompt: String? = nil, options: ClaudeCodeProcessOptions = ClaudeCodeProcessOptions()) -> ClaudeCodeExecStreamResult {
    stream(prompt: prompt ?? "", arguments: ClaudeCodeProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func list() -> [ClaudeCodeProcessRecord] {
    supervisor.list()
  }

  public func get(id: String) -> ClaudeCodeProcessRecord? {
    supervisor.get(id: id)
  }

  public func kill(id: String) -> Bool {
    supervisor.kill(id: id)
  }

  public func writeInput(id: String, text: String) -> Bool {
    supervisor.writeInput(id: id, text: text)
  }

  public func killAll() {
    supervisor.killAll()
  }

  @discardableResult
  public func prune() -> Int {
    supervisor.prune()
  }

  private func run(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions) -> (process: ClaudeCodeProcessRecord, result: ClaudeCodeProcessExecution) {
    supervisor.run(
      prompt: prompt,
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  private func stream(prompt: String, arguments: [String], options: ClaudeCodeProcessOptions) -> ClaudeCodeExecStreamResult {
    supervisor.stream(
      prompt: prompt,
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      makeOutputBuffers: { ProcessOutputBuffers() },
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  private static func environment(_ options: ClaudeCodeProcessOptions) -> [String: String] {
    ClaudeCodeProcessCommandBuilder.buildEnvironment(options: options)
  }

  private static func makeManaged(process: Process, input: FileHandle, output: FileHandle, error: FileHandle) -> ManagedClaudeCodeProcess {
    ManagedClaudeCodeProcess(process: process, input: input, output: output, error: error)
  }

  private static func makeFailedManaged(_ error: Error) -> ManagedClaudeCodeProcess {
    ManagedClaudeCodeProcess(failedExecution: ClaudeCodeProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
  }
}

public final class ClaudeCodeProcessRunningSession: ClaudeCodeRunningSession, @unchecked Sendable {
  private let state: AgentRunningSessionState<ClaudeCodeRolloutLine>

  fileprivate init(
    sessionId: String,
    processRecord: ClaudeCodeProcessRecord,
    streamResult: ClaudeCodeExecStreamResult,
    existingLines: [ClaudeCodeRolloutLine] = [],
    streamGranularity: String = "event",
    resumeCapture: ClaudeCodeResumeRolloutCapture? = nil,
    terminateProcess: @escaping @Sendable () -> Bool = { false }
  ) {
    let resumeBackfill: AgentRunningSessionState<ClaudeCodeRolloutLine>.ResumeBackfill?
    if let resumeCapture {
      resumeBackfill = { includeFinalBackfill in
        resumeCapture.flush(includeFinalBackfill: includeFinalBackfill)
      }
    } else {
      resumeBackfill = nil
    }
    self.state = AgentRunningSessionState(
      sessionId: sessionId,
      processRecord: processRecord,
      streamResult: streamResult,
      existingLines: existingLines,
      streamGranularity: streamGranularity,
      resumeBackfill: resumeBackfill,
      terminateProcess: terminateProcess,
      sessionIdResolver: { lines in Self.sessionId(from: lines) },
      lineDeduplicator: { lines in lines.deduplicatingStableRolloutLines() },
      streamChunker: { lines, granularity, sessionId in
        lines.streamChunks(granularity: granularity, sessionId: sessionId)
      }
    )
  }

  public var sessionId: String {
    state.sessionId
  }

  public func getState() -> [String: String] {
    state.getState()
  }

  public func pushMessage(_ message: ClaudeCodeRolloutLine) throws {
    throw ClaudeCodeProcessSessionError.readOnlySession
  }

  public func messages() -> [ClaudeCodeRolloutLine] {
    state.messages()
  }

  public func waitForCompletion() -> ClaudeCodeSessionResult {
    ClaudeCodeSessionResult(state.waitForCompletion())
  }

  public func cancel() -> ClaudeCodeSessionResult {
    ClaudeCodeSessionResult(state.cancel())
  }

  private static func sessionId(from lines: [ClaudeCodeRolloutLine]) -> String? {
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
}

private extension ClaudeCodeSessionResult {
  init(_ completion: AgentRunningSessionCompletion<ClaudeCodeRolloutLine>) {
    self.init(
      success: completion.success,
      exitCode: completion.exitCode,
      startedAt: completion.startedAt,
      completedAt: completion.completedAt,
      messageCount: completion.messageCount
    )
  }
}

public final class ClaudeCodeProcessSessionRunner: ClaudeCodeSessionRunner, @unchecked Sendable {
  public typealias Session = ClaudeCodeProcessRunningSession
  private let processManager: ClaudeCodeProcessManager

  public init(processManager: ClaudeCodeProcessManager = ClaudeCodeProcessManager()) {
    self.processManager = processManager
  }

  public func startSession(config: ClaudeCodeSessionConfig) throws -> ClaudeCodeProcessRunningSession {
    if let resumeSessionId = config.resumeSessionId {
      return try resumeSession(sessionId: resumeSessionId, prompt: config.prompt, options: config.options)
    }
    let result = processManager.spawnExecStream(prompt: config.prompt, options: config.options)
    return ClaudeCodeProcessRunningSession(
      sessionId: sessionId(from: result.lines.snapshot()) ?? result.process.id,
      processRecord: result.process,
      streamResult: result,
      streamGranularity: config.options.streamGranularity ?? "event",
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  public func resumeSession(sessionId: String, prompt: String?, options: ClaudeCodeProcessOptions) throws -> ClaudeCodeProcessRunningSession {
    let claudeCodeHome = options.claudeCodeHome ?? options.environmentVariables["CLAUDE_CONFIG_DIR"]
    let session = ClaudeCodeSessionIndex.findSession(id: sessionId, claudeCodeHome: claudeCodeHome)
    let existingLines = options.includeExistingOnResume ? existingRolloutLines(session: session) : []
    let capture = ClaudeCodeResumeRolloutCapture(sessionId: sessionId, claudeCodeHome: claudeCodeHome, initialSession: session)
    let result = processManager.spawnResumeStream(sessionId: sessionId, prompt: prompt, options: options)
    return ClaudeCodeProcessRunningSession(
      sessionId: sessionId,
      processRecord: result.process,
      streamResult: result,
      existingLines: existingLines,
      streamGranularity: options.streamGranularity ?? "event",
      resumeCapture: capture,
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  private func sessionId(from lines: [ClaudeCodeRolloutLine]) -> String? {
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

  private func existingRolloutLines(session: ClaudeCodeSession?) -> [ClaudeCodeRolloutLine] {
    guard let session else {
      return []
    }
    return (try? ClaudeCodeRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }
}

public enum ClaudeCodeProcessSessionError: Error, Equatable {
  case readOnlySession
}

private func parseStdoutLines(_ stdout: String) -> [ClaudeCodeRolloutLine] {
  stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { ClaudeCodeRolloutReader.parseRolloutLine(String($0)) }
}
