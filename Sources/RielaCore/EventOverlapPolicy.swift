import Foundation

public enum EventOverlapPolicy: String, Codable, CaseIterable, Sendable {
  case skip
  case cancelRunning
  case queue
  case concurrent

  public static let allowedValuesText = "skip, cancelRunning, queue, concurrent"
}

public enum EventOverlapPolicySource: String, Codable, Sendable {
  case binding
  case workflow
  case `default`
}

public struct EventOverlapSettings: Codable, Equatable, Sendable {
  public var overlapPolicy: String?
  public var maxQueuedRuns: Int?
  public var maxConcurrentRuns: Int?

  public init(overlapPolicy: String? = nil, maxQueuedRuns: Int? = nil, maxConcurrentRuns: Int? = nil) {
    self.overlapPolicy = overlapPolicy
    self.maxQueuedRuns = maxQueuedRuns
    self.maxConcurrentRuns = maxConcurrentRuns
  }
}

public struct EffectiveEventOverlapPolicy: Codable, Equatable, Sendable {
  public var policy: EventOverlapPolicy
  public var source: EventOverlapPolicySource
  public var maxQueuedRuns: Int?
  public var maxConcurrentRuns: Int?

  public init(
    policy: EventOverlapPolicy,
    source: EventOverlapPolicySource,
    maxQueuedRuns: Int? = nil,
    maxConcurrentRuns: Int? = nil
  ) {
    self.policy = policy
    self.source = source
    self.maxQueuedRuns = maxQueuedRuns
    self.maxConcurrentRuns = maxConcurrentRuns
  }
}

public struct EventOverlapPolicyError: Error, Equatable, Sendable, CustomStringConvertible {
  public var message: String

  public init(_ message: String) {
    self.message = message
  }

  public var description: String { message }
}

public let defaultEventOverlapMaxQueuedRuns = 1

public func resolveEventOverlapPolicy(
  binding: EventOverlapSettings?,
  workflow: EventOverlapSettings?
) throws -> EffectiveEventOverlapPolicy {
  let winner: EventOverlapSettings
  let source: EventOverlapPolicySource
  if let binding, binding.overlapPolicy != nil {
    winner = binding
    source = .binding
  } else if let workflow, workflow.overlapPolicy != nil {
    winner = workflow
    source = .workflow
  } else {
    return EffectiveEventOverlapPolicy(policy: .skip, source: .default)
  }

  guard let rawPolicy = winner.overlapPolicy, let policy = EventOverlapPolicy(rawValue: rawPolicy) else {
    let rawPolicy = winner.overlapPolicy ?? ""
    throw EventOverlapPolicyError(
      "overlapPolicy must be one of \(EventOverlapPolicy.allowedValuesText); got '\(rawPolicy)'"
    )
  }
  for (name, cap) in [("maxQueuedRuns", winner.maxQueuedRuns), ("maxConcurrentRuns", winner.maxConcurrentRuns)] {
    if let cap, cap < 1 {
      throw EventOverlapPolicyError("\(name) must be an integer >= 1; got \(cap)")
    }
  }
  return EffectiveEventOverlapPolicy(
    policy: policy,
    source: source,
    maxQueuedRuns: policy == .queue ? (winner.maxQueuedRuns ?? defaultEventOverlapMaxQueuedRuns) : nil,
    maxConcurrentRuns: policy == .concurrent ? winner.maxConcurrentRuns : nil
  )
}
