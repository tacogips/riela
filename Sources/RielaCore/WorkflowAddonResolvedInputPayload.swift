func workflowAddonResolvedInputPayload(_ payload: JSONObject, session: WorkflowSession) -> JSONObject {
  var resolved = payload
  let completedExecutions = session.executions.filter { $0.status == .completed }
  let outputEntries = completedExecutions.compactMap { execution -> JSONValue? in
    guard let acceptedOutput = execution.acceptedOutput else {
      return nil
    }
    return .object([
      "stepId": .string(execution.stepId),
      "nodeId": .string(execution.nodeId),
      "executionId": .string(execution.executionId),
      "output": .object([
        "payload": .object(acceptedOutput.payload),
        "when": .object(acceptedOutput.when.mapValues(JSONValue.bool)),
        "isRootOutput": .bool(acceptedOutput.isRootOutput)
      ]),
      "payload": .object(acceptedOutput.payload),
      "when": .object(acceptedOutput.when.mapValues(JSONValue.bool))
    ])
  }
  if resolved["upstream"] == nil {
    resolved["upstream"] = .array(outputEntries)
  }
  resolved["runtime"] = .object([
    "sessionId": .string(session.sessionId),
    "workflowId": .string(session.workflowId),
    "executedStepIds": .array(completedExecutions.map(\.stepId).map(JSONValue.string)),
    "executedNodeIds": .array(completedExecutions.map(\.nodeId).map(JSONValue.string))
  ])
  return resolved
}
