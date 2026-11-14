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

public enum EventOverlapSettingsField: String, Equatable, Sendable {
  case overlapPolicy
  case maxQueuedRuns
  case maxConcurrentRuns
}

/// One semantic problem with a set of overlap settings. Every surface (event
/// contract validation, workflow `triggerDefaults` validation, serve-time
/// resolution, routine mutations) derives its diagnostics from this single
/// rule set and only maps each issue to its own path and wording.
public enum EventOverlapSettingsIssue: Equatable, Sendable {
  /// `overlapPolicy` is not one of `EventOverlapPolicy.allCases`.
  case unknownPolicy(String)
  /// A run cap is below 1.
  case capBelowMinimum(EventOverlapSettingsField, value: Int)
  /// A run cap is set but the policy on the same layer is not the one it applies to.
  case capRequiresPolicy(EventOverlapSettingsField, required: EventOverlapPolicy)

  public var field: EventOverlapSettingsField {
    switch self {
    case .unknownPolicy:
      .overlapPolicy
    case let .capBelowMinimum(field, _), let .capRequiresPolicy(field, _):
      field
    }
  }
}

/// Validates one layer of overlap settings. Issues are ordered: policy first,
/// then `maxQueuedRuns`, then `maxConcurrentRuns` (minimum before policy match).
public func eventOverlapSettingsIssues(_ settings: EventOverlapSettings) -> [EventOverlapSettingsIssue] {
  var issues: [EventOverlapSettingsIssue] = []
  if let raw = settings.overlapPolicy, EventOverlapPolicy(rawValue: raw) == nil {
    issues.append(.unknownPolicy(raw))
  }
  for field in [EventOverlapSettingsField.maxQueuedRuns, .maxConcurrentRuns] {
    let value = field == .maxQueuedRuns ? settings.maxQueuedRuns : settings.maxConcurrentRuns
    let required: EventOverlapPolicy = field == .maxQueuedRuns ? .queue : .concurrent
    guard let value else { continue }
    if value < 1 {
      issues.append(.capBelowMinimum(field, value: value))
    }
    if settings.overlapPolicy != required.rawValue {
      issues.append(.capRequiresPolicy(field, required: required))
    }
  }
  return issues
}

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

  // Resolution is lenient about caps that do not match the winning policy
  // (they are ignored); validators report that mismatch before serve starts.
  for issue in eventOverlapSettingsIssues(winner) {
    switch issue {
    case let .unknownPolicy(raw):
      throw EventOverlapPolicyError(
        "overlapPolicy must be one of \(EventOverlapPolicy.allowedValuesText); got '\(raw)'"
      )
    case let .capBelowMinimum(field, value):
      throw EventOverlapPolicyError("\(field.rawValue) must be an integer >= 1; got \(value)")
    case .capRequiresPolicy:
      continue
    }
  }
  guard let rawPolicy = winner.overlapPolicy, let policy = EventOverlapPolicy(rawValue: rawPolicy) else {
    return EffectiveEventOverlapPolicy(policy: .skip, source: .default)
  }
  return EffectiveEventOverlapPolicy(
    policy: policy,
    source: source,
    maxQueuedRuns: policy == .queue ? (winner.maxQueuedRuns ?? defaultEventOverlapMaxQueuedRuns) : nil,
    maxConcurrentRuns: policy == .concurrent ? winner.maxConcurrentRuns : nil
  )
}
