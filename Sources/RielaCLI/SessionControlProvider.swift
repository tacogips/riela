import Foundation
import RielaCore
import RielaGraphQL

/// Sessions this process is executing, so `stopSession` can cancel one and wait
/// for its terminal state before answering (design delta D3). A session absent
/// here is `session_not_running`: Riela never kills a session in another
/// process.
public actor RielaRunningSessionRegistry {
  public static let shared = RielaRunningSessionRegistry()

  private var running: [String: Task<Void, Never>] = [:]

  public init() {}

  public func register(sessionId: String, task: Task<Void, Never>) {
    running[sessionId] = task
  }

  public func unregister(sessionId: String) {
    running.removeValue(forKey: sessionId)
  }

  public func isRunning(sessionId: String) -> Bool {
    running[sessionId] != nil
  }

  /// Cancels the session and returns only once its task has finished, which is
  /// after the runner's cancellation path has persisted the terminal state.
  public func cancelAndAwait(sessionId: String) async -> Bool {
    guard let task = running.removeValue(forKey: sessionId) else { return false }
    task.cancel()
    await task.value
    return true
  }

  /// Runs `operation` while the session is registered as in-process.
  public func withRegisteredSession<T: Sendable>(
    sessionId: String,
    operation: @escaping @Sendable () async -> T
  ) async -> T {
    let box = SessionResultBox<T>()
    let task = Task { await box.set(operation()) }
    register(sessionId: sessionId, task: task)
    await task.value
    unregister(sessionId: sessionId)
    return await box.take()
  }
}

private actor SessionResultBox<T: Sendable> {
  private var value: T?

  func set(_ value: T) { self.value = value }

  func take() -> T {
    guard let value else { preconditionFailure("session result was never produced") }
    return value
  }
}

/// GraphQL session control backed by the same commands the CLI runs, so a
/// rerun issued over `/graphql` and one issued from a shell take the same
/// runner path and produce the same lineage.
public struct RielaSessionControlProvider: GraphQLSessionControlProviding {
  public var rerunCommand: SessionRerunCommand
  public var resumeCommand: SessionResumeCommand
  public var workingDirectory: String
  public var sessionStore: String?
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var registry: RielaRunningSessionRegistry

  public init(
    rerunCommand: SessionRerunCommand = SessionRerunCommand(),
    resumeCommand: SessionResumeCommand = SessionResumeCommand(),
    workingDirectory: String = FileManager.default.currentDirectoryPath,
    sessionStore: String? = nil,
    scope: WorkflowScope = .auto,
    workflowDefinitionDir: String? = nil,
    registry: RielaRunningSessionRegistry = .shared
  ) {
    self.rerunCommand = rerunCommand
    self.resumeCommand = resumeCommand
    self.workingDirectory = workingDirectory
    self.sessionStore = sessionStore
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.registry = registry
  }

  public func rerunSession(_ input: GraphQLRerunSessionInput) async throws -> GraphQLSessionMutationPayload {
    try requireWorkflow(input.workflowId, sessionId: input.sessionId)
    try requireSessionBelongsToWorkflow(workflowId: input.workflowId, sessionId: input.sessionId)
    let options = SessionRerunOptions(
      sessionId: input.sessionId,
      stepId: input.stepId,
      output: .json,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      sessionStore: sessionStore
    )
    let result = await registry.withRegisteredSession(sessionId: input.sessionId) {
      await rerunCommand.run(options)
    }
    return try payload(
      from: result,
      decoding: SessionRerunCommandResult.self,
      sessionId: { $0.sessionId },
      status: { $0.status.rawValue },
      lineage: { record in
        GraphQLSessionLineageDTO(
          sessionId: record.sessionId,
          parentSessionId: record.recovery?.parentSessionId,
          rootSessionId: record.recovery?.rootSessionId ?? record.sourceSessionId,
          entryMode: record.recovery?.entryMode.rawValue ?? LoopEntryMode.rerun.rawValue,
          sourceStepId: record.rerunFromStepId
        )
      }
    )
  }

  public func resumeSession(_ input: GraphQLResumeSessionInput) async throws -> GraphQLSessionMutationPayload {
    try requireWorkflow(input.workflowId, sessionId: input.sessionId)
    try requireSessionBelongsToWorkflow(workflowId: input.workflowId, sessionId: input.sessionId)
    let options = SessionResumeOptions(
      sessionId: input.sessionId,
      output: .json,
      scope: scope,
      workflowDefinitionDir: workflowDefinitionDir,
      workingDirectory: workingDirectory,
      sessionStore: sessionStore
    )
    let result = await registry.withRegisteredSession(sessionId: input.sessionId) {
      await resumeCommand.run(options)
    }
    return try payload(
      from: result,
      decoding: SessionResumeCommandResult.self,
      sessionId: { $0.sessionId },
      status: { $0.status.rawValue },
      lineage: { record in
        GraphQLSessionLineageDTO(
          sessionId: record.sessionId,
          parentSessionId: record.recovery?.parentSessionId,
          rootSessionId: record.recovery?.rootSessionId ?? record.sourceSessionId ?? record.sessionId,
          entryMode: record.recovery?.entryMode.rawValue ?? LoopEntryMode.resume.rawValue,
          sourceStepId: record.recovery?.sourceStepId
        )
      }
    )
  }

  /// Cancels a session this process is executing. The id is the one the run
  /// was *entered from*: a rerun registers under the session it re-enters, not
  /// under the new session id its payload reports, because that id does not
  /// exist until the rerun finishes. See `GraphQLStopSessionInput`.
  public func stopSession(_ input: GraphQLStopSessionInput) async throws -> GraphQLSessionMutationPayload {
    try requireWorkflow(input.workflowId, sessionId: input.sessionId)
    // Fail closed before anything else: a session this process is not running
    // is never reached across processes (design delta D3).
    guard await registry.isRunning(sessionId: input.sessionId) else {
      throw GraphQLSessionControlError.sessionNotRunning(input.sessionId)
    }
    try requireSessionBelongsToWorkflow(workflowId: input.workflowId, sessionId: input.sessionId)
    guard await registry.cancelAndAwait(sessionId: input.sessionId) else {
      throw GraphQLSessionControlError.sessionNotRunning(input.sessionId)
    }
    // The runner's cancellation path persists the terminal state before its
    // task returns, so the session is readable here.
    let persisted = try? CLIWorkflowSessionResolution.loadPersistedSession(
      sessionId: input.sessionId,
      sessionStore: sessionStore,
      scope: scope,
      workingDirectory: workingDirectory
    )
    return GraphQLSessionMutationPayload(
      result: GraphQLControlPlaneResult(
        accepted: true,
        status: GraphQLLoopEvidenceQueryStatus.found.rawValue
      ),
      sessionId: input.sessionId,
      status: persisted?.record.session.status.rawValue,
      lineage: persisted.map { loaded in
        GraphQLSessionLineageDTO(
          sessionId: loaded.record.session.sessionId,
          parentSessionId: loaded.record.session.parentSessionId,
          rootSessionId: loaded.record.session.rootSessionId ?? loaded.record.session.sessionId,
          entryMode: LoopEntryMode.resume.rawValue,
          sourceStepId: loaded.record.session.currentStepId
        )
      }
    )
  }

  public func continueSession(_ input: GraphQLContinueSessionRequest) async throws -> GraphQLControlPlaneResult {
    let payload = try await resumeSession(GraphQLResumeSessionInput(
      workflowId: input.workflowId,
      sessionId: input.sessionId
    ))
    return payload.result
  }

  // MARK: - Helpers

  /// The session must belong to the workflow the caller named. Without this a
  /// caller could drive any session by guessing its id and supplying any
  /// workflow id.
  private func requireSessionBelongsToWorkflow(workflowId: String, sessionId: String) throws {
    let loaded: LoadedPersistedCLIWorkflowSession
    do {
      loaded = try CLIWorkflowSessionResolution.loadPersistedSession(
        sessionId: sessionId,
        sessionStore: sessionStore,
        scope: scope,
        workingDirectory: workingDirectory
      )
    } catch {
      throw GraphQLSessionControlError(
        code: "SESSION_NOT_FOUND",
        message: "session_not_found: \(sessionId)"
      )
    }
    guard loaded.record.session.workflowId == workflowId else {
      throw GraphQLSessionControlError(
        code: "SESSION_WORKFLOW_MISMATCH",
        message: "session \(sessionId) belongs to workflow \(loaded.record.session.workflowId), not \(workflowId)"
      )
    }
  }

  private func requireWorkflow(_ workflowId: String, sessionId: String) throws {
    guard !workflowId.isEmpty, !sessionId.isEmpty else {
      throw GraphQLSessionControlError(
        code: "INVALID_SESSION_CONTROL",
        message: "workflowId and sessionId are required"
      )
    }
  }

  private func payload<Record: Decodable>(
    from result: CLICommandResult,
    decoding: Record.Type,
    sessionId: (Record) -> String,
    status: (Record) -> String,
    lineage: (Record) -> GraphQLSessionLineageDTO
  ) throws -> GraphQLSessionMutationPayload {
    guard let data = result.stdout.data(using: .utf8),
          let record = try? JSONDecoder().decode(Record.self, from: data) else {
      throw GraphQLSessionControlError(
        code: "SESSION_CONTROL_FAILURE",
        message: sessionControlFailureMessage(result)
      )
    }
    return GraphQLSessionMutationPayload(
      result: GraphQLControlPlaneResult(
        accepted: result.exitCode == .success,
        status: result.exitCode == .success
          ? GraphQLLoopEvidenceQueryStatus.found.rawValue
          : GraphQLLoopEvidenceQueryStatus.error.rawValue
      ),
      sessionId: sessionId(record),
      status: status(record),
      lineage: lineage(record)
    )
  }

  private func sessionControlFailureMessage(_ result: CLICommandResult) -> String {
    if let data = result.stdout.data(using: .utf8),
       let failure = try? JSONDecoder().decode(SessionCommandFailureResult.self, from: data) {
      return failure.error
    }
    let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return stderr.isEmpty ? "session command produced no decodable result" : stderr
  }
}
