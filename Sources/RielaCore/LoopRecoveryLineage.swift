import Foundation

public enum LoopEntryMode: String, Codable, Sendable {
  case run
  case resume
  case rerun
  case retry
  case replay
}

public struct LoopRecoveryLineage: Codable, Equatable, Sendable {
  public var entryMode: LoopEntryMode
  public var sourceSessionId: String?
  public var sourceStepId: String?
  public var sourceStepExecutionId: String?
  public var parentSessionId: String?
  public var childSessionIds: [String]
  public var reason: String?
  public var inputReusePolicy: String
  public var preservedFailureEvidenceRefs: [String]
  /// First session of this loop lineage (additive; nil on legacy records and
  /// on initial runs, where the session is its own root).
  public var rootSessionId: String?
  /// 1-based attempt counter within the lineage. Rerun increments it; resume
  /// continues the source attempt. Nil on legacy records (treated as 1).
  public var attemptNumber: Int?

  public init(
    entryMode: LoopEntryMode,
    sourceSessionId: String? = nil,
    sourceStepId: String? = nil,
    sourceStepExecutionId: String? = nil,
    parentSessionId: String? = nil,
    childSessionIds: [String] = [],
    reason: String? = nil,
    inputReusePolicy: String,
    preservedFailureEvidenceRefs: [String] = [],
    rootSessionId: String? = nil,
    attemptNumber: Int? = nil
  ) {
    self.entryMode = entryMode
    self.sourceSessionId = sourceSessionId
    self.sourceStepId = sourceStepId
    self.sourceStepExecutionId = sourceStepExecutionId
    self.parentSessionId = parentSessionId
    self.childSessionIds = childSessionIds
    self.reason = reason
    self.inputReusePolicy = inputReusePolicy
    self.preservedFailureEvidenceRefs = preservedFailureEvidenceRefs
    self.rootSessionId = rootSessionId
    self.attemptNumber = attemptNumber
  }
}
