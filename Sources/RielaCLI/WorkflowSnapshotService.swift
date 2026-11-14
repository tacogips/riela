import Foundation
import RielaCore

public struct WorkflowSnapshotTargetRequest: Sendable {
  public var workflowName: String
  public var scope: WorkflowScope
  public var workflowDefinitionDir: String?
  public var workingDirectory: String

  public init(workflowName: String, scope: WorkflowScope, workflowDefinitionDir: String?, workingDirectory: String) {
    self.workflowName = workflowName
    self.scope = scope
    self.workflowDefinitionDir = workflowDefinitionDir
    self.workingDirectory = workingDirectory
  }
}

public struct WorkflowSnapshotService: Sendable {
  private let resolver: any WorkflowBundleResolving
  private let mutableRegistry: WorkflowMutableRegistry?

  public init(resolver: any WorkflowBundleResolving = FileSystemWorkflowBundleResolver(),
              mutableRegistry: WorkflowMutableRegistry? = nil) {
    self.resolver = resolver
    self.mutableRegistry = mutableRegistry
  }

  private struct Context {
    let bundle: ResolvedWorkflowBundle
    let target: WorkflowBundleIdentity
    let root: URL
    let store: WorkflowHistoryStore
  }

  private func resolve(_ request: WorkflowSnapshotTargetRequest) throws -> Context {
    let directory = URL(fileURLWithPath: request.workingDirectory, isDirectory: true)
    let bundle = try resolver.resolve(WorkflowResolutionOptions(workflowName: request.workflowName, scope: request.scope,
      workflowDefinitionDir: request.workflowDefinitionDir, workingDirectory: directory.path))
    let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
    let root = try WorkflowHistoryIdentityResolver.historyRoot(for: target, workingDirectory: directory,
      configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot)
    return Context(bundle: bundle, target: target, root: root, store: WorkflowHistoryStore(root: root))
  }

  public func list(_ request: WorkflowSnapshotTargetRequest, limit: Int, beforeSnapshotId: String?) throws -> WorkflowVersionsCommandResult {
    let context = try resolve(request)
    let target = context.target
    let root = context.root
    let store = context.store
    let snapshots = try store.list(expectedIdentity: target, limit: limit, beforeSnapshotId: beforeSnapshotId).map { snapshot in
      var snapshot = snapshot
      let related = try historyReferences(snapshotId: snapshot.snapshotId, historyRoot: root)
      snapshot.mutationReferences = Set(related.mutations + [snapshot.createdBeforeChangeSetId].compactMap { $0 }).sorted()
      snapshot.restoreReferences = Set(related.restores + [snapshot.createdBeforeRestoreId].compactMap { $0 }).sorted()
      return snapshot
    }
    return WorkflowVersionsCommandResult(workflow: target, snapshots: snapshots,
      nextBeforeSnapshotId: snapshots.count == limit ? snapshots.last?.snapshotId : nil)
  }

  public func show(_ request: WorkflowSnapshotTargetRequest, snapshotId: String) throws -> WorkflowVersionShowCommandResult {
    let context = try resolve(request)
    let target = context.target
    let root = context.root
    let store = context.store
    let manifest = try store.loadSnapshot(snapshotId, expectedIdentity: target)
    let related = try historyReferences(snapshotId: snapshotId, historyRoot: root)
    return WorkflowVersionShowCommandResult(workflow: target, manifest: manifest, integrityVerified: true,
      mutationReferences: Set(related.mutations + [manifest.createdBeforeChangeSetId].compactMap { $0 }).sorted(),
      restoreReferences: Set(related.restores + [manifest.createdBeforeRestoreId].compactMap { $0 }).sorted())
  }

  public func diff(_ request: WorkflowSnapshotTargetRequest, from: String, to: String, includeContent: Bool) throws -> WorkflowVersionDiffCommandResult {
    let context = try resolve(request)
    let (target, store) = (context.target, context.store)
    let current = (from == "current" || to == "current") ? try WorkflowHistoryIdentityResolver.inventory(for: target) : nil
    func side(_ reference: String) throws -> ([WorkflowBundleSnapshotFile], [String: Data]) {
      if reference == "current", let current {
        return (current.files.map(\.metadata), Dictionary(uniqueKeysWithValues: current.files.map { ($0.metadata.relativePath, $0.bytes) }))
      }
      let manifest = try store.loadSnapshot(reference, expectedIdentity: target)
      var bytes: [String: Data] = [:]
      if includeContent {
        for file in manifest.files { bytes[file.relativePath] = try store.objectBytes(snapshot: manifest, relativePath: file.relativePath) }
      }
      return (manifest.files, bytes)
    }
    let lhs = try side(from)
    let rhs = try side(to)
    var differences = try diff(from: lhs.0, to: rhs.0)
    if includeContent {
      for index in differences.indices where differences[index].kind != .executableBitOnly {
        let path = differences[index].relativePath
        differences[index].content = WorkflowUnifiedDiff.render(path: path, before: lhs.1[path], after: rhs.1[path])
      }
    }
    return WorkflowVersionDiffCommandResult(workflow: target, from: from, to: to, differences: differences)
  }

  public func restore(_ request: WorkflowSnapshotTargetRequest, snapshotId: String, approved: Bool, reason: String?,
                      actor: WorkflowDefinitionActor, attribution: WorkflowDefinitionChangeAttribution? = nil,
                      beforePublication: ((String) throws -> Void)? = nil,
                      recorder: (any WorkflowDefinitionChangeRecording)? = nil) throws -> WorkflowRestoreCommandResult {
    let context = try resolve(request)
    let bundle = context.bundle
    if let reason, reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw CLIUsageError("--reason must not be empty")
    }
    let recorder = recorder ?? WorkflowDefinitionChangeRecorder(workingDirectory: request.workingDirectory,
      fileResolver: FileSystemWorkflowBundleResolver(enforcesTransactionBlock: false, capturesCatalogOriginSnapshot: false))
    let attribution = attribution ?? WorkflowDefinitionChangeAttribution(operation: .snapshotRestore, actor: actor,
      reason: reason ?? "restore bundle snapshot \(snapshotId)")
    if bundle.provenance == .mutable {
      guard let expectedDigest = bundle.mutableRegistryDigest else {
        throw CLIUsageError("mutable workflow resolution did not retain a registry digest")
      }
      let registry = mutableRegistry ?? WorkflowMutableRegistry(definitionRecorder: recorder)
      if !approved {
        return try registry.withWorkflowMutationAccess(workflowId: bundle.workflow.workflowId,
          expectedDigest: expectedDigest, shouldPublish: { $0.restored }, { directory, publish in
            try restore(workflowName: request.workflowName, snapshotId: snapshotId, context: context,
              approved: false, reason: reason, physicalOwnershipRoot: directory, postCommitPublication: { url, _ in try publish(url) },
              attribution: attribution, recorder: recorder, beforePublication: nil)
          })
      }
      var publishedAttribution = attribution
      let publication = try registry.withWorkflowMutationAccess(workflowId: bundle.workflow.workflowId,
        expectedDigest: expectedDigest, attribution: attribution, attributionProvider: { publishedAttribution },
        beforePublication: beforePublication, shouldPublish: { $0.restored }, { directory, publish in
          try restore(workflowName: request.workflowName, snapshotId: snapshotId, context: context,
            approved: true, reason: reason, physicalOwnershipRoot: directory, postCommitPublication: { url, before in
              publishedAttribution.evidence.append(.init(kind: .bundleSnapshotBefore, id: before))
              publishedAttribution.evidence.append(.init(kind: .bundleSnapshotAfter, id: snapshotId))
              try publish(url)
            },
            attribution: attribution, recorder: recorder, beforePublication: beforePublication)
        })
      var result = publication.result
      result.applyDefinitionSyncOutcome(publication.definitionSync)
      return result
    }
    return try restore(workflowName: request.workflowName, snapshotId: snapshotId, context: context,
      approved: approved, reason: reason, physicalOwnershipRoot: nil, postCommitPublication: { _, _ in },
      attribution: attribution, recorder: recorder, beforePublication: beforePublication)
  }

  private func diff(
    from: [WorkflowBundleSnapshotFile],
    to: [WorkflowBundleSnapshotFile]
  ) throws -> [WorkflowVersionDifference] {
    let fromByPath = Dictionary(uniqueKeysWithValues: from.map { ($0.relativePath, $0) })
    let toByPath = Dictionary(uniqueKeysWithValues: to.map { ($0.relativePath, $0) })
    return Set(fromByPath.keys).union(toByPath.keys).sorted(by: utf8LessThan).compactMap { path in
      let lhs = fromByPath[path]
      let rhs = toByPath[path]
      let kind: WorkflowVersionDifferenceKind?
      switch (lhs, rhs) {
      case (nil, .some): kind = .added
      case (.some, nil): kind = .removed
      case let (.some(lhs), .some(rhs)) where lhs.contentDigest != rhs.contentDigest: kind = .contentModified
      case let (.some(lhs), .some(rhs)) where lhs.executable != rhs.executable: kind = .executableBitOnly
      default: kind = nil
      }
      return kind.map { WorkflowVersionDifference(relativePath: path, kind: $0, from: lhs, to: rhs) }
    }
  }

  private func restore(
    workflowName: String,
    snapshotId: String,
    context: Context,
    approved: Bool,
    reason: String?,
    physicalOwnershipRoot: URL?,
    postCommitPublication: (URL, String) throws -> Void,
    attribution: WorkflowDefinitionChangeAttribution,
    recorder: any WorkflowDefinitionChangeRecording,
    beforePublication: ((String) throws -> Void)?
  ) throws -> WorkflowRestoreCommandResult {
    let target = context.target
    let historyRoot = context.root
    let store = context.store
    let source = try store.loadSnapshot(snapshotId, expectedIdentity: target)
    // Digests include the operation's identity metadata. A historical authored
    // contract version may differ while the history owner stays the same.
    let restoredDigest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: target, files: source.files)
    let current = try WorkflowHistoryIdentityResolver.inventory(
      for: target,
      rootOverride: physicalOwnershipRoot
    )
    let changes = try diff(from: current.files.map(\.metadata), to: source.files)
    let sourcePaths = Set(source.files.map(\.relativePath))
    let dirtyConflicts = current.unownedFiles
      .map(\.metadata.relativePath)
      .filter(sourcePaths.contains)
      .sorted(by: utf8LessThan)
    var validation = [LoopVerificationEvidence(
      id: "snapshot-integrity",
      outcome: "passed",
      diagnosticSummary: "canonical manifest, object digests, byte counts, identity, and bundle digest verified"
    )]
    if !approved {
      return WorkflowRestoreCommandResult(
        workflow: target,
        sourceSnapshotId: snapshotId,
        dryRun: true,
        approved: false,
        restored: false,
        beforeBundleDigest: current.bundleDigest,
        requestedBundleDigest: source.bundleDigest,
        preRestoreSnapshotId: nil,
        restoreId: nil,
        transactionId: nil,
        restoredFiles: changes.map(\.relativePath),
        dirtyConflicts: dirtyConflicts,
        validation: validation,
        reason: reason
      )
    }
    guard target.sourceMutable, target.sourceKind != .installedPackage, target.packageDirectory == nil else {
      throw WorkflowRegistryError(
        code: .immutableWorkflow,
        message: "immutable workflow '\(target.workflowId)' cannot be restored; register a mutable copy",
        workflowId: target.workflowId
      )
    }
    guard dirtyConflicts.isEmpty else {
      throw CLIUsageError("workflow restore refused dirty conflicts: \(dirtyConflicts.joined(separator: ", "))")
    }
    let restoreId = "restore-\(UUID().uuidString.lowercased())"
    let preRestore = try store.createSnapshot(
      inventory: current,
      createdBeforeRestoreId: restoreId
    )
    let transaction = try WorkflowDirectoryTransactionCoordinator().commit(
      target: target,
      historyRoot: historyRoot,
      kind: .restore,
      expectedBeforeBundleDigest: current.bundleDigest,
      expectedAfterBundleDigest: restoredDigest,
      preOperationSnapshotId: preRestore.snapshotId,
      operationAuditIntent: { transactionId in
        .restore(WorkflowRestoreRecord(
          restoreId: restoreId,
          target: target,
          sourceSnapshotId: snapshotId,
          preRestoreSnapshotId: preRestore.snapshotId,
          requestedBundleDigest: source.bundleDigest,
          beforeBundleDigest: current.bundleDigest,
          approved: true,
          dirtyConflictPolicy: "reject",
          restoredFiles: changes.map(\.relativePath),
          validation: validation,
          transactionId: transactionId,
          startedAt: Date(),
          outcome: .failed
        ))
      },
      physicalOwnershipRoot: physicalOwnershipRoot,
      postCommitPublication: { try postCommitPublication($0, preRestore.snapshotId) },
      definitionSync: physicalOwnershipRoot == nil ? WorkflowDirectoryDefinitionSync(recorder: recorder,
        workflowName: workflowName, sourceScope: WorkflowScope(rawValue: target.sourceScope.rawValue) ?? .direct,
        attribution: attribution, bundleSnapshotBefore: preRestore.snapshotId, bundleSnapshotAfter: snapshotId,
        beforePublication: beforePublication) : nil,
      mutateStaging: { staging in
      for owned in current.files where !WorkflowSharedNodeDependencyInventory.isDependencyPath(
        owned.metadata.relativePath
      ) {
        let destination = staging.appendingPathComponent(owned.metadata.relativePath)
        if FileManager.default.fileExists(atPath: destination.path) {
          try FileManager.default.removeItem(at: destination)
        }
      }
      try store.restoreSnapshot(source, to: staging)
    })
    validation.append(contentsOf: transaction.verification)
    var result = WorkflowRestoreCommandResult(
      workflow: target,
      sourceSnapshotId: snapshotId,
      dryRun: false,
      approved: true,
      restored: true,
      beforeBundleDigest: current.bundleDigest,
      requestedBundleDigest: source.bundleDigest,
      preRestoreSnapshotId: preRestore.snapshotId,
      restoreId: restoreId,
      transactionId: transaction.transactionId,
      restoredFiles: changes.map(\.relativePath),
      dirtyConflicts: [],
      validation: validation,
      reason: reason
    )
    result.applyDefinitionSyncOutcome(transaction.definitionSyncOutcome)
    if let error = transaction.definitionSyncError {
      throw CLIUsageError("definition_sync_failed: \(error)")
    }
    return result
  }

  private func utf8LessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }

  private func historyReferences(
    snapshotId: String,
    historyRoot: URL
  ) throws -> (mutations: [String], restores: [String]) {
    var mutations = Set<String>()
    var restores = Set<String>()
    let audits = historyRoot.appendingPathComponent("audits", isDirectory: true)
    if FileManager.default.fileExists(atPath: audits.path) {
      for url in try FileManager.default.contentsOfDirectory(at: audits, includingPropertiesForKeys: nil)
      where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix("transaction-transaction-") {
        let evidence = try WorkflowHistorySecurePersistence.readCanonical(
          LoopWorkflowMutationEvidence.self,
          from: url,
          historyRoot: historyRoot
        )
        try WorkflowHistoryCanonicalCoding.validate(evidence)
        if evidence.snapshotId == snapshotId {
          if let changeSetId = evidence.changeSetId { mutations.insert(changeSetId) }
          if let transactionId = evidence.transactionId { mutations.insert(transactionId) }
        }
      }
    }
    let restoreDirectory = historyRoot.appendingPathComponent("restores", isDirectory: true)
    if FileManager.default.fileExists(atPath: restoreDirectory.path) {
      for url in try FileManager.default.contentsOfDirectory(at: restoreDirectory, includingPropertiesForKeys: nil)
      where url.pathExtension == "json" {
        let record = try WorkflowHistorySecurePersistence.readCanonical(
          WorkflowRestoreRecord.self,
          from: url,
          historyRoot: historyRoot
        )
        try WorkflowHistoryCanonicalCoding.validate(record)
        if record.sourceSnapshotId == snapshotId || record.preRestoreSnapshotId == snapshotId {
          restores.insert(record.restoreId)
          restores.insert(record.transactionId)
        }
      }
    }
    return (mutations.sorted(), restores.sorted())
  }

}

extension WorkflowRestoreCommandResult {
  mutating func applyDefinitionSyncOutcome(_ outcome: WorkflowDefinitionSyncOutcome?) {
    guard let outcome else { return }
    switch outcome {
    case let .versionWritten(version, audit, overwrittenAuditIds):
      definitionVersionId = version.versionId
      definitionAuditId = audit.auditId
      if !overwrittenAuditIds.isEmpty {
        definitionWarnings = ["definition_overwritten_changes: " + overwrittenAuditIds.joined(separator: ",")]
      }
    case let .auditOnly(audit): definitionAuditId = audit.auditId
    case .collapsed, .alreadyComplete, .noHead: break
    }
  }
}
