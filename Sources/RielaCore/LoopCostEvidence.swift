import Foundation

/// Per-step cost evidence captured from live backend usage events.
///
/// `LoopCostSummary` (the compact session totals) already lives in
/// `LoopSessionOverview.swift` from the LA1a pass and is intentionally not
/// redefined here. This file adds the per-step record that the usage
/// accumulator hands to evidence projection.
public struct LoopCostEvidence: Codable, Equatable, Sendable {
  public var stepExecutionId: String
  public var backend: String?
  public var model: String?
  public var inputTokens: Int?
  public var outputTokens: Int?
  public var totalTokens: Int?
  public var durationMs: Int?
  public var diagnostics: [String]

  public init(
    stepExecutionId: String,
    backend: String? = nil,
    model: String? = nil,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    totalTokens: Int? = nil,
    durationMs: Int? = nil,
    diagnostics: [String] = []
  ) {
    self.stepExecutionId = stepExecutionId
    self.backend = backend
    self.model = model
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.durationMs = durationMs
    self.diagnostics = diagnostics
  }

  private enum CodingKeys: String, CodingKey {
    case stepExecutionId
    case backend
    case model
    case inputTokens
    case outputTokens
    case totalTokens
    case durationMs
    case diagnostics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stepExecutionId = try container.decode(String.self, forKey: .stepExecutionId)
    backend = try container.decodeIfPresent(String.self, forKey: .backend)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
    outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
    totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
    durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
    diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
  }
}

public extension LoopCostSummary {
  /// Derives compact session totals from per-step cost evidence. Totals are
  /// honest partial sums: a token total is present only when at least one step
  /// reported that dimension, and `stepsWithoutUsage` counts steps that emitted
  /// no usage so callers can flag partial numbers instead of fabricating zeros.
  static func make(from costs: [LoopCostEvidence]) -> LoopCostSummary {
    var totalInput: Int?
    var totalOutput: Int?
    var totalTokens: Int?
    var totalDuration: Int?
    var withUsage = 0
    var withoutUsage = 0
    for cost in costs {
      let hasUsage = cost.inputTokens != nil
        || cost.outputTokens != nil
        || cost.totalTokens != nil
      if hasUsage { withUsage += 1 } else { withoutUsage += 1 }
      if let value = cost.inputTokens { totalInput = (totalInput ?? 0) + value }
      if let value = cost.outputTokens { totalOutput = (totalOutput ?? 0) + value }
      if let value = cost.totalTokens { totalTokens = (totalTokens ?? 0) + value }
      if let value = cost.durationMs { totalDuration = (totalDuration ?? 0) + value }
    }
    return LoopCostSummary(
      totalInputTokens: totalInput,
      totalOutputTokens: totalOutput,
      totalTokens: totalTokens,
      totalDurationMs: totalDuration,
      stepsWithUsage: withUsage,
      stepsWithoutUsage: withoutUsage
    )
  }

  /// True when any step lacked usage, so totals are partial.
  var isPartial: Bool { stepsWithoutUsage > 0 }
}
