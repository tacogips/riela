import RielaCore

struct AskToolCase {
  let name: String
  var arguments: JSONObject = [:]
  var ref: AskRef?
  var expectedText: String?
}

extension AskToolFixture {
  var readCases: [AskToolCase] {
    let sessionRef = AskRef(kind: .session, id: session.sessionId)
    let stepRef = session.executions.last.map {
      AskRef(kind: .step, id: $0.stepId, sessionId: session.sessionId)
    }
    let botRef = AskRef(kind: .bot, id: Self.botId)
    let workflowRef = AskRef(kind: .workflow, id: Self.workflowId)
    let routineRef = AskRef(kind: .routine, id: Self.routineId)
    let sessionArgs: JSONObject = ["sessionId": .string(session.sessionId)]
    let botArgs: JSONObject = ["botId": .string(Self.botId)]
    let workflowArgs: JSONObject = ["workflowId": .string(Self.workflowId)]
    return [
      AskToolCase(name: "session_list", arguments: ["workflowName": .string(Self.workflowId)], ref: sessionRef),
      AskToolCase(name: "session_status", arguments: sessionArgs, ref: stepRef, expectedText: session.sessionId),
      AskToolCase(name: "session_progress", arguments: sessionArgs, ref: sessionRef),
      AskToolCase(name: "session_health", arguments: sessionArgs, ref: sessionRef),
      AskToolCase(name: "session_logs", arguments: sessionArgs, ref: sessionRef, expectedText: "Untrusted fixture instructions"),
      AskToolCase(name: "ops_overview", ref: workflowRef),
      AskToolCase(name: "bot_list", ref: botRef),
      AskToolCase(name: "bot_board", arguments: botArgs, ref: botRef, expectedText: session.sessionId),
      AskToolCase(name: "bot_activity", arguments: sessionArgs.merging(["limit": .integer(10)]) { _, newer in newer }, ref: sessionRef),
      AskToolCase(name: "routine_list", arguments: ["status": .string("active")], ref: routineRef),
      AskToolCase(name: "workflow_list", arguments: ["query": .string(Self.workflowId)], ref: workflowRef),
      AskToolCase(name: "workflow_inspect", arguments: workflowArgs, ref: workflowRef),
      AskToolCase(name: "workflow_validate", arguments: workflowArgs, ref: workflowRef),
      AskToolCase(
        name: "definition_history", arguments: ["workflowName": .string(Self.workflowId), "limit": .integer(5)],
        ref: workflowRef, expectedText: Self.historyReason
      ),
      AskToolCase(name: "model_catalog", expectedText: "codex-agent"),
      AskToolCase(name: "remote_list", expectedText: Self.remoteName)
    ]
  }
}
