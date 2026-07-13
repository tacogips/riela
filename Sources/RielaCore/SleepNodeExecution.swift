import Foundation

/// Runtime semantics for `nodeType: "sleep"` nodes: pause for the declared
/// `sleep.durationMs` (cancellation-cooperative), then complete with a
/// deterministic payload. Shared by the production dispatching adapter and
/// the deterministic local adapter so sleep nodes behave the same in real
/// and mock-scenario runs; the step's node timeout still bounds the pause.
public enum SleepNodeExecution {
  public static func isSleepNode(_ node: AgentNodePayload) -> Bool {
    node.nodeType == .sleep
  }

  /// Returns the completion output for a sleep node after pausing, or nil
  /// when the node is not a sleep node.
  public static func outputIfSleepNode(_ input: AdapterExecutionInput) async throws -> AdapterExecutionOutput? {
    guard isSleepNode(input.node) else {
      return nil
    }
    let durationMs = max(0, input.node.sleep?.durationMs ?? 0)
    let nanoseconds = sleepDurationNanoseconds(durationMs: durationMs)
    if nanoseconds > 0 {
      try await Task.sleep(nanoseconds: nanoseconds)
    }
    return AdapterExecutionOutput(
      provider: "sleep",
      model: input.node.model,
      promptText: input.promptText,
      completionPassed: true,
      payload: [
        "nodeId": .string(input.node.id),
        "provider": .string("sleep"),
        "status": .string("completed"),
        "durationMs": .integer(Int64(durationMs))
      ]
    )
  }

  static func sleepDurationNanoseconds(durationMs: Int) -> UInt64 {
    let milliseconds = UInt64(max(0, durationMs))
    let multiplier: UInt64 = 1_000_000
    guard milliseconds <= UInt64.max / multiplier else {
      return UInt64.max
    }
    return milliseconds * multiplier
  }
}
