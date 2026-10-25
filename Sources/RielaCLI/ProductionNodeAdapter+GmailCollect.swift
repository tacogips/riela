import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let gmailCollectionRegistration = BuiltinAddonHandlerRegistration(name: "riela/gmail-collect") { resolver, input, context in
    try await resolver.executeGmailCollect(input, context: context)
  }

  func executeGmailCollect(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context"]), case let .object(values)? = config["options"],
      try JSONEncoder().encode(config).count <= 8_000_000 else { throw gmailCollectionInvalid() }
    let contextBytes = try JSONEncoder().encode(config["context"] ?? .null).count
    let budget = 8_000_000 - contextBytes - 64
    guard try JSONEncoder().encode(values["previous"] ?? .object([:])).count + 131_072 < budget else {
      throw gmailCollectionInvalid()
    }
    func fetch(_ operation: String, _ arguments: JSONObject, _ selection: [String]) async throws -> JSONObject {
      let child = WorkflowAddonExecutionInput(workflowId: input.workflowId, stepId: input.stepId, nodeId: input.nodeId,
        addon: .init(name: "riela/gmail-gateway-reader", version: "1", config: ["operation": .string(operation),
          "arguments": .string("{{collectorArguments}}"), "selection": .array(selection.map(JSONValue.string)),
          "postprocess": .array([.object(["pick": .string("/data/" + operation)])])], env: input.addon.env),
        variables: ["collectorArguments": .object(arguments)], executionIdentity: input.executionIdentity)
      var childContext = context
      childContext.deadline = min(context.deadline?.addingTimeInterval(-3) ?? .distantFuture,
        Date().addingTimeInterval(30))
      let output = try await execute(child, context: childContext)
      guard case let .object(response)? = output.payload["processed"] else { throw gmailCollectionInvalid() }
      return response
    }
    var payload: JSONObject
    if values["mode"] == .string("message-bodies") {
      payload = try await GmailMessageBodyCollector(options: .init(values),
        deadline: context.deadline?.addingTimeInterval(-3), outputByteBudget: budget).collect(fetch: fetch)
    } else {
      payload = try await GmailMailboxCollector(options: .init(values),
        deadline: context.deadline?.addingTimeInterval(-3), outputByteBudget: budget).collect(fetch: fetch)
    }
    payload["context"] = config["context"] ?? .null
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw gmailCollectionInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      when: ["always": true], payload: payload)
  }
}
