#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public struct WorkflowTransactionStableMetadata: Codable, Equatable, Sendable {
  public var schemaVersion: Int
  public var transactionId: String
  public var target: WorkflowBundleIdentity
  public var historyRoot: String
  public var physicalOwnershipRoot: String?
  public var physicalOwnershipContainerDevice: UInt64?
  public var physicalOwnershipContainerInode: UInt64?

  public init(
    schemaVersion: Int = 1,
    transactionId: String,
    target: WorkflowBundleIdentity,
    historyRoot: String,
    physicalOwnershipRoot: String? = nil,
    physicalOwnershipContainerDevice: UInt64? = nil,
    physicalOwnershipContainerInode: UInt64? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.transactionId = transactionId
    self.target = target
    self.historyRoot = historyRoot
    self.physicalOwnershipRoot = physicalOwnershipRoot
    self.physicalOwnershipContainerDevice = physicalOwnershipContainerDevice
    self.physicalOwnershipContainerInode = physicalOwnershipContainerInode
  }

  public static func url(forOwnershipRoot root: URL) -> URL {
    root.deletingLastPathComponent().appendingPathComponent(
      ".\(root.lastPathComponent).riela-active-transaction.json"
    )
  }
}

struct WorkflowDetachedOwnershipRootIdentity: Equatable, Sendable {
  var root: URL
  var containerDevice: UInt64
  var containerInode: UInt64
}

enum WorkflowDetachedOwnershipRoot {
  static let containerPrefix = "riela-temporary-snapshot-"

  static func create() throws -> URL {
    let namespace = canonicalNamespaceRoot
    let pinned = try WorkflowHistoryPinnedRoot(namespace, create: false)
    let container = containerPrefix + UUID().uuidString.lowercased()
    guard mkdirat(pinned.descriptor, container, S_IRWXU) == 0 else {
      throw CLIUsageError("unable to create detached workflow ownership container")
    }
    let descriptor = openat(pinned.descriptor, container, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      _ = unlinkat(pinned.descriptor, container, AT_REMOVEDIR)
      throw CLIUsageError("unable to pin detached workflow ownership container")
    }
    defer { _ = close(descriptor) }
    guard mkdirat(descriptor, "root", S_IRWXU) == 0, fsync(descriptor) == 0 else {
      _ = unlinkat(pinned.descriptor, container, AT_REMOVEDIR)
      throw CLIUsageError("unable to create detached workflow ownership root")
    }
    let root = namespace.appendingPathComponent(container, isDirectory: true)
      .appendingPathComponent("root", isDirectory: true)
    return try validate(root, requireRoot: true).root
  }

  static func validate(_ candidate: URL, requireRoot: Bool) throws -> WorkflowDetachedOwnershipRootIdentity {
    try WorkflowDetachedOwnershipPinnedRoot(candidate: candidate, requireRoot: requireRoot).identity
  }

  static var canonicalNamespaceRoot: URL {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
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

func makeWorkflowTransactionPreflightAttempt(
  transactionId: String,
  kind: WorkflowDirectoryTransactionKind,
  target: WorkflowBundleIdentity,
  beforeDigest: String,
  afterDigest: String,
  snapshotId: String
) -> WorkflowPreflightAttemptRecord {
  WorkflowPreflightAttemptRecord(
    attemptId: "attempt-\(transactionId)",
    transactionId: transactionId,
    kind: kind,
    target: target,
    expectedBeforeBundleDigest: beforeDigest,
    expectedAfterBundleDigest: afterDigest,
    preOperationSnapshotId: snapshotId,
    status: .attempted,
    mutationOccurred: false,
    diagnostics: [],
    startedAt: Date(
      timeIntervalSince1970: (Date().timeIntervalSince1970 * 1_000).rounded(.down) / 1_000
    )
  )
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
    #if canImport(Darwin)
    let written = Darwin.write(descriptor, bytes.baseAddress, bytes.count)
    #else
    let written = Glibc.write(descriptor, bytes.baseAddress, bytes.count)
    #endif
    guard written == bytes.count else {
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
  let detachedIdentity = try record.physicalOwnershipRoot.map {
    try WorkflowDetachedOwnershipRoot.validate(URL(fileURLWithPath: $0, isDirectory: true), requireRoot: false)
  }
  let live = detachedIdentity?.root
    ?? URL(fileURLWithPath: record.target.ownershipRoot, isDirectory: true).standardizedFileURL
  let parent = live.deletingLastPathComponent()
  let expectedStaging = parent.appendingPathComponent(
    ".\(live.lastPathComponent).riela-stage-\(record.transactionId)", isDirectory: true
  ).standardizedFileURL
  let expectedRollback = parent.appendingPathComponent(
    ".\(live.lastPathComponent).riela-rollback-\(record.transactionId)", isDirectory: true
  ).standardizedFileURL
  guard URL(fileURLWithPath: record.stagingPath).standardizedFileURL.path == expectedStaging.path,
        URL(fileURLWithPath: record.rollbackPath).standardizedFileURL.path == expectedRollback.path,
        record.physicalOwnershipRoot == detachedIdentity?.root.path,
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
  historyRoot: URL,
  detachedRoot: WorkflowDetachedOwnershipPinnedRoot? = nil
) throws {
  let detachedMetadata = try detachedRoot?.readCanonicalIfPresent(
    WorkflowTransactionStableMetadata.self,
    name: marker.lastPathComponent
  )
  let markerExists = detachedRoot == nil
    ? try historyEntryExistsWithoutFollowingLinks(marker)
    : detachedMetadata != nil
  if markerExists {
    let metadata = try detachedMetadata ?? WorkflowHistorySecurePersistence.readCanonical(
      WorkflowTransactionStableMetadata.self,
      from: marker,
      historyRoot: marker.deletingLastPathComponent()
    )
    guard metadata.schemaVersion == 1,
          metadata.transactionId == record.transactionId,
          metadata.target == record.target,
          metadata.historyRoot == historyRoot.standardizedFileURL.path,
          metadata.physicalOwnershipRoot == record.physicalOwnershipRoot else {
      throw CLIUsageError("stable workflow transaction metadata does not match the active transaction")
    }
    if let physicalOwnershipRoot = record.physicalOwnershipRoot {
      guard let detachedRoot else {
        throw CLIUsageError("detached workflow recovery did not retain its ownership container")
      }
      let identity = detachedRoot.identity
      guard identity.root.path == physicalOwnershipRoot else {
        throw CLIUsageError("detached workflow ownership root changed before recovery")
      }
      guard metadata.physicalOwnershipContainerDevice == identity.containerDevice,
            metadata.physicalOwnershipContainerInode == identity.containerInode else {
        throw CLIUsageError("detached workflow ownership container identity changed before recovery")
      }
    } else if metadata.physicalOwnershipContainerDevice != nil || metadata.physicalOwnershipContainerInode != nil {
      throw CLIUsageError("stable workflow transaction metadata has unexpected detached ownership identity")
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
