#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public enum WorkflowVersionDifferenceKind: String, Codable, Equatable, Sendable {
  case added
  case removed
  case contentModified = "content-modified"
  case executableBitOnly = "executable-bit-only"
}

public struct WorkflowVersionDifference: Codable, Equatable, Sendable {
  public var relativePath: String
  public var kind: WorkflowVersionDifferenceKind
  public var from: WorkflowBundleSnapshotFile?
  public var to: WorkflowBundleSnapshotFile?
}

public struct WorkflowVersionsCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var snapshots: [WorkflowSnapshotReference]
}

public struct WorkflowVersionShowCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var manifest: WorkflowBundleSnapshotManifest
  public var integrityVerified: Bool
  public var mutationReferences: [String]
  public var restoreReferences: [String]
}

public struct WorkflowVersionDiffCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var from: String
  public var to: String
  public var differences: [WorkflowVersionDifference]
}

public struct WorkflowRestoreCommandResult: Codable, Equatable, Sendable {
  public var workflow: WorkflowBundleIdentity
  public var sourceSnapshotId: String
  public var dryRun: Bool
  public var approved: Bool
  public var restored: Bool
  public var beforeBundleDigest: String
  public var requestedBundleDigest: String
  public var preRestoreSnapshotId: String?
  public var restoreId: String?
  public var transactionId: String?
  public var restoredFiles: [String]
  public var dirtyConflicts: [String]
  public var validation: [LoopVerificationEvidence]
}

public struct WorkflowVersionCommand: Sendable {
  private let resolver: any WorkflowBundleResolving
  private let temporaryRegistry: WorkflowTemporaryRegistry

  public init() {
    resolver = FileSystemWorkflowBundleResolver()
    temporaryRegistry = WorkflowTemporaryRegistry()
  }

  init(
    resolver: any WorkflowBundleResolving,
    temporaryRegistry: WorkflowTemporaryRegistry
  ) {
    self.resolver = resolver
    self.temporaryRegistry = temporaryRegistry
  }

  public func run(_ options: WorkflowVersionCommandOptions) -> CLICommandResult {
    do {
      let parsed = try ParsedParityOptions(options.arguments)
      let output = try parseOutputOnly(options.arguments, allowTableOutput: false, defaultOutput: .json)
      let workingDirectory = URL(
        fileURLWithPath: parsed.workingDirectory ?? FileManager.default.currentDirectoryPath,
        isDirectory: true
      )
      let bundle = try resolver.resolve(WorkflowResolutionOptions(
        workflowName: options.workflowName,
        scope: parsed.scope,
        workflowDefinitionDir: parsed.workflowDefinitionDir,
        workingDirectory: workingDirectory.path
      ))
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
        for: target,
        workingDirectory: workingDirectory,
        configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot
      )
      let store = WorkflowHistoryStore(root: historyRoot)
      switch options.kind {
      case .list:
        let snapshots = try store.list(expectedIdentity: target).map { snapshot in
          var snapshot = snapshot
          let related = try historyReferences(snapshotId: snapshot.snapshotId, historyRoot: historyRoot)
          snapshot.mutationReferences = Set(related.mutations + [snapshot.createdBeforeChangeSetId].compactMap { $0 }).sorted()
          snapshot.restoreReferences = Set(related.restores + [snapshot.createdBeforeRestoreId].compactMap { $0 }).sorted()
          return snapshot
        }
        let result = WorkflowVersionsCommandResult(workflow: target, snapshots: snapshots)
        return try render(result, output: output) { result in
          result.snapshots.map { "\($0.snapshotId) \($0.bundleDigest) integrity=verified" }.joined(separator: "\n") + "\n"
        }
      case .show:
        let snapshotId = try require(options.firstReference, "workflow version show requires a snapshot id")
        let manifest = try store.loadSnapshot(snapshotId, expectedIdentity: target)
        let related = try historyReferences(snapshotId: snapshotId, historyRoot: historyRoot)
        let result = WorkflowVersionShowCommandResult(
          workflow: target,
          manifest: manifest,
          integrityVerified: true,
          mutationReferences: Set(related.mutations + [manifest.createdBeforeChangeSetId].compactMap { $0 }).sorted(),
          restoreReferences: Set(related.restores + [manifest.createdBeforeRestoreId].compactMap { $0 }).sorted()
        )
        return try render(result, output: output) { result in
          "snapshot \(result.manifest.snapshotId) \(result.manifest.bundleDigest) files=\(result.manifest.files.count) integrity=verified\n"
        }
      case .diff:
        let from = try require(options.firstReference, "workflow version diff requires a from reference")
        let to = try require(options.secondReference, "workflow version diff requires a to reference")
        let differences = try diff(
          from: metadata(reference: from, target: target, store: store),
          to: metadata(reference: to, target: target, store: store)
        )
        let result = WorkflowVersionDiffCommandResult(workflow: target, from: from, to: to, differences: differences)
        return try render(result, output: output) { result in
          result.differences.map { "\($0.kind.rawValue) \($0.relativePath)" }.joined(separator: "\n") + "\n"
        }
      case .restore:
        let snapshotId = try require(options.firstReference, "workflow restore requires a snapshot id")
        let result: WorkflowRestoreCommandResult
        if bundle.temporary {
          guard let expectedDigest = bundle.temporaryRegistryDigest else {
            throw CLIUsageError("temporary workflow resolution did not retain a registry digest")
          }
          result = try temporaryRegistry.withWorkflowMutationAccess(
            workflowId: bundle.workflow.workflowId,
            expectedDigest: expectedDigest,
            shouldPublish: { $0.restored },
            { detachedWorkflowDirectory, publish in
              let stableTarget = try WorkflowHistoryIdentityResolver.identity(for: bundle)
              let stableHistoryRoot = try WorkflowHistoryIdentityResolver.historyRoot(
                for: stableTarget,
                workingDirectory: workingDirectory,
                configuredRoot: bundle.workflow.loop?.selfEvolution?.historyRoot
              )
              return try restore(
                snapshotId: snapshotId,
                target: stableTarget,
                historyRoot: stableHistoryRoot,
                store: WorkflowHistoryStore(root: stableHistoryRoot),
                approved: parsed.exactYes,
                physicalOwnershipRoot: detachedWorkflowDirectory,
                postCommitPublication: publish
              )
            }
          )
        } else {
          result = try restore(
            snapshotId: snapshotId,
            target: target,
            historyRoot: historyRoot,
            store: store,
            approved: parsed.exactYes,
            physicalOwnershipRoot: nil,
            postCommitPublication: { _ in }
          )
        }
        return try render(result, output: output) { result in
          "restore snapshot=\(result.sourceSnapshotId) dryRun=\(result.dryRun) restored=\(result.restored) files=\(result.restoredFiles.count) conflicts=\(result.dirtyConflicts.count)\n"
        }
      }
    } catch let error as CLIUsageError {
      return CLICommandResult(exitCode: .usage, stderr: error.message + "\n")
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "\(error)\n")
    }
  }

  private func metadata(
    reference: String,
    target: WorkflowBundleIdentity,
    store: WorkflowHistoryStore
  ) throws -> [WorkflowBundleSnapshotFile] {
    if reference == "current" {
      guard target.sourceMutable, target.sourceKind != .installedPackage else {
        throw CLIUsageError("the current token is available only for mutable workflow bundles")
      }
      return try WorkflowHistoryIdentityResolver.inventory(for: target).files.map(\.metadata)
    }
    return try store.loadSnapshot(reference, expectedIdentity: target).files
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
    snapshotId: String,
    target: WorkflowBundleIdentity,
    historyRoot: URL,
    store: WorkflowHistoryStore,
    approved: Bool,
    physicalOwnershipRoot: URL?,
    postCommitPublication: (URL) throws -> Void
  ) throws -> WorkflowRestoreCommandResult {
    guard target.sourceMutable, target.sourceKind != .installedPackage, target.packageDirectory == nil else {
      throw CLIUsageError("installed package workflows are immutable restore destinations")
    }
    let source = try store.loadSnapshot(snapshotId, expectedIdentity: target)
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
        validation: validation
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
      expectedAfterBundleDigest: source.bundleDigest,
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
      postCommitPublication: postCommitPublication,
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
    return WorkflowRestoreCommandResult(
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
      validation: validation
    )
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

  private func require(_ value: String?, _ message: String) throws -> String {
    guard let value else { throw CLIUsageError(message) }
    return value
  }

  private func render<T: Encodable>(
    _ value: T,
    output: WorkflowOutputFormat,
    text: (T) -> String
  ) throws -> CLICommandResult {
    if output == .text { return CLICommandResult(exitCode: .success, stdout: text(value)) }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let json = String(data: try encoder.encode(value), encoding: .utf8) else {
      throw CLIUsageError("unable to encode workflow version command output as UTF-8")
    }
    return CLICommandResult(exitCode: .success, stdout: json + "\n")
  }
}
