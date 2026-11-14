import RielaCore

public protocol SessionFollowSleeping: Sendable {
  func sleep(seconds: Double) async throws
}

public struct SystemSessionFollowSleeper: SessionFollowSleeping {
  public init() {}

  public func sleep(seconds: Double) async throws {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}

enum SessionObservabilityComposition {
  static func makeService(
    store: SQLiteWorkflowRuntimePersistenceStore,
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock()
  ) -> SessionObservabilityService {
    SessionObservabilityService(
      store: store,
      clock: clock,
      probes: makeProbeRegistry()
    )
  }

  static func makeProbeRegistry() -> SessionBackendActivityProbeRegistry {
    SessionBackendActivityProbeRegistry([
      GatewayEventActivityProbe(backend: .codexAgent),
      GatewayEventActivityProbe(backend: .claudeCodeAgent),
      GatewayEventActivityProbe(backend: .cursorCliAgent),
      GatewayEventActivityProbe(backend: .officialOpenAISDK),
      GatewayEventActivityProbe(backend: .officialAnthropicSDK),
      GatewayEventActivityProbe(backend: .officialGeminiSDK),
      GatewayEventActivityProbe(backend: .officialCursorSDK)
    ])
  }
}

private struct GatewayEventActivityProbe: SessionBackendActivityProbing {
  var backend: NodeExecutionBackend

  func assess(_ input: SessionBackendActivityProbeInput) throws -> SessionBackendActivity {
    SessionBackendActivityClassifier.classify(
      input: input,
      providerActivityAt: nil,
      providerEvidence: [],
      requiresProviderArtifactForStall: false,
      hasCorrelatedProviderArtifact: false
    )
  }
}
