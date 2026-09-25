import Foundation
import RielaCore
import RielaGraphQL

/// Runs and reads workflows within a single host-selected store context.
public struct WorkflowExecutionProvider: WorkflowExecutionGraphQLProviding {
  public let workingDirectory: String
  public let sessionStoreRoot: String
  public let environment: [String: String]
  public let command: WorkflowRunCommand
#if DEBUG
  var testCommandResultOverride: (@Sendable (CLICommandResult) -> CLICommandResult)?
#endif

  public init(
    workingDirectory: String,
    sessionStoreRoot: String,
    environment: [String: String],
    command: WorkflowRunCommand = WorkflowRunCommand()
  ) {
    self.workingDirectory = workingDirectory
    self.sessionStoreRoot = sessionStoreRoot
    self.environment = environment
    self.command = command
  }

  public func executeWorkflow(_ input: GraphQLExecuteWorkflowInput) async throws -> GraphQLExecuteWorkflowPayload {
    let options = WorkflowRunOptions(
      target: input.workflowName,
      resolution: WorkflowResolutionOptions(
        workflowName: input.workflowName,
        workingDirectory: workingDirectory
      ),
      variables: try input.runtimeVariables.map(encodeInlineJSON),
      nodePatch: try input.nodePatch.map(encodeInlineJSON),
      instance: input.instanceIdentity,
      output: .json,
      maxSteps: input.maxSteps,
      maxConcurrency: input.maxConcurrency,
      maxLoopIterations: input.maxLoopIterations,
      disableDefaultLoopGuard: input.disableDefaultLoopGuard ?? false,
      defaultTimeoutMs: input.defaultTimeoutMs,
      sessionStore: sessionStoreRoot,
      workingDirectory: workingDirectory
    )
    var nodeEnvironment = environment
    nodeEnvironment["RIELA_MANAGER_AUTH_TOKEN"] = ""
    let commandResult = await CLIRuntimeEnvironment.$overrides.withValue(nodeEnvironment) {
      await command.run(options)
    }
#if DEBUG
    let result = testCommandResultOverride?(commandResult) ?? commandResult
#else
    let result = commandResult
#endif
    let data = Data(result.stdout.utf8)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let run = try? decoder.decode(WorkflowRunResult.self, from: data) {
      let sessionId = run.session.sessionId
      let persisted = try strictSummary(sessionId: sessionId)
      guard run.workflowId == run.session.workflowId,
            run.status == run.session.status,
            persisted.summary.session.workflowId == run.workflowId,
            persisted.status == run.status,
            result.exitCode.rawValue == run.exitCode else {
        throw WorkflowExecutionProviderError.persistenceFailed
      }
      return GraphQLExecuteWorkflowPayload(
        workflowExecutionId: sessionId,
        sessionId: sessionId,
        status: persisted.status.rawValue,
        exitCode: Int(result.exitCode.rawValue)
      )
    }
    if let failure = try? JSONDecoder().decode(WorkflowRunFailureResult.self, from: data),
       let sessionId = failure.sessionId {
      let persisted = try strictSummary(sessionId: sessionId)
      guard failure.workflowId == nil || failure.workflowId == persisted.summary.session.workflowId,
            failure.status == persisted.status,
            failure.exitCode == result.exitCode.rawValue else {
        throw WorkflowExecutionProviderError.persistenceFailed
      }
      return GraphQLExecuteWorkflowPayload(
        workflowExecutionId: sessionId,
        sessionId: sessionId,
        status: persisted.status.rawValue,
        exitCode: Int(result.exitCode.rawValue)
      )
    }
    throw WorkflowExecutionProviderError.runFailed
  }

  public func workflowExecution(workflowExecutionId: String) async throws -> GraphQLWorkflowExecutionSummary? {
    do {
      return try strictSummary(sessionId: workflowExecutionId).summary
    } catch CLIWorkflowSessionStoreError.notFound {
      return nil
    }
  }

  private func strictSummary(
    sessionId: String
  ) throws -> (summary: GraphQLWorkflowExecutionSummary, status: WorkflowSessionStatus) {
    let record = try CLIWorkflowSessionStore(rootDirectory: sessionStoreRoot)
      .loadStrictReadOnly(sessionId: sessionId)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)
    ).loadStrictReadOnly(sessionId: sessionId)
    guard record.session.sessionId == sessionId,
          snapshot.session.sessionId == sessionId,
          record.session.workflowId == snapshot.session.workflowId,
          record.session.status == snapshot.session.status else {
      throw WorkflowExecutionProviderError.persistenceFailed
    }
    let transitions = snapshot.workflowMessages
      .filter { $0.workflowExecutionId == sessionId }
      .sorted { $0.createdOrder < $1.createdOrder }
      .map { GraphQLExecutionTransitionSummary(when: $0.transitionCondition) }
    let summary = GraphQLWorkflowExecutionSummary(
      session: GraphQLWorkflowExecutionSessionSummary(
        sessionId: sessionId,
        workflowName: record.workflowName,
        workflowId: snapshot.session.workflowId,
        transitions: transitions
      ),
      nodeExecutions: snapshot.session.executions.map {
        GraphQLWorkflowExecutionNodeSummary(nodeExecId: $0.executionId)
      }
    )
    return (summary, record.session.status)
  }

  private func encodeInlineJSON(_ object: JSONObject) throws -> String {
    guard let text = String(data: try JSONEncoder().encode(object), encoding: .utf8) else {
      throw WorkflowExecutionProviderError.runFailed
    }
    return text
  }
}

public enum WorkflowExecutionProviderError: Error, Sendable {
  case runFailed
  case persistenceFailed
}
