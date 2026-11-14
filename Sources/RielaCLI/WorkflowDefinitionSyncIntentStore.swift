import Foundation
import RielaCore
import RielaWorkflowRegistry

struct WorkflowDefinitionSyncIntentStore {
  let historyRoot: URL

  private var directory: URL { historyRoot.appendingPathComponent("definition-sync", isDirectory: true) }

  func write(_ intent: WorkflowDefinitionSyncIntent) throws {
    try WorkflowHistorySecurePersistence.writeCanonical(intent, to: url(intent.transactionId),
      historyRoot: historyRoot, overwrite: false)
  }

  func pending() throws -> [WorkflowDefinitionSyncIntent] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    try WorkflowHistorySecurePersistence.validateContained(directory, historyRoot: historyRoot, leafType: .directory)
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
      .filter { $0.pathExtension == "json" }
    var ordered: [(URL, Date)] = try files.map { file in
      (file, try file.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast)
    }
    ordered.sort { lhs, rhs in
      if lhs.1 == rhs.1 { return lhs.0.lastPathComponent < rhs.0.lastPathComponent }
      return lhs.1 < rhs.1
    }
    return try ordered.map {
      try WorkflowHistorySecurePersistence.readCanonical(WorkflowDefinitionSyncIntent.self, from: $0.0, historyRoot: historyRoot)
    }
  }

  func delete(transactionId: String) throws {
    let file = url(transactionId)
    let root = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
    try root.unlink(file)
    try root.unlink(WorkflowHistorySecurePersistence.digestSidecar(for: file))
  }

  func replayPending(recorder: any WorkflowDefinitionChangeRecording,
                     isCommitted: (WorkflowDefinitionSyncIntent) throws -> Bool) throws -> [WorkflowDefinitionSyncOutcome] {
    var outcomes: [WorkflowDefinitionSyncOutcome] = []
    for intent in try pending() {
      if try !isCommitted(intent) {
        if let proposalId = intent.attribution.rollbackProposalId {
          do {
            _ = try WorkflowRollbackProposalStore(rootDirectory: intent.storeRoot).transition(
              proposalId: proposalId, from: [.applying], to: .pending, decidedActor: nil,
              decisionReason: nil, failureCode: nil, diagnostics: [], expectedClaimTransactionId: intent.transactionId)
          } catch let error as WorkflowDefinitionStoreError where error.code == .rollbackProposalNotPending {
            // Another recovery already resolved the claim.
          }
        }
        try delete(transactionId: intent.transactionId)
        continue
      }
      let complete = try WorkflowDefinitionStore(rootDirectory: intent.storeRoot).isChangeComplete(
        workflowName: intent.workflowName, operation: intent.attribution.operation,
        transactionId: intent.transactionId, documentDigest: intent.documentDigest)
      if !complete { outcomes.append(try recorder.sync(intent)) }
      try delete(transactionId: intent.transactionId)
    }
    return outcomes
  }

  private func url(_ transactionId: String) -> URL {
    directory.appendingPathComponent("\(transactionId).json")
  }
}
