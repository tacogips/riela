import Foundation

/// Accumulates per-step token usage from live backend `usage` events into
/// `LoopCostEvidence`, then derives an honest `LoopCostSummary`.
///
/// This is the pure logic half of the LA2 cost accumulator, mirroring how
/// `LoopConvergenceTracker` is a self-contained value type fed by the runner.
/// The runner wiring (calling `recordUsage`/`recordStep` from the backend-event
/// handler and handing `evidence()` to evidence projection) is a separate step;
/// callers must serialize access since this is a value type.
///
/// Within a single step, each token dimension is **last-value-wins**: streaming
/// providers commonly emit cumulative usage snapshots (e.g. Anthropic sends the
/// running totals), so the most recent value is authoritative. Single-event
/// providers (e.g. a codex `total_token_usage`) are handled identically. Totals
/// are summed across steps by `LoopCostSummary.make(from:)`.
public struct LoopCostAccumulator: Sendable {
  private var order: [String] = []
  private var steps: [String: StepState] = [:]

  public init() {}

  /// Records a usage event for a step, updating any dimensions it carries.
  /// Registers the step if not seen before.
  public mutating func recordUsage(
    stepExecutionId: String,
    backend: String? = nil,
    model: String? = nil,
    usage: JSONObject,
    at: Date? = nil
  ) {
    var state = ensureStep(stepExecutionId, backend: backend, model: model)
    if let input = Self.token(usage, "input_tokens") { state.inputTokens = input }
    if let output = Self.token(usage, "output_tokens") { state.outputTokens = output }
    if let total = Self.token(usage, "total_tokens") ?? Self.token(usage, "total_token_usage") {
      state.totalTokens = total
    }
    if state.inputTokens != nil || state.outputTokens != nil || state.totalTokens != nil {
      state.sawUsage = true
    }
    if let at {
      state.firstAt = state.firstAt.map { min($0, at) } ?? at
      state.lastAt = state.lastAt.map { max($0, at) } ?? at
    }
    steps[stepExecutionId] = state
  }

  /// Registers a step and optionally its measured duration, even when the step
  /// emitted no usage events (so it is counted in `stepsWithoutUsage`).
  public mutating func recordStep(
    stepExecutionId: String,
    backend: String? = nil,
    model: String? = nil,
    durationMs: Int? = nil
  ) {
    var state = ensureStep(stepExecutionId, backend: backend, model: model)
    if let durationMs { state.explicitDurationMs = durationMs }
    steps[stepExecutionId] = state
  }

  /// Per-step cost evidence in the order steps were first seen.
  public func evidence() -> [LoopCostEvidence] {
    order.compactMap { id in
      guard let state = steps[id] else { return nil }
      var diagnostics: [String] = []
      if !state.sawUsage {
        diagnostics.append("no usage events recorded for step")
      }
      return LoopCostEvidence(
        stepExecutionId: id,
        backend: state.backend,
        model: state.model,
        inputTokens: state.inputTokens,
        outputTokens: state.outputTokens,
        totalTokens: state.totalTokens,
        durationMs: state.durationMs,
        diagnostics: diagnostics
      )
    }
  }

  /// Honest session totals derived from the per-step evidence.
  public func summary() -> LoopCostSummary {
    LoopCostSummary.make(from: evidence())
  }

  private mutating func ensureStep(_ id: String, backend: String?, model: String?) -> StepState {
    if var state = steps[id] {
      if state.backend == nil, let backend { state.backend = backend }
      if state.model == nil, let model { state.model = model }
      return state
    }
    order.append(id)
    var state = StepState()
    state.backend = backend
    state.model = model
    steps[id] = state
    return state
  }

  private static func token(_ usage: JSONObject, _ key: String) -> Int? {
    guard let raw = usage[key]?.asInt64 else { return nil }
    return Int(raw)
  }

  /// Derives per-step cost evidence from recorded executions. Each agent
  /// execution (one with a `backend`) contributes its `recentBackendEvents`
  /// usage; an agent step with no usage event is registered so it counts as
  /// `stepsWithoutUsage`. Non-agent executions (no backend, e.g. command/stdio
  /// nodes) are skipped. This is how the evidence projector recovers cost from a
  /// session's in-memory backend events without threading a live accumulator
  /// through the runner.
  public static func evidence(from executions: [WorkflowStepExecution]) -> [LoopCostEvidence] {
    var accumulator = LoopCostAccumulator()
    for execution in executions where execution.backend != nil {
      let backend = execution.backend?.rawValue
      let model = execution.adapterOutput?.model
      let usageEvents = (execution.recentBackendEvents ?? []).filter { $0.usage != nil }
      if usageEvents.isEmpty {
        accumulator.recordStep(stepExecutionId: execution.executionId, backend: backend, model: model)
      } else {
        for event in usageEvents {
          accumulator.recordUsage(
            stepExecutionId: execution.executionId,
            backend: backend,
            model: model,
            usage: event.usage ?? [:],
            at: event.at
          )
        }
      }
    }
    return accumulator.evidence()
  }

  private struct StepState: Sendable {
    var backend: String?
    var model: String?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var explicitDurationMs: Int?
    var firstAt: Date?
    var lastAt: Date?
    var sawUsage = false

    /// Explicit duration when provided, otherwise derived from the span of
    /// observed usage-event timestamps.
    var durationMs: Int? {
      if let explicitDurationMs { return explicitDurationMs }
      guard let firstAt, let lastAt, lastAt >= firstAt else { return nil }
      return Int((lastAt.timeIntervalSince(firstAt) * 1_000).rounded())
    }
  }
}
