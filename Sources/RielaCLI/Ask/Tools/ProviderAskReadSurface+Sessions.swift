import Foundation
import RielaCore
import RielaGraphQL

extension ProviderAskReadSurface {
  func sessionList(_ arguments: JSONObject) async throws -> AskReadResult {
    let response = await providers.sessions.workflowSessions(.init(
      workflowName: arguments.askString("workflowName"), status: arguments.askString("status"),
      limit: try arguments.askRequiredInt("limit")
    ))
    guard response.result.accepted else { throw sessionReadError(response.result) }
    return (
      try BotSurfaceJSON.value(response.sessions),
      response.sessions.map { AskRef(kind: .session, id: $0.sessionId) }
    )
  }

  func sessionStatus(_ arguments: JSONObject) async throws -> AskReadResult {
    let session = try await actionSession(id: arguments.askRequiredString("sessionId"))
    var summary = sessionSummary(session)
    summary["parentSessionId"] = session.parentSessionId.map(JSONValue.string)
    summary["rootSessionId"] = session.rootSessionId.map(JSONValue.string)
    summary["error"] = session.failureReason.map(JSONValue.string)
    summary["stepExecutions"] = .array(session.executions.map { execution in
      var step: JSONObject = [
        "executionId": .string(execution.executionId), "stepId": .string(execution.stepId),
        "nodeId": .string(execution.nodeId), "attempt": .integer(Int64(execution.attempt)),
        "status": .string(execution.status.rawValue), "createdAt": dateValue(execution.createdAt),
        "updatedAt": dateValue(execution.updatedAt)
      ]
      step["backend"] = execution.backend.map { .string($0.rawValue) }
      step["error"] = execution.failureReason.map(JSONValue.string)
      return .object(step)
    })
    let refs = [AskRef(kind: .session, id: session.sessionId)] + session.executions.map {
      AskRef(kind: .step, id: $0.stepId, sessionId: session.sessionId)
    }
    return (.object(summary), refs)
  }

  func sessionProgress(_ arguments: JSONObject) async throws -> AskReadResult {
    let id = try arguments.askRequiredString("sessionId")
    return try await observeSession(id: id) {
      await providers.sessions.sessionProgress(.init(
        sessionId: id, includeChildren: arguments.askBool("includeChildren") ?? false
      ))
    }
  }

  func sessionHealth(_ arguments: JSONObject) async throws -> AskReadResult {
    let id = try arguments.askRequiredString("sessionId")
    return try await observeSession(id: id) { await providers.sessions.sessionHealth(.init(sessionId: id)) }
  }

  func sessionLogs(_ arguments: JSONObject) async throws -> AskReadResult {
    try askRead {
      try providers.sessionLogs(
        arguments.askRequiredString("sessionId"), arguments.askString("stepExecutionId"),
        arguments.askRequiredInt("tail"), arguments.askString("contains")
      )
    }
  }

  func actionSession(id: String) async throws -> WorkflowSession {
    try askRead { try providers.sessions.loadSnapshot(id).session }
  }

  func actionStepExists(sessionId: String, stepId: String) async throws -> Bool {
    try await registryRead { try providers.stepExists(sessionId, stepId) }
  }

  private func observeSession(
    id: String, query: () async -> GraphQLSessionObservabilityResult
  ) async throws -> AskReadResult {
    // Observability folds missing records and store faults into diagnostics.
    _ = try await actionSession(id: id)
    let response = await query()
    guard let view = response.view else { throw sessionReadError(response.result) }
    return (try BotSurfaceJSON.value(view), sessionRefs(view.root))
  }

  private func sessionRefs(_ node: SessionRollupNode) -> [AskRef] {
    let session = AskRef(kind: .session, id: node.digest.sessionId)
    return [session] + node.children.flatMap(sessionRefs)
  }

  private func sessionReadError(_ result: GraphQLControlPlaneResult) -> AskError {
    let code = result.status == GraphQLLoopEvidenceQueryStatus.invalidRequest.rawValue
      ? "tool_arguments_invalid" : "tool_failed"
    return AskError(code: code, message: result.diagnostics.first ?? "Could not read session records")
  }
}

func sessionSummary(_ session: WorkflowSession) -> JSONObject {
  var data: JSONObject = [
    "sessionId": .string(session.sessionId), "workflowName": .string(session.workflowId),
    "status": .string(session.status.rawValue),
    "startedAt": dateValue(session.executions.first?.createdAt ?? session.createdAt)
  ]
  data["currentStepId"] = session.currentStepId.map(JSONValue.string)
  data["finishedAt"] = session.status.isTerminal ? dateValue(session.failedAt ?? session.updatedAt) : nil
  return data
}

private func dateValue(_ date: Date) -> JSONValue {
  .string(GraphQLContractProjector.iso8601String(date))
}
