extension AdapterExecutionInput {
  /// Record invocation values, not credentials or process environment. This is
  /// persisted before dispatch so failure and retry inspection remains exact.
  var invocationSnapshot: JSONObject {
    var result: JSONObject = [
      "promptText": .string(promptText),
      "arguments": .object(arguments),
      "mergedVariables": .object(mergedVariables)
    ]
    if let systemPromptText { result["systemPromptText"] = .string(systemPromptText) }
    if let freshPromptText { result["freshPromptText"] = .string(freshPromptText) }
    if let resumedPromptText { result["resumedPromptText"] = .string(resumedPromptText) }
    return result
  }
}
