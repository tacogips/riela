import Darwin
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

public struct WorkflowTransactionStableMetadata: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var target: WorkflowBundleIdentity
  public var historyRoot: String

  public init(
    schemaVersion: Int = 1,
    transactionId: String,
    target: WorkflowBundleIdentity,
    historyRoot: String
  ) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
    self.target = target
    self.historyRoot = historyRoot
  }

  public static func url(forOwnershipRoot root: URL) -> URL {
    root.deletingLastPathComponent().appendingPathComponent(
      ".\(root.lastPathComponent).riela-active-transaction.json"
    )
  }
}

public enum WorkflowInventoryEntryType: String, Codable, Equatable, Sendable {
  case regularFile = "regular-file"
}

public struct WorkflowUnownedInventoryEntry: Codable, Equatable, Sendable {
  public var relativePath: String
  public var entryType: WorkflowInventoryEntryType
  public var contentDigest: String
  public var byteCount: Int
  public var executable: Bool

  init(_ file: WorkflowOwnedFile) {
    relativePath = file.metadata.relativePath
    entryType = .regularFile
    contentDigest = file.metadata.contentDigest
    byteCount = file.metadata.byteCount
    executable = file.metadata.executable
  }
}

public enum WorkflowDirectoryOperationAuditIntent: Codable, Equatable, Sendable {
  case mutation(LoopWorkflowMutationEvidence)
  case restore(WorkflowRestoreRecord)

  private enum CodingKeys: String, CodingKey { case kind, mutation, restore }
  private enum Kind: String, Codable { case mutation, restore }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .mutation:
      self = .mutation(try container.decode(LoopWorkflowMutationEvidence.self, forKey: .mutation))
    case .restore:
      self = .restore(try container.decode(WorkflowRestoreRecord.self, forKey: .restore))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .mutation(value):
      try container.encode(Kind.mutation, forKey: .kind)
      try container.encode(value, forKey: .mutation)
    case let .restore(value):
      try container.encode(Kind.restore, forKey: .kind)
      try container.encode(value, forKey: .restore)
    }
  }
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

  public init() {
    auditStore = FileWorkflowTransactionAuditStore()
    preflightAttemptStore = FileWorkflowPreflightAttemptStore()
    lockedPreflightHook = {}
    boundaryHook = { _ in }
  }

  init(
    auditStore: any WorkflowTransactionAuditPersisting,
    preflightAttemptStore: any WorkflowPreflightAttemptPersisting = FileWorkflowPreflightAttemptStore(),
    lockedPreflightHook: @escaping @Sendable () throws -> Void = {},
    boundaryHook: @escaping @Sendable (WorkflowDirectoryTransactionBoundary) throws -> Void = { _ in }
  ) {
    self.auditStore = auditStore
    self.preflightAttemptStore = preflightAttemptStore
    self.lockedPreflightHook = lockedPreflightHook
    self.boundaryHook = boundaryHook
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
    mutateStaging: (URL) throws -> Void
  ) throws -> WorkflowDirectoryTransactionResult {
    let transactionId = "transaction-\(UUID().uuidString.lowercased())"
    var attempt = WorkflowPreflightAttemptRecord(
      attemptId: "attempt-\(transactionId)",
      transactionId: transactionId,
      kind: kind,
      target: target,
      expectedBeforeBundleDigest: expectedBeforeBundleDigest,
      expectedAfterBundleDigest: expectedAfterBundleDigest,
      preOperationSnapshotId: preOperationSnapshotId,
      status: .attempted,
      mutationOccurred: false,
      diagnostics: [],
      startedAt: millisecondDate()
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
    let live = URL(fileURLWithPath: target.ownershipRoot, isDirectory: true)
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
      historyRoot: historyRoot.standardizedFileURL.path
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
      active: active
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
      try WorkflowHistorySecurePersistence.writeCanonical(stableMetadata, to: stableMarker, historyRoot: parent)
      try boundaryHook(.stableMarker)
      try FileManager.default.copyItem(at: live, to: staging)
      try mutateStaging(staging)
      record.verification = try WorkflowStagedVerifier().verify(target: target, stagingRoot: staging)
        .sorted { $0.id < $1.id }
      let staged = try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: staging)
      guard staged.bundleDigest == expectedAfterBundleDigest else {
        throw CLIUsageError("staged workflow digest does not match reviewed result")
      }
      guard staged.unownedFiles.map(\.metadata) == current.unownedFiles.map(\.metadata) else {
        throw CLIUsageError("staged workflow changed unowned files")
      }
      record.phase = .prepared
      try syncTree(staging)
      try write(record, to: recordURL, active: active)
      try boundaryHook(.preparedRecord)
      let immediatelyBeforeCommit = try WorkflowHistoryIdentityResolver.inventory(for: target)
      guard immediatelyBeforeCommit.bundleDigest == expectedBeforeBundleDigest,
            immediatelyBeforeCommit.unownedFiles.map(\.metadata) == current.unownedFiles.map(\.metadata) else {
        throw CLIUsageError("workflow owned or unowned files drifted immediately before commit")
      }
      record.phase = .committing
      try write(record, to: recordURL, active: active)
      try boundaryHook(.committingRecord)
      guard try directoryExistsWithoutFollowingLinks(live),
            try directoryExistsWithoutFollowingLinks(staging),
            try !historyEntryExistsWithoutFollowingLinks(rollback) else {
        throw CLIUsageError("workflow transaction paths changed type before the first rename")
      }
      try moveSiblingDirectory(from: live, to: rollback, parent: parent)
      try syncDirectory(parent)
      try boundaryHook(.liveToRollbackRename)
      record.phase = .liveMoved
      try write(record, to: recordURL, active: active)
      try boundaryHook(.liveMovedRecord)
      guard try !historyEntryExistsWithoutFollowingLinks(live),
            try directoryExistsWithoutFollowingLinks(rollback),
            try directoryExistsWithoutFollowingLinks(staging) else {
        throw CLIUsageError("workflow transaction paths changed type before publication")
      }
      try moveSiblingDirectory(from: staging, to: live, parent: parent)
      try syncDirectory(parent)
      try boundaryHook(.stagingToLiveRename)
      record.phase = .published
      try write(record, to: recordURL, active: active)
      try boundaryHook(.publishedRecord)
      let published = try WorkflowHistoryIdentityResolver.inventory(for: target)
      guard published.bundleDigest == expectedAfterBundleDigest,
            published.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.expectedAfterUnownedInventory else {
        throw CLIUsageError("published workflow failed post-commit digest verification")
      }
      try verifyTree(
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
      try FileManager.default.removeItem(at: rollback)
      try syncDirectory(parent)
      try boundaryHook(.rollbackUnlink)
      try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
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
          if try historyEntryExistsWithoutFollowingLinks(staging) {
            try FileManager.default.removeItem(at: staging)
            try syncDirectory(parent)
          }
          try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
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
    lockAlreadyHeld: Bool = false
  ) throws -> WorkflowDirectoryTransactionRecord? {
    let transactions = historyRoot.appendingPathComponent("transactions", isDirectory: true)
    let active = transactions.appendingPathComponent("active.json")
    let lockDescriptor = lockAlreadyHeld ? nil : try acquireWorkflowTargetLock(target: target, owner: "recovery")
    defer {
      if let lockDescriptor { releaseWorkflowTargetLock(lockDescriptor) }
    }
    guard try directoryExistsWithoutFollowingLinks(transactions) else { return nil }
    guard let discovered = try discoverWorkflowTransaction(
      transactions: transactions,
      active: active,
      historyRoot: historyRoot
    ) else { return nil }
    guard discovered.record.target == target else {
      throw CLIUsageError("workflow transaction recovery target does not match the locked canonical target")
    }
    var record = discovered.record
    let recordURL = discovered.recordURL
    let snapshot = try WorkflowHistoryStore(root: historyRoot).loadSnapshot(
      record.preOperationSnapshotId,
      expectedIdentity: record.target
    )
    guard snapshot.bundleDigest == record.beforeBundleDigest else {
      throw CLIUsageError("recovery snapshot does not match the transaction before digest")
    }
    let live = URL(fileURLWithPath: record.target.ownershipRoot, isDirectory: true)
    let staging = URL(fileURLWithPath: record.stagingPath, isDirectory: true)
    let rollback = URL(fileURLWithPath: record.rollbackPath, isDirectory: true)
    let present: (URL) throws -> Bool = { try directoryExistsWithoutFollowingLinks($0) }
    let parent = live.deletingLastPathComponent()
    let stableMarker = WorkflowTransactionStableMetadata.url(forOwnershipRoot: live)
    try validateWorkflowTransactionStableMetadata(
      record: record,
      marker: stableMarker,
      historyRoot: historyRoot
    )
    var terminalOutcome = WorkflowHistoryOutcome.recovered
    switch record.phase {
    case .preparing, .prepared:
      guard try present(live), try !present(rollback) else {
        throw CLIUsageError("ambiguous pre-commit workflow transaction state; no recovery action taken")
      }
      let inventory = try WorkflowHistoryIdentityResolver.inventory(for: record.target)
      guard inventory.bundleDigest == record.beforeBundleDigest,
            inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == record.beforeUnownedInventory else {
        throw CLIUsageError("pre-commit workflow tree does not match transaction before digest")
      }
      if try present(staging) { try FileManager.default.removeItem(at: staging) }
      try syncDirectory(parent)
      terminalOutcome = .failed
    case .committing:
      switch (try present(live), try present(rollback), try present(staging)) {
      case (true, false, true):
        try verifyTree(live, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try verifyTree(staging, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
        try FileManager.default.removeItem(at: staging)
      case (false, true, true):
        try verifyTree(rollback, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try verifyTree(staging, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
        try moveSiblingDirectory(from: rollback, to: live, parent: parent)
        try syncDirectory(parent)
        try FileManager.default.removeItem(at: staging)
      default:
        throw CLIUsageError("ambiguous committing workflow transaction state; no recovery action taken")
      }
      try syncDirectory(parent)
    case .liveMoved:
      switch (try present(live), try present(rollback), try present(staging)) {
      case (false, true, false):
        try verifyTree(rollback, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try moveSiblingDirectory(from: rollback, to: live, parent: parent)
      case (false, true, true):
        try verifyTree(rollback, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
        try verifyTree(staging, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
        try moveSiblingDirectory(from: rollback, to: live, parent: parent)
        try syncDirectory(parent)
        try FileManager.default.removeItem(at: staging)
      case (true, true, false):
        try verifyTree(live, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
        try verifyTree(rollback, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
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
        try FileManager.default.removeItem(at: rollback)
        try syncDirectory(parent)
        try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
        try syncDirectory(parent)
        return record
      default:
        throw CLIUsageError("ambiguous live-moved workflow transaction state; no recovery action taken")
      }
      try syncDirectory(parent)
    case .published:
      guard try present(live), try present(rollback), try !present(staging) else {
        throw CLIUsageError("ambiguous published workflow transaction state; no recovery action taken")
      }
      try verifyTree(live, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
      try verifyTree(rollback, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
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
      try FileManager.default.removeItem(at: rollback)
      try syncDirectory(parent)
      try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
      try syncDirectory(parent)
      return record
    case .committed:
      guard try present(live), try !present(staging) else {
        throw CLIUsageError("terminal committed workflow transaction has ambiguous tree state")
      }
      try verifyTree(live, target: record.target, digest: record.expectedAfterBundleDigest, unowned: record.expectedAfterUnownedInventory)
      try completeCommittedAudits(record, historyRoot: historyRoot)
      if try present(rollback) {
        try verifyTree(
          rollback,
          target: record.target,
          digest: record.beforeBundleDigest,
          unowned: record.beforeUnownedInventory
        )
        try FileManager.default.removeItem(at: rollback)
        try syncDirectory(parent)
      }
      try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
      return record
    case .failed, .recovered:
      guard try present(live), try !present(rollback), try !present(staging) else {
        throw CLIUsageError("terminal rolled-back workflow transaction has ambiguous tree state")
      }
      try verifyTree(live, target: record.target, digest: record.beforeBundleDigest, unowned: record.beforeUnownedInventory)
      try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
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
    try cleanupMarkers(stableMarker: stableMarker, targetParent: parent, active: active, historyRoot: historyRoot)
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
      try validateLockedTarget(input.target, live: input.live, parent: input.parent)
      let snapshot = try WorkflowHistoryStore(root: input.historyRoot).loadSnapshot(
        input.preOperationSnapshotId,
        expectedIdentity: input.target
      )
      guard snapshot.bundleDigest == input.expectedBeforeBundleDigest else {
        throw CLIUsageError("pre-operation snapshot does not match the transaction before digest")
      }
      let current = try WorkflowHistoryIdentityResolver.inventory(for: input.target)
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
    parent: URL
  ) throws {
    guard target.sourceMutable,
          target.sourceKind != .installedPackage,
          target.packageDirectory == nil,
          live.resolvingSymlinksInPath().standardizedFileURL.path == target.ownershipRoot,
          try directoryExistsWithoutFollowingLinks(live),
          try directoryExistsWithoutFollowingLinks(parent),
          try deviceIdentifier(live) == deviceIdentifier(parent) else {
      throw CLIUsageError("workflow target identity, mutability, or same-filesystem staging authority changed under lock")
    }
    let workflowURL = URL(fileURLWithPath: target.workflowDirectory).appendingPathComponent("workflow.json")
    let workflowDirectory = URL(fileURLWithPath: target.workflowDirectory, isDirectory: true)
    let workflowBytes = try WorkflowDescriptorRelativeReader.read(workflowURL, within: workflowDirectory).bytes
    let object = try JSONSerialization.jsonObject(with: workflowBytes)
    guard let declaration = object as? [String: Any],
          declaration["workflowId"] as? String == target.workflowId,
          declaration["workflowContractVersion"] as? String == target.workflowContractVersion else {
      throw CLIUsageError("workflow declaration identity changed under the transaction lock")
    }
  }

  private func verifyTree(
    _ root: URL,
    target: WorkflowBundleIdentity,
    digest: String,
    unowned: [WorkflowUnownedInventoryEntry]
  ) throws {
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: target, rootOverride: root)
    guard inventory.bundleDigest == digest,
          inventory.unownedFiles.map(WorkflowUnownedInventoryEntry.init) == unowned else {
      throw CLIUsageError("workflow transaction tree digest verification failed: \(root.path)")
    }
  }

  private func syncTree(_ root: URL) throws {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isDirectoryKey],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate transaction staging entry \(url.path): \(error)")
        return false
      }
    ) else {
      throw CLIUsageError("unable to enumerate transaction staging tree for fsync")
    }
    var directories = [root]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true { directories.append(url) } else { try syncFile(url) }
    }
    if let enumerationError { throw enumerationError }
    for directory in directories.reversed() { try syncDirectory(directory) }
  }

  private func syncFile(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open file for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync file: \(url.path)") }
  }

  private func syncDirectory(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open directory for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync directory: \(url.path)") }
  }

  private func cleanupMarkers(
    stableMarker: URL,
    targetParent: URL,
    active: URL,
    historyRoot: URL
  ) throws {
    let stable = try WorkflowPinnedRecordCleanup(record: stableMarker, historyRoot: targetParent)
    let history = try WorkflowPinnedRecordCleanup(record: active, historyRoot: historyRoot)
    try boundaryHook(.stableMarkerUnlink)
    try stable.remove(beforeRecord: {}, beforeSidecar: {})
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
