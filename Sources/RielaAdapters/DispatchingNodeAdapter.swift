import Foundation
import RielaCore

public typealias NodeAdapterFactory = @Sendable () async throws -> any NodeAdapter
public typealias NodeAdapterRegistry = [NodeExecutionBackend: NodeAdapterFactory]

public struct DispatchingNodeAdapterConfiguration: Sendable {
  public var registry: NodeAdapterRegistry

  public init(
    registry: NodeAdapterRegistry = [:]
  ) {
    self.registry = registry
  }
}

public actor DispatchingNodeAdapter: NodeAdapter {
  private let registry: NodeAdapterRegistry
  private var adapters: [NodeExecutionBackend: any NodeAdapter] = [:]

  public init(registry: NodeAdapterRegistry = [:]) {
    self.init(configuration: DispatchingNodeAdapterConfiguration(registry: registry))
  }

  public init(configuration: DispatchingNodeAdapterConfiguration) {
    self.registry = configuration.registry
  }

  public func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if let sleepOutput = try await SleepNodeExecution.outputIfSleepNode(input) {
      return sleepOutput
    }
    let backend = try resolveNodeExecutionBackend(input.node)
    let adapter = try await loadAdapter(for: backend)
    return try await adapter.execute(input, context: context)
  }

  public func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    let loadedAdapters = Array(adapters.values)
    for adapter in loadedAdapters {
      await adapter.workflowRunDidEnd(context)
    }
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
}
