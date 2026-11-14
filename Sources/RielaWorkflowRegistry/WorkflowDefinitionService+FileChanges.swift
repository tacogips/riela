import Foundation
import RielaAddons
import RielaCore

extension WorkflowDefinitionService {
  func captureBaselineIfAbsent(workflowName: String, liveDirectory: URL, sourceScope: WorkflowScope,
                               transactionId: String, actor: WorkflowDefinitionActor,
                               operation: WorkflowDefinitionOperation, bundleSnapshotBefore: String?) throws -> WorkflowDefinitionBaselineOutcome? {
    if let head = try store.head(workflowName: workflowName) { return .headExists(versionId: head.currentVersionId) }
    guard FileManager.default.fileExists(atPath: liveDirectory.path) else { return nil }
    let bundle = try resolveDirectory(liveDirectory)
    let data = try WorkflowDefinitionDocument.make(from: bundle).canonicalData()
    var evidence = [WorkflowDefinitionEvidenceRef(kind: .baselineTransaction, id: transactionId)]
    if let bundleSnapshotBefore { evidence.append(.init(kind: .bundleSnapshotBefore, id: bundleSnapshotBefore)) }
    let write = WorkflowDefinitionWrite(workflowName: workflowName, operation: .import, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: liveDirectory.path, sourceScope: sourceScope.rawValue,
      provenance: operation == .registryWrite ? WorkflowProvenance.mutable.rawValue : bundle.provenance.rawValue, actor: actor,
      reason: "baseline captured before first tracked \(operation.rawValue) (\(transactionId))", evidence: evidence,
      defaultHistoryRetention: defaultHistoryRetention)
    switch try store.commit(write) {
    case let .created(version, _): return .captured(versionId: version.versionId)
    case let .alreadyRegistered(head): return .headExists(versionId: head.currentVersionId)
    }
  }

  func committedDocument(workflowName: String, stagingDirectory: URL, liveDirectory: URL) throws -> (data: Data, digest: String) {
    let staging = try resolveDirectory(stagingDirectory)
    let authored = try WorkflowDefinitionDocument.make(from: staging).authoredFiles
    let overlay = try WorkflowAuthoredFileOverlay(files: authored)
    let live = try resolveDirectory(liveDirectory, overlay: overlay)
    guard live.workflow.workflowId == staging.workflow.workflowId else { throw invalidDefinition("re-derived bundle does not match staged workflow") }
    let doc = try WorkflowDefinitionDocument.make(from: live, authoredOverlay: overlay)
    let diagnostics = DefaultWorkflowValidator().validate(doc.runtime.workflow)
      + doc.runtime.nodePayloads.keys.sorted().flatMap { validateAgentNodePayload(doc.runtime.nodePayloads[$0]!, path: "nodes.\($0)") }
    guard !diagnostics.contains(where: { $0.severity == .error }) else {
      throw invalidDefinition(diagnostics.filter { $0.severity == .error }.map(\.message).joined(separator: "; "))
    }
    let data = try doc.canonicalData()
    return (data, JSONCanonical.sha256Hex(data))
  }

  private func resolveDirectory(_ directory: URL, overlay: WorkflowAuthoredFileOverlay? = nil) throws -> ResolvedWorkflowBundle {
    let parent = directory.deletingLastPathComponent()
    return try fileResolver.resolve(WorkflowResolutionOptions(workflowName: directory.lastPathComponent, scope: .direct,
      workflowDefinitionDir: parent.path, workingDirectory: parent.path, includeDeactivated: true, authoredOverlay: overlay))
  }

  func sync(_ intent: WorkflowDefinitionSyncIntent) throws -> WorkflowDefinitionSyncOutcome {
    let attribution = intent.attribution
    let data = Data(intent.documentJSON.utf8)
    let after = try document(data)
    let evidence = changeEvidence(transactionId: intent.transactionId, before: intent.bundleSnapshotBefore,
                                  after: intent.bundleSnapshotAfter, attribution: attribution)
    for attempt in 0..<3 {
      if try store.isChangeComplete(workflowName: intent.workflowName, operation: attribution.operation,
                                    transactionId: intent.transactionId, documentDigest: nil) { return .alreadyComplete }
      let current = try store.current(workflowName: intent.workflowName)
      if let expected = attribution.expectedHeadVersionId, current?.head.currentVersionId != expected {
        throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed")
      }
      if let current, current.version.documentDigest == intent.documentDigest {
        if attribution.operation == .rollback { throw invalidDefinition("rollback target equals head") }
        do {
          return try auditOnly(workflowName: intent.workflowName, attribution: attribution, evidence: evidence,
                               expectedHeadVersionId: current.head.currentVersionId)
        } catch let error as WorkflowDefinitionStoreError where error.code == .staleHead && attribution.expectedHeadVersionId == nil && attempt < 2 {
          continue
        }
      }
      var overwritten: WorkflowDefinitionOverwrittenChanges?
      var overwrittenIds: [String] = []
      if let current, current.head.currentVersionId != current.head.lastFileVersionId {
        let audits = try store.auditRecords(workflowName: intent.workflowName, afterVersionId: current.head.lastFileVersionId)
          .filter { [.updatePrompt, .update, .restore, .undo, .redo].contains($0.operation)
            || ($0.operation == .rollback && !$0.evidence.contains { $0.kind == .fileTransaction }) }
        overwrittenIds = audits.map(\.auditId)
        let baseline = try store.document(versionId: current.head.lastFileVersionId)
        let currentDoc = try document(current.document)
        overwritten = WorkflowDefinitionOverwrittenChanges(sinceVersionId: current.head.lastFileVersionId,
          auditIds: overwrittenIds, diff: baseline.map { diffDocuments(try? document($0), currentDoc) } ?? [])
      }
      let write = WorkflowDefinitionWrite(workflowName: intent.workflowName, operation: attribution.operation,
        documentData: data, documentDigest: intent.documentDigest, sourceDirectory: intent.sourceDirectory,
        sourceScope: intent.sourceScope, provenance: current?.version.provenance
          ?? (attribution.operation == .registryWrite ? WorkflowProvenance.mutable.rawValue : WorkflowProvenance.immutable.rawValue),
        actor: attribution.actor, reason: attribution.reason, evidence: evidence,
        diff: diffDocuments(try current.map { try document($0.document) }, after), overwrittenChanges: overwritten,
        expectedCurrentVersionId: attribution.expectedHeadVersionId ?? current?.head.currentVersionId,
        defaultHistoryRetention: defaultHistoryRetention, rollbackProposalId: attribution.rollbackProposalId)
      do {
        switch try store.commit(write) {
        case let .created(version, audit): return .versionWritten(version, audit, overwrittenAuditIds: overwrittenIds)
        case .alreadyRegistered: if attribution.expectedHeadVersionId != nil { throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed") }
        }
      } catch let error as WorkflowDefinitionStoreError where error.code == .staleHead && attribution.expectedHeadVersionId == nil && attempt < 2 {
        continue
      }
    }
    throw WorkflowDefinitionStoreError(code: .staleHead, message: "definition head changed during sync")
  }

  func recordDelete(workflowName: String, transactionId: String, bundleSnapshotBefore: String?,
                    attribution: WorkflowDefinitionChangeAttribution) throws -> WorkflowDefinitionSyncOutcome {
    let evidence = changeEvidence(transactionId: transactionId, before: bundleSnapshotBefore, after: nil, attribution: attribution)
    return try auditOnly(workflowName: workflowName, attribution: attribution, evidence: evidence)
  }

  private func auditOnly(workflowName: String, attribution: WorkflowDefinitionChangeAttribution,
                         evidence: [WorkflowDefinitionEvidenceRef], expectedHeadVersionId: String? = nil) throws -> WorkflowDefinitionSyncOutcome {
    switch try store.recordAuditOnlyChange(workflowName: workflowName, operation: attribution.operation,
                                            reason: attribution.reason, evidence: evidence, actor: attribution.actor,
                                            expectedHeadVersionId: expectedHeadVersionId) {
    case let .recorded(audit): return .auditOnly(audit)
    case .collapsed: return .collapsed
    case .noHead: return .noHead
    }
  }

  private func changeEvidence(transactionId: String, before: String?, after: String?,
                              attribution: WorkflowDefinitionChangeAttribution) -> [WorkflowDefinitionEvidenceRef] {
    var result = attribution.evidence + [.init(kind: .fileTransaction, id: transactionId)]
    if let before { result.append(.init(kind: .bundleSnapshotBefore, id: before)) }
    if let after { result.append(.init(kind: .bundleSnapshotAfter, id: after)) }
    return result
  }
}
