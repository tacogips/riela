#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public enum WorkflowTemporaryRegistryPhase: String, Codable, CaseIterable, Sendable {
  case prepared
  case movingOriginal
  case originalBackedUp
  case publishingReplacement
  case replacementPublished
}

enum WorkflowTemporaryRegistryLock: Equatable, Sendable {
  case catalog
  case workflow(String)
}

public struct WorkflowTemporaryRegistryHooks: Sendable {
  public var afterPhase: @Sendable (WorkflowTemporaryRegistryPhase) throws -> Void
  var beforeRecordRead: @Sendable (String) throws -> Void
  var beforeLockAcquire: @Sendable (WorkflowTemporaryRegistryLock) throws -> Void
  var afterLockAcquire: @Sendable (WorkflowTemporaryRegistryLock) throws -> Void
  var beforeDetachedBundleLoad: @Sendable () throws -> Void
  var afterMutationWorkspaceExport: @Sendable () throws -> Void

  public init(afterPhase: @escaping @Sendable (WorkflowTemporaryRegistryPhase) throws -> Void = { _ in }) {
    self.afterPhase = afterPhase
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
  }

  init(
    afterPhase: @escaping @Sendable (WorkflowTemporaryRegistryPhase) throws -> Void,
    beforeRecordRead: @escaping @Sendable (String) throws -> Void
  ) {
    self.afterPhase = afterPhase
    self.beforeRecordRead = beforeRecordRead
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
  }

  init(
    beforeLockAcquire: @escaping @Sendable (WorkflowTemporaryRegistryLock) throws -> Void,
    afterLockAcquire: @escaping @Sendable (WorkflowTemporaryRegistryLock) throws -> Void
  ) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    self.beforeLockAcquire = beforeLockAcquire
    self.afterLockAcquire = afterLockAcquire
    beforeDetachedBundleLoad = {}
    afterMutationWorkspaceExport = {}
  }

  init(
    beforeDetachedBundleLoad: @escaping @Sendable () throws -> Void = {},
    afterMutationWorkspaceExport: @escaping @Sendable () throws -> Void = {}
  ) {
    afterPhase = { _ in }
    beforeRecordRead = { _ in }
    beforeLockAcquire = { _ in }
    afterLockAcquire = { _ in }
    self.beforeDetachedBundleLoad = beforeDetachedBundleLoad
    self.afterMutationWorkspaceExport = afterMutationWorkspaceExport
  }
}

struct TemporaryRegistryInterruption: Error, Sendable {}

struct RegisteredTemporaryWorkflow: Equatable, Sendable {
  var workflowId: String
  var workflowDirectory: String
  var inputPath: String
  var overwritten: Bool
}

private struct WorkflowTemporaryRegistryTransaction: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var workflowId: String
  var transactionId: String
  var phase: WorkflowTemporaryRegistryPhase
  var hadOriginal: Bool
  var replacementDigest: String
  var destinationPath: String
  var stagingPath: String
  var backupPath: String?
}

private struct WorkflowTemporaryRegistryRecoveryFailure: Error, CustomStringConvertible {
  var publicationError: Error
  var recoveryError: Error

  var description: String {
    "temporary workflow publication failed: \(publicationError); "
      + "recovery failed and registry artifacts were preserved: \(recoveryError)"
  }
}

public struct WorkflowTemporaryRegistry: Sendable {
  public static let reservedStateName = ".registry-state"

  let hooks: WorkflowTemporaryRegistryHooks

  public init(hooks: WorkflowTemporaryRegistryHooks = WorkflowTemporaryRegistryHooks()) {
    self.hooks = hooks
  }

  var root: URL {
    URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("temporary-workflows", isDirectory: true)
      .standardizedFileURL
  }

  func register(input: URL, overwrite: Bool) throws -> RegisteredTemporaryWorkflow {
    let pinned = try pinnedRoot(create: true)
    try ensureLayout(pinned: pinned)
    let transactionId = UUID().uuidString.lowercased()
    let staging = stagingRoot.appendingPathComponent(transactionId, isDirectory: true)
    var preserveStagingForRecovery = false
    do {
      try copyInput(input.standardizedFileURL, to: staging, pinned: pinned)
      try pinned.requireConfiguredPathIdentity()
      let bundle = try withDetachedSnapshot(of: staging, pinned: pinned) { snapshot in
        try hooks.beforeDetachedBundleLoad()
        return try FileSystemWorkflowBundleResolver().loadBundle(
          at: snapshot,
          rootDirectory: snapshot,
          scope: .user,
          temporary: true
        )
      }
      try pinned.requireConfiguredPathIdentity()
      let workflowId = bundle.workflow.workflowId
      try validateWorkflowId(workflowId)
      let diagnostics = bundle.diagnostics
        + DefaultWorkflowValidator().validate(bundle.workflow, nodePayloads: bundle.nodePayloads)
      if diagnostics.contains(where: { $0.severity == .error }) {
        throw WorkflowResolutionError.invalidWorkflow(diagnostics)
      }
      let replacementDigest = try bundleDigest(at: staging, pinned: pinned)
      let destination = root.appendingPathComponent(workflowId, isDirectory: true)
      let backup = backupsRoot
        .appendingPathComponent(workflowId, isDirectory: true)
        .appendingPathComponent(transactionId, isDirectory: true)
      let overwritten = try withCatalogLock(pinned: pinned, createIfMissing: false) {
        try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
          try recoverLocked(pinned: pinned, workflowId: workflowId)
          let hadOriginal = try registryItemExists(destination, pinned: pinned)
          if hadOriginal && !overwrite {
            throw CLIUsageError(
              "temporary workflow '\(workflowId)' already exists at \(destination.path); use --overwrite to replace it"
            )
          }
          var record = WorkflowTemporaryRegistryTransaction(
            schemaVersion: 1,
            workflowId: workflowId,
            transactionId: transactionId,
            phase: .prepared,
            hadOriginal: hadOriginal,
            replacementDigest: replacementDigest,
            destinationPath: workflowId,
            stagingPath: relativePath(staging),
            backupPath: hadOriginal ? relativePath(backup) : nil
          )
          var replacementPublished = false
          do {
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.prepared)
            if hadOriginal {
              try createRealDirectory(backup.deletingLastPathComponent(), pinned: pinned)
              record.phase = .movingOriginal
              try publish(record, pinned: pinned)
              try hooks.afterPhase(.movingOriginal)
              try renameDirectory(destination, to: backup, pinned: pinned)
              record.phase = .originalBackedUp
              try publish(record, pinned: pinned)
              try hooks.afterPhase(.originalBackedUp)
            }
            record.phase = .publishingReplacement
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.publishingReplacement)
            try renameDirectory(staging, to: destination, pinned: pinned)
            guard try bundleDigest(at: destination, pinned: pinned) == replacementDigest else {
              throw CLIUsageError("temporary workflow replacement digest verification failed")
            }
            replacementPublished = true
            record.phase = .replacementPublished
            try publish(record, pinned: pinned)
            try hooks.afterPhase(.replacementPublished)
            try finish(record, pinned: pinned)
            try pinned.requireConfiguredPathIdentity()
            return hadOriginal
          } catch {
            let publicationError = error
            if publicationError is TemporaryRegistryInterruption {
              throw publicationError
            }
            do {
              try recoverLocked(pinned: pinned, workflowId: workflowId)
            } catch {
              preserveStagingForRecovery = true
              throw WorkflowTemporaryRegistryRecoveryFailure(
                publicationError: publicationError,
                recoveryError: error
              )
            }
            if replacementPublished {
              try pinned.requireConfiguredPathIdentity()
              return hadOriginal
            }
            throw publicationError
          }
        }
      }
      return RegisteredTemporaryWorkflow(
        workflowId: workflowId,
        workflowDirectory: destination.path,
        inputPath: input.path,
        overwritten: overwritten
      )
    } catch {
      if error is TemporaryRegistryInterruption {
        throw error
      }
      if !preserveStagingForRecovery, (try? registryItemExists(staging, pinned: pinned)) == true {
        try? removeArtifact(staging, pinned: pinned)
      }
      throw error
    }
  }

  func snapshotCandidates() throws -> [URL] {
    guard let pinned = try existingPinnedRoot() else { return [] }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try recoverAllLocked(pinned: pinned)
      return try pinned.names(in: root)
        .filter { $0 != Self.reservedStateName }
        .map { root.appendingPathComponent($0, isDirectory: true) }
    }
  }

  func withWorkflowRead<T>(workflowId: String, _ body: (URL) throws -> T) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else {
      throw CLIUsageError("temporary workflow registry is not initialized")
    }
    try validateExistingLayout(pinned: pinned)
    return try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
      try withDetachedRegistrySnapshot(pinned: pinned) { snapshotRoot in
        try hooks.beforeDetachedBundleLoad()
        return try body(snapshotRoot.appendingPathComponent(workflowId, isDirectory: true))
      }
    }
  }

  func withWorkflowAccess<T>(workflowId: String, _ body: () throws -> T) throws -> T {
    try withWorkflowPinnedAccess(workflowId: workflowId) { _ in try body() }
  }

  func withWorkflowPinnedAccess<T>(
    workflowId: String,
    _ body: (WorkflowTemporaryRegistryPinnedRoot?) throws -> T
  ) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else { return try body(nil) }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      let destination = root.appendingPathComponent(workflowId, isDirectory: true)
      let transaction = transactionsRoot.appendingPathComponent("\(workflowId).json")
      guard try registryItemExists(destination, pinned: pinned)
        || registryItemExists(transaction, pinned: pinned) else {
        return try body(pinned)
      }
      return try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
        return try body(pinned)
      }
    }
  }

  func withWorkflowMutationAccess<T>(
    workflowId: String,
    expectedDigest: String,
    shouldPublish: (T) -> Bool = { _ in true },
    _ body: (URL, (URL) throws -> Void) throws -> T
  ) throws -> T {
    try validateWorkflowId(workflowId)
    guard let pinned = try existingPinnedRoot() else {
      throw CLIUsageError("temporary workflow registry is not initialized")
    }
    try validateExistingLayout(pinned: pinned)
    return try withCatalogLock(pinned: pinned, createIfMissing: false) {
      try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
        let destination = root.appendingPathComponent(workflowId, isDirectory: true)
        guard try realDirectoryExists(
          destination,
          under: root,
          label: "temporary workflow destination",
          pinned: pinned
        ) else {
          throw CLIUsageError("temporary workflow '\(workflowId)' disappeared before mutation")
        }
        guard try bundleDigest(at: destination, pinned: pinned) == expectedDigest else {
          throw CLIUsageError("temporary workflow '\(workflowId)' changed before mutation; resolve it again")
        }
        let result = try withDetachedSnapshot(of: destination, pinned: pinned) { workspace in
          try hooks.afterMutationWorkspaceExport()
          try pinned.requireConfiguredPathIdentity()
          var published = false
          let result = try body(workspace) { preparedWorkflow in
            try replaceLocked(
              workflowId: workflowId,
              input: preparedWorkflow,
              pinned: pinned
            )
            published = true
          }
          if shouldPublish(result), !published {
            throw CLIUsageError("temporary workflow mutation completed without registry publication")
          }
          return result
        }
        try pinned.requireConfiguredPathIdentity()
        return result
      }
    }
  }

  private var stateRoot: URL { root.appendingPathComponent(Self.reservedStateName, isDirectory: true) }
  private var locksRoot: URL { stateRoot.appendingPathComponent("locks", isDirectory: true) }
  private var transactionsRoot: URL { stateRoot.appendingPathComponent("transactions", isDirectory: true) }
  private var recordStagingRoot: URL { stateRoot.appendingPathComponent("record-staging", isDirectory: true) }
  private var stagingRoot: URL { stateRoot.appendingPathComponent("staging", isDirectory: true) }
  private var backupsRoot: URL { stateRoot.appendingPathComponent("backups", isDirectory: true) }
  private var catalogLockURL: URL { stateRoot.appendingPathComponent("catalog.lock") }

  private func replaceLocked(
    workflowId: String,
    input: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    let transactionId = UUID().uuidString.lowercased()
    let staging = stagingRoot.appendingPathComponent(transactionId, isDirectory: true)
    let destination = root.appendingPathComponent(workflowId, isDirectory: true)
    let backup = backupsRoot
      .appendingPathComponent(workflowId, isDirectory: true)
      .appendingPathComponent(transactionId, isDirectory: true)
    try copyInput(input, to: staging, pinned: pinned)
    var preserveStagingForRecovery = false
    do {
      let loaded = try withDetachedSnapshot(of: staging, pinned: pinned) { snapshot in
        try FileSystemWorkflowBundleResolver().loadBundle(
          at: snapshot,
          rootDirectory: snapshot,
          scope: .user,
          temporary: true,
          expectedWorkflowId: workflowId
        )
      }
      let diagnostics = loaded.diagnostics
        + DefaultWorkflowValidator().validate(loaded.workflow, nodePayloads: loaded.nodePayloads)
      guard !diagnostics.contains(where: { $0.severity == .error }) else {
        throw WorkflowResolutionError.invalidWorkflow(diagnostics)
      }
      let replacementDigest = try bundleDigest(at: staging, pinned: pinned)
      var record = WorkflowTemporaryRegistryTransaction(
        schemaVersion: 1,
        workflowId: workflowId,
        transactionId: transactionId,
        phase: .prepared,
        hadOriginal: true,
        replacementDigest: replacementDigest,
        destinationPath: workflowId,
        stagingPath: relativePath(staging),
        backupPath: relativePath(backup)
      )
      var replacementPublished = false
      do {
        try publish(record, pinned: pinned)
        try createRealDirectory(backup.deletingLastPathComponent(), pinned: pinned)
        record.phase = .movingOriginal
        try publish(record, pinned: pinned)
        try renameDirectory(destination, to: backup, pinned: pinned)
        record.phase = .originalBackedUp
        try publish(record, pinned: pinned)
        record.phase = .publishingReplacement
        try publish(record, pinned: pinned)
        try renameDirectory(staging, to: destination, pinned: pinned)
        guard try bundleDigest(at: destination, pinned: pinned) == replacementDigest else {
          throw CLIUsageError("temporary workflow mutation publication digest verification failed")
        }
        replacementPublished = true
        record.phase = .replacementPublished
        try publish(record, pinned: pinned)
        try finish(record, pinned: pinned)
      } catch {
        let publicationError = error
        do {
          try recoverLocked(pinned: pinned, workflowId: workflowId)
        } catch {
          preserveStagingForRecovery = true
          throw WorkflowTemporaryRegistryRecoveryFailure(
            publicationError: publicationError,
            recoveryError: error
          )
        }
        if !replacementPublished { throw publicationError }
      }
    } catch {
      if !preserveStagingForRecovery, (try? registryItemExists(staging, pinned: pinned)) == true {
        try? removeArtifact(staging, pinned: pinned)
      }
      throw error
    }
  }

  private func ensureLayout(pinned: WorkflowTemporaryRegistryPinnedRoot) throws {
    for directory in [stateRoot, locksRoot, transactionsRoot, recordStagingRoot, stagingRoot, backupsRoot] {
      try pinned.ensureDirectory(directory)
    }
    try createLockFileIfNeeded(catalogLockURL, pinned: pinned)
  }

  private func existingPinnedRoot() throws -> WorkflowTemporaryRegistryPinnedRoot? {
    do {
      return try pinnedRoot(create: false)
    } catch is WorkflowTemporaryRegistryRootAbsent {
      return nil
    }
  }

  private func validateExistingLayout(pinned: WorkflowTemporaryRegistryPinnedRoot) throws {
    guard try pinned.entryType(stateRoot) == S_IFDIR else {
      throw CLIUsageError("temporary workflow registry state layout is incomplete: \(stateRoot.path)")
    }
    for directory in [locksRoot, transactionsRoot, recordStagingRoot, stagingRoot, backupsRoot] {
      guard try pinned.entryType(directory) == S_IFDIR else {
        throw CLIUsageError("temporary workflow registry state layout is incomplete: \(directory.path)")
      }
    }
    guard try pinned.entryType(catalogLockURL) == S_IFREG else {
      throw CLIUsageError("temporary workflow registry catalog lock is missing or malformed")
    }
  }

  private func createLockFileIfNeeded(
    _ url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot? = nil
  ) throws {
    let descriptor = try (pinned ?? pinnedRoot(create: false)).openRegularFile(
      url,
      flags: O_RDWR | O_CREAT
    )
    guard descriptor >= 0 else {
      throw CLIUsageError("temporary workflow registry lock must be a regular non-symbolic-link file")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("temporary workflow registry lock has unexpected type")
    }
  }

  private func createRealDirectory(
    _ directory: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    try pinned.ensureDirectory(directory)
  }

  private func validateWorkflowId(_ workflowId: String) throws {
    guard workflowId != Self.reservedStateName, isSafeScopedWorkflowName(workflowId) else {
      throw CLIUsageError("unsafe temporary workflowId '\(workflowId)'")
    }
  }

  private func copyInput(
    _ input: URL,
    to staging: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    var status = stat()
    guard lstat(input.path, &status) == 0 else {
      throw CLIUsageError("temporary workflow registration input not found: \(input.path)")
    }
    let kind = status.st_mode & S_IFMT
    guard kind == S_IFREG || kind == S_IFDIR else {
      throw CLIUsageError("temporary workflow registration input must be a regular JSON file or real directory")
    }
    guard let resolvedPointer = input.path.withCString({ realpath($0, nil) }) else {
      throw CLIUsageError("unable to resolve temporary workflow registration input")
    }
    defer { free(resolvedPointer) }
    let sourceRoot = URL(
      fileURLWithPath: String(cString: resolvedPointer),
      isDirectory: kind == S_IFDIR
    ).standardizedFileURL
    try createRealDirectory(staging, pinned: pinned)
    if kind == S_IFREG {
      guard input.pathExtension.lowercased() == "json" else {
        throw CLIUsageError("temporary workflow file input must be JSON")
      }
      try copyRegularFile(
        sourceRoot,
        to: staging.appendingPathComponent("workflow.json"),
        pinned: pinned
      )
      return
    }
    let workflowJSON = sourceRoot.appendingPathComponent("workflow.json")
    var workflowStatus = stat()
    guard lstat(workflowJSON.path, &workflowStatus) == 0,
          workflowStatus.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("temporary workflow bundle must contain a regular root workflow.json")
    }
    guard let enumerator = FileManager.default.enumerator(atPath: sourceRoot.path) else {
      throw CLIUsageError("unable to enumerate temporary workflow bundle")
    }
    for case let relative as String in enumerator {
      let source = sourceRoot.appendingPathComponent(relative)
      var entryStatus = stat()
      guard lstat(source.path, &entryStatus) == 0 else {
        throw CLIUsageError("temporary workflow bundle entry disappeared: \(source.path)")
      }
      let entryKind = entryStatus.st_mode & S_IFMT
      guard entryKind == S_IFREG || entryKind == S_IFDIR else {
        throw CLIUsageError("temporary workflow bundle contains a linked or special entry: \(source.path)")
      }
      guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
        throw CLIUsageError("temporary workflow bundle entry escapes its input root")
      }
      let destination = staging.appendingPathComponent(relative, isDirectory: entryKind == S_IFDIR)
      guard isContained(destination, in: staging) else {
        throw CLIUsageError("temporary workflow bundle entry escapes staging")
      }
      if entryKind == S_IFDIR {
        try createRealDirectory(destination, pinned: pinned)
      } else {
        try copyRegularFile(source, to: destination, pinned: pinned)
      }
    }
  }

  private func copyRegularFile(
    _ source: URL,
    to destination: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else {
      throw CLIUsageError("temporary workflow bundle file is linked, missing, or unreadable")
    }
    defer { _ = close(sourceDescriptor) }
    var status = stat()
    guard fstat(sourceDescriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("temporary workflow bundle entry changed type during copy")
    }
    let bytes = try FileHandle(fileDescriptor: sourceDescriptor, closeOnDealloc: false).readToEnd() ?? Data()
    try pinned.writeNewRegularFile(
      bytes,
      to: destination,
      permissions: status.st_mode & 0o777
    )
  }

  func bundleDigest(
    at directory: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws -> String {
    try pinned.requireConfiguredPathIdentity()
    let records = try pinned.bundleInventory(in: directory).map { entry in
      if let bytes = entry.bytes {
        return "file\t\(entry.relativePath)\t\(WorkflowHistoryCanonicalCoding.sha256(bytes))"
      }
      return "directory\t\(entry.relativePath)"
    }.sorted()
    try pinned.requireConfiguredPathIdentity()
    return WorkflowHistoryCanonicalCoding.sha256(Data(records.joined(separator: "\n").utf8))
  }

  private func withCatalogLock<T>(
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    try withFileLock(
      pinned: pinned,
      catalogLockURL,
      lock: .catalog,
      createIfMissing: createIfMissing,
      body
    )
  }

  private func withWorkflowLock<T>(
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    workflowId: String,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    try withFileLock(
      pinned: pinned,
      locksRoot.appendingPathComponent("\(workflowId).lock"),
      lock: .workflow(workflowId),
      createIfMissing: createIfMissing,
      body
    )
  }

  private func withFileLock<T>(
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    _ url: URL,
    lock: WorkflowTemporaryRegistryLock,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    let flags = O_RDWR | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
    let descriptor = try pinned.openRegularFile(url, flags: flags)
    guard descriptor >= 0 else {
      throw CLIUsageError("temporary workflow registry lock must be a regular non-symbolic-link file")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("temporary workflow registry lock has unexpected type")
    }
    try hooks.beforeLockAcquire(lock)
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw CLIUsageError("unable to acquire temporary workflow registry lock")
    }
    defer { _ = flock(descriptor, LOCK_UN) }
    try hooks.afterLockAcquire(lock)
    try pinned.requireConfiguredPathIdentity()
    do {
      let result = try body()
      try pinned.requireConfiguredPathIdentity()
      return result
    } catch {
      do {
        try pinned.requireConfiguredPathIdentity()
      } catch {
        throw error
      }
      throw error
    }
  }

  private func recoverAllLocked(pinned: WorkflowTemporaryRegistryPinnedRoot) throws {
    let records = try pinned.names(in: transactionsRoot)
      .filter { $0.hasSuffix(".json") }
      .map { transactionsRoot.appendingPathComponent($0) }
    for recordURL in records {
      let workflowId = recordURL.deletingPathExtension().lastPathComponent
      try validateWorkflowId(workflowId)
      try withWorkflowLock(pinned: pinned, workflowId: workflowId, createIfMissing: true) {
        try recoverLocked(pinned: pinned, workflowId: workflowId)
      }
    }
  }

  private func recoverLocked(
    pinned: WorkflowTemporaryRegistryPinnedRoot,
    workflowId: String
  ) throws {
    let recordURL = transactionsRoot.appendingPathComponent("\(workflowId).json")
    try hooks.beforeRecordRead(workflowId)
    try pinned.requireConfiguredPathIdentity()
    guard let recordData = try readRegularFileIfPresent(recordURL, pinned: pinned) else { return }
    let record = try JSONDecoder().decode(
      WorkflowTemporaryRegistryTransaction.self,
      from: recordData
    )
    try validate(record, expectedWorkflowId: workflowId)
    let destination = root.appendingPathComponent(record.destinationPath, isDirectory: true)
    let staging = root.appendingPathComponent(record.stagingPath, isDirectory: true)
    let backup = record.backupPath.map { root.appendingPathComponent($0, isDirectory: true) }
    let destinationExists = try realDirectoryExists(
      destination,
      under: root,
      label: "temporary workflow destination",
      pinned: pinned
    )
    let stagingExists = try realDirectoryExists(
      staging,
      under: stagingRoot,
      label: "temporary workflow staging artifact",
      pinned: pinned
    )
    let backupExists = try backup.map {
      try realDirectoryExists(
        $0,
        under: backupsRoot,
        label: "temporary workflow backup artifact",
        pinned: pinned
      )
    } ?? false
    let replacementPresent: Bool
    if destinationExists {
      replacementPresent = try bundleDigest(at: destination, pinned: pinned) == record.replacementDigest
    } else {
      replacementPresent = false
    }
    if replacementPresent {
      if backupExists, let backup { try removeArtifact(backup, pinned: pinned) }
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    if backupExists, let backup {
      guard !destinationExists else {
        throw CLIUsageError("ambiguous temporary workflow recovery state for '\(workflowId)'")
      }
      try renameDirectory(backup, to: destination, pinned: pinned)
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    if record.hadOriginal {
      guard [.prepared, .movingOriginal].contains(record.phase), destinationExists else {
        throw CLIUsageError("incomplete temporary workflow recovery cannot prove the prior entry for '\(workflowId)'")
      }
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    guard !destinationExists else {
      throw CLIUsageError("ambiguous fresh temporary workflow recovery state for '\(workflowId)'")
    }
    if stagingExists { try removeArtifact(staging, pinned: pinned) }
    try removeRecord(recordURL, pinned: pinned)
  }

  private func validate(
    _ record: WorkflowTemporaryRegistryTransaction,
    expectedWorkflowId: String
  ) throws {
    try validateWorkflowId(record.workflowId)
    let canonicalTransactionId = UUID(uuidString: record.transactionId)?.uuidString.lowercased()
    let destination = root.appendingPathComponent(record.workflowId, isDirectory: true)
    let staging = stagingRoot.appendingPathComponent(record.transactionId, isDirectory: true)
    let backup = backupsRoot
      .appendingPathComponent(record.workflowId, isDirectory: true)
      .appendingPathComponent(record.transactionId, isDirectory: true)
    guard record.schemaVersion == 1,
          record.workflowId == expectedWorkflowId,
          canonicalTransactionId == record.transactionId,
          record.destinationPath == record.workflowId,
          record.stagingPath == "\(Self.reservedStateName)/staging/\(record.transactionId)",
          record.backupPath == (record.hadOriginal
            ? "\(Self.reservedStateName)/backups/\(record.workflowId)/\(record.transactionId)"
            : nil),
          isCanonicalSHA256(record.replacementDigest) else {
      throw CLIUsageError("temporary workflow transaction record does not match its registry key")
    }
    try validateRelativePath(
      record.destinationPath,
      expected: destination,
      under: root,
      label: "destination"
    )
    try validateRelativePath(
      record.stagingPath,
      expected: staging,
      under: stagingRoot,
      label: "staging"
    )
    if let backupPath = record.backupPath {
      try validateRelativePath(
        backupPath,
        expected: backup,
        under: backupsRoot,
        label: "backup"
      )
    }
  }

  private func publish(
    _ record: WorkflowTemporaryRegistryTransaction,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    let bytes = try JSONEncoder().encode(record)
    let staged = recordStagingRoot.appendingPathComponent("\(record.transactionId).json")
    try writeNewRegularFile(bytes, to: staged, pinned: pinned)
    let active = transactionsRoot.appendingPathComponent("\(record.workflowId).json")
    try renameItem(staged, to: active, pinned: pinned)
  }

  private func finish(
    _ record: WorkflowTemporaryRegistryTransaction,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    if let backupPath = record.backupPath {
      let backup = root.appendingPathComponent(backupPath, isDirectory: true)
      if try realDirectoryExists(
        backup,
        under: backupsRoot,
        label: "temporary workflow backup artifact",
        pinned: pinned
      ) {
        try removeArtifact(backup, pinned: pinned)
      }
    }
    try removeRecord(
      transactionsRoot.appendingPathComponent("\(record.workflowId).json"),
      pinned: pinned
    )
  }

  private func validateRelativePath(
    _ relative: String,
    expected: URL,
    under subtree: URL,
    label: String
  ) throws {
    let resolved = root.appendingPathComponent(relative).standardizedFileURL
    guard !relative.hasPrefix("/"),
          isContained(resolved, in: subtree.standardizedFileURL),
          resolved.path == expected.standardizedFileURL.path,
          relativePath(resolved) == relative else {
      throw CLIUsageError("temporary workflow transaction \(label) path is not normalized and contained")
    }
  }

  private func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
  }

  private func realDirectoryExists(
    _ url: URL,
    under base: URL,
    label: String,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws -> Bool {
    let base = base.standardizedFileURL
    let url = url.standardizedFileURL
    guard url != base, isContained(url, in: base) else {
      throw CLIUsageError("\(label) escaped its declared registry subtree")
    }
    guard try pinned.entryType(url) != nil else { return false }
    do {
      let descriptor = try pinned.openDirectory(relativePath(url))
      _ = close(descriptor)
      return true
    } catch {
      throw CLIUsageError("\(label) must be a real non-symbolic-link directory")
    }
  }

  private func readRegularFileIfPresent(
    _ url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws -> Data? {
    try pinned.readRegularIfPresent(url)
  }

  private func writeNewRegularFile(
    _ data: Data,
    to url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    try pinned.writeNewRegularFile(data, to: url)
  }

  private func removeRecord(
    _ record: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    if try registryItemExists(record, pinned: pinned) {
      try removeArtifact(record, pinned: pinned)
      try syncDirectory(record.deletingLastPathComponent(), pinned: pinned)
    }
  }

  private func removeArtifact(
    _ url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    guard isContained(url.standardizedFileURL, in: root), url.standardizedFileURL != root else {
      throw CLIUsageError("refusing to remove an artifact outside the temporary workflow registry")
    }
    try pinned.remove(url)
  }

  private func renameItem(
    _ source: URL,
    to destination: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    guard isContained(source, in: root), isContained(destination, in: root) else {
      throw CLIUsageError("temporary workflow registry rename escaped its root")
    }
    try pinned.rename(source, to: destination)
  }

  private func renameDirectory(
    _ source: URL,
    to destination: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    guard try pinned.entryType(source) == S_IFDIR else {
      throw CLIUsageError("temporary workflow registry rename source must be a real directory")
    }
    guard try pinned.entryType(destination) == nil else {
      throw CLIUsageError("temporary workflow registry rename destination must be absent")
    }
    try pinned.rename(source, to: destination)
  }

  private func syncDirectory(
    _ url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws {
    try pinned.syncDirectory(url)
  }

  private func registryItemExists(
    _ url: URL,
    pinned: WorkflowTemporaryRegistryPinnedRoot
  ) throws -> Bool {
    try pinned.entryType(url) != nil
  }

  private func pinnedRoot(create: Bool) throws -> WorkflowTemporaryRegistryPinnedRoot {
    try WorkflowTemporaryRegistryPinnedRoot(
      homeDirectory: URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(),
        isDirectory: true
      ),
      create: create
    )
  }

}

private extension WorkflowTemporaryRegistry {
  func relativePath(_ url: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
  }

  func isContained(_ candidate: URL, in container: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let containerPath = container.standardizedFileURL.path
    return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
  }
}
