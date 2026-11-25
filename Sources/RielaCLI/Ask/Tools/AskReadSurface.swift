import RielaCore

typealias AskReadResult = (data: JSONValue, refs: [AskRef])

protocol AskReadSurface: Sendable {
  func sessionList(_ arguments: JSONObject) async throws -> AskReadResult
  func sessionStatus(_ arguments: JSONObject) async throws -> AskReadResult
  func sessionProgress(_ arguments: JSONObject) async throws -> AskReadResult
  func sessionHealth(_ arguments: JSONObject) async throws -> AskReadResult
  func sessionLogs(_ arguments: JSONObject) async throws -> AskReadResult
  func opsOverview(_ arguments: JSONObject) async throws -> AskReadResult
  func botList(_ arguments: JSONObject) async throws -> AskReadResult
  func botBoard(_ arguments: JSONObject) async throws -> AskReadResult
  func botActivity(_ arguments: JSONObject) async throws -> AskReadResult
  func routineList(_ arguments: JSONObject) async throws -> AskReadResult
  func workflowList(_ arguments: JSONObject) async throws -> AskReadResult
  func workflowInspect(_ arguments: JSONObject) async throws -> AskReadResult
  func workflowValidate(_ arguments: JSONObject) async throws -> AskReadResult
  func definitionHistory(_ arguments: JSONObject) async throws -> AskReadResult
  func modelCatalog(_ arguments: JSONObject) async throws -> AskReadResult
  func remoteList(_ arguments: JSONObject) async throws -> AskReadResult

  func contextSummary(_ context: AskContext) async throws -> (data: JSONObject, ref: AskRef)?
  func actionSession(id: String) async throws -> WorkflowSession
  func actionStepExists(sessionId: String, stepId: String) async throws -> Bool
  func actionBotExists(id: String) async throws -> Bool
  func actionPermissionRequest(id: String) async throws -> ActivityRequestRecord?
}
