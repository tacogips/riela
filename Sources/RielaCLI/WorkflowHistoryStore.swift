import Darwin
import Foundation
import RielaCore

public struct WorkflowSnapshotReference: Codable, Equatable, Sendable {
  public var snapshotId: String
  public var createdAt: Date
  public var bundleDigest: String
  public var sourceScope: WorkflowHistorySourceScope
  public var sourceKind: WorkflowHistorySourceKind
  public var packageName: String?
  public var packageVersion: String?
  public var workflowContractVersion: String?
  public var createdBySessionId: String?
  public var createdBeforeChangeSetId: String?
  public var createdBeforeRestoreId: String?
  public var retentionClass: String
  public var redactionStatus: String
  public var integrityAlgorithm: String
  public var complete: Bool
  public var integrityVerified: Bool
  public var mutationReferences: [String]
  public var restoreReferences: [String]
}

public struct WorkflowHistoryStore: Sendable {
  public let root: URL
  private let beforePublication: @Sendable () throws -> Void
  private let constructionHook: @Sendable (WorkflowHistoryConstructionBoundary) throws -> Void

  public init(root: URL) {
    self.root = root.standardizedFileURL
    beforePublication = {}
    constructionHook = { _ in }
  }

  init(
    root: URL,
    beforePublication: @escaping @Sendable () throws -> Void,
    constructionHook: @escaping @Sendable (WorkflowHistoryConstructionBoundary) throws -> Void = { _ in }
  ) {
    self.root = root.standardizedFileURL
    self.beforePublication = beforePublication
    self.constructionHook = constructionHook
  }

  public func createSnapshot(
    inventory: WorkflowBundleInventory,
    snapshotId requestedId: String? = nil,
    createdBySessionId: String? = nil,
    createdBeforeChangeSetId: String? = nil,
    createdBeforeRestoreId: String? = nil,
    now: Date = Date()
  ) throws -> WorkflowBundleSnapshotManifest {
    let pinnedRoot = try WorkflowHistoryPinnedRoot(root)
    let snapshotId = requestedId ?? "snapshot-\(UUID().uuidString.lowercased())"
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(snapshotId)
    let snapshots = try contained(root.appendingPathComponent("snapshots", isDirectory: true))
    let destination = try contained(snapshots.appendingPathComponent(snapshotId, isDirectory: true))
    let artifact = try WorkflowHistoryPrivateDirectory(parent: snapshots, pinnedRoot: pinnedRoot)
    do {
      try artifact.ensureDirectory("objects/sha256")
      try constructionHook(.childDirectory)
      for file in inventory.files {
        let source = try WorkflowDescriptorRelativeReader.read(
          file.url,
          within: file.readRoot
        )
        guard source.bytes == file.bytes,
              WorkflowHistoryCanonicalCoding.sha256(source.bytes) == file.metadata.contentDigest,
              source.bytes.count == file.metadata.byteCount,
              source.executable == file.metadata.executable else {
          throw CLIUsageError("workflow file changed after inventory: \(file.metadata.relativePath)")
        }
        try writeObject(bytes: source.bytes, digest: file.metadata.contentDigest, artifact: artifact)
      }
      let manifest = WorkflowBundleSnapshotManifest(
        snapshotId: snapshotId,
        target: inventory.target,
        createdBySessionId: createdBySessionId,
        createdBeforeChangeSetId: createdBeforeChangeSetId,
        createdBeforeRestoreId: createdBeforeRestoreId,
        createdAt: now,
        bundleDigest: inventory.bundleDigest,
        files: inventory.files.map(\.metadata)
      )
      try WorkflowHistoryCanonicalCoding.validate(manifest)
      let bytes = try WorkflowHistoryCanonicalCoding.encode(manifest)
      try artifact.write(bytes, to: "manifest.json")
      let sidecar = WorkflowHistoryCanonicalCoding.sha256(bytes) + "\n"
      try artifact.write(Data(sidecar.utf8), to: "manifest.sha256")
      try constructionHook(.leafFile)
      try constructionHook(.beforeVerification)
      _ = try verifySnapshot(artifact: artifact, expectedIdentity: inventory.target, expectedSnapshotId: snapshotId)
      try artifact.syncAndMakeImmutable()
      _ = try verifySnapshot(
        artifact: artifact,
        expectedIdentity: inventory.target,
        expectedSnapshotId: snapshotId,
        requireImmutable: true
      )
      try beforePublication()
      try artifact.publish(to: destination, pinnedRoot: pinnedRoot)
      return try verifySnapshot(at: destination, expectedIdentity: inventory.target, expectedSnapshotId: snapshotId)
    } catch {
      try? artifact.remove()
      throw error
    }
  }

  public func list(expectedIdentity: WorkflowBundleIdentity) throws -> [WorkflowSnapshotReference] {
    let snapshots = try contained(root.appendingPathComponent("snapshots", isDirectory: true))
    guard FileManager.default.fileExists(atPath: snapshots.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)
      .filter { !$0.lastPathComponent.hasPrefix(".") }
      .map { url in
        try WorkflowHistoryCanonicalCoding.validateSafeComponent(url.lastPathComponent)
        let manifest = try verifySnapshot(at: try contained(url), expectedIdentity: expectedIdentity)
        return WorkflowSnapshotReference(
          snapshotId: manifest.snapshotId,
          createdAt: manifest.createdAt,
          bundleDigest: manifest.bundleDigest,
          sourceScope: manifest.target.sourceScope,
          sourceKind: manifest.target.sourceKind,
          packageName: manifest.target.packageName,
          packageVersion: manifest.target.packageVersion,
          workflowContractVersion: manifest.target.workflowContractVersion,
          createdBySessionId: manifest.createdBySessionId,
          createdBeforeChangeSetId: manifest.createdBeforeChangeSetId,
          createdBeforeRestoreId: manifest.createdBeforeRestoreId,
          retentionClass: manifest.retentionClass,
          redactionStatus: manifest.redactionStatus,
          integrityAlgorithm: manifest.integrityAlgorithm,
          complete: manifest.complete,
          integrityVerified: true,
          mutationReferences: [],
          restoreReferences: []
        )
      }
      .sorted { lhs, rhs in
        lhs.createdAt == rhs.createdAt ? lhs.snapshotId > rhs.snapshotId : lhs.createdAt > rhs.createdAt
      }
  }

  public func loadSnapshot(_ snapshotId: String, expectedIdentity: WorkflowBundleIdentity) throws -> WorkflowBundleSnapshotManifest {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(snapshotId)
    let url = root.appendingPathComponent("snapshots/\(snapshotId)", isDirectory: true)
    return try verifySnapshot(at: contained(url), expectedIdentity: expectedIdentity)
  }

  public func objectBytes(digest: String, snapshotId: String) throws -> Data {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(snapshotId)
    try WorkflowHistoryCanonicalCoding.validateDigest(digest)
    let url = root.appendingPathComponent("snapshots/\(snapshotId)/objects/sha256/\(digest.prefix(2))/\(digest)")
    return try verifiedRegularFile(at: contained(url), digest: digest, requireImmutable: true)
  }

  public func restoreSnapshot(
    _ manifest: WorkflowBundleSnapshotManifest,
    to stagingRoot: URL
  ) throws {
    for file in manifest.files where !WorkflowSharedNodeDependencyInventory.isDependencyPath(file.relativePath) {
      let destination = stagingRoot.appendingPathComponent(file.relativePath)
      guard WorkflowHistoryIdentityResolver.contained(destination.standardizedFileURL, in: stagingRoot.standardizedFileURL) else {
        throw CLIUsageError("snapshot path escapes staging root: \(file.relativePath)")
      }
      try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try objectBytes(digest: file.contentDigest, snapshotId: manifest.snapshotId).write(to: destination, options: .withoutOverwriting)
      let permissions = file.executable ? 0o755 : 0o644
      try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
    }
  }

  private func verifySnapshot(
    at directory: URL,
    expectedIdentity: WorkflowBundleIdentity,
    expectedSnapshotId: String? = nil
  ) throws -> WorkflowBundleSnapshotManifest {
    let manifestURL = try contained(directory.appendingPathComponent("manifest.json"))
    let sidecarURL = try contained(directory.appendingPathComponent("manifest.sha256"))
    let requireImmutable = expectedSnapshotId == nil || directory.lastPathComponent == expectedSnapshotId
      && !directory.lastPathComponent.hasPrefix(".tmp-")
    let bytes = try verifiedRegularFile(at: manifestURL, requireImmutable: requireImmutable)
    let expectedSidecar = WorkflowHistoryCanonicalCoding.sha256(bytes) + "\n"
    let sidecar = try verifiedRegularFile(at: sidecarURL, requireImmutable: requireImmutable)
    guard sidecar == Data(expectedSidecar.utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let manifest = try WorkflowHistoryCanonicalCoding.decode(WorkflowBundleSnapshotManifest.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(manifest)
    guard manifest.target == expectedIdentity,
          manifest.snapshotId == (expectedSnapshotId ?? directory.lastPathComponent) else {
      throw CLIUsageError("snapshot identity does not match the resolved workflow")
    }
    var expectedFiles: Set<String> = ["manifest.json", "manifest.sha256"]
    for file in manifest.files {
      let objectURL = directory.appendingPathComponent("objects/sha256/\(file.contentDigest.prefix(2))/\(file.contentDigest)")
      let object = try verifiedRegularFile(
        at: contained(objectURL),
        digest: file.contentDigest,
        requireImmutable: requireImmutable
      )
      expectedFiles.insert("objects/sha256/\(file.contentDigest.prefix(2))/\(file.contentDigest)")
      guard object.count == file.byteCount else {
        throw CLIUsageError("snapshot object byte count mismatch for \(file.relativePath)")
      }
    }
    try WorkflowHistoryTopologyValidator.validate(
      directory: directory,
      historyRoot: root,
      expectedFiles: expectedFiles,
      expectedDirectories: WorkflowHistoryTopologyValidator.canonicalDirectories(
        forFiles: expectedFiles,
        required: ["objects", "objects/sha256"]
      ),
      requireNonWritable: requireImmutable
    )
    let digest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: manifest.target, files: manifest.files)
    guard digest == manifest.bundleDigest else { throw WorkflowHistoryValidationError.integrityMismatch }
    return manifest
  }

  private func writeObject(
    bytes: Data,
    digest: String,
    artifact: WorkflowHistoryPrivateDirectory
  ) throws {
    try WorkflowHistoryCanonicalCoding.validateDigest(digest)
    guard WorkflowHistoryCanonicalCoding.sha256(bytes) == digest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let relative = "objects/sha256/\(digest.prefix(2))/\(digest)"
    if try artifact.entryExists(relative) {
      guard try artifact.read(relative) == bytes else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
      return
    }
    try artifact.write(bytes, to: relative)
  }

  private func verifySnapshot(
    artifact: WorkflowHistoryPrivateDirectory,
    expectedIdentity: WorkflowBundleIdentity,
    expectedSnapshotId: String,
    requireImmutable: Bool = false
  ) throws -> WorkflowBundleSnapshotManifest {
    let bytes = try artifact.read("manifest.json", requireNonWritable: requireImmutable)
    let sidecar = try artifact.read("manifest.sha256", requireNonWritable: requireImmutable)
    guard sidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let manifest = try WorkflowHistoryCanonicalCoding.decode(WorkflowBundleSnapshotManifest.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(manifest)
    guard manifest.target == expectedIdentity, manifest.snapshotId == expectedSnapshotId else {
      throw CLIUsageError("snapshot identity does not match the resolved workflow")
    }
    var expectedFiles: Set<String> = ["manifest.json", "manifest.sha256"]
    for file in manifest.files {
      let relative = "objects/sha256/\(file.contentDigest.prefix(2))/\(file.contentDigest)"
      let object = try artifact.read(relative, requireNonWritable: requireImmutable)
      guard WorkflowHistoryCanonicalCoding.sha256(object) == file.contentDigest,
            object.count == file.byteCount else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
      expectedFiles.insert(relative)
    }
    try artifact.verifyTopology(
      files: expectedFiles,
      directories: WorkflowHistoryTopologyValidator.canonicalDirectories(
        forFiles: expectedFiles,
        required: ["objects", "objects/sha256"]
      ),
      requireNonWritable: requireImmutable
    )
    guard try WorkflowHistoryCanonicalCoding.bundleDigest(target: manifest.target, files: manifest.files)
      == manifest.bundleDigest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return manifest
  }

  private func contained(_ url: URL) throws -> URL {
    let lexicalRoot = root.standardizedFileURL.path
    let lexicalURL = url.standardizedFileURL
    guard lexicalURL.path == lexicalRoot || lexicalURL.path.hasPrefix(lexicalRoot + "/") else {
      throw CLIUsageError("workflow history path escapes selected root")
    }
    let existingAncestor = nearestExistingAncestor(of: lexicalURL)
    let rootAncestor = nearestExistingAncestor(of: root)
    guard existingAncestor == rootAncestor || WorkflowHistoryIdentityResolver.contained(existingAncestor, in: root) else {
      throw CLIUsageError("workflow history path escapes selected root through a symbolic link")
    }
    return lexicalURL
  }

  private func nearestExistingAncestor(of url: URL) -> URL {
    var current = url
    while !FileManager.default.fileExists(atPath: current.path), current.path != "/" {
      current.deleteLastPathComponent()
    }
    return current.resolvingSymlinksInPath().standardizedFileURL
  }

  private func verifiedRegularFile(
    at url: URL,
    digest: String? = nil,
    requireImmutable: Bool = false
  ) throws -> Data {
    let read = try WorkflowDescriptorRelativeReader.read(url, within: root)
    if requireImmutable, read.writable {
      throw CLIUsageError("workflow snapshot artifact is mutable: \(url.path)")
    }
    let bytes = read.bytes
    if let digest, WorkflowHistoryCanonicalCoding.sha256(bytes) != digest {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return bytes
  }

  private func makeImmutable(_ directory: URL) throws {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate workflow snapshot entry \(url.path): \(error)")
        return false
      }
    ) else { throw CLIUsageError("unable to enumerate workflow snapshot for publication") }
    var directories = [directory]
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      if values.isDirectory == true {
        directories.append(url)
      } else {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
      }
    }
    if let enumerationError { throw enumerationError }
    for url in directories.reversed() {
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
    }
  }

  private func syncTree(_ directory: URL) throws {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate workflow snapshot entry \(url.path): \(error)")
        return false
      }
    ) else { throw CLIUsageError("unable to enumerate workflow snapshot for fsync") }
    var directories = [directory]
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(url)
      } else {
        try sync(url)
      }
    }
    if let enumerationError { throw enumerationError }
    for url in directories.reversed() { try syncDirectory(url) }
  }

  private func sync(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open snapshot artifact for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync snapshot artifact: \(url.path)") }
  }

  private func syncDirectory(_ url: URL) throws {
    try sync(url)
  }
}
