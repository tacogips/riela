import ClaudeCodeAgent
import CodexAgent
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
      CodexBackendActivityProbe(),
      ClaudeCodeBackendActivityProbe()
    ])
  }
}
