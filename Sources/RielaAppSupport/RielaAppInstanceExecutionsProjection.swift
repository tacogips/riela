import Foundation
import RielaCore
import RielaViewer

public enum RielaAppInstanceExecutionsProjection {
  public static func list(
    identity: String, workflowDirectory: String, sessionStoreRoot: String, revision: Int?
  ) -> JSONObject {
    do {
      let state = try WorkflowViewerLoader().loadBounded(
        WorkflowViewerLoadRequest(
          workflowDirectory: workflowDirectory,
          sessionStoreRoot: sessionStoreRoot
        ),
        maximumSessionCount: 101
      )
      let formatter = ISO8601DateFormatter()
      let projection = WorkflowWebProjectionPolicy()
      var result: JSONObject = [
        "instanceId": .string(identity),
        "items": .array(state.sessions.prefix(100).map { session in
          let endedAt: JSONValue
          switch session.status {
          case .created, .running, .suspended:
            endedAt = .null
          case .completed, .failed, .cancelled:
            endedAt = .string(formatter.string(from: session.updatedAt))
          }
          return .object([
            "sessionId": .string(session.sessionId),
            "workflowId": .string(session.workflowId),
            "status": .string(session.status.rawValue),
            "currentStepId": session.currentStepId.map(JSONValue.string) ?? .null,
            "activeStepIds": .array(session.activeStepIds.map(JSONValue.string)),
            "updatedAt": .string(formatter.string(from: session.updatedAt)),
            "startedAt": session.startedAt.map { .string(formatter.string(from: $0)) } ?? .null,
            "endedAt": endedAt
          ])
        }),
        "truncated": .bool(state.sessions.count > 100),
        "diagnostics": .array(state.diagnostics.prefix(20).map {
          .string(projection.persistedSummary($0, context: .diagnostic).value)
        })
      ]
      if let revision { result["revision"] = .number(Double(revision)) }
      return result
    } catch {
      var result: JSONObject = [
        "instanceId": .string(identity),
        "items": .array([]),
        "truncated": .bool(false),
        "diagnostics": .array([.string("Workflow executions could not be loaded")])
      ]
      if let revision { result["revision"] = .number(Double(revision)) }
      return result
    }
  }

  // The shared API returns the three fields required by the local execution reader.
  public static func detailStatus(
    workflowDirectory: String, sessionStoreRoot: String, sessionId: String
  ) -> (sessionId: String, status: String, updatedAt: String)? { // swiftlint:disable:this large_tuple
    guard let state = try? WorkflowViewerLoader().loadBounded(
      WorkflowViewerLoadRequest(
        workflowDirectory: workflowDirectory, sessionStoreRoot: sessionStoreRoot, selectedSessionId: sessionId
      ),
      maximumSessionCount: 1
    ), state.selectedSessionId == sessionId,
      let summary = state.sessions.first(where: { $0.sessionId == sessionId }) else { return nil }
    return (summary.sessionId, summary.status.rawValue, ISO8601DateFormatter().string(from: summary.updatedAt))
  }
}
