import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  static let youtubeCollectionRegistration = BuiltinAddonHandlerRegistration(name: "riela/youtube-collect") { resolver, input, context in
    try await resolver.executeYouTubeCollect(input, context: context)
  }

  func executeYouTubeCollect(
    _ input: WorkflowAddonExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1",
      case let .object(config) = try renderAddonConfig(.object(input.addon.config ?? [:]), variables: addonVariables(for: input)),
      Set(config.keys).isSubset(of: ["options", "context"]), case let .object(values)? = config["options"],
      try JSONEncoder().encode(config).count <= 8_000_000 else { throw youtubeCollectionInvalid() }
    let collection = YouTubeCollection(options: try YouTubeCollectionOptions(values))
    let bindings = input.addon.env ?? [:]
    let allowedTargets = Set(["YOUTUBE_GATEWAY_TOKEN_STORE_JSON", "YOUTUBE_GATEWAY_ACCESS_TOKEN"])
    guard Set(bindings.keys).isSubset(of: allowedTargets) else {
      throw AdapterExecutionError(.policyBlocked, "YouTube collection only allows YOUTUBE_GATEWAY_ACCESS_TOKEN and YOUTUBE_GATEWAY_TOKEN_STORE_JSON")
    }
    let environment = try resolveAddonEnvironment(bindings, runtimeEnvironment: self.environment)
    var payload = try await collection.collect(environment: environment)
    payload["context"] = config["context"] ?? .null
    guard try JSONEncoder().encode(payload).count <= 8_000_000 else { throw youtubeCollectionInvalid() }
    return .init(provider: "riela-builtin-addon", model: input.addon.name, promptText: "", completionPassed: true,
      when: ["always": true], payload: payload)
  }
}
