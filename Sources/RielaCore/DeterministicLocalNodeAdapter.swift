public struct DeterministicLocalNodeAdapter: NodeAdapter {
  public init() {}

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    var payload: JSONObject = [
      "nodeId": .string(input.node.id),
      "provider": .string("deterministic-local"),
      "status": .string("completed")
    ]
    if let resumedFromNodeExecId = input.mergedVariables["resumedFromNodeExecId"] {
      payload["resumedFromNodeExecId"] = resumedFromNodeExecId
    }
    if input.mergedVariables["resumedFromNodeExecId"] != nil {
      payload["promptText"] = .string(input.promptText)
    }
    return AdapterExecutionOutput(
      provider: "deterministic-local",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: payload
    )
  }
}
