#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

enum WorkflowConsolidationPhase: String, Codable, CaseIterable, Sendable {
  case prepared
  case replacementPublished
  case retiringSources
  case committed
}

struct WorkflowConsolidationSource: Codable, Equatable, Sendable {
  var target: WorkflowRegistryTarget
  var provenance: WorkflowProvenance
  var activationState: WorkflowActivationState
  var backupPath: String?
  var backupDigest: String?
}

struct WorkflowConsolidationJournal: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var transactionId: String
  var phase: WorkflowConsolidationPhase
  var sources: [WorkflowConsolidationSource]
  var replacementWorkflowId: String
  var replacementDigest: String
  var retireMode: WorkflowRetireMode
  var activateReplacement: Bool
}

struct WorkflowRegistryCoordinatorHooks: Sendable {
  var afterPhase: @Sendable (WorkflowConsolidationPhase) throws -> Void

  init(afterPhase: @escaping @Sendable (WorkflowConsolidationPhase) throws -> Void = { _ in }) {
    self.afterPhase = afterPhase
  }
}

struct WorkflowConsolidationInterruption: Error, Sendable {}

struct WorkflowRegistryCoordinator: Sendable {
  private static let recursionKey = "riela.workflow-registry-coordinator"
  let hooks: WorkflowRegistryCoordinatorHooks

  init(hooks: WorkflowRegistryCoordinatorHooks = WorkflowRegistryCoordinatorHooks()) {
    self.hooks = hooks
  }

  func withLock<T>(
    registry: WorkflowMutableRegistry,
    activationStore: WorkflowActivationStore,
    recovery: () throws -> Void,
    body: () throws -> T
  ) throws -> T {
    if Thread.current.threadDictionary[Self.recursionKey] as? Bool == true {
      return try body()
    }
    return try registry.withCoordinatorCatalogLock {
      try activationStore.withCoordinatorLock {
        Thread.current.threadDictionary[Self.recursionKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.recursionKey) }
        try recovery()
        return try body()
      }
    }
  }

  func withReadLock<T>(
    registry: WorkflowMutableRegistry,
    activationStore: WorkflowActivationStore,
    recovery: () throws -> Void,
    body: () throws -> T
  ) throws -> T {
    if Thread.current.threadDictionary[Self.recursionKey] as? Bool == true {
      return try body()
    }
    return try registry.withCoordinatorCatalogReadLock {
      try activationStore.withCoordinatorReadLock {
        Thread.current.threadDictionary[Self.recursionKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: Self.recursionKey) }
        try recovery()
        return try body()
      }
    }
  }

  func loadJournal() throws -> WorkflowConsolidationJournal? {
    let pinned: WorkflowMutableRegistryPinnedRoot
    do {
      pinned = try stateRoot(create: false)
    } catch is WorkflowMutableRegistryRootAbsent {
      return nil
    }
    let journalURL = pinned.url.appendingPathComponent("consolidation.json")
    guard let data = try pinned.readRegularIfPresent(journalURL) else { return nil }
    let journal = try JSONDecoder().decode(WorkflowConsolidationJournal.self, from: data)
    guard journal.schemaVersion == 1, UUID(uuidString: journal.transactionId) != nil else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "unsupported consolidation journal")
    }
    return journal
  }

  func write(_ journal: WorkflowConsolidationJournal) throws {
    let pinned = try stateRoot(create: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(journal)
    let staging = pinned.url.appendingPathComponent(".consolidation-\(journal.transactionId).json")
    let journalURL = pinned.url.appendingPathComponent("consolidation.json")
    try pinned.writeNewRegularFile(data, to: staging)
    do {
      try pinned.rename(staging, to: journalURL)
      try pinned.syncDirectory(pinned.url)
    } catch {
      try? pinned.unlink(staging)
      throw error
    }
  }

  func removeJournal() throws {
    let pinned: WorkflowMutableRegistryPinnedRoot
    do {
      pinned = try stateRoot(create: false)
    } catch is WorkflowMutableRegistryRootAbsent {
      return
    }
    try pinned.unlink(pinned.url.appendingPathComponent("consolidation.json"))
  }

  func createBackup(source: URL, transactionId: String, originId: String) throws -> URL {
    let pinned = try stateRoot(create: true)
    let transactionRoot = pinned.url
      .appendingPathComponent("consolidation-backups", isDirectory: true)
      .appendingPathComponent(transactionId, isDirectory: true)
    try pinned.ensureDirectory(transactionRoot)
    let destination = transactionRoot.appendingPathComponent(originId, isDirectory: true)
    guard try pinned.entryType(destination) == nil else {
      throw WorkflowRegistryError(code: .registryConflict, message: "consolidation backup already exists")
    }
    try pinned.ensureDirectory(destination)
    try copyDirectoryContents(from: source, to: destination, pinned: pinned)
    try pinned.syncDirectory(transactionRoot)
    return destination
  }

  func removeBackups(transactionId: String) throws {
    let pinned: WorkflowMutableRegistryPinnedRoot
    do {
      pinned = try stateRoot(create: false)
    } catch is WorkflowMutableRegistryRootAbsent {
      return
    }
    let transactionRoot = pinned.url
      .appendingPathComponent("consolidation-backups", isDirectory: true)
      .appendingPathComponent(transactionId, isDirectory: true)
    guard try pinned.entryType(transactionRoot) != nil else { return }
    try pinned.remove(transactionRoot)
  }

  func withValidatedBackupSnapshot<T>(
    path: String,
    transactionId: String,
    originId: String,
    expectedDigest: String,
    body: (URL) throws -> T
  ) throws -> T {
    let pinned = try stateRoot(create: false)
    let expected = pinned.url
      .appendingPathComponent("consolidation-backups", isDirectory: true)
      .appendingPathComponent(transactionId, isDirectory: true)
      .appendingPathComponent(originId, isDirectory: true)
      .standardizedFileURL
    guard URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == expected.path else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation backup path is invalid")
    }
    guard try pinned.entryType(expected) == S_IFDIR else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation backup is missing or malformed")
    }
    let inventory = try pinned.bundleInventory(in: expected)
    guard bundleDigest(inventory: inventory) == expectedDigest else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source backup digest mismatch")
    }
    let detached = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-consolidation-backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: detached, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: detached) }
    try materialize(inventory: inventory, at: detached)
    return try body(detached)
  }

  func bundleDigest(at directory: URL) throws -> String {
    if let pinned = try? stateRoot(create: false),
       directory.standardizedFileURL.path.hasPrefix(pinned.url.path + "/") {
      return bundleDigest(inventory: try pinned.bundleInventory(in: directory))
    }
    var rootStatus = stat()
    guard lstat(directory.path, &rootStatus) == 0, rootStatus.st_mode & S_IFMT == S_IFDIR else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "workflow snapshot is missing or malformed")
    }
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
    ) else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "unable to enumerate workflow snapshot")
    }
    var records: [String] = []
    for case let item as URL in enumerator {
      let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
      guard values.isSymbolicLink != true else {
        throw WorkflowRegistryError(code: .registryIOFailure, message: "workflow snapshot contains a symbolic link")
      }
      let relative = String(item.path.dropFirst(directory.path.count + 1))
      if values.isDirectory == true {
        records.append("directory\t\(relative)")
      } else if values.isRegularFile == true {
        records.append("file\t\(relative)\t\(WorkflowHistoryCanonicalCoding.sha256(try Data(contentsOf: item)))")
      } else {
        throw WorkflowRegistryError(code: .registryIOFailure, message: "workflow snapshot contains a special entry")
      }
    }
    return WorkflowHistoryCanonicalCoding.sha256(Data(records.sorted().joined(separator: "\n").utf8))
  }

  private func stateRoot(create: Bool) throws -> WorkflowMutableRegistryPinnedRoot {
    if let pinned = WorkflowActivationStore.coordinatorPinnedRoot {
      return pinned
    }
    return try WorkflowMutableRegistryPinnedRoot(
      homeDirectory: URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true),
      rootComponents: [".riela", "workflow-state"],
      create: create
    )
  }

  private func copyDirectoryContents(
    from source: URL,
    to destination: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    var sourceStatus = stat()
    guard lstat(source.path, &sourceStatus) == 0, sourceStatus.st_mode & S_IFMT == S_IFDIR else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source is missing or malformed")
    }
    guard let enumerator = FileManager.default.enumerator(
      at: source,
      includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
    ) else {
      throw WorkflowRegistryError(code: .registryIOFailure, message: "unable to enumerate consolidation source")
    }
    for case let item as URL in enumerator {
      let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
      guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else {
        throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source contains a linked or special entry")
      }
      let relative = String(item.path.dropFirst(source.path.count + 1))
      let target = destination.appendingPathComponent(relative, isDirectory: values.isDirectory == true)
      if values.isDirectory == true {
        try pinned.ensureDirectory(target)
      } else {
        var status = stat()
        guard lstat(item.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
          throw WorkflowRegistryError(code: .registryIOFailure, message: "consolidation source changed during backup")
        }
        try pinned.ensureDirectory(target.deletingLastPathComponent())
        try pinned.writeNewRegularFile(
          try Data(contentsOf: item),
          to: target,
          permissions: status.st_mode & 0o777
        )
      }
    }
  }

  private func materialize(
    inventory: [WorkflowMutableRegistryInventoryEntry],
    at root: URL
  ) throws {
    for entry in inventory {
      let target = root.appendingPathComponent(entry.relativePath, isDirectory: entry.bytes == nil)
      if let bytes = entry.bytes {
        try FileManager.default.createDirectory(
          at: target.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try bytes.write(to: target, options: [.withoutOverwriting])
        try FileManager.default.setAttributes(
          [.posixPermissions: NSNumber(value: entry.mode & 0o777)],
          ofItemAtPath: target.path
        )
      } else {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      }
    }
  }

  private func bundleDigest(
    inventory: [WorkflowMutableRegistryInventoryEntry]
  ) -> String {
    let records = inventory.map { entry in
      if let bytes = entry.bytes {
        return "file\t\(entry.relativePath)\t\(WorkflowHistoryCanonicalCoding.sha256(bytes))"
      }
      return "directory\t\(entry.relativePath)"
    }.sorted()
    return WorkflowHistoryCanonicalCoding.sha256(Data(records.joined(separator: "\n").utf8))
  }
}
