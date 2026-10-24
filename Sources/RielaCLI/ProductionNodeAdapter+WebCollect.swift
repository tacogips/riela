import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let webCollectionRegistration = BuiltinAddonHandlerRegistration(name: "riela/web-collect", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try await resolver.executeWebCollection(input, context: context)
  }

  func executeWebCollection(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context"]), case let .object(values)? = config["options"],
      try JSONEncoder().encode(config).count <= 8_000_000 else { throw webCollectionInvalid() }
    let options: WebCollectionOptions
    do { options = try .init(values) } catch { throw webCollectionInvalid() }
    let browser = PublicWebExecutionContext.browser ?? { url, options, blocked, deadline in
      try await self.publicWebBrowser(url: url, options: options, blockedHosts: blocked, deadline: deadline)
    }
    let contextBytes = try JSONEncoder().encode(config["context"] ?? .null).count
    let budget = 8_000_000 - contextBytes - 64
    guard try JSONEncoder().encode(options.previous).count + WebCollector.metadataReserve + WebCollector.minimumRecordBudget <= budget else { throw webCollectionInvalid() }
    var payload: JSONObject
    do {
      payload = try await WebCollector(options: options,
        reader: .init(transport: PublicWebExecutionContext.transport ?? PublicWebHTTP.native, browser: browser),
        deadline: min(context.deadline?.addingTimeInterval(-2) ?? .distantFuture, Date().addingTimeInterval(120)), outputByteBudget: budget).collect()
    } catch is CancellationError { throw CancellationError() } catch { throw AdapterExecutionError(.providerError, "public Web collection unavailable") }
    payload["context"] = config["context"] ?? .null
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw webCollectionInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      when: ["always": true], payload: payload)
  }
}

private func webCollectionInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid public Web collection configuration") }
