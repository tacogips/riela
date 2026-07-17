import AgentRuntimeKit
import Foundation
import RielaCore

public typealias CodexProcessStatus = AgentProcessStatus
public typealias CodexProcessRecord = AgentProcessRecord
public typealias CodexProcessExecution = AgentProcessExecution
public typealias CodexExecStreamResult = AgentExecStreamResult<CodexRolloutLine>
public typealias CodexRolloutLineStream = AgentRolloutLineStream<CodexRolloutLine>
public typealias CodexProcessCompletion = AgentProcessCompletion

public final class CodexProcessManager: @unchecked Sendable {
  public typealias Executor = @Sendable ([String], String, [String: String]) -> CodexProcessExecution
  private let supervisor: AgentProcessSupervisor<ManagedCodexProcess>

  public init(executableName: String = "codex", executor: Executor? = nil) {
    self.supervisor = AgentProcessSupervisor(executableName: executableName, executor: executor)
  }

  public func spawnExec(prompt: String, options: CodexProcessOptions = CodexProcessOptions()) -> (process: CodexProcessRecord, result: CodexProcessExecution) {
    let arguments = CodexProcessCommandBuilder.buildExecArguments(prompt: "-", options: options)
    return run(prompt: prompt, arguments: arguments, options: options, initialInput: prompt)
  }

  public func spawnResume(sessionId: String, prompt: String? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> (process: CodexProcessRecord, result: CodexProcessExecution) {
    run(prompt: prompt ?? "", arguments: CodexProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func spawnResumeProcess(sessionId: String, prompt: String? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> CodexProcessRecord {
    let arguments = CodexProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options)
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

  public func spawnFork(sessionId: String, nthMessage: Int? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> (process: CodexProcessRecord, result: CodexProcessExecution) {
    run(prompt: "", arguments: CodexProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options), options: options)
  }

  public func spawnForkProcess(sessionId: String, nthMessage: Int? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> CodexProcessRecord {
    let arguments = CodexProcessCommandBuilder.buildForkArguments(sessionId: sessionId, nthMessage: nthMessage, options: options)
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

  public func spawnExecStream(prompt: String, options: CodexProcessOptions = CodexProcessOptions()) -> CodexExecStreamResult {
    let arguments = CodexProcessCommandBuilder.buildExecArguments(prompt: "-", options: options)
    return stream(prompt: prompt, arguments: arguments, options: options, initialInput: prompt)
  }

  public func spawnResumeStream(sessionId: String, prompt: String? = nil, options: CodexProcessOptions = CodexProcessOptions()) -> CodexExecStreamResult {
    stream(prompt: prompt ?? "", arguments: CodexProcessCommandBuilder.buildResumeArguments(sessionId: sessionId, prompt: prompt, options: options), options: options)
  }

  public func list() -> [CodexProcessRecord] {
    supervisor.list()
  }

  public func get(id: String) -> CodexProcessRecord? {
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

  private func run(
    prompt: String,
    arguments: [String],
    options: CodexProcessOptions,
    initialInput: String? = nil
  ) -> (process: CodexProcessRecord, result: CodexProcessExecution) {
    supervisor.run(
      prompt: prompt,
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      initialInput: initialInput,
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  private func stream(
    prompt: String,
    arguments: [String],
    options: CodexProcessOptions,
    initialInput: String? = nil
  ) -> CodexExecStreamResult {
    supervisor.stream(
      prompt: prompt,
      arguments: arguments,
      environment: Self.environment(options),
      cwd: options.cwd,
      initialInput: initialInput,
      makeOutputBuffers: { ProcessOutputBuffers() },
      makeManaged: Self.makeManaged,
      makeFailedManaged: Self.makeFailedManaged
    )
  }

  private static func environment(_ options: CodexProcessOptions) -> [String: String] {
    CodexProcessCommandBuilder.buildEnvironment(options: options)
  }

  private static func makeManaged(process: Process, input: FileHandle, output: FileHandle, error: FileHandle) -> ManagedCodexProcess {
    ManagedCodexProcess(process: process, input: input, output: output, error: error)
  }

  private static func makeFailedManaged(_ error: Error) -> ManagedCodexProcess {
    ManagedCodexProcess(failedExecution: CodexProcessExecution(stdout: "", stderr: error.localizedDescription, exitCode: 127))
  }
}

public final class CodexProcessRunningSession: CodexRunningSession, @unchecked Sendable {
  private let state: AgentRunningSessionState<CodexRolloutLine>

  fileprivate init(
    sessionId: String,
    processRecord: CodexProcessRecord,
    streamResult: CodexExecStreamResult,
    existingLines: [CodexRolloutLine] = [],
    streamGranularity: String = "event",
    resumeCapture: CodexResumeRolloutCapture? = nil,
    terminateProcess: @escaping @Sendable () -> Bool = { false }
  ) {
    let resumeBackfill: AgentRunningSessionState<CodexRolloutLine>.ResumeBackfill?
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
      sessionIdResolver: { lines in CodexSessionIdExtractor.firstSessionId(from: lines) },
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

  public func pushMessage(_ message: CodexRolloutLine) throws {
    throw CodexProcessSessionError.readOnlySession
  }

  public func messages() -> [CodexRolloutLine] {
    state.messages()
  }

  public func waitForCompletion() -> CodexSessionResult {
    CodexSessionResult(state.waitForCompletion())
  }

  public func cancel() -> CodexSessionResult {
    CodexSessionResult(state.cancel())
  }

}

private extension CodexSessionResult {
  init(_ completion: AgentRunningSessionCompletion<CodexRolloutLine>) {
    self.init(
      success: completion.success,
      exitCode: completion.exitCode,
      startedAt: completion.startedAt,
      completedAt: completion.completedAt,
      messageCount: completion.messageCount
    )
  }
}

public final class CodexProcessSessionRunner: CodexSessionRunner, @unchecked Sendable {
  public typealias Session = CodexProcessRunningSession
  private let processManager: CodexProcessManager

  public init(processManager: CodexProcessManager = CodexProcessManager()) {
    self.processManager = processManager
  }

  public func startSession(config: CodexSessionConfig) throws -> CodexProcessRunningSession {
    if let resumeSessionId = config.resumeSessionId {
      return try resumeSession(sessionId: resumeSessionId, prompt: config.prompt, options: config.options)
    }
    let result = processManager.spawnExecStream(prompt: config.prompt, options: config.options)
    return CodexProcessRunningSession(
      sessionId: CodexSessionIdExtractor.firstSessionId(from: result.lines.snapshot()) ?? result.process.id,
      processRecord: result.process,
      streamResult: result,
      streamGranularity: config.options.streamGranularity ?? "event",
      terminateProcess: { [processManager, processId = result.process.id] in
        processManager.kill(id: processId)
      }
    )
  }

  public func resumeSession(sessionId: String, prompt: String?, options: CodexProcessOptions) throws -> CodexProcessRunningSession {
    let codexHome = options.codexHome ?? options.environmentVariables["CODEX_HOME"]
    let session = CodexSessionIndex.findSession(id: sessionId, codexHome: codexHome)
    let existingLines = options.includeExistingOnResume ? existingRolloutLines(session: session) : []
    let capture = CodexResumeRolloutCapture(sessionId: sessionId, codexHome: codexHome, initialSession: session)
    let result = processManager.spawnResumeStream(sessionId: sessionId, prompt: prompt, options: options)
    return CodexProcessRunningSession(
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

  private func existingRolloutLines(session: CodexSession?) -> [CodexRolloutLine] {
    guard let session else {
      return []
    }
    return (try? CodexRolloutReader.readRollout(path: session.rolloutPath)) ?? []
  }
}

public enum CodexProcessSessionError: Error, Equatable {
  case readOnlySession
}

private func parseStdoutLines(_ stdout: String) -> [CodexRolloutLine] {
  stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { CodexRolloutReader.parseRolloutLine(String($0)) }
}
