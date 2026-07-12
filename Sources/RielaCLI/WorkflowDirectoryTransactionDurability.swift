import Darwin
import Foundation
import RielaCore

struct WorkflowTransactionActiveMarker: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var transactionId: String

  init(schemaVersion: Int = 1, transactionId: String) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
  }
}

enum WorkflowDirectoryTransactionBoundary: String, CaseIterable, Sendable {
  case preparingPayloadBeforeSidecar
  case transactionRecord
  case activeMarker
  case stableMarker
  case preparedRecord
  case preparedPayloadBeforeSidecar
  case committingRecord
  case committingPayloadBeforeSidecar
  case liveToRollbackRename
  case liveMovedRecord
  case liveMovedPayloadBeforeSidecar
  case stagingToLiveRename
  case publishedRecord
  case publishedPayloadBeforeSidecar
  case operationAudit
  case transactionAudit
  case committedRecord
  case committedPayloadBeforeSidecar
  case rollbackUnlink
  case stableMarkerUnlink
  case activeMarkerUnlink
}

struct WorkflowDirectoryInjectedInterruption: Error, Sendable {
  var boundary: WorkflowDirectoryTransactionBoundary
}

struct WorkflowDiscoveredTransaction {
  var record: WorkflowDirectoryTransactionRecord
  var recordURL: URL
}

func discoverWorkflowTransaction(
  transactions: URL,
  active: URL,
  historyRoot: URL
) throws -> WorkflowDiscoveredTransaction? {
  guard try directoryExistsWithoutFollowingLinks(transactions) else { return nil }
  let pinned = try WorkflowHistoryPinnedRoot(historyRoot, create: false)
  let entries = try pinned.names(in: transactions).map { transactions.appendingPathComponent($0) }
  var records: [String: WorkflowDiscoveredTransaction] = [:]
  for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
    let name = entry.lastPathComponent
    guard name.hasSuffix(".json.generations") else { continue }
    let transactionId = String(name.dropLast(".json.generations".count))
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(transactionId)
    let logicalURL = transactions.appendingPathComponent("\(transactionId).json")
    guard let record = try WorkflowTransactionGenerationStore.readLatest(
      logicalURL: logicalURL,
      historyRoot: historyRoot
    ) else { throw CLIUsageError("transaction generation set has no canonical generation") }
    guard record.transactionId == transactionId else {
      throw CLIUsageError("workflow transaction filename does not match its canonical record")
    }
    try validateWorkflowTransactionRecordForDiscovery(record, historyRoot: historyRoot)
    guard records.updateValue(
      WorkflowDiscoveredTransaction(record: record, recordURL: logicalURL),
      forKey: transactionId
    ) == nil else {
      throw CLIUsageError("duplicate workflow transaction record")
    }
  }
  let nonterminal = records.values.filter { !$0.record.phase.isTerminal }
  guard nonterminal.count <= 1 else {
    throw CLIUsageError("multiple nonterminal workflow transaction records; recovery is ambiguous")
  }
  guard try historyEntryExistsWithoutFollowingLinks(active) else { return nonterminal.first }
  let activeBytes = try WorkflowHistorySecurePersistence.readPersistedBytes(from: active, historyRoot: historyRoot)
  let marker = try? WorkflowHistoryCanonicalCoding.decode(WorkflowTransactionActiveMarker.self, from: activeBytes)
  let legacy = marker == nil
    ? try WorkflowHistoryCanonicalCoding.decode(WorkflowDirectoryTransactionRecord.self, from: activeBytes)
    : nil
  let transactionId = marker?.transactionId ?? legacy?.transactionId ?? ""
  try WorkflowHistoryCanonicalCoding.validateSafeComponent(transactionId)
  guard var selected = records[transactionId] else {
    throw CLIUsageError("active workflow transaction marker has no durable transaction record")
  }
  if let other = nonterminal.first, other.record.transactionId != transactionId {
    throw CLIUsageError("active workflow transaction marker conflicts with another nonterminal record")
  }
  if let legacy, legacy != selected.record {
    selected.record = try reconcileWorkflowTransaction(record: selected.record, legacyActive: legacy)
    try validateWorkflowTransactionRecordForDiscovery(selected.record, historyRoot: historyRoot)
    try WorkflowTransactionGenerationStore.write(
      selected.record,
      logicalURL: selected.recordURL,
      historyRoot: historyRoot,
      betweenPayloadAndSidecar: {}
    )
  }
  return selected
}

func acquireWorkflowTargetLock(
  target: WorkflowBundleIdentity,
  owner: String,
  beforeOpen: () throws -> Void = {}
) throws -> Int32 {
  let live = URL(fileURLWithPath: target.ownershipRoot, isDirectory: true).standardizedFileURL
  guard live.path == target.ownershipRoot else {
    throw CLIUsageError("workflow target lock requires canonical ownership identity")
  }
  let lockURL = workflowTargetLockURL(target: target)
  let pinnedParent = try WorkflowHistoryPinnedRoot(lockURL.deletingLastPathComponent())
  let parentDescriptor = pinnedParent.descriptor
  var parentStatus = stat()
  guard fstat(parentDescriptor, &parentStatus) == 0,
        parentStatus.st_uid == geteuid(),
        parentStatus.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
    throw CLIUsageError("workflow target lock directory has unsafe ownership or permissions")
  }
  try beforeOpen()
  let name = lockURL.lastPathComponent
  let descriptor = openat(parentDescriptor, name, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else {
    throw CLIUsageError("workflow target lock must be a regular non-symbolic-link file")
  }
  var status = stat()
  guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
        flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
    _ = close(descriptor)
    throw CLIUsageError("workflow target is locked by another directory transaction")
  }
  guard ftruncate(descriptor, 0) == 0 else {
    releaseWorkflowTargetLock(descriptor)
    throw CLIUsageError("unable to record workflow transaction lock owner")
  }
  try Data(owner.utf8).withUnsafeBytes { bytes in
    guard Darwin.write(descriptor, bytes.baseAddress, bytes.count) == bytes.count else {
      throw CLIUsageError("unable to write workflow transaction lock owner")
    }
  }
  guard fsync(descriptor) == 0 else {
    releaseWorkflowTargetLock(descriptor)
    throw CLIUsageError("unable to fsync workflow transaction lock")
  }
  return descriptor
}

func workflowTargetLockURL(target: WorkflowBundleIdentity) -> URL {
  let key = WorkflowHistoryCanonicalCoding.sha256(Data(target.ownershipRoot.utf8))
  return URL(fileURLWithPath: "/var/tmp", isDirectory: true)
    .appendingPathComponent("riela-workflow-target-locks-\(geteuid())", isDirectory: true)
    .appendingPathComponent(key, isDirectory: true)
    .appendingPathComponent("target.lock")
}

func releaseWorkflowTargetLock(_ descriptor: Int32) {
  _ = flock(descriptor, LOCK_UN)
  _ = close(descriptor)
}

func withWorkflowTargetLock<T>(
  target: WorkflowBundleIdentity,
  owner: String,
  _ body: () throws -> T
) throws -> T {
  let descriptor = try acquireWorkflowTargetLock(target: target, owner: owner)
  defer { releaseWorkflowTargetLock(descriptor) }
  return try body()
}

func validateWorkflowTransactionRecordForDiscovery(
  _ record: WorkflowDirectoryTransactionRecord,
  historyRoot: URL
) throws {
  guard record.schemaVersion == 1 else {
    throw CLIUsageError("unsupported workflow directory transaction schema")
  }
  try WorkflowHistoryCanonicalCoding.validateSafeComponent(record.transactionId)
  try WorkflowHistoryCanonicalCoding.validateSafeComponent(record.preOperationSnapshotId)
  try WorkflowHistoryCanonicalCoding.validateDigest(record.beforeBundleDigest)
  try WorkflowHistoryCanonicalCoding.validateDigest(record.expectedAfterBundleDigest)
  try validateWorkflowUnownedInventory(record.beforeUnownedInventory, field: "beforeUnownedInventory")
  try validateWorkflowUnownedInventory(record.expectedAfterUnownedInventory, field: "expectedAfterUnownedInventory")
  let verificationIds = record.verification.map(\.id)
  guard verificationIds == verificationIds.sorted(), Set(verificationIds).count == verificationIds.count,
        record.diagnostics == record.diagnostics.sorted(), Set(record.diagnostics).count == record.diagnostics.count else {
    throw CLIUsageError("transaction verification or diagnostics are not canonical")
  }
  for verification in record.verification {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(verification.id)
    guard verification.evidenceRefs == verification.evidenceRefs.sorted(),
          Set(verification.evidenceRefs).count == verification.evidenceRefs.count else {
      throw CLIUsageError("transaction verification evidence references are not canonical")
    }
  }
  switch record.operationAuditIntent {
  case let .mutation(evidence): try WorkflowHistoryCanonicalCoding.validate(evidence)
  case let .restore(restore): try WorkflowHistoryCanonicalCoding.validate(restore)
  }
  let live = URL(fileURLWithPath: record.target.ownershipRoot, isDirectory: true).standardizedFileURL
  let parent = live.deletingLastPathComponent()
  let expectedStaging = parent.appendingPathComponent(
    ".\(live.lastPathComponent).riela-stage-\(record.transactionId)", isDirectory: true
  ).standardizedFileURL
  let expectedRollback = parent.appendingPathComponent(
    ".\(live.lastPathComponent).riela-rollback-\(record.transactionId)", isDirectory: true
  ).standardizedFileURL
  guard URL(fileURLWithPath: record.stagingPath).standardizedFileURL.path == expectedStaging.path,
        URL(fileURLWithPath: record.rollbackPath).standardizedFileURL.path == expectedRollback.path,
        historyRoot.standardizedFileURL.path.hasPrefix("/") else {
    throw CLIUsageError("transaction paths do not match their canonical target and history root")
  }
}

private func validateWorkflowUnownedInventory(
  _ inventory: [WorkflowUnownedInventoryEntry],
  field: String
) throws {
  let paths = inventory.map(\.relativePath)
  guard paths == paths.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }),
        Set(paths).count == paths.count else {
    throw CLIUsageError("transaction \(field) is not canonical or contains duplicates")
  }
  for entry in inventory {
    try WorkflowHistoryCanonicalCoding.validateRelativePath(entry.relativePath)
    try WorkflowHistoryCanonicalCoding.validateDigest(entry.contentDigest)
    guard entry.byteCount >= 0, entry.entryType == .regularFile else {
      throw CLIUsageError("transaction \(field) contains an invalid entry")
    }
  }
}

private extension WorkflowDirectoryTransactionPhase {
  var isTerminal: Bool {
    self == .committed || self == .failed || self == .recovered
  }
}

func reconcileWorkflowTransaction(
  record: WorkflowDirectoryTransactionRecord,
  legacyActive: WorkflowDirectoryTransactionRecord
) throws -> WorkflowDirectoryTransactionRecord {
  // Legacy writers durably replaced the transaction record before replacing
  // active.json. Therefore the active value may equal the generation value or
  // be its immediate predecessor; it may never be a successor or a different
  // branch. Validate in chronological order so immutable fields, verification,
  // diagnostics, and the real branched phase graph use the generation rules.
  if record == legacyActive { return record }
  try WorkflowTransactionGenerationStore.validateTransition(from: legacyActive, to: record)
  return record
}

func validateWorkflowTransactionStableMetadata(
  record: WorkflowDirectoryTransactionRecord,
  marker: URL,
  historyRoot: URL
) throws {
  if try historyEntryExistsWithoutFollowingLinks(marker) {
    let metadata = try WorkflowHistorySecurePersistence.readCanonical(
      WorkflowTransactionStableMetadata.self,
      from: marker,
      historyRoot: marker.deletingLastPathComponent()
    )
    guard metadata.schemaVersion == 1,
          metadata.transactionId == record.transactionId,
          metadata.target == record.target,
          metadata.historyRoot == historyRoot.standardizedFileURL.path else {
      throw CLIUsageError("stable workflow transaction metadata does not match the active transaction")
    }
  } else if record.phase != .preparing
              && record.phase != .committed
              && record.phase != .failed
              && record.phase != .recovered {
    throw CLIUsageError("nonterminal workflow transaction is missing stable target metadata")
  }
}

func directoryExistsWithoutFollowingLinks(_ url: URL) throws -> Bool {
  var status = stat()
  if lstat(url.path, &status) != 0 {
    if errno == ENOENT { return false }
    throw CLIUsageError("unable to inspect workflow transaction tree: \(url.path)")
  }
  guard status.st_mode & S_IFMT == S_IFDIR else {
    throw CLIUsageError("workflow transaction tree is linked or has unexpected type: \(url.path)")
  }
  return true
}

func historyEntryExistsWithoutFollowingLinks(_ url: URL) throws -> Bool {
  var status = stat()
  if lstat(url.path, &status) != 0 {
    if errno == ENOENT { return false }
    throw CLIUsageError("unable to inspect workflow history entry: \(url.path)")
  }
  guard status.st_mode & S_IFMT != S_IFLNK else {
    throw CLIUsageError("workflow history entry is a symbolic link: \(url.path)")
  }
  return true
}

func deviceIdentifier(_ url: URL) throws -> UInt64 {
  var status = stat()
  guard lstat(url.path, &status) == 0 else {
    throw CLIUsageError("unable to inspect workflow transaction filesystem boundary: \(url.path)")
  }
  return UInt64(status.st_dev)
}

func moveSiblingDirectory(from source: URL, to destination: URL, parent: URL) throws {
  guard source.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
        destination.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL,
        try directoryExistsWithoutFollowingLinks(source),
        try !historyEntryExistsWithoutFollowingLinks(destination) else {
    throw CLIUsageError("workflow transaction rename paths are not verified siblings")
  }
  let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
  guard descriptor >= 0 else {
    throw CLIUsageError("unable to open workflow transaction parent without following links")
  }
  defer { _ = close(descriptor) }
  guard renameat(descriptor, source.lastPathComponent, descriptor, destination.lastPathComponent) == 0 else {
    throw CLIUsageError("unable to rename workflow transaction directory")
  }
}
