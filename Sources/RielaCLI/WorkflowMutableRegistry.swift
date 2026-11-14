#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public struct WorkflowMutableRegistry: Sendable {
  public static let reservedStateName = ".registry-state"
  static let coordinatorCatalogKey = "riela.workflow-registry.catalog-lock"
  static let coordinatorOriginsKey = "riela.workflow-registry.origin-locks"

  let hooks: WorkflowMutableRegistryHooks

  public init(hooks: WorkflowMutableRegistryHooks = WorkflowMutableRegistryHooks()) {
    self.hooks = hooks
  }

  var root: URL {
    URL(fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(), isDirectory: true)
      .appendingPathComponent(".riela", isDirectory: true)
      .appendingPathComponent("temporary-workflows", isDirectory: true)
      .standardizedFileURL
  }

  var stateRoot: URL { root.appendingPathComponent(Self.reservedStateName, isDirectory: true) }
  var locksRoot: URL { stateRoot.appendingPathComponent("locks", isDirectory: true) }
  var transactionsRoot: URL { stateRoot.appendingPathComponent("transactions", isDirectory: true) }
  private var recordStagingRoot: URL { stateRoot.appendingPathComponent("record-staging", isDirectory: true) }
  var stagingRoot: URL { stateRoot.appendingPathComponent("staging", isDirectory: true) }
  var backupsRoot: URL { stateRoot.appendingPathComponent("backups", isDirectory: true) }
  private var catalogLockURL: URL { stateRoot.appendingPathComponent("catalog.lock") }

  func replaceLocked(
    workflowId: String,
    input: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
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
      let candidate = try loadCandidateBundle(
        at: staging,
        expectedWorkflowId: workflowId,
        pinned: pinned
      )
      let loaded = candidate.bundle
      let diagnostics = loaded.diagnostics
        + DefaultWorkflowValidator().validate(loaded.workflow, nodePayloads: loaded.nodePayloads)
      guard !diagnostics.contains(where: { $0.severity == .error }) else {
        throw WorkflowResolutionError.invalidWorkflow(diagnostics)
      }
      let replacementDigest = candidate.registryDigest
      var record = WorkflowMutableRegistryTransaction(
        schemaVersion: 1,
        workflowId: workflowId,
        transactionId: transactionId,
        phase: .prepared,
        hadOriginal: true,
        replacementDigest: replacementDigest,
        destinationPath: workflowId,
        stagingPath: relativePath(staging),
        backupPath: relativePath(backup),
        operation: .replace,
        requestedActivationState: nil
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
          throw CLIUsageError("mutable workflow mutation publication digest verification failed")
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
          throw WorkflowMutableRegistryRecoveryFailure(
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

  func ensureLayout(pinned: WorkflowMutableRegistryPinnedRoot) throws {
    for directory in [stateRoot, locksRoot, transactionsRoot, recordStagingRoot, stagingRoot, backupsRoot] {
      try pinned.ensureDirectory(directory)
    }
    try createLockFileIfNeeded(catalogLockURL, pinned: pinned)
  }

  func existingPinnedRoot() throws -> WorkflowMutableRegistryPinnedRoot? {
    do {
      return try pinnedRoot(create: false)
    } catch is WorkflowMutableRegistryRootAbsent {
      return nil
    }
  }

  func validateExistingLayout(pinned: WorkflowMutableRegistryPinnedRoot) throws {
    guard try pinned.entryType(stateRoot) == S_IFDIR else {
      throw CLIUsageError("mutable workflow registry state layout is incomplete: \(stateRoot.path)")
    }
    for directory in [locksRoot, transactionsRoot, recordStagingRoot, stagingRoot, backupsRoot] {
      guard try pinned.entryType(directory) == S_IFDIR else {
        throw CLIUsageError("mutable workflow registry state layout is incomplete: \(directory.path)")
      }
    }
    guard try pinned.entryType(catalogLockURL) == S_IFREG else {
      throw CLIUsageError("mutable workflow registry catalog lock is missing or malformed")
    }
  }

  private func createLockFileIfNeeded(
    _ url: URL,
    pinned: WorkflowMutableRegistryPinnedRoot? = nil
  ) throws {
    let descriptor = try (pinned ?? pinnedRoot(create: false)).openRegularFile(
      url,
      flags: O_RDWR | O_CREAT
    )
    guard descriptor >= 0 else {
      throw CLIUsageError("mutable workflow registry lock must be a regular non-symbolic-link file")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("mutable workflow registry lock has unexpected type")
    }
  }

  func createRealDirectory(
    _ directory: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    try pinned.ensureDirectory(directory)
  }

  func validateWorkflowId(_ workflowId: String) throws {
    guard workflowId != Self.reservedStateName, isSafeScopedWorkflowName(workflowId) else {
      throw CLIUsageError("unsafe mutable workflowId '\(workflowId)'")
    }
  }

  func copyInput(
    _ input: URL,
    to staging: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    var status = stat()
    guard lstat(input.path, &status) == 0 else {
      throw CLIUsageError("mutable workflow registration input not found: \(input.path)")
    }
    let kind = status.st_mode & S_IFMT
    guard kind == S_IFREG || kind == S_IFDIR else {
      throw CLIUsageError("mutable workflow registration input must be a regular JSON file or real directory")
    }
    guard let resolvedPointer = input.path.withCString({ realpath($0, nil) }) else {
      throw CLIUsageError("unable to resolve mutable workflow registration input")
    }
    defer { free(resolvedPointer) }
    let sourceRoot = URL(
      fileURLWithPath: String(cString: resolvedPointer),
      isDirectory: kind == S_IFDIR
    ).standardizedFileURL
    try createRealDirectory(staging, pinned: pinned)
    if kind == S_IFREG {
      guard input.pathExtension.lowercased() == "json" else {
        throw CLIUsageError("mutable workflow file input must be JSON")
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
      throw CLIUsageError("mutable workflow bundle must contain a regular root workflow.json")
    }
    guard let enumerator = FileManager.default.enumerator(atPath: sourceRoot.path) else {
      throw CLIUsageError("unable to enumerate mutable workflow bundle")
    }
    for case let relative as String in enumerator {
      let source = sourceRoot.appendingPathComponent(relative)
      var entryStatus = stat()
      guard lstat(source.path, &entryStatus) == 0 else {
        throw CLIUsageError("mutable workflow bundle entry disappeared: \(source.path)")
      }
      let entryKind = entryStatus.st_mode & S_IFMT
      guard entryKind == S_IFREG || entryKind == S_IFDIR else {
        throw CLIUsageError("mutable workflow bundle contains a linked or special entry: \(source.path)")
      }
      guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else {
        throw CLIUsageError("mutable workflow bundle entry escapes its input root")
      }
      let destination = staging.appendingPathComponent(relative, isDirectory: entryKind == S_IFDIR)
      guard isContained(destination, in: staging) else {
        throw CLIUsageError("mutable workflow bundle entry escapes staging")
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
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    let sourceDescriptor = open(source.path, O_RDONLY | O_NOFOLLOW)
    guard sourceDescriptor >= 0 else {
      throw CLIUsageError("mutable workflow bundle file is linked, missing, or unreadable")
    }
    defer { _ = close(sourceDescriptor) }
    var status = stat()
    guard fstat(sourceDescriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("mutable workflow bundle entry changed type during copy")
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
    pinned: WorkflowMutableRegistryPinnedRoot
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

  func withCatalogLock<T>(
    pinned: WorkflowMutableRegistryPinnedRoot,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    if Thread.current.threadDictionary[Self.coordinatorCatalogKey] as? Bool == true {
      return try body()
    }
    return try withFileLock(
      pinned: pinned,
      catalogLockURL,
      lock: .catalog,
      createIfMissing: createIfMissing,
      body
    )
  }

  func withWorkflowLock<T>(
    pinned: WorkflowMutableRegistryPinnedRoot,
    workflowId: String,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    if (Thread.current.threadDictionary[Self.coordinatorOriginsKey] as? Set<String>)?.contains(workflowId) == true {
      return try body()
    }
    return try withFileLock(
      pinned: pinned,
      locksRoot.appendingPathComponent(originLockName(workflowId: workflowId)),
      lock: .workflow(workflowId),
      createIfMissing: createIfMissing,
      body
    )
  }

  func originLockName(workflowId: String) -> String {
    originLockName(originId: mutableOriginId(workflowId))
  }

  func mutableOriginId(_ workflowId: String) -> String {
    workflowOriginIdentity(
      name: workflowId,
      workflowId: workflowId,
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      locator: root.appendingPathComponent(workflowId, isDirectory: true).path
    ).originId
  }

  func originLockName(originId: String) -> String {
    "\(WorkflowHistoryCanonicalCoding.sha256(Data(originId.utf8))).lock"
  }

  func withFileLock<T>(
    pinned: WorkflowMutableRegistryPinnedRoot,
    _ url: URL,
    lock: WorkflowMutableRegistryLock,
    createIfMissing: Bool,
    _ body: () throws -> T
  ) throws -> T {
    let flags = O_RDWR | O_NOFOLLOW | (createIfMissing ? O_CREAT : 0)
    let descriptor = try pinned.openRegularFile(url, flags: flags)
    guard descriptor >= 0 else {
      throw CLIUsageError("mutable workflow registry lock must be a regular non-symbolic-link file")
    }
    defer { _ = close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
      throw CLIUsageError("mutable workflow registry lock has unexpected type")
    }
    try hooks.beforeLockAcquire(lock)
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw CLIUsageError("unable to acquire mutable workflow registry lock")
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

  func recoverAllLocked(pinned: WorkflowMutableRegistryPinnedRoot) throws {
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

  func recoverLocked(
    pinned: WorkflowMutableRegistryPinnedRoot,
    workflowId: String
  ) throws {
    let recordURL = transactionsRoot.appendingPathComponent("\(workflowId).json")
    try hooks.beforeRecordRead(workflowId)
    try pinned.requireConfiguredPathIdentity()
    guard let recordData = try readRegularFileIfPresent(recordURL, pinned: pinned) else { return }
    let record = try JSONDecoder().decode(
      WorkflowMutableRegistryTransaction.self,
      from: recordData
    )
    try validate(record, expectedWorkflowId: workflowId)
    let destination = root.appendingPathComponent(record.destinationPath, isDirectory: true)
    let staging = root.appendingPathComponent(record.stagingPath, isDirectory: true)
    let backup = record.backupPath.map { root.appendingPathComponent($0, isDirectory: true) }
    let destinationExists = try realDirectoryExists(
      destination,
      under: root,
      label: "mutable workflow destination",
      pinned: pinned
    )
    let stagingExists = try realDirectoryExists(
      staging,
      under: stagingRoot,
      label: "mutable workflow staging artifact",
      pinned: pinned
    )
    let backupExists = try backup.map {
      try realDirectoryExists(
        $0,
        under: backupsRoot,
        label: "mutable workflow backup artifact",
        pinned: pinned
      )
    } ?? false
    if record.operation == .delete {
      try recoverDeletion(
        record,
        recordURL: recordURL,
        destination: destination,
        staging: staging,
        backup: backup,
        destinationExists: destinationExists,
        stagingExists: stagingExists,
        backupExists: backupExists,
        pinned: pinned
      )
      return
    }
    let replacementPresent: Bool
    if destinationExists {
      replacementPresent = try bundleDigest(at: destination, pinned: pinned) == record.replacementDigest
    } else {
      replacementPresent = false
    }
    if replacementPresent {
      try applyRequestedActivation(record)
      if backupExists, let backup { try removeArtifact(backup, pinned: pinned) }
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    if backupExists, let backup {
      guard !destinationExists else {
        throw CLIUsageError("ambiguous mutable workflow recovery state for '\(workflowId)'")
      }
      try renameDirectory(backup, to: destination, pinned: pinned)
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    if record.hadOriginal {
      guard [.prepared, .movingOriginal].contains(record.phase), destinationExists else {
        throw CLIUsageError("incomplete mutable workflow recovery cannot prove the prior entry for '\(workflowId)'")
      }
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    guard !destinationExists else {
      throw CLIUsageError("ambiguous fresh mutable workflow recovery state for '\(workflowId)'")
    }
    if stagingExists { try removeArtifact(staging, pinned: pinned) }
    try removeRecord(recordURL, pinned: pinned)
  }

  private func recoverDeletion(
    _ record: WorkflowMutableRegistryTransaction,
    recordURL: URL,
    destination: URL,
    staging: URL,
    backup: URL?,
    destinationExists: Bool,
    stagingExists: Bool,
    backupExists: Bool,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    if record.phase == .replacementPublished {
      guard !destinationExists else {
        throw CLIUsageError("ambiguous committed mutable deletion for '\(record.workflowId)'")
      }
      try removeActivationForCommittedDeletion(workflowId: record.workflowId)
      if backupExists, let backup { try removeArtifact(backup, pinned: pinned) }
      if stagingExists { try removeArtifact(staging, pinned: pinned) }
      try removeRecord(recordURL, pinned: pinned)
      return
    }
    if backupExists, let backup {
      guard !destinationExists else {
        throw CLIUsageError("ambiguous mutable deletion recovery for '\(record.workflowId)'")
      }
      try renameDirectory(backup, to: destination, pinned: pinned)
    } else if !destinationExists {
      throw CLIUsageError("mutable deletion recovery cannot prove the prior entry for '\(record.workflowId)'")
    }
    if stagingExists { try removeArtifact(staging, pinned: pinned) }
    try removeRecord(recordURL, pinned: pinned)
  }

  func removeActivationForCommittedDeletion(workflowId: String) throws {
    guard WorkflowActivationStore.coordinatorLockHeld else { return }
    let origin = WorkflowOriginIdentity(
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      name: workflowId,
      workflowId: workflowId,
      canonicalLocator: root.appendingPathComponent(workflowId, isDirectory: true).path
    )
    try WorkflowActivationStore().remove(origin: origin)
  }

  func applyRequestedActivation(_ record: WorkflowMutableRegistryTransaction) throws {
    guard let activationState = record.requestedActivationState else { return }
    guard WorkflowActivationStore.coordinatorLockHeld else {
      throw WorkflowRegistryError(
        code: .registryIOFailure,
        message: "mutable workflow activation recovery requires the registry coordinator"
      )
    }
    let origin = WorkflowOriginIdentity(
      scope: .user,
      sourceKind: .workflow,
      provenance: .mutable,
      name: record.workflowId,
      workflowId: record.workflowId,
      canonicalLocator: root.appendingPathComponent(record.workflowId, isDirectory: true).path
    )
    try WorkflowActivationStore().set(activationState, for: origin)
  }

  private func validate(
    _ record: WorkflowMutableRegistryTransaction,
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
      throw CLIUsageError("mutable workflow transaction record does not match its registry key")
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

  func publish(
    _ record: WorkflowMutableRegistryTransaction,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    let bytes = try JSONEncoder().encode(record)
    let staged = recordStagingRoot.appendingPathComponent("\(record.transactionId).json")
    try writeNewRegularFile(bytes, to: staged, pinned: pinned)
    let active = transactionsRoot.appendingPathComponent("\(record.workflowId).json")
    try renameItem(staged, to: active, pinned: pinned)
  }

  func finish(
    _ record: WorkflowMutableRegistryTransaction,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    if let backupPath = record.backupPath {
      let backup = root.appendingPathComponent(backupPath, isDirectory: true)
      if try realDirectoryExists(
        backup,
        under: backupsRoot,
        label: "mutable workflow backup artifact",
        pinned: pinned
      ) {
        try removeArtifact(backup, pinned: pinned)
      }
    }
    let staging = root.appendingPathComponent(record.stagingPath, isDirectory: true)
    if try realDirectoryExists(
      staging,
      under: stagingRoot,
      label: "mutable workflow staging artifact",
      pinned: pinned
    ) {
      try removeArtifact(staging, pinned: pinned)
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
      throw CLIUsageError("mutable workflow transaction \(label) path is not normalized and contained")
    }
  }

  private func isCanonicalSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
        || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
    }
  }

  func realDirectoryExists(
    _ url: URL,
    under base: URL,
    label: String,
    pinned: WorkflowMutableRegistryPinnedRoot
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
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> Data? {
    try pinned.readRegularIfPresent(url)
  }

  private func writeNewRegularFile(
    _ data: Data,
    to url: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    try pinned.writeNewRegularFile(data, to: url)
  }

  private func removeRecord(
    _ record: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    if try registryItemExists(record, pinned: pinned) {
      try removeArtifact(record, pinned: pinned)
      try syncDirectory(record.deletingLastPathComponent(), pinned: pinned)
    }
  }

  func removeArtifact(
    _ url: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    guard isContained(url.standardizedFileURL, in: root), url.standardizedFileURL != root else {
      throw CLIUsageError("refusing to remove an artifact outside the mutable workflow registry")
    }
    try pinned.remove(url)
  }

  private func renameItem(
    _ source: URL,
    to destination: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    guard isContained(source, in: root), isContained(destination, in: root) else {
      throw CLIUsageError("mutable workflow registry rename escaped its root")
    }
    try pinned.rename(source, to: destination)
  }

  func renameDirectory(
    _ source: URL,
    to destination: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    guard try pinned.entryType(source) == S_IFDIR else {
      throw CLIUsageError("mutable workflow registry rename source must be a real directory")
    }
    guard try pinned.entryType(destination) == nil else {
      throw CLIUsageError("mutable workflow registry rename destination must be absent")
    }
    try pinned.rename(source, to: destination)
  }

  private func syncDirectory(
    _ url: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws {
    try pinned.syncDirectory(url)
  }

  func registryItemExists(
    _ url: URL,
    pinned: WorkflowMutableRegistryPinnedRoot
  ) throws -> Bool {
    try pinned.entryType(url) != nil
  }

  func pinnedRoot(create: Bool) throws -> WorkflowMutableRegistryPinnedRoot {
    try WorkflowMutableRegistryPinnedRoot(
      homeDirectory: URL(
        fileURLWithPath: CLIRuntimeEnvironment.homeDirectory(),
        isDirectory: true
      ),
      create: create
    )
  }

}

extension WorkflowMutableRegistry {
  func relativePath(_ url: URL) -> String {
    String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
  }

  func isContained(_ candidate: URL, in container: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let containerPath = container.standardizedFileURL.path
    return candidatePath == containerPath || candidatePath.hasPrefix(containerPath + "/")
  }
}
