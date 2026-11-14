import Foundation
import RielaCore
import RielaWorkflowRegistry

public enum WorkflowRegressionRollbackOutcome: String, Codable, Sendable {
  case noBaseline, noTargetEvidence, noRegression, targetVersionUnknown, notEligible, proposed, existing
}

public struct WorkflowRegressionRollbackCheckResult: Codable, Equatable, Sendable {
  public var outcome: WorkflowRegressionRollbackOutcome
  public var eligibilityCode: String?
  public var regressions: [WorkflowRollbackRegressionEntry]
  public var proposal: WorkflowRollbackProposal?
  public var diagnostics: [String]
}

public struct WorkflowRegressionRollbackError: Error, Equatable, CustomStringConvertible {
  public var code: String
  public var message: String
  public var description: String { message }
}

public struct WorkflowRegressionRollbackService: Sendable {
  let workingDirectory: String
  let sessionStore: String?
  let scope: WorkflowScope
  let environment: [String: String]
  let snapshotService: WorkflowSnapshotService
  let mutableRegistry: WorkflowMutableRegistry

  public init(workingDirectory: String, sessionStore: String?, scope: WorkflowScope = .auto,
              environment: [String: String] = CLIRuntimeEnvironment.mergedProcessEnvironment(),
              snapshotService: WorkflowSnapshotService = WorkflowSnapshotService(),
              mutableRegistry: WorkflowMutableRegistry = WorkflowMutableRegistry()) {
    self.workingDirectory = workingDirectory; self.sessionStore = sessionStore; self.scope = scope
    self.environment = environment; self.snapshotService = snapshotService; self.mutableRegistry = mutableRegistry
  }

  func recorder() -> WorkflowDefinitionChangeRecorder {
    WorkflowDefinitionChangeRecorder(sessionStoreRoot: sessionStore, workingDirectory: workingDirectory,
      environment: environment, fileResolver: FileSystemWorkflowBundleResolver(
        enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
  }

  func root(workflowName: String, sourceScope: WorkflowScope? = nil) throws -> String {
    try recorder().storeRoot(workflowName: workflowName, sourceScope: sourceScope ?? scope)
  }

  public func check(workflowName: String, targetSessionId: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRegressionRollbackCheckResult {
    try recoverClaims(workflowName: workflowName, root: root(workflowName: workflowName))
    let parsed = LoopCommandRunner.ParsedBaselineOptions(sessionId: targetSessionId, note: nil, scope: scope,
      workingDirectory: workingDirectory, sessionStore: sessionStore)
    let pair: LoopCommandRunner.BaselinePair
    switch try LoopCommandRunner().resolveBaselinePair(workflowId: workflowName, parsed: parsed) {
    case let .missing(verdict, diagnostics):
      return .init(outcome: verdict == "no-target-evidence" ? .noTargetEvidence : .noBaseline,
        eligibilityCode: nil, regressions: [], proposal: nil, diagnostics: diagnostics)
    case let .resolved(value): pair = value
    }
    let verdict = LoopRegressionClassifier.verdict(base: pair.baseManifest, target: pair.targetManifest,
      requiredGateIds: pair.requiredGateIds)
    let regressions = verdict.regressions.map { WorkflowRollbackRegressionEntry(kind: $0.kind, gateId: $0.gateId, detail: $0.detail) }
    func result(_ outcome: WorkflowRegressionRollbackOutcome, _ code: String? = nil,
                _ proposal: WorkflowRollbackProposal? = nil, _ diagnostics: [String] = []) -> WorkflowRegressionRollbackCheckResult {
      .init(outcome: outcome, eligibilityCode: code, regressions: regressions, proposal: proposal,
        diagnostics: verdict.diagnostics + diagnostics)
    }
    let targetSession = try CLIWorkflowSessionResolution.loadPersistedSession(sessionId: pair.targetManifest.sessionId,
      sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment)
    let targetPin = targetSession.record.session.definitionSource
    if let pin = targetPin, pin.workflowName == workflowName {
      let sourceScope = pin.sourceScope.flatMap(WorkflowScope.init(rawValue:)) ?? scope
      let pinRoot = try pin.storeRoot ?? root(workflowName: workflowName, sourceScope: sourceScope)
      try recoverClaims(workflowName: workflowName, root: pinRoot)
    }
    guard verdict.hasRegression else { return result(.noRegression) }
    guard let pin = targetPin, pin.workflowName == workflowName else { return result(.targetVersionUnknown) }
    let sourceScope = pin.sourceScope.flatMap(WorkflowScope.init(rawValue:)) ?? scope
    let storeRoot = try pin.storeRoot ?? root(workflowName: workflowName, sourceScope: sourceScope)
    let store = WorkflowDefinitionStore(rootDirectory: storeRoot)
    let version: WorkflowDefinitionVersion?
    if pin.kind == .store, let id = pin.versionId { version = try store.version(versionId: id) } else { version = try store.latestVersion(workflowName: workflowName, documentDigest: pin.digest) }
    guard let version, version.workflowName == workflowName else { return result(.targetVersionUnknown) }
    let proposals = WorkflowRollbackProposalStore(rootDirectory: storeRoot)
    if let existing = try proposals.proposal(workflowName: workflowName, regressedVersionId: version.versionId) {
      return result(.existing, nil, existing)
    }
    guard try store.head(workflowName: workflowName)?.currentVersionId == version.versionId else { return result(.notEligible, "headMoved") }
    guard version.operation == .selfImprove || ([.update, .updatePrompt].contains(version.operation) && version.actor.kind == .improvementNode) else {
      return result(.notEligible, "notImprovementVersion")
    }
    let baseSession = try CLIWorkflowSessionResolution.loadPersistedSession(sessionId: pair.baseManifest.sessionId,
      sessionStore: sessionStore, scope: scope, workingDirectory: workingDirectory, environment: environment)
    if let basePin = baseSession.record.session.definitionSource,
       basePin.versionId == version.versionId || (basePin.kind == .file && basePin.digest == version.documentDigest) {
      return result(.notEligible, "sameVersionAsBaseline")
    }
    guard let parent = version.parentVersionId, let parentData = try store.document(versionId: parent) else {
      return result(.notEligible, "noParent")
    }
    let audit = try store.audit(forVersionId: version.versionId)
    let bundle = version.operation == .selfImprove
    var policy = try WorkflowDefinitionDocument.decode(parentData).runtime.workflow.loop?.regressionRollback?.policy ?? .manual
    var diagnostics: [String] = []
    if bundle && audit?.overwrittenChanges != nil { policy = .manual; diagnostics.append("divergedParent") }
    let snapshotId = audit?.evidence.first(where: { $0.kind == .bundleSnapshotBefore })?.id
    let draft = WorkflowRollbackProposalDraft(workflowName: workflowName, regressedVersionId: version.versionId,
      rollbackToVersionId: parent, mode: bundle ? .bundle : .store, bundleSnapshotId: snapshotId,
      baselineSessionId: pair.baseManifest.sessionId, targetSessionId: pair.targetManifest.sessionId,
      regressions: regressions, policy: policy, status: policy == .manual ? .recorded : .pending, createdActor: actor)
    let inserted = try proposals.insertIfAbsent(draft)
    if inserted.created && policy == .automatic {
      let system = WorkflowDefinitionActor(kind: .system, id: "regression-rollback@\(pair.targetManifest.sessionId)")
      let applied = try bundle
        ? approveInBundle(root: storeRoot, workflowName: workflowName, proposal: inserted.proposal, reason: nil, actor: system)
        : approveInStore(root: storeRoot, workflowName: workflowName, proposal: inserted.proposal, reason: nil, actor: system)
      return result(.proposed, nil, applied, diagnostics)
    }
    return result(inserted.created ? .proposed : .existing, nil, inserted.proposal, diagnostics)
  }

  public func list(workflowName: String, status: WorkflowRollbackProposalStatus?, limit: Int) throws -> [WorkflowRollbackProposal] {
    try WorkflowRollbackProposalStore(rootDirectory: root(workflowName: workflowName)).list(workflowName: workflowName, status: status, limit: limit)
  }

  public func approve(workflowName: String, proposalId: String, reason: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal {
    let storeRoot = try root(workflowName: workflowName)
    try recoverClaims(workflowName: workflowName, root: storeRoot)
    let proposals = WorkflowRollbackProposalStore(rootDirectory: storeRoot)
    guard let proposal = try proposals.proposal(id: proposalId), proposal.workflowName == workflowName else {
      throw WorkflowRegressionRollbackError(code: "rollback_proposal_not_found", message: "proposal not found")
    }
    guard proposal.status == .pending else {
      throw WorkflowRegressionRollbackError(code: proposal.status == .applying ? "rollback_in_progress" : "rollback_proposal_not_pending", message: "proposal is not pending")
    }
    if proposal.mode == .bundle {
      return try approveInBundle(root: storeRoot, workflowName: workflowName, proposal: proposal, reason: reason, actor: actor)
    }
    return try approveInStore(root: storeRoot, workflowName: workflowName, proposal: proposal, reason: reason, actor: actor)
  }

  func approveInStore(root: String, workflowName: String, proposal: WorkflowRollbackProposal,
                      reason: String?, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal {
    let proposals = WorkflowRollbackProposalStore(rootDirectory: root)
    let store = WorkflowDefinitionStore(rootDirectory: root)
    guard try store.head(workflowName: workflowName)?.currentVersionId == proposal.regressedVersionId else {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .superseded,
        decidedActor: actor, decisionReason: reason, failureCode: nil, diagnostics: [])
      throw WorkflowRegressionRollbackError(code: "rollback_superseded", message: "definition head changed")
    }
    let kinds = proposal.regressions.map(\.kind).joined(separator: ", ")
    var text = "regression rollback of \(proposal.regressedVersionId) to \(proposal.rollbackToVersionId): \(kinds)"
    text += " (baseline \(proposal.baselineSessionId), target \(proposal.targetSessionId))"
    if let reason, !reason.isEmpty { text += "; approved: \(reason)" }
    let evidence: [WorkflowDefinitionEvidenceRef] = [.init(kind: .rollbackProposal, id: proposal.proposalId),
      .init(kind: .session, id: proposal.baselineSessionId), .init(kind: .session, id: proposal.targetSessionId)]
    let service = WorkflowDefinitionService(storeRoot: root, fileResolver: FileSystemWorkflowBundleResolver())
    do {
      _ = try service.rollback(workflowName: workflowName, toVersionId: proposal.rollbackToVersionId,
        expectedHeadVersionId: proposal.regressedVersionId, proposalId: proposal.proposalId, reason: text, evidence: evidence, actor: actor)
    } catch let error as WorkflowDefinitionStoreError where error.code == .staleHead {
      _ = try proposals.transition(proposalId: proposal.proposalId, from: [.pending], to: .superseded,
        decidedActor: actor, decisionReason: reason, failureCode: nil, diagnostics: [])
      throw WorkflowRegressionRollbackError(code: "rollback_superseded", message: "definition head changed")
    }
    guard let updated = try proposals.proposal(id: proposal.proposalId) else {
      throw WorkflowRegressionRollbackError(code: "rollback_proposal_not_found", message: "proposal not found")
    }
    return updated
  }

  public func reject(workflowName: String, proposalId: String, reason: String, actor: WorkflowDefinitionActor) throws -> WorkflowRollbackProposal {
    guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw WorkflowRegressionRollbackError(code: "reason_required", message: "reason is required")
    }
    let proposals = WorkflowRollbackProposalStore(rootDirectory: try root(workflowName: workflowName))
    guard let proposal = try proposals.proposal(id: proposalId), proposal.workflowName == workflowName else {
      throw WorkflowRegressionRollbackError(code: "rollback_proposal_not_found", message: "proposal not found")
    }
    guard proposal.status == .pending else {
      throw WorkflowRegressionRollbackError(code: proposal.status == .applying ? "rollback_in_progress" : "rollback_proposal_not_pending", message: "proposal is not pending")
    }
    return try proposals.transition(proposalId: proposalId, from: [.pending], to: .rejected,
      decidedActor: actor, decisionReason: reason, failureCode: nil, diagnostics: [])
  }
}
