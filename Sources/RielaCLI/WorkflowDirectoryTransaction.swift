#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore
public enum WorkflowDirectoryTransactionPhase: String, Codable, Equatable, Sendable {
  case preparing
  case prepared
  case committing
  case liveMoved = "live-moved"
  case published
  case committed
  case failed
  case recovered
}
public enum WorkflowDirectoryTransactionKind: String, Codable, Equatable, Sendable {
  case apply
  case restore
}
public struct WorkflowDirectoryTransactionRecord: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var kind: WorkflowDirectoryTransactionKind
  public var target: WorkflowBundleIdentity
  public var beforeBundleDigest: String
  public var expectedAfterBundleDigest: String
  public var preOperationSnapshotId: String
  public var beforeUnownedInventory: [WorkflowUnownedInventoryEntry]
  public var expectedAfterUnownedInventory: [WorkflowUnownedInventoryEntry]
  public var operationAuditIntent: WorkflowDirectoryOperationAuditIntent
  public var stagingPath: String
  public var rollbackPath: String
  public var physicalOwnershipRoot: String?
  public var phase: WorkflowDirectoryTransactionPhase
  public var verification: [LoopVerificationEvidence]
  public var diagnostics: [String]
  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case transactionId
    case kind
    case target
    case beforeBundleDigest
    case expectedAfterBundleDigest
    case preOperationSnapshotId
    case beforeUnownedInventory
    case expectedAfterUnownedInventory
    case operationAuditIntent
    case stagingPath
    case rollbackPath
    case physicalOwnershipRoot
    case phase
    case verification
    case diagnostics
  }
  public init(
    schemaVersion: Int = 1,
    transactionId: String,
    kind: WorkflowDirectoryTransactionKind,
    target: WorkflowBundleIdentity,
    beforeBundleDigest: String,
    expectedAfterBundleDigest: String,
    preOperationSnapshotId: String,
    beforeUnownedInventory: [WorkflowUnownedInventoryEntry],
    expectedAfterUnownedInventory: [WorkflowUnownedInventoryEntry],
    operationAuditIntent: WorkflowDirectoryOperationAuditIntent,
    stagingPath: String,
    rollbackPath: String,
    physicalOwnershipRoot: String? = nil,
    phase: WorkflowDirectoryTransactionPhase,
    verification: [LoopVerificationEvidence] = [],
    diagnostics: [String] = []
  ) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
    self.kind = kind
    self.target = target
    self.beforeBundleDigest = beforeBundleDigest
    self.expectedAfterBundleDigest = expectedAfterBundleDigest
    self.preOperationSnapshotId = preOperationSnapshotId
    self.beforeUnownedInventory = beforeUnownedInventory
    self.expectedAfterUnownedInventory = expectedAfterUnownedInventory
    self.operationAuditIntent = operationAuditIntent
    self.stagingPath = stagingPath
    self.rollbackPath = rollbackPath
    self.physicalOwnershipRoot = physicalOwnershipRoot
    self.phase = phase
    self.verification = verification
    self.diagnostics = diagnostics
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    transactionId = try container.decode(String.self, forKey: .transactionId)
    kind = try container.decode(WorkflowDirectoryTransactionKind.self, forKey: .kind)
    target = try container.decode(WorkflowBundleIdentity.self, forKey: .target)
    beforeBundleDigest = try container.decode(String.self, forKey: .beforeBundleDigest)
    expectedAfterBundleDigest = try container.decode(String.self, forKey: .expectedAfterBundleDigest)
    preOperationSnapshotId = try container.decode(String.self, forKey: .preOperationSnapshotId)
    beforeUnownedInventory = try container.decode([WorkflowUnownedInventoryEntry].self, forKey: .beforeUnownedInventory)
    expectedAfterUnownedInventory = try container.decode(
      [WorkflowUnownedInventoryEntry].self,
      forKey: .expectedAfterUnownedInventory
    )
    operationAuditIntent = try container.decode(WorkflowDirectoryOperationAuditIntent.self, forKey: .operationAuditIntent)
    stagingPath = try container.decode(String.self, forKey: .stagingPath)
    rollbackPath = try container.decode(String.self, forKey: .rollbackPath)
    physicalOwnershipRoot = try container.decodeIfPresent(String.self, forKey: .physicalOwnershipRoot)
    phase = try container.decode(WorkflowDirectoryTransactionPhase.self, forKey: .phase)
    verification = try container.decodeIfPresent([LoopVerificationEvidence].self, forKey: .verification) ?? []
    diagnostics = try container.decodeIfPresent([String].self, forKey: .diagnostics) ?? []
  }
}
public struct WorkflowDirectoryTransactionAudit: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var kind: WorkflowDirectoryTransactionKind
  public var target: WorkflowBundleIdentity
  public var preOperationSnapshotId: String
  public var beforeBundleDigest: String
  public var resultBundleDigest: String?
  public var observedPhase: WorkflowDirectoryTransactionPhase
  public var outcome: WorkflowHistoryOutcome
  public var verification: [LoopVerificationEvidence]
  public var diagnostics: [String]
  public init(
    transaction: WorkflowDirectoryTransactionRecord,
    resultBundleDigest: String?,
    outcome: WorkflowHistoryOutcome,
    diagnostics: [String] = []
  ) {
    schemaVersion = 1
    transactionId = transaction.transactionId
    kind = transaction.kind
    target = transaction.target
    preOperationSnapshotId = transaction.preOperationSnapshotId
    beforeBundleDigest = transaction.beforeBundleDigest
    self.resultBundleDigest = resultBundleDigest
    observedPhase = transaction.phase
    self.outcome = outcome
    verification = transaction.verification
    self.diagnostics = diagnostics
  }
}
protocol WorkflowTransactionAuditPersisting: Sendable {
  func persist(_ audit: WorkflowDirectoryTransactionAudit, historyRoot: URL) throws
}
struct FileWorkflowTransactionAuditStore: WorkflowTransactionAuditPersisting {
  func persist(_ audit: WorkflowDirectoryTransactionAudit, historyRoot: URL) throws {
    let directory = historyRoot.appendingPathComponent("audits", isDirectory: true)
    let url = directory.appendingPathComponent("transaction-\(audit.transactionId).json")
    if try historyEntryExistsWithoutFollowingLinks(url) {
      let existing = try WorkflowHistorySecurePersistence.readCanonical(
        WorkflowDirectoryTransactionAudit.self,
        from: url,
        historyRoot: historyRoot
      )
      guard existing == audit else {
        throw CLIUsageError("existing workflow transaction audit does not match recovery intent")
      }
      return
    }
    try WorkflowHistorySecurePersistence.writeCanonical(audit, to: url, historyRoot: historyRoot, overwrite: false)
  }
}
public struct WorkflowDirectoryTransactionResult: Equatable, Sendable {
  public var transactionId: String
  public var resultBundleDigest: String
  public var verification: [LoopVerificationEvidence]
}
private struct DirectoryTransactionPreflightInput {
  var target: WorkflowBundleIdentity
  var historyRoot: URL
  var kind: WorkflowDirectoryTransactionKind
  var expectedBeforeBundleDigest: String
  var expectedAfterBundleDigest: String
  var preOperationSnapshotId: String
  var auditIntent: WorkflowDirectoryOperationAuditIntent
  var live: URL
  var parent: URL
  var staging: URL
  var rollback: URL
  var transactions: URL
  var active: URL
  var usesDetachedPhysicalRoot: Bool
  var detachedRoot: WorkflowDetachedOwnershipPinnedRoot?
}

private struct DirectoryTransactionPreflightResult {
  var record: WorkflowDirectoryTransactionRecord
  var inventory: WorkflowBundleInventory
  var lockDescriptor: Int32
}

public struct WorkflowDirectoryTransactionCoordinator: Sendable {
  private let auditStore: any WorkflowTransactionAuditPersisting
  private let preflightAttemptStore: any WorkflowPreflightAttemptPersisting
  private let lockedPreflightHook: @Sendable () throws -> Void
  private let boundaryHook: @Sendable (WorkflowDirectoryTransactionBoundary) throws -> Void
  let detachedRecoveryValidatedHook: @Sendable () throws -> Void

  public init() {
    auditStore = FileWorkflowTransactionAuditStore()
    preflightAttemptStore = FileWorkflowPreflightAttemptStore()
    lockedPreflightHook = {}
    boundaryHook = { _ in }
    detachedRecoveryValidatedHook = {}
  }

  init(
    auditStore: any WorkflowTransactionAuditPersisting,
    preflightAttemptStore: any WorkflowPreflightAttemptPersisting = FileWorkflowPreflightAttemptStore(),
    lockedPreflightHook: @escaping @Sendable () throws -> Void = {},
    boundaryHook: @escaping @Sendable (WorkflowDirectoryTransactionBoundary) throws -> Void = { _ in },
    detachedRecoveryValidatedHook: @escaping @Sendable () throws -> Void = {}
  ) {
    self.auditStore = auditStore
    self.preflightAttemptStore = preflightAttemptStore
    self.lockedPreflightHook = lockedPreflightHook
    self.boundaryHook = boundaryHook
    self.detachedRecoveryValidatedHook = detachedRecoveryValidatedHook
  }

  public func commit(
    target: WorkflowBundleIdentity,
    historyRoot: URL,
    kind: WorkflowDirectoryTransactionKind,
    expectedBeforeBundleDigest: String,
    expectedAfterBundleDigest: String,
    preOperationSnapshotId: String,
    operationAuditIntent: ((String) -> WorkflowDirectoryOperationAuditIntent)? = nil,
    persistOperationAudit: (WorkflowDirectoryTransactionResult) throws -> Void = { _ in },
    physicalOwnershipRoot: URL? = nil,
    postCommitPublication: (URL) throws -> Void = { _ in },
    mutateStaging: (URL) throws -> Void
  ) throws -> WorkflowDirectoryTransactionResult {
    let transactionId = "transaction-\(UUID().uuidString.lowercased())"
    var attempt = makeWorkflowTransactionPreflightAttempt(
      transactionId: transactionId, kind: kind, target: target,
      beforeDigest: expectedBeforeBundleDigest, afterDigest: expectedAfterBundleDigest,
      snapshotId: preOperationSnapshotId
    )
    try preflightAttemptStore.persist(attempt, historyRoot: historyRoot)
    let auditIntent = operationAuditIntent?(transactionId) ?? defaultAuditIntent(
      kind: kind,
      transactionId: transactionId,
      target: target,
      beforeBundleDigest: expectedBeforeBundleDigest,
      expectedAfterBundleDigest: expectedAfterBundleDigest,
      preOperationSnapshotId: preOperationSnapshotId
    )
    let detachedRoot = try physicalOwnershipRoot.map {
      try WorkflowDetachedOwnershipPinnedRoot(candidate: $0, requireRoot: true)
    }
    let detachedIdentity = detachedRoot?.identity
    let fileSystem = WorkflowDirectoryCommitFileSystem(detachedRoot: detachedRoot)
    let live = detachedIdentity?.root
      ?? URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
    let parent = live.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".\(live.lastPathComponent).riela-stage-\(transactionId)", isDirectory: true)
    let rollback = parent.appendingPathComponent(".\(live.lastPathComponent).riela-rollback-\(transactionId)", isDirectory: true)
    let transactions = historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let active = transactions.appendingPathComponent("active.json")
    let recordURL = transactions.appendingPathComponent("\(transactionId).json")
    let stableMarker = WorkflowTransactionStableMetadata.url(forOwnershipRoot: live)
    let stableMetadata = WorkflowTransactionStableMetadata(
      transactionId: transactionId,
      target: target,
      historyRoot: historyRoot.standardizedFileURL.path,
      physicalOwnershipRoot: detachedIdentity?.root.path,
      physicalOwnershipContainerDevice: detachedIdentity?.containerDevice,
      physicalOwnershipContainerInode: detachedIdentity?.containerInode
    )
    let preflightInput = DirectoryTransactionPreflightInput(
      target: target,
      historyRoot: historyRoot,
      kind: kind,
      expectedBeforeBundleDigest: expectedBeforeBundleDigest,
      expectedAfterBundleDigest: expectedAfterBundleDigest,
      preOperationSnapshotId: preOperationSnapshotId,
      auditIntent: auditIntent,
      live: live,
      parent: parent,
      staging: staging,
      rollback: rollback,
      transactions: transactions,
      active: active,
      usesDetachedPhysicalRoot: physicalOwnershipRoot != nil,
      detachedRoot: detachedRoot
    )
    let preflight: DirectoryTransactionPreflightResult
    do {
      preflight = try performPreflight(preflightInput, attempt: &attempt)
    } catch {
      try failPreflightAttempt(attempt, error: error, historyRoot: historyRoot)
    }
    defer {
      releaseWorkflowTargetLock(preflight.lockDescriptor)
    }
    var record = preflight.record
    let current = preflight.inventory
    do {
      try write(record, to: recordURL, active: nil)
      try boundaryHook(.transactionRecord)
      try WorkflowHistorySecurePersistence.writeCanonical(
        WorkflowTransactionActiveMarker(transactionId: record.transactionId),
        to: active,
        historyRoot: historyRoot,
        overwrite: false
      )
      try boundaryHook(.activeMarker)
      try fileSystem.writeStableMetadata(stableMetadata, marker: stableMarker, parent: parent)
      try boundaryHook(.stableMarker)
      record.verification = try fileSystem.prepareStaging(
        target: target,
        live: live,
        staging: staging,
        expectedAfterDigest: expectedAfterBundleDigest,
        expectedUnowned: current.unownedFiles.map(\.metadata),
        mutate: mutateStaging
      )
      record.phase = .prepared
      try write(record, to: recordURL, active: active)
      try boundaryHook(.preparedRecord)
      let immediatelyBeforeCommit = try fileSystem.inventory(for: target, at: live)
      guard immediatelyBeforeCommit.bundleDigest == expectedBeforeBundleDigest,
            immediatelyBeforeCommit.unownedFiles.map(\.metadata) == current.unownedFiles.map(\.metadata) else {
        throw CLIUsageError("workflow owned or unowned files drifted immediately before commit")
      }
      record.phase = .committing
      try write(record, to: recordURL, active: active)
      try boundaryHook(.committingRecord)
      try fileSystem.requireConfiguredPathIdentity()
      guard try fileSystem.directoryExists(live),
            try fileSystem.directoryExists(staging),
            try !fileSystem.entryExists(rollback) else {
        throw CLIUsageError("workflow transaction paths changed type before the first rename")
      }
      try fileSystem.renameDirectory(from: live, to: rollback, parent: parent)
      try fileSystem.syncParent(parent)
      try boundaryHook(.liveToRollbackRename)
      record.phase = .liveMoved
      try write(record, to: recordURL, active: active)
      try boundaryHook(.liveMovedRecord)
      try fileSystem.requireConfiguredPathIdentity()
      guard try !fileSystem.entryExists(live),
            try fileSystem.directoryExists(rollback),
            try fileSystem.directoryExists(staging) else {
        throw CLIUsageError("workflow transaction paths changed type before publication")
      }
      try fileSystem.renameDirectory(from: staging, to: live, parent: parent)
      try fileSystem.syncParent(parent)
      try boundaryHook(.stagingToLiveRename)
      record.phase = .published
      try write(record, to: recordURL, active: active)
      try boundaryHook(.publishedRecord)
      let published = try fileSystem.inventory(for: target, at: live)
      guard published.bundleDigest == expectedAfterBundleDigest,
            published.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.expectedAfterUnownedInventory else {
        throw CLIUsageError("published workflow failed post-commit digest verification")
      }
      try postCommitPublication(try fileSystem.accessURL(live))
      try fileSystem.verifyTree(
        rollback,
        target: target,
        digest: expectedBeforeBundleDigest,
        unowned: record.beforeUnownedInventory
      )
      let result = WorkflowDirectoryTransactionResult(
        transactionId: transactionId,
        resultBundleDigest: published.bundleDigest,
        verification: record.verification
      )
      try persistOperationAudit(result)
      try persistSpecificOperationAudit(record, resultBundleDigest: published.bundleDigest, outcome: kind == .apply ? .applied : .restored, historyRoot: historyRoot)
      try boundaryHook(.operationAudit)
      let audit = WorkflowDirectoryTransactionAudit(
        transaction: record,
        resultBundleDigest: published.bundleDigest,
        outcome: kind == .apply ? .applied : .restored
      )
      try auditStore.persist(audit, historyRoot: historyRoot)
      try boundaryHook(.transactionAudit)
      record.phase = .committed
      try write(record, to: recordURL, active: nil)
      try boundaryHook(.committedRecord)
      try fileSystem.requireConfiguredPathIdentity()
      try fileSystem.removeDirectory(rollback)
      try fileSystem.syncParent(parent)
      try boundaryHook(.rollbackUnlink)
      try cleanupMarkers(
        stableMarker: stableMarker, targetParent: parent, active: active,
        historyRoot: historyRoot, detachedRoot: detachedRoot
      )
      return result
    } catch {
      if error is WorkflowDirectoryInjectedInterruption { throw error }
      record.diagnostics = Array(Set(record.diagnostics + [String(describing: error)])).sorted()
      if record.phase == .preparing || record.phase == .prepared {
        let recoverablePhase = record.phase
        do {
          try persistSpecificOperationAudit(
            record,
            resultBundleDigest: record.beforeBundleDigest,
            outcome: .failed,
            historyRoot: historyRoot
          )
          try auditStore.persist(WorkflowDirectoryTransactionAudit(
            transaction: record,
            resultBundleDigest: record.beforeBundleDigest,
            outcome: .failed,
            diagnostics: record.diagnostics
          ), historyRoot: historyRoot)
          record.phase = .failed
          try write(record, to: recordURL, active: nil)
          if try fileSystem.entryExists(staging) {
            try fileSystem.removeDirectory(staging)
            try fileSystem.syncParent(parent)
          }
          try cleanupMarkers(
            stableMarker: stableMarker, targetParent: parent, active: active,
            historyRoot: historyRoot, detachedRoot: detachedRoot
          )
        } catch let auditError {
          record.phase = recoverablePhase
          try? write(record, to: recordURL, active: active)
          throw CLIUsageError(
            "workflow transaction failed during \(record.phase.rawValue); "
              + "failure audit persistence also failed and recovery state was retained: \(auditError)"
          )
        }
      } else {
        // Once the write phase starts, preserve every tree and the active
        // marker. Phase-aware recovery is the only authority allowed to
        // rename or delete commit evidence.
        try? write(record, to: recordURL, active: active)
      }
      throw CLIUsageError("workflow transaction failed during \(record.phase.rawValue): \(error)")
    }
  }

  public func recover(
    historyRoot: URL,
    target: WorkflowBundleIdentity,
    authoritativeBundleDigest: String? = nil,
    lockAlreadyHeld: Bool = false
  ) throws -> WorkflowDirectoryTransactionRecord? {
    let transactions = historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let active = transactions.appendingPathComponent("active.json")
    let lockDescriptor = lockAlreadyHeld ? nil : try acquireWorkflowTargetLock(target: target, owner: "recovery")
    defer {
      if let lockDescriptor { releaseWorkflowTargetLock(lockDescriptor) }
    }
    guard let context = try prepareLockedRecovery(
      transactions: transactions, active: active, historyRoot: historyRoot, target: target
    ) else { return nil }
    var record = context.record
    let recordURL = context.recordURL
    let live = context.live
    let staging = context.staging
    let rollback = context.rollback
    let parent = context.parent
    let stableMarker = context.stableMarker
    let detachedRoot = context.detachedRoot
    let recoveryFileSystem = WorkflowDirectoryRecoveryFileSystem(
      target: record.target, parent: parent, detachedRoot: detachedRoot
    )
    if let recovered = try recoverUnpublishedDetachedTransaction(
      record: &record,
      authoritativeBundleDigest: authoritativeBundleDigest,
      detachedRoot: detachedRoot,
      recordURL: recordURL,
      active: active,
      stableMarker: stableMarker,
      historyRoot: historyRoot
    ) {
      return recovered
    }
    var terminalOutcome = WorkflowHistoryOutcome.recovered
    switch record.phase {
    case .preparing, .prepared:
      guard try recoveryFileSystem.directoryExists(live),
            try !recoveryFileSystem.directoryExists(rollback) else {
        throw CLIUsageError("ambiguous pre-commit workflow transaction state; no recovery action taken")
      }
      let inventory = try WorkflowHistoryIdentityResolver.inventory(for: record.target)
      guard inventory.bundleDigest == record.beforeBundleDigest,
            inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.beforeUnownedInventory else {
        throw CLIUsageError("pre-commit workflow tree does not match transaction before digest")
      }
      if try recoveryFileSystem.directoryExists(staging) { try recoveryFileSystem.remove(staging) }
      try recoveryFileSystem.syncParent()
      terminalOutcome = .failed
    case .committing:
      switch (try recoveryFileSystem.directoryExists(live),
              try recoveryFileSystem.directoryExists(rollback),
              try recoveryFileSystem.directoryExists(staging)) {
      case (true, false, true):
        try recoveryFileSystem.verify(live, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try recoveryFileSystem.verify(
          staging,
          digest: record.expectedAfterBundleDigest,
          unowned: record.expectedAfterUnownedInventory
        )
        try recoveryFileSystem.remove(staging)
      case (false, true, true):
        try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try recoveryFileSystem.verify(
          staging,
          digest: record.expectedAfterBundleDigest,
          unowned: record.expectedAfterUnownedInventory
        )
        try recoveryFileSystem.move(rollback, to: live)
        try recoveryFileSystem.syncParent()
        try recoveryFileSystem.remove(staging)
      default:
        throw CLIUsageError("ambiguous committing workflow transaction state; no recovery action taken")
      }
      try recoveryFileSystem.syncParent()
    case .liveMoved:
      switch (try recoveryFileSystem.directoryExists(live),
              try recoveryFileSystem.directoryExists(rollback),
              try recoveryFileSystem.directoryExists(staging)) {
      case (false, true, false):
        try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try recoveryFileSystem.move(rollback, to: live)
      case (false, true, true):
        try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try recoveryFileSystem.verify(
          staging,
          digest: record.expectedAfterBundleDigest,
          unowned: record.expectedAfterUnownedInventory
        )
        try recoveryFileSystem.move(rollback, to: live)
        try recoveryFileSystem.syncParent()
        try recoveryFileSystem.remove(staging)
      case (true, true, false):
        try recoveryFileSystem.verify(
          live,
          digest: record.expectedAfterBundleDigest,
          unowned: record.expectedAfterUnownedInventory
        )
        try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        record.phase = .published
        try write(record, to: recordURL, active: active)
        try persistSpecificOperationAudit(
          record,
          resultBundleDigest: record.expectedAfterBundleDigest,
          outcome: record.kind == .apply ? .applied : .restored,
          historyRoot: historyRoot
        )
        try auditStore.persist(WorkflowDirectoryTransactionAudit(
          transaction: record,
          resultBundleDigest: record.expectedAfterBundleDigest,
          outcome: record.kind == .apply ? .applied : .restored
        ), historyRoot: historyRoot)
        record.phase = .committed
        try write(record, to: recordURL, active: nil)
        try recoveryFileSystem.remove(rollback)
        try recoveryFileSystem.syncParent()
        try cleanupRecoveryMarkers(context: context, active: active, historyRoot: historyRoot)
        try recoveryFileSystem.syncParent()
        return record
      default:
        throw CLIUsageError("ambiguous live-moved workflow transaction state; no recovery action taken")
      }
      try recoveryFileSystem.syncParent()
    case .published:
      guard try recoveryFileSystem.directoryExists(live),
            try recoveryFileSystem.directoryExists(rollback),
            try !recoveryFileSystem.directoryExists(staging) else {
        throw CLIUsageError("ambiguous published workflow transaction state; no recovery action taken")
      }
      try recoveryFileSystem.verify(
        live,
        digest: record.expectedAfterBundleDigest,
        unowned: record.expectedAfterUnownedInventory
      )
      try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
      try persistSpecificOperationAudit(
        record,
        resultBundleDigest: record.expectedAfterBundleDigest,
        outcome: record.kind == .apply ? .applied : .restored,
        historyRoot: historyRoot
      )
      try auditStore.persist(WorkflowDirectoryTransactionAudit(
        transaction: record,
        resultBundleDigest: record.expectedAfterBundleDigest,
        outcome: record.kind == .apply ? .applied : .restored
      ), historyRoot: historyRoot)
      record.phase = .committed
      try write(record, to: recordURL, active: nil)
      try recoveryFileSystem.remove(rollback)
      try recoveryFileSystem.syncParent()
      try cleanupRecoveryMarkers(context: context, active: active, historyRoot: historyRoot)
      try recoveryFileSystem.syncParent()
      return record
    case .committed:
      guard try recoveryFileSystem.directoryExists(live),
            try !recoveryFileSystem.directoryExists(staging) else {
        throw CLIUsageError("terminal committed workflow transaction has ambiguous tree state")
      }
      try recoveryFileSystem.verify(
        live,
        digest: record.expectedAfterBundleDigest,
        unowned: record.expectedAfterUnownedInventory
      )
      try completeCommittedAudits(record, historyRoot: historyRoot)
      if try recoveryFileSystem.directoryExists(rollback) {
        try recoveryFileSystem.verify(rollback, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try recoveryFileSystem.remove(rollback)
        try recoveryFileSystem.syncParent()
      }
      try cleanupRecoveryMarkers(context: context, active: active, historyRoot: historyRoot)
      return record
    case .failed, .recovered:
      guard try recoveryFileSystem.directoryExists(live),
            try !recoveryFileSystem.directoryExists(rollback),
            try !recoveryFileSystem.directoryExists(staging) else {
        throw CLIUsageError("terminal rolled-back workflow transaction has ambiguous tree state")
      }
      try recoveryFileSystem.verify(live, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
      try cleanupRecoveryMarkers(context: context, active: active, historyRoot: historyRoot)
      return record
    }
    try persistSpecificOperationAudit(
      record,
      resultBundleDigest: record.beforeBundleDigest,
      outcome: terminalOutcome,
      historyRoot: historyRoot
    )
    try auditStore.persist(WorkflowDirectoryTransactionAudit(
      transaction: record,
      resultBundleDigest: record.beforeBundleDigest,
      outcome: terminalOutcome,
      diagnostics: terminalOutcome == .failed
        ? ["pre-commit transaction failure audit completed during recovery"]
        : ["transaction rolled back during recovery"]
    ), historyRoot: historyRoot)
    record.phase = terminalOutcome == .failed ? .failed : .recovered
    try write(record, to: recordURL, active: nil)
    try cleanupRecoveryMarkers(context: context, active: active, historyRoot: historyRoot)
    return record
  }

  private func cleanupRecoveryMarkers(
    context: WorkflowDirectoryRecoveryContext,
    active: URL,
    historyRoot: URL
  ) throws {
    try cleanupMarkers(
      stableMarker: context.stableMarker,
      targetParent: context.parent,
      active: active,
      historyRoot: historyRoot,
      detachedRoot: context.detachedRoot
    )
  }
  private func recoverUnpublishedDetachedTransaction(
    record: inout WorkflowDirectoryTransactionRecord,
    authoritativeBundleDigest: String?,
    detachedRoot: WorkflowDetachedOwnershipPinnedRoot?,
    recordURL: URL,
    active: URL,
    stableMarker: URL,
    historyRoot: URL
  ) throws -> WorkflowDirectoryTransactionRecord? {
    guard record.physicalOwnershipRoot != nil, let detachedRoot,
          [.liveMoved, .published].contains(record.phase) else { return nil }
    guard let authoritativeBundleDigest else {
      throw CLIUsageError("detached workflow recovery requires an authoritative registry digest")
    }
    if authoritativeBundleDigest != record.beforeBundleDigest {
      guard authoritativeBundleDigest == record.expectedAfterBundleDigest else {
        throw CLIUsageError(
          "authoritative workflow digest does not match detached recovery state "
            + "(authoritative=\(authoritativeBundleDigest), before=\(record.beforeBundleDigest), "
            + "after=\(record.expectedAfterBundleDigest))"
        )
      }
      return nil
    }
    let liveName = "root"
    let stagingName = URL(fileURLWithPath: record.stagingPath).lastPathComponent
    let rollbackName = URL(fileURLWithPath: record.rollbackPath).lastPathComponent
    let state = (try detachedRoot.directoryExists(liveName),
                 try detachedRoot.directoryExists(rollbackName),
                 try detachedRoot.directoryExists(stagingName))
    if record.phase == .liveMoved, state == (false, true, true) { return nil }
    guard state == (true, true, false) else {
      throw CLIUsageError("ambiguous detached workflow publication state; no recovery action taken")
    }
    let liveInventory = try detachedRoot.inventory(for: record.target, directory: liveName)
    let rollbackInventory = try detachedRoot.inventory(for: record.target, directory: rollbackName)
    guard liveInventory.bundleDigest == record.expectedAfterBundleDigest,
          liveInventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.expectedAfterUnownedInventory,
          rollbackInventory.bundleDigest == record.beforeBundleDigest,
          rollbackInventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.beforeUnownedInventory else {
      throw CLIUsageError("detached workflow recovery tree digest verification failed")
    }
    try detachedRoot.removeDirectory(liveName)
    try detachedRoot.renameDirectory(from: rollbackName, to: liveName)
    try detachedRoot.sync()
    try persistSpecificOperationAudit(
      record,
      resultBundleDigest: record.beforeBundleDigest,
      outcome: .failed,
      historyRoot: historyRoot
    )
    try auditStore.persist(WorkflowDirectoryTransactionAudit(
      transaction: record,
      resultBundleDigest: record.beforeBundleDigest,
      outcome: .failed,
      diagnostics: ["registry publication did not reach its authoritative commit point"]
    ), historyRoot: historyRoot)
    record.phase = .recovered
    try write(record, to: recordURL, active: nil)
    try cleanupMarkers(
      stableMarker: stableMarker,
      targetParent: stableMarker.deletingLastPathComponent(),
      active: active,
      historyRoot: historyRoot,
      detachedRoot: detachedRoot
    )
    return record
  }

  private func write(_ record: WorkflowDirectoryTransactionRecord, to recordURL: URL, active: URL?) throws {
    let historyRoot = recordURL.deletingLastPathComponent().deletingLastPathComponent()
    try WorkflowTransactionGenerationStore.write(
      record,
      logicalURL: recordURL,
      historyRoot: historyRoot
    ) {
      try boundaryHook(payloadBoundary(for: record.phase))
    }
    if let active, try !historyEntryExistsWithoutFollowingLinks(active) {
      try WorkflowHistorySecurePersistence.writeCanonical(
        WorkflowTransactionActiveMarker(transactionId: record.transactionId),
        to: active,
        historyRoot: historyRoot,
        overwrite: false
      )
    }
  }

  private func payloadBoundary(
    for phase: WorkflowDirectoryTransactionPhase
  ) -> WorkflowDirectoryTransactionBoundary {
    switch phase {
    case .preparing: .preparingPayloadBeforeSidecar
    case .prepared: .preparedPayloadBeforeSidecar
    case .committing: .committingPayloadBeforeSidecar
    case .liveMoved: .liveMovedPayloadBeforeSidecar
    case .published: .publishedPayloadBeforeSidecar
    case .committed: .committedPayloadBeforeSidecar
    case .failed: .committedPayloadBeforeSidecar
    case .recovered: .committedPayloadBeforeSidecar
    }
  }

  private func performPreflight(
    _ input: DirectoryTransactionPreflightInput,
    attempt: inout WorkflowPreflightAttemptRecord
  ) throws -> DirectoryTransactionPreflightResult {
    guard input.target.sourceMutable,
          input.target.sourceKind != .installedPackage,
          input.target.packageDirectory == nil else {
      throw CLIUsageError("installed package workflow sources are immutable")
    }
    try WorkflowHistoryCanonicalCoding.validateDigest(input.expectedBeforeBundleDigest)
    try WorkflowHistoryCanonicalCoding.validateDigest(input.expectedAfterBundleDigest)
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(input.preOperationSnapshotId)
    let descriptor = try acquireWorkflowTargetLock(target: input.target, owner: attempt.transactionId)
    do {
      try WorkflowHistorySecurePersistence.ensureDirectory(input.transactions, historyRoot: input.historyRoot)
      guard try discoverWorkflowTransaction(
        transactions: input.transactions,
        active: input.active,
        historyRoot: input.historyRoot
      ) == nil else {
        throw CLIUsageError("workflow target has a nonterminal directory transaction")
      }
      try lockedPreflightHook()
      try input.detachedRoot?.requireConfiguredPathIdentity()
      try validateLockedTarget(
        input.target,
        live: input.live,
        parent: input.parent,
        usesDetachedPhysicalRoot: input.usesDetachedPhysicalRoot,
        detachedRoot: input.detachedRoot
      )
      let snapshot = try WorkflowHistoryStore(root: input.historyRoot).loadSnapshot(
        input.preOperationSnapshotId,
        expectedIdentity: input.target
      )
      guard snapshot.bundleDigest == input.expectedBeforeBundleDigest else {
        throw CLIUsageError("pre-operation snapshot does not match the transaction before digest")
      }
      let current = try WorkflowDirectoryCommitFileSystem(detachedRoot: input.detachedRoot)
        .inventory(for: input.target, at: input.live)
      guard current.bundleDigest == input.expectedBeforeBundleDigest else {
        throw CLIUsageError("workflow bundle changed since review; refusing dirty mutation")
      }
      let record = WorkflowDirectoryTransactionRecord(
        transactionId: attempt.transactionId,
        kind: input.kind,
        target: input.target,
        beforeBundleDigest: input.expectedBeforeBundleDigest,
        expectedAfterBundleDigest: input.expectedAfterBundleDigest,
        preOperationSnapshotId: input.preOperationSnapshotId,
        beforeUnownedInventory: current.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
        expectedAfterUnownedInventory: current.unownedFiles.map(WorkflowUnownedInventoryEntry.init),
        operationAuditIntent: input.auditIntent,
        stagingPath: input.staging.path,
        rollbackPath: input.rollback.path,
        physicalOwnershipRoot: input.usesDetachedPhysicalRoot ? input.live.path : nil,
        phase: .preparing
      )
      attempt.status = .transactionStarted
      try preflightAttemptStore.persist(attempt, historyRoot: input.historyRoot)
      return DirectoryTransactionPreflightResult(
        record: record,
        inventory: current,
        lockDescriptor: descriptor
      )
    } catch {
      releaseWorkflowTargetLock(descriptor)
      throw error
    }
  }

  private func failPreflightAttempt(
    _ source: WorkflowPreflightAttemptRecord,
    error: Error,
    historyRoot: URL
  ) throws -> Never {
    var attempt = source
    attempt.status = .failed
    attempt.diagnostics = [String(describing: error)]
    attempt.completedAt = millisecondDate()
    do {
      try preflightAttemptStore.persist(attempt, historyRoot: historyRoot)
    } catch let auditError {
      throw CLIUsageError(
        "workflow mutation preflight failed without mutation; "
          + "failure audit persistence also failed: \(auditError)"
      )
    }
    throw CLIUsageError("workflow mutation preflight failed without mutation: \(error)")
  }

  private func validateLockedTarget(
    _ target: WorkflowBundleIdentity,
    live: URL,
    parent: URL,
    usesDetachedPhysicalRoot: Bool,
    detachedRoot: WorkflowDetachedOwnershipPinnedRoot?
  ) throws {
    let ownershipMatches = usesDetachedPhysicalRoot
      || live.resolvingSymlinksInPath().standardizedFileURL.path == target.ownershipRoot
    guard target.sourceMutable,
          target.sourceKind != .installedPackage,
          target.packageDirectory == nil,
          ownershipMatches else {
      throw CLIUsageError("workflow target identity, mutability, or same-filesystem staging authority changed under lock")
    }
    let fileSystem = WorkflowDirectoryCommitFileSystem(detachedRoot: detachedRoot)
    if detachedRoot == nil {
      guard try directoryExistsWithoutFollowingLinks(live),
            try directoryExistsWithoutFollowingLinks(parent),
            try deviceIdentifier(live) == deviceIdentifier(parent) else {
        throw CLIUsageError("workflow target identity, mutability, or same-filesystem staging authority changed under lock")
      }
    } else {
      guard try fileSystem.directoryExists(live) else {
        throw CLIUsageError("detached workflow target changed under the transaction lock")
      }
    }
    let workflowBytes = try fileSystem.readWorkflowBytes(target: target, live: live)
    let object = try JSONSerialization.jsonObject(with: workflowBytes)
    guard let declaration = object as? [String: Any],
          declaration["workflowId"] as? String == target.workflowId,
          declaration["workflowContractVersion"] as? String == target.workflowContractVersion else {
      throw CLIUsageError("workflow declaration identity changed under the transaction lock")
    }
  }

  private func cleanupMarkers(
    stableMarker: URL,
    targetParent: URL,
    active: URL,
    historyRoot: URL,
    detachedRoot: WorkflowDetachedOwnershipPinnedRoot? = nil
  ) throws {
    // Pin the stable-marker parent before the unlink boundary: an ancestor
    // swapped in after this point must not receive the unlink.
    let stable = detachedRoot == nil
      ? try WorkflowPinnedRecordCleanup(record: stableMarker, historyRoot: targetParent)
      : nil
    let history = try WorkflowPinnedRecordCleanup(record: active, historyRoot: historyRoot)
    try boundaryHook(.stableMarkerUnlink)
    if let detachedRoot {
      try detachedRoot.removePersistedRecord(name: stableMarker.lastPathComponent)
    } else if let stable {
      try stable.remove(beforeRecord: {}, beforeSidecar: {})
    }
    try boundaryHook(.activeMarkerUnlink)
    try history.remove(beforeRecord: {}, beforeSidecar: {})
  }

  private func completeCommittedAudits(
    _ record: WorkflowDirectoryTransactionRecord,
    historyRoot: URL
  ) throws {
    let outcome: WorkflowHistoryOutcome = record.kind == .apply ? .applied : .restored
    let operationURL = WorkflowOperationAuditStore.url(for: record, historyRoot: historyRoot)
    let transactionURL = historyRoot.appendingPathComponent("audits/transaction-\(record.transactionId).json")
    guard try historyEntryExistsWithoutFollowingLinks(operationURL),
          try historyEntryExistsWithoutFollowingLinks(transactionURL) else {
      throw CLIUsageError("committed workflow transaction is missing required durable audits")
    }
    try persistSpecificOperationAudit(
      record,
      resultBundleDigest: record.expectedAfterBundleDigest,
      outcome: outcome,
      historyRoot: historyRoot
    )
    var published = record
    published.phase = .published
    try auditStore.persist(WorkflowDirectoryTransactionAudit(
      transaction: published,
      resultBundleDigest: record.expectedAfterBundleDigest,
      outcome: outcome
    ), historyRoot: historyRoot)
  }

  private func defaultAuditIntent(
    kind: WorkflowDirectoryTransactionKind,
    transactionId: String,
    target: WorkflowBundleIdentity,
    beforeBundleDigest: String,
    expectedAfterBundleDigest: String,
    preOperationSnapshotId: String
  ) -> WorkflowDirectoryOperationAuditIntent {
    switch kind {
    case .apply:
      return .mutation(LoopWorkflowMutationEvidence(
        mode: "directory-transaction",
        snapshotId: preOperationSnapshotId,
        transactionId: transactionId,
        target: target,
        beforeBundleDigest: beforeBundleDigest,
        afterBundleDigest: expectedAfterBundleDigest,
        applied: false,
        restored: false,
        outcome: .failed
      ))
    case .restore:
      return .restore(WorkflowRestoreRecord(
        restoreId: "restore-\(transactionId)",
        target: target,
        sourceSnapshotId: preOperationSnapshotId,
        preRestoreSnapshotId: preOperationSnapshotId,
        requestedBundleDigest: expectedAfterBundleDigest,
        beforeBundleDigest: beforeBundleDigest,
        approved: true,
        dirtyConflictPolicy: "reject",
        transactionId: transactionId,
        startedAt: Date(),
        outcome: .failed
      ))
    }
  }

  private func persistSpecificOperationAudit(
    _ record: WorkflowDirectoryTransactionRecord,
    resultBundleDigest: String,
    outcome: WorkflowHistoryOutcome,
    historyRoot: URL
  ) throws {
    try WorkflowOperationAuditStore.persist(
      record,
      resultBundleDigest: resultBundleDigest,
      outcome: outcome,
      historyRoot: historyRoot
    )
  }

  private func millisecondDate() -> Date {
    let milliseconds = (Date().timeIntervalSince1970 * 1_000).rounded(.down)
    return Date(timeIntervalSince1970: milliseconds / 1_000)
  }
}
