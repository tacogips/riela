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

  public init(
    entryMode: LoopEntryMode,
    sourceSessionId: String? = nil,
    sourceStepId: String? = nil,
    sourceStepExecutionId: String? = nil,
    parentSessionId: String? = nil,
    childSessionIds: [String] = [],
    reason: String? = nil,
    inputReusePolicy: String,
    preservedFailureEvidenceRefs: [String] = []
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
  }
}
