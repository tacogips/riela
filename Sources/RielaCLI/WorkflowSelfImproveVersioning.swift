#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public struct WorkflowSelfImproveVersioning: Sendable {
  private let beforeProposalWorkflowOpen: @Sendable () throws -> Void
  private let mutableRegistry: WorkflowMutableRegistry

  public init() {
    beforeProposalWorkflowOpen = {}
    mutableRegistry = WorkflowMutableRegistry()
  }

  init(beforeProposalWorkflowOpen: @escaping @Sendable () throws -> Void) {
    self.beforeProposalWorkflowOpen = beforeProposalWorkflowOpen
    mutableRegistry = WorkflowMutableRegistry()
  }

  init(mutableRegistry: WorkflowMutableRegistry) {
    beforeProposalWorkflowOpen = {}
    self.mutableRegistry = mutableRegistry
  }

  func finalize(
    workflowName: String,
    bundle: ResolvedWorkflowBundle,
    workingDirectory: URL,
    proposalId: String,
    runtimeSnapshot: WorkflowRuntimePersistenceSnapshot
  ) throws -> WorkflowSelfImproveCommandResult {
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: workingDirectory,
      configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot
    )
    let changeSet = try WorkflowRuntimeReviewFinalizer().finalize(
      proposalId: proposalId,
      expectedIdentity: target,
      historyRoot: historyRoot,
      workflow: bundle.workflow,
      runtimeSnapshot: runtimeSnapshot
    )
    return WorkflowSelfImproveCommandResult(
      workflowName: workflowName,
      dryRun: false,
      mutated: false,
      backupDirectory: nil,
      reportPath: historyRoot.appendingPathComponent("change-sets/\(changeSet.changeSetId)/change-set.json").path,
      report: [
        "Workflow self-improve proposal finalized from runtime-owned review evidence.",
        "workflow=\(workflowName)",
        "proposalId=\(proposalId)",
        "reviewSessionId=\(runtimeSnapshot.session.sessionId)",
        "changeSetId=\(changeSet.changeSetId)"
      ],
      proposalId: proposalId,
      proposalDigest: changeSet.proposal.proposalDigest,
      changeSetId: changeSet.changeSetId,
      finalizedDigest: changeSet.finalizedDigest,
      snapshotId: nil,
      transactionId: nil,
      mutationEvidence: nil
    )
  }

  func execute(
    workflowName: String,
    bundle: ResolvedWorkflowBundle,
    workingDirectory: URL,
    dryRun: Bool,
    approved: Bool,
    changeSetId: String?,
    expectedDigest: String?,
    sourceSessionId: String?
  ) throws -> WorkflowSelfImproveCommandResult {
    func operation(
      _ operationBundle: ResolvedWorkflowBundle,
      physicalRoot: URL?,
      publish: (URL) throws -> Void
    ) throws -> WorkflowSelfImproveCommandResult {
      try executeUnlocked(
        workflowName: workflowName,
        bundle: operationBundle,
        workingDirectory: workingDirectory,
        dryRun: dryRun,
        approved: approved,
        changeSetId: changeSetId,
        expectedDigest: expectedDigest,
        sourceSessionId: sourceSessionId,
        physicalOwnershipRoot: physicalRoot,
        postCommitPublication: publish
      )
    }
    guard bundle.provenance == .mutable else {
      return try operation(bundle, physicalRoot: nil, publish: { _ in })
    }
    guard let expectedDigest = bundle.mutableRegistryDigest else {
      throw CLIUsageError("mutable workflow resolution did not retain a registry digest")
    }
    return try mutableRegistry.withWorkflowMutationAccess(
      workflowId: bundle.workflow.workflowId,
      expectedDigest: expectedDigest,
      shouldPublish: { $0.mutated },
      { detachedWorkflowDirectory, publish in
        try operation(bundle, physicalRoot: detachedWorkflowDirectory, publish: publish)
      }
    )
  }

  private func executeUnlocked(
    workflowName: String,
    bundle: ResolvedWorkflowBundle,
    workingDirectory: URL,
    dryRun: Bool,
    approved: Bool,
    changeSetId: String?,
    expectedDigest: String?,
    sourceSessionId: String?,
    physicalOwnershipRoot: URL?,
    postCommitPublication: (URL) throws -> Void
  ) throws -> WorkflowSelfImproveCommandResult {
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let selfEvolution = bundle.workflow.loop?.selfEvolution
    if let selfEvolution, !selfEvolution.allowed {
      throw CLIUsageError("workflow self-evolution is disabled by workflow loop metadata")
    }
    let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
      for: target,
      workingDirectory: workingDirectory,
      configuredRoot: selfEvolution?.historyRoot
    )
    if dryRun {
      return try propose(
        workflowName: workflowName,
        target: target,
        historyRoot: historyRoot,
        sourceSessionId: sourceSessionId ?? "cli-\(UUID().uuidString.lowercased())",
        physicalOwnershipRoot: physicalOwnershipRoot
      )
    }
    guard approved else {
      throw CLIUsageError("workflow self-improve apply requires explicit --yes approval")
    }
    guard let changeSetId, let expectedDigest else {
      throw CLIUsageError("workflow self-improve --yes requires --change-set-id and --expected-digest")
    }
    return try apply(
      workflowName: workflowName,
      workflow: bundle.workflow,
      target: target,
      historyRoot: historyRoot,
      changeSetId: changeSetId,
      expectedDigest: expectedDigest,
      physicalOwnershipRoot: physicalOwnershipRoot,
      postCommitPublication: postCommitPublication
    )
  }

  private func propose(
    workflowName: String,
    target: WorkflowBundleIdentity,
    historyRoot: URL,
    sourceSessionId: String,
    physicalOwnershipRoot: URL?
  ) throws -> WorkflowSelfImproveCommandResult {
    let inventory = try WorkflowHistoryIdentityResolver.inventory(
      for: target,
      rootOverride: physicalOwnershipRoot
    )
    let workflowRelativePath = try relativeWorkflowPath(target)
    guard let beforeFile = inventory.files.first(where: { $0.metadata.relativePath == workflowRelativePath }) else {
      throw CLIUsageError("workflow inventory does not contain the resolved workflow.json")
    }
    let updatedBytes = try proposedWorkflowBytes(from: beforeFile)
    let afterState = WorkflowFileState(
      contentDigest: WorkflowHistoryCanonicalCoding.sha256(updatedBytes),
      byteCount: updatedBytes.count,
      artifactKind: .workflowDefinition,
      executable: beforeFile.metadata.executable
    )
    let beforeState = WorkflowFileState(
      contentDigest: beforeFile.metadata.contentDigest,
      byteCount: beforeFile.metadata.byteCount,
      artifactKind: beforeFile.metadata.artifactKind,
      executable: beforeFile.metadata.executable
    )
    let operation = WorkflowFileOperation(
      relativePath: workflowRelativePath,
      kind: .update,
      before: beforeState,
      after: afterState
    )
    var afterFiles = inventory.files.map(\.metadata)
    guard let index = afterFiles.firstIndex(where: { $0.relativePath == workflowRelativePath }) else {
      throw CLIUsageError("workflow operation target disappeared from inventory")
    }
    afterFiles[index] = WorkflowBundleSnapshotFile(
      relativePath: workflowRelativePath,
      contentDigest: afterState.contentDigest,
      byteCount: afterState.byteCount,
      artifactKind: afterState.artifactKind,
      executable: afterState.executable
    )
    let expectedAfterDigest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: afterFiles)
    var proposal = WorkflowChangeProposal(
      proposalId: "proposal-\(UUID().uuidString.lowercased())",
      sourceSessionId: sourceSessionId,
      target: target,
      beforeBundleDigest: inventory.bundleDigest,
      operations: [operation],
      expectedAfterBundleDigest: expectedAfterDigest,
      rationale: "Apply the reviewed self-improvement marker without broadening the immutable proposal.",
      validation: [],
      createdAt: Date(),
      proposalDigest: String(repeating: "0", count: 64)
    )
    proposal.proposalDigest = try WorkflowHistoryCanonicalCoding.proposalDigest(proposal)
    try WorkflowChangeSetStore(root: historyRoot).publishProposal(
      proposal,
      contentObjects: [afterState.contentDigest: updatedBytes]
    )
    let report = [
      "Workflow self-improve proposal published without source mutation.",
      "dryRun=true",
      "workflow=\(workflowName)",
      "proposalId=\(proposal.proposalId)",
      "proposalDigest=\(proposal.proposalDigest)"
    ]
    return WorkflowSelfImproveCommandResult(
      workflowName: workflowName,
      dryRun: true,
      mutated: false,
      backupDirectory: nil,
      reportPath: historyRoot.appendingPathComponent("proposals/\(proposal.proposalId)/proposal.json").path,
      report: report,
      proposalId: proposal.proposalId,
      proposalDigest: proposal.proposalDigest,
      changeSetId: nil,
      finalizedDigest: nil,
      snapshotId: nil,
      transactionId: nil,
      mutationEvidence: nil
    )
  }

  private func apply(
    workflowName: String,
    workflow: WorkflowDefinition,
    target: WorkflowBundleIdentity,
    historyRoot: URL,
    changeSetId: String,
    expectedDigest: String,
    physicalOwnershipRoot: URL?,
    postCommitPublication: (URL) throws -> Void
  ) throws -> WorkflowSelfImproveCommandResult {
    guard target.sourceMutable, target.sourceKind != .installedPackage else {
      throw WorkflowRegistryError(
        code: .immutableWorkflow,
        message: "immutable workflow '\(workflowName)' cannot apply self-improvement; register a mutable copy",
        workflowId: workflowName
      )
    }
    try WorkflowHistoryCanonicalCoding.validateDigest(expectedDigest)
    let changeStore = WorkflowChangeSetStore(root: historyRoot)
    let changeSet = try changeStore.loadChangeSet(changeSetId, expectedIdentity: target)
    guard changeSet.finalizedDigest == expectedDigest else {
      throw CLIUsageError("finalized change-set digest does not match --expected-digest")
    }
    let requiredGate = try WorkflowReviewGatePolicy.requiredGate(in: workflow)
    let gateEvidence = try WorkflowRuntimeGateEvidenceStore(root: historyRoot).load(changeSet.review.gateResultId)
    guard gateEvidence.workflowId == workflow.workflowId else {
      throw CLIUsageError("persisted runtime gate evidence belongs to a different workflow")
    }
    try WorkflowReviewGatePolicy.validate(gateEvidence.result, gate: requiredGate, review: changeSet.review)
    let current = try WorkflowHistoryIdentityResolver.inventory(
      for: target,
      rootOverride: physicalOwnershipRoot
    )
    guard current.bundleDigest == changeSet.proposal.beforeBundleDigest else {
      throw CLIUsageError("workflow bundle changed after review; refusing apply")
    }
    let historyStore = WorkflowHistoryStore(root: historyRoot)
    let snapshot = try historyStore.createSnapshot(
      inventory: current,
      createdBySessionId: changeSet.proposal.sourceSessionId,
      createdBeforeChangeSetId: changeSet.changeSetId
    )
    let transaction = try WorkflowDirectoryTransactionCoordinator().commit(
      target: target,
      historyRoot: historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: current.bundleDigest,
      expectedAfterBundleDigest: changeSet.proposal.expectedAfterBundleDigest,
      preOperationSnapshotId: snapshot.snapshotId,
      operationAuditIntent: { transactionId in
        .mutation(LoopWorkflowMutationEvidence(
          mode: "reviewed-change-set",
          changeSetId: changeSet.changeSetId,
          snapshotId: snapshot.snapshotId,
          transactionId: transactionId,
          target: target,
          beforeBundleDigest: current.bundleDigest,
          afterBundleDigest: changeSet.proposal.expectedAfterBundleDigest,
          review: changeSet.review,
          applied: false,
          restored: false,
          outcome: .failed
        ))
      },
      physicalOwnershipRoot: physicalOwnershipRoot,
      postCommitPublication: postCommitPublication,
      mutateStaging: { staging in
      try apply(changeSet.proposal.operations, proposalId: changeSet.proposal.proposalId, store: changeStore, to: staging)
    })
    let evidence = LoopWorkflowMutationEvidence(
      mode: "reviewed-change-set",
      changeSetId: changeSet.changeSetId,
      snapshotId: snapshot.snapshotId,
      transactionId: transaction.transactionId,
      target: target,
      beforeBundleDigest: current.bundleDigest,
      afterBundleDigest: transaction.resultBundleDigest,
      review: changeSet.review,
      validation: transaction.verification,
      applied: true,
      restored: false,
      outcome: .applied
    )
    let auditURL = historyRoot.appendingPathComponent("audits/\(transaction.transactionId).json")
    return WorkflowSelfImproveCommandResult(
      workflowName: workflowName,
      dryRun: false,
      mutated: true,
      backupDirectory: historyRoot.appendingPathComponent("snapshots/\(snapshot.snapshotId)").path,
      reportPath: auditURL.path,
      report: [
        "Workflow self-improve reviewed change set applied.",
        "dryRun=false",
        "workflow=\(workflowName)",
        "changeSetId=\(changeSet.changeSetId)",
        "snapshotId=\(snapshot.snapshotId)",
        "transactionId=\(transaction.transactionId)"
      ],
      proposalId: changeSet.proposal.proposalId,
      proposalDigest: changeSet.proposal.proposalDigest,
      changeSetId: changeSet.changeSetId,
      finalizedDigest: changeSet.finalizedDigest,
      snapshotId: snapshot.snapshotId,
      transactionId: transaction.transactionId,
      mutationEvidence: evidence
    )
  }

  private func apply(
    _ operations: [WorkflowFileOperation],
    proposalId: String,
    store: WorkflowChangeSetStore,
    to staging: URL
  ) throws {
    for operation in operations {
      let destination = staging.appendingPathComponent(operation.relativePath)
      guard WorkflowHistoryIdentityResolver.contained(destination, in: staging) else {
        throw CLIUsageError("proposed operation escapes workflow root")
      }
      switch operation.kind {
      case .create, .update:
        guard let after = operation.after else { throw CLIUsageError("operation is missing after state") }
        let bytes = try store.proposalObject(proposalId: proposalId, digest: after.contentDigest)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
        try setExecutable(after.executable, at: destination)
      case .delete:
        try FileManager.default.removeItem(at: destination)
      case .executableBit:
        guard let after = operation.after else { throw CLIUsageError("mode operation is missing after state") }
        try setExecutable(after.executable, at: destination)
      }
    }
  }

  private func proposedWorkflowBytes(from file: WorkflowOwnedFile) throws -> Data {
    let read = try WorkflowDescriptorRelativeReader.read(file.url, within: file.readRoot) {
      try beforeProposalWorkflowOpen()
    }
    guard read.bytes == file.bytes,
          WorkflowHistoryCanonicalCoding.sha256(read.bytes) == file.metadata.contentDigest,
          read.bytes.count == file.metadata.byteCount,
          read.executable == file.metadata.executable else {
      throw CLIUsageError("workflow.json changed after secure inventory")
    }
    let bytes = read.bytes
    guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
      throw CLIUsageError("workflow self-improve requires a workflow.json object")
    }
    let marker = "self-improve-reviewed"
    let description = object["description"] as? String ?? ""
    if !description.contains(marker) {
      object["description"] = description.isEmpty ? marker : "\(description) \(marker)"
    }
    object["selfImproveMutation"] = ["mode": "reviewed-change-set"]
    return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
  }

  private func relativeWorkflowPath(_ target: WorkflowBundleIdentity) throws -> String {
    let workflowJSON = URL(fileURLWithPath: target.workflowDirectory).appendingPathComponent("workflow.json").path
    guard workflowJSON.hasPrefix(target.ownershipRoot + "/") else {
      throw CLIUsageError("workflow.json is outside the ownership root")
    }
    return String(workflowJSON.dropFirst(target.ownershipRoot.count + 1))
  }

  private func setExecutable(_ executable: Bool, at url: URL) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let current = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
    let permissions = executable ? (current | 0o111) : (current & ~0o111)
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

}
