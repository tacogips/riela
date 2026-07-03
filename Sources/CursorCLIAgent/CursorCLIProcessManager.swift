import AgentRuntimeKit
import Foundation
import RielaCore

public typealias CursorCLIProcessStatus = AgentProcessStatus
public typealias CursorCLIProcessRecord = AgentProcessRecord
public typealias CursorCLIProcessExecution = AgentProcessExecution
public typealias CursorCLIExecStreamResult = AgentExecStreamResult<CursorCLIRolloutLine>
public typealias CursorCLIRolloutLineStream = AgentRolloutLineStream<CursorCLIRolloutLine>
public typealias CursorCLIProcessCompletion = AgentProcessCompletion

public final class CursorCLIProcessManager: @unchecked Sendable {
  public typealias Executor = @Sendable ([String], String, [String: String]) -> CursorCLIProcessExecution
  private let supervisor: AgentProcessSupervisor<ManagedCursorCLIProcess>

  public init(executableName: String = "cursor-agent", executor: Executor? = nil) {
    self.supervisor = AgentProcessSupervisor(executableName: executableName, executor: executor)
  }

  public func spawnExec(prompt: String, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: prompt, arguments: CursorCLIProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResume(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: prompt ?? "", arguments: CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func spawnResumeProcess(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIProcessRecord {
    let arguments = CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
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

  public func spawnFork(sessionId: String, nthMessage: Int? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    run(prompt: "", arguments: CursorCLIProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options), options: options)
  }

  public func spawnForkProcess(sessionId: String, nthMessage: Int? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIProcessRecord {
    let arguments = CursorCLIProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options)
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

  public func spawnExecStream(prompt: String, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIExecStreamResult {
    stream(prompt: prompt, arguments: CursorCLIProcessCommandBuilder.buildExecArguments(prompt: prompt, options: options), options: options)
  }

  public func spawnResumeStream(sessionId: String, prompt: String? = nil, options: CursorCLIProcessOptions = CursorCLIProcessOptions()) -> CursorCLIExecStreamResult {
    stream(prompt: prompt ?? "", arguments: CursorCLIProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func list() -> [CursorCLIProcessRecord] {
    supervisor.list()
  }

  public func get(id: String) -> CursorCLIProcessRecord? {
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

  private func run(prompt: String, arguments: [String], options: CursorCLIProcessOptions) -> (process: CursorCLIProcessRecord, result: CursorCLIProcessExecution) {
    supervisor.run(
      prompt: prompt,
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  private func stream(prompt: String, arguments: [String], options: CursorCLIProcessOptions) -> CursorCLIExecStreamResult {
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

  private static func environment(_ options: CursorCLIProcessOptions) -> [String: String] {
    CursorCLIProcessCommandBuilder.buildEnvironment(options: options)
  }

  private static func makeManaged(process: Process, input: FileHandle, output: FileHandle, error: FileHandle) -> ManagedCursorCLIProcess {
    ManagedCursorCLIProcess(process: process, input: input, output: output, error: error)
  }

  private static func makeFailedManaged(_ error: Error) -> ManagedCursorCLIProcess {
    ManagedCursorCLIProcess(failedExecution: CursorCLIProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
  }
}

public final class CursorCLIProcessRunningSession: CursorCLIRunningSession, @unchecked Sendable {
  private let state: AgentRunningSessionState<CursorCLIRolloutLine>

  fileprivate init(
    sessionId: String,
    processRecord: CursorCLIProcessRecord,
    streamResult: CursorCLIExecStreamResult,
    existingLines: [CursorCLIRolloutLine] = [],
    streamGranularity: String = "event",
    resumeCapture: CursorCLIResumeRolloutCapture? = nil,
    terminateProcess: @escaping @Sendable () -> Bool = { false }
  ) {
    let resumeBackfill: AgentRunningSessionState<CursorCLIRolloutLine>.ResumeBackfill?
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

  public func pushMessage(_ message: CursorCLIRolloutLine) throws {
    throw CursorCLIProcessSessionError.readOnlySession
  }

  public func messages() -> [CursorCLIRolloutLine] {
    state.messages()
  }

  public func waitForCompletion() -> CursorCLISessionResult {
    CursorCLISessionResult(state.waitForCompletion())
  }

  public func cancel() -> CursorCLISessionResult {
    CursorCLISessionResult(state.cancel())
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
}

private extension CursorCLISessionResult {
  init(_ completion: AgentRunningSessionCompletion<CursorCLIRolloutLine>) {
    self.init(
      success: completion.success,
      exitCode: completion.exitCode,
      startedAt: completion.startedAt,
      completedAt: completion.completedAt,
      messageCount: completion.messageCount
    )
  }
}

public final class CursorCLIProcessSessionRunner: CursorCLISessionRunner, @unchecked Sendable {
  public typealias Session = CursorCLIProcessRunningSession
  private let processManager: CursorCLIProcessManager

  public init(processManager: CursorCLIProcessManager = CursorCLIProcessManager()) {
    self.processManager = processManager
  }

  public func startSession(config: CursorCLISessionConfig) throws -> CursorCLIProcessRunningSession {
    if let resumeSessionId = config.resumeSessionId {
      return try resumeSession(sessionId: resumeSessionId, prompt: config.prompt, options: config.options)
    }
    let result = processManager.spawnExecStream(prompt: config.prompt, options: config.options)
    return CursorCLIProcessRunningSession(
      sessionId: sessionId(from: result.lines.snapshot()) ?? result.process.id,
      processRecord: result.process,
      streamResult: result,
      streamGranularity: config.options.streamGranularity ?? "event",
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  public func resumeSession(sessionId: String, prompt: String?, options: CursorCLIProcessOptions) throws -> CursorCLIProcessRunningSession {
    let cursorCLIHome = options.cursorCLIHome ?? options.environmentVariables["CURSOR_CLI_AGENT_CURSOR_HOME"]
    let session = CursorCLISessionIndex.findSession(id: sessionId, cursorCLIHome: cursorCLIHome)
    let existingLines = options.includeExistingOnResume ? existingRolloutLines(session: session) : []
    let capture = CursorCLIResumeRolloutCapture(sessionId: sessionId, cursorCLIHome: cursorCLIHome, initialSession: session)
    let result = processManager.spawnResumeStream(sessionId: sessionId, prompt: prompt, options: options)
    return CursorCLIProcessRunningSession(
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

  private func sessionId(from lines: [CursorCLIRolloutLine]) -> String? {
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

  private func existingRolloutLines(session: CursorCLISession?) -> [CursorCLIRolloutLine] {
    guard let session else {
      return []
    }
    return (try? CursorCLIRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }
}

public enum CursorCLIProcessSessionError: Error, Equatable {
  case readOnlySession
}

private func parseStdoutLines(_ stdout: String) -> [CursorCLIRolloutLine] {
  stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { CursorCLIRolloutReader.parseRolloutLine(String($0)) }
}
