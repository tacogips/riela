import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let publicDiscoveryRegistration = BuiltinAddonHandlerRegistration(name: "riela/public-discovery", bindsCLIVariablesAsInputs: false) { resolver, input, context in
    try await resolver.executePublicDiscovery(input, context: context)
  }

  func executePublicDiscovery(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try Task.checkCancellation()
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      try JSONEncoder().encode(config).count <= 65_536 else { throw discoveryInvalid() }
    let options: PublicDiscoveryOptions
    do { options = try .init(config) } catch { throw discoveryInvalid() }
    let result = try await PublicDiscovery(options: options, transport: PublicWebExecutionContext.transport ?? PublicWebHTTP.native,
      authenticatedTransport: PublicDiscoveryExecutionContext.authenticatedTransport ?? PublicDiscoveryHTTP.exa,
      environment: environment, deadline: context.deadline).run()
    guard try JSONEncoder().encode(result).count <= 256_000 else { throw discoveryInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true, payload: result)
  }
}

private func discoveryInvalid() -> AdapterExecutionError { .init(.invalidInput, "invalid bounded public discovery configuration") }
