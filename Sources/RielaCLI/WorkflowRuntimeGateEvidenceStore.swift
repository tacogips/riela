import Darwin
import Foundation
import RielaCore

struct WorkflowRuntimeGateEvidence: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var resultId: String
  var workflowId: String
  var sessionId: String
  var result: LoopGateResult

  init(resultId: String, workflowId: String, sessionId: String, result: LoopGateResult) {
    schemaVersion = 1
    self.resultId = resultId
    self.workflowId = workflowId
    self.sessionId = sessionId
    self.result = result
  }
}

struct WorkflowRuntimeGateEvidenceStore: Sendable {
  let root: URL
  private let constructionHook: @Sendable (WorkflowHistoryArtifactConstructionBoundary) throws -> Void

  init(root: URL) {
    self.root = root
    constructionHook = { _ in }
  }

  init(
    root: URL,
    constructionHook: @escaping @Sendable (WorkflowHistoryArtifactConstructionBoundary) throws -> Void
  ) {
    self.root = root
    self.constructionHook = constructionHook
  }

  func publish(_ evidence: WorkflowRuntimeGateEvidence) throws {
    try validate(evidence)
    let url = evidenceURL(evidence.resultId)
    let pinned = try WorkflowHistoryPinnedRoot(root)
    if try pinned.entryType(url) != nil {
      guard try load(evidence.resultId) == evidence else {
        throw CLIUsageError("existing runtime gate evidence does not match the finalized review")
      }
      return
    }
    let bytes = try WorkflowHistoryCanonicalCoding.encode(evidence)
    let sidecar = WorkflowHistorySecurePersistence.digestSidecar(for: url)
    try pinned.ensureDirectory(url.deletingLastPathComponent())
    try constructionHook(.childDirectory)
    try pinned.atomicWrite(bytes, to: url, overwrite: false)
    try pinned.atomicWrite(
      Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
      to: sidecar,
      overwrite: false
    )
    try constructionHook(.leafFile)
    try pinned.setPermissions(0o444, for: url, expectedType: S_IFREG)
    try pinned.setPermissions(
      0o444,
      for: sidecar,
      expectedType: S_IFREG
    )
    try constructionHook(.beforeVerification)
    let reread = try pinned.readRegular(url, requireNonWritable: true)
    let rereadSidecar = try pinned.readRegular(sidecar, requireNonWritable: true)
    guard reread == bytes,
          rereadSidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
          try WorkflowHistoryCanonicalCoding.decode(WorkflowRuntimeGateEvidence.self, from: reread) == evidence else {
      throw CLIUsageError("published runtime gate evidence failed immutable reread verification")
    }
  }

  func load(_ resultId: String) throws -> WorkflowRuntimeGateEvidence {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(resultId)
    let url = evidenceURL(resultId)
    try requireImmutableRegularFile(url)
    try requireImmutableRegularFile(WorkflowHistorySecurePersistence.digestSidecar(for: url))
    let evidence = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowRuntimeGateEvidence.self,
      from: url,
      historyRoot: root
    )
    try validate(evidence)
    guard evidence.resultId == resultId else {
      throw CLIUsageError("runtime gate evidence id does not match its immutable path")
    }
    return evidence
  }

  static func resultId(stepExecutionId: String) throws -> String {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(stepExecutionId)
    let resultId = "gate-result-\(stepExecutionId)"
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(resultId)
    return resultId
  }

  private func validate(_ evidence: WorkflowRuntimeGateEvidence) throws {
    guard evidence.schemaVersion == 1 else {
      throw CLIUsageError("unsupported runtime gate evidence schema")
    }
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.resultId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.workflowId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.sessionId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.result.gateId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.result.stepId)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(evidence.result.stepExecutionId)
  }

  private func evidenceURL(_ resultId: String) -> URL {
    root.appendingPathComponent("gate-results/\(resultId).json")
  }

  private func requireImmutableRegularFile(_ url: URL) throws {
    _ = try WorkflowHistoryPinnedRoot(root, create: false).readRegular(url, requireNonWritable: true)
  }
}

enum WorkflowReviewGatePolicy {
  static func requiredGate(in workflow: WorkflowDefinition) throws -> LoopGateDeclaration {
    guard workflow.loop?.selfEvolution?.requiresReviewGate == true else {
      throw CLIUsageError("workflow self-evolution must declare a required review gate")
    }
    let stepsById = Dictionary(uniqueKeysWithValues: workflow.steps.map { ($0.id, $0) })
    let gates = (workflow.loop?.gates ?? []).filter { gate in
      guard gate.required, let step = stepsById[gate.stepId] else { return false }
      return step.loop?.role == "gate" && step.loop?.gateId == gate.id
    }
    guard gates.count == 1, let gate = gates.first else {
      throw CLIUsageError("workflow self-evolution must declare exactly one required review-gate step")
    }
    return gate
  }

  static func validate(
    _ result: LoopGateResult,
    gate: LoopGateDeclaration,
    review: WorkflowChangeSetReviewEvidence? = nil
  ) throws {
    guard result.gateId == gate.id,
          result.stepId == gate.stepId,
          result.decision == (gate.acceptWhen.decision ?? .accepted) else {
      throw CLIUsageError("runtime review gate result does not satisfy the declared gate decision policy")
    }
    if let maximum = gate.acceptWhen.maxHighFindings, result.severityCounts.high > maximum {
      throw CLIUsageError("runtime review gate result exceeds the declared high-finding policy")
    }
    if let maximum = gate.acceptWhen.maxMediumFindings, result.severityCounts.medium > maximum {
      throw CLIUsageError("runtime review gate result exceeds the declared medium-finding policy")
    }
    guard result.blockingFindings.isEmpty else {
      throw CLIUsageError("runtime review gate result contains blocking findings")
    }
    if let review {
      guard review.gateId == result.gateId,
            review.reviewerStepId == result.stepId,
            review.reviewerStepExecutionId == result.stepExecutionId else {
        throw CLIUsageError("finalized review does not bind the persisted runtime gate result")
      }
    }
  }
}
