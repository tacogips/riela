import Foundation
import RielaCore

public typealias NodeAdapterFactory = @Sendable () async throws -> any NodeAdapter
public typealias NodeAdapterRegistry = [NodeExecutionBackend: NodeAdapterFactory]

public struct DispatchingNodeAdapterConfiguration: Sendable {
  public var openAISDK: OfficialSDKAdapterConfiguration
  public var anthropicSDK: AnthropicSDKAdapterConfiguration
  public var geminiSDK: OfficialSDKAdapterConfiguration
  public var cursorSDK: OfficialSDKAdapterConfiguration
  public var registry: NodeAdapterRegistry
  public var includeDefaultOfficialSDKAdapters: Bool

  public init(
    openAISDK: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration(),
    anthropicSDK: AnthropicSDKAdapterConfiguration = AnthropicSDKAdapterConfiguration(),
    geminiSDK: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration(),
    cursorSDK: OfficialSDKAdapterConfiguration = OfficialSDKAdapterConfiguration(),
    registry: NodeAdapterRegistry = [:],
    includeDefaultOfficialSDKAdapters: Bool = true
  ) {
    self.openAISDK = openAISDK
    self.anthropicSDK = anthropicSDK
    self.geminiSDK = geminiSDK
    self.cursorSDK = cursorSDK
    self.registry = registry
    self.includeDefaultOfficialSDKAdapters = includeDefaultOfficialSDKAdapters
  }
}

public actor DispatchingNodeAdapter: NodeAdapter {
  private let registry: NodeAdapterRegistry
  private var adapters: [NodeExecutionBackend: any NodeAdapter] = [:]

  public init(registry: NodeAdapterRegistry = [:]) {
    self.init(configuration: DispatchingNodeAdapterConfiguration(registry: registry))
  }

  public init(configuration: DispatchingNodeAdapterConfiguration) {
    var resolvedRegistry: NodeAdapterRegistry = configuration.includeDefaultOfficialSDKAdapters
      ? Self.createDefaultOfficialSDKRegistry(configuration: configuration)
      : [:]
    for (backend, factory) in configuration.registry {
      resolvedRegistry[backend] = factory
    }
    self.registry = resolvedRegistry
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    let backend = try resolveNodeExecutionBackend(input.node)
    let adapter = try await loadAdapter(for: backend)
    return try await adapter.execute(input, context: context)
  }

  private func loadAdapter(for backend: NodeExecutionBackend) async throws -> any NodeAdapter {
    if let adapter = adapters[backend] {
      return adapter
    }
    guard let factory = registry[backend] else {
      throw AdapterExecutionError(.providerError, "node execution backend '\(backend.rawValue)' has no registered adapter")
    }
    let adapter = try await factory()
    adapters[backend] = adapter
    return adapter
  }

  private static func createDefaultOfficialSDKRegistry(configuration: DispatchingNodeAdapterConfiguration) -> NodeAdapterRegistry {
    [
      .officialOpenAISDK: {
        OpenAiSDKAdapter(configuration: configuration.openAISDK)
      },
      .officialAnthropicSDK: {
        AnthropicSDKAdapter(configuration: configuration.anthropicSDK)
      },
      .officialGeminiSDK: {
        GeminiSDKAdapter(configuration: configuration.geminiSDK)
      },
      .officialCursorSDK: {
        CursorSDKAdapter(configuration: configuration.cursorSDK)
      }
    ]
  }
}
