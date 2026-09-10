import Foundation
import RielaCore
import RielaServer

public extension RielaWebWorkflowRequestHandler {
  /// Deliberate inspector endpoint for actual recorded values. Summary endpoints
  /// retain their existing redacted contracts; values are fetched per attempt.
  func webWorkflowEditorRunEvidence(request: RielaHTTPRequest) -> RielaHTTPResponse {
    guard request.headers["x-riela-profile"] == context.profile.rawValue else {
      return editorEvidenceError(409, "The active profile changed. Refresh before continuing.")
    }
    let parts = request.percentEncodedPath.split(separator: "/").map(String.init)
    guard request.method == "GET", parts.count == 5 || parts.count == 7,
          let sessionId = parts[4].removingPercentEncoding else {
      return editorEvidenceError(400, "Select a valid workflow run.")
    }
    let root = URL(fileURLWithPath: context.sessionStoreRoot,
      isDirectory: true).appendingPathComponent("runtime-records").path
    do {
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root).loadStrictReadOnly(sessionId: sessionId)
      let session = snapshot.session
      if parts.count == 7 {
        guard parts[5] == "steps", let executionId = parts[6].removingPercentEncoding,
              let execution = session.executions.first(where: { $0.executionId == executionId }) else {
          return editorEvidenceError(404, "The selected execution attempt was not found.")
        }
        return editorEvidenceJSON([
          "sessionId": .string(sessionId), "executionId": .string(execution.executionId),
          "input": execution.inputSnapshot.map(JSONValue.object) ?? .null,
          "output": execution.acceptedOutput.map { .object($0.payload) } ?? .null,
          "responseText": execution.streamedResponseText.map(JSONValue.string) ?? .null,
          "failureReason": execution.failureReason.map(JSONValue.string) ?? .null,
          "inputRecorded": .bool(execution.inputSnapshot != nil),
          "outputRecorded": .bool(execution.acceptedOutput != nil)
        ])
      }
      let formatter = ISO8601DateFormatter()
      return editorEvidenceJSON([
        "sessionId": .string(sessionId), "workflowId": .string(session.workflowId),
        "status": .string(session.status.rawValue),
        "currentStepId": session.currentStepId.map(JSONValue.string) ?? .null,
        "stepsTotalCount": .number(Double(session.executions.count)),
        "steps": .array(session.executions.suffix(500).map { execution in
          .object([
            "executionId": .string(execution.executionId), "stepId": .string(execution.stepId),
            "nodeId": .string(execution.nodeId), "attempt": .number(Double(execution.attempt)),
            "status": .string(execution.status.rawValue),
            "updatedAt": .string(formatter.string(from: execution.updatedAt))
          ])
        })
      ])
    } catch {
      return editorEvidenceError(404, "Persisted run evidence is not available yet. Refresh after the run starts.")
    }
  }

  private func editorEvidenceJSON(_ value: JSONObject) -> RielaHTTPResponse {
    guard let data = try? JSONEncoder().encode(value), data.count <= 524_288 else {
      return editorEvidenceError(413, "Recorded values exceed the 512 KiB inspector limit. Use the session export to inspect the complete record.")
    }
    return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
  }

  private func editorEvidenceError(_ status: Int, _ message: String) -> RielaHTTPResponse {
    .json(status: status, .object(["error": .object(["code": .string("run_evidence_error"), "message": .string(message)])]))
  }
}
