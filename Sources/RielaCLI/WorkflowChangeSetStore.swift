#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import RielaCore

public struct WorkflowChangeSetStore: Sendable {
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

  public func publishProposal(
    _ proposal: WorkflowChangeProposal,
    contentObjects: [String: Data]
  ) throws {
    try WorkflowHistoryCanonicalCoding.validate(proposal)
    let current = try WorkflowHistoryIdentityResolver.inventory(for: proposal.target)
    guard current.bundleDigest == proposal.beforeBundleDigest else {
      throw CLIUsageError("proposal before bundle digest does not match the resolved workflow")
    }
    try verifyExpectedResult(proposal, current: current)
    let destination = root.appendingPathComponent("proposals/\(proposal.proposalId)", isDirectory: true)
    try publishImmutableDirectory(destination: destination) { artifact in
      try artifact.ensureDirectory("objects/sha256")
      try constructionHook(.childDirectory)
      let expectedDigests = Set(proposal.operations.compactMap { operation in
        operation.after?.contentDigest == operation.before?.contentDigest ? nil : operation.after?.contentDigest
      })
      guard Set(contentObjects.keys) == expectedDigests else {
        throw CLIUsageError("proposal content objects do not exactly match proposed operations")
      }
      for (digest, bytes) in contentObjects {
        try WorkflowHistoryCanonicalCoding.validateDigest(digest)
        guard WorkflowHistoryCanonicalCoding.sha256(bytes) == digest else {
          throw WorkflowHistoryValidationError.integrityMismatch
        }
        try artifact.write(bytes, to: "objects/sha256/\(digest.prefix(2))/\(digest)")
      }
      let bytes = try WorkflowHistoryCanonicalCoding.encode(proposal)
      try artifact.write(bytes, to: "proposal.json")
      try artifact.write(
        Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
        to: "proposal.sha256"
      )
      try constructionHook(.leafFile)
      try constructionHook(.beforeVerification)
      _ = try verifyProposal(
        artifact: artifact,
        expectedIdentity: proposal.target,
        expectedProposalId: proposal.proposalId
      )
    }
    let published = try loadProposal(proposal.proposalId, expectedIdentity: proposal.target)
    guard try WorkflowHistoryCanonicalCoding.encode(published)
      == WorkflowHistoryCanonicalCoding.encode(proposal) else {
      throw CLIUsageError("published proposal does not exactly match its canonical source value")
    }
  }

  public func loadProposal(_ proposalId: String, expectedIdentity: WorkflowBundleIdentity) throws -> WorkflowChangeProposal {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(proposalId)
    let directory = try contained(root.appendingPathComponent("proposals/\(proposalId)", isDirectory: true))
    return try verifyProposal(at: directory, expectedIdentity: expectedIdentity)
  }

  public func finalize(
    proposalId: String,
    expectedIdentity: WorkflowBundleIdentity,
    review: WorkflowChangeSetReviewEvidence,
    changeSetId requestedId: String? = nil,
    finalizedAt: Date = Date()
  ) throws -> WorkflowChangeSet {
    let proposal = try loadProposal(proposalId, expectedIdentity: expectedIdentity)
    guard review.decision == .accepted else {
      throw CLIUsageError("only accepted review evidence may finalize a workflow change set")
    }
    let changeSetId = requestedId ?? "change-set-\(UUID().uuidString.lowercased())"
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(changeSetId)
    var changeSet = WorkflowChangeSet(
      changeSetId: changeSetId,
      proposal: proposal,
      review: review,
      finalizedAt: finalizedAt,
      finalizedDigest: String(repeating: "0", count: 64)
    )
    changeSet.finalizedDigest = try WorkflowHistoryCanonicalCoding.finalizedDigest(changeSet)
    try WorkflowHistoryCanonicalCoding.validate(changeSet)
    let destination = root.appendingPathComponent("change-sets/\(changeSetId)", isDirectory: true)
    try publishImmutableDirectory(destination: destination) { artifact in
      let bytes = try WorkflowHistoryCanonicalCoding.encode(changeSet)
      try artifact.write(bytes, to: "change-set.json")
      try artifact.write(
        Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8),
        to: "change-set.sha256"
      )
      try constructionHook(.leafFile)
      try constructionHook(.beforeVerification)
      _ = try verifyChangeSet(
        artifact: artifact,
        expectedIdentity: expectedIdentity,
        expectedChangeSetId: changeSetId
      )
    }
    return try loadChangeSet(changeSetId, expectedIdentity: expectedIdentity)
  }

  public func loadChangeSet(_ changeSetId: String, expectedIdentity: WorkflowBundleIdentity) throws -> WorkflowChangeSet {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(changeSetId)
    let directory = try contained(root.appendingPathComponent("change-sets/\(changeSetId)", isDirectory: true))
    let bytes = try regularBytes(at: directory.appendingPathComponent("change-set.json"), requireImmutable: true)
    let sidecar = try regularBytes(at: directory.appendingPathComponent("change-set.sha256"), requireImmutable: true)
    guard sidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let changeSet = try WorkflowHistoryCanonicalCoding.decode(WorkflowChangeSet.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(changeSet)
    guard changeSet.changeSetId == changeSetId, changeSet.proposal.target == expectedIdentity else {
      throw CLIUsageError("change-set identity does not match the resolved workflow")
    }
    try WorkflowHistoryTopologyValidator.validate(
      directory: directory,
      historyRoot: root,
      expectedFiles: ["change-set.json", "change-set.sha256"],
      expectedDirectories: [],
      requireNonWritable: true
    )
    let persistedProposal = try loadProposal(changeSet.proposal.proposalId, expectedIdentity: expectedIdentity)
    guard persistedProposal == changeSet.proposal,
          try WorkflowHistoryCanonicalCoding.encode(persistedProposal)
            == WorkflowHistoryCanonicalCoding.encode(changeSet.proposal) else {
      throw CLIUsageError("change-set embedded proposal does not exactly match the referenced immutable proposal")
    }
    return changeSet
  }

  public func proposalObject(proposalId: String, digest: String) throws -> Data {
    try WorkflowHistoryCanonicalCoding.validateSafeComponent(proposalId)
    try WorkflowHistoryCanonicalCoding.validateDigest(digest)
    let url = root.appendingPathComponent("proposals/\(proposalId)/objects/sha256/\(digest.prefix(2))/\(digest)")
    let bytes = try regularBytes(at: contained(url), requireImmutable: true)
    guard WorkflowHistoryCanonicalCoding.sha256(bytes) == digest else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    return bytes
  }

  private func verifyProposal(
    at directory: URL,
    expectedIdentity: WorkflowBundleIdentity,
    expectedProposalId: String? = nil
  ) throws -> WorkflowChangeProposal {
    let requireImmutable = expectedProposalId == nil
    let bytes = try regularBytes(
      at: directory.appendingPathComponent("proposal.json"),
      requireImmutable: requireImmutable
    )
    let sidecar = try regularBytes(
      at: directory.appendingPathComponent("proposal.sha256"),
      requireImmutable: requireImmutable
    )
    guard sidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let proposal = try WorkflowHistoryCanonicalCoding.decode(WorkflowChangeProposal.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(proposal)
    guard proposal.proposalId == (expectedProposalId ?? directory.lastPathComponent), proposal.target == expectedIdentity else {
      throw CLIUsageError("proposal identity does not match the resolved workflow")
    }
    var expectedFiles: Set<String> = ["proposal.json", "proposal.sha256"]
    for operation in proposal.operations {
      guard let after = operation.after, after.contentDigest != operation.before?.contentDigest else { continue }
      let objectURL = directory.appendingPathComponent("objects/sha256/\(after.contentDigest.prefix(2))/\(after.contentDigest)")
      let object = try regularBytes(at: objectURL, requireImmutable: requireImmutable)
      expectedFiles.insert("objects/sha256/\(after.contentDigest.prefix(2))/\(after.contentDigest)")
      guard WorkflowHistoryCanonicalCoding.sha256(object) == after.contentDigest else {
        throw WorkflowHistoryValidationError.integrityMismatch
      }
      guard object.count == after.byteCount else {
        throw CLIUsageError("proposal object byte count mismatch for \(operation.relativePath)")
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
    return proposal
  }

  private func verifyExpectedResult(
    _ proposal: WorkflowChangeProposal,
    current: WorkflowBundleInventory
  ) throws {
    var files = Dictionary(uniqueKeysWithValues: current.files.map { ($0.metadata.relativePath, $0.metadata) })
    for operation in proposal.operations {
      let existing = files[operation.relativePath]
      guard existing.map({ WorkflowFileState($0) }) == operation.before else {
        throw CLIUsageError("proposal before state does not match owned file: \(operation.relativePath)")
      }
      switch operation.kind {
      case .create, .update, .executableBit:
        guard let after = operation.after else {
          throw CLIUsageError("proposal operation is missing after state")
        }
        files[operation.relativePath] = WorkflowBundleSnapshotFile(
          relativePath: operation.relativePath,
          contentDigest: after.contentDigest,
          byteCount: after.byteCount,
          artifactKind: after.artifactKind,
          executable: after.executable
        )
      case .delete:
        files.removeValue(forKey: operation.relativePath)
      }
    }
    let ordered = files.values.sorted {
      $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    let digest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: proposal.target, files: ordered)
    guard digest == proposal.expectedAfterBundleDigest else {
      throw CLIUsageError("proposal expected-after bundle digest does not match its operations")
    }
  }

  private func publishImmutableDirectory(
    destination: URL,
    writer: (WorkflowHistoryPrivateDirectory) throws -> Void
  ) throws {
    let pinnedRoot = try WorkflowHistoryPinnedRoot(root)
    let parent = try contained(destination.deletingLastPathComponent())
    let artifact = try WorkflowHistoryPrivateDirectory(parent: parent, pinnedRoot: pinnedRoot)
    do {
      try writer(artifact)
      try artifact.syncAndMakeImmutable()
      try beforePublication()
      try artifact.publish(to: destination, pinnedRoot: pinnedRoot)
    } catch {
      try? artifact.remove()
      throw error
    }
  }

  private func verifyProposal(
    artifact: WorkflowHistoryPrivateDirectory,
    expectedIdentity: WorkflowBundleIdentity,
    expectedProposalId: String,
    requireImmutable: Bool = false
  ) throws -> WorkflowChangeProposal {
    let bytes = try artifact.read("proposal.json", requireNonWritable: requireImmutable)
    let sidecar = try artifact.read("proposal.sha256", requireNonWritable: requireImmutable)
    guard sidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let proposal = try WorkflowHistoryCanonicalCoding.decode(WorkflowChangeProposal.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(proposal)
    guard proposal.proposalId == expectedProposalId, proposal.target == expectedIdentity else {
      throw CLIUsageError("proposal identity does not match the resolved workflow")
    }
    var expectedFiles: Set<String> = ["proposal.json", "proposal.sha256"]
    for operation in proposal.operations {
      guard let after = operation.after, after.contentDigest != operation.before?.contentDigest else { continue }
      let relative = "objects/sha256/\(after.contentDigest.prefix(2))/\(after.contentDigest)"
      let object = try artifact.read(relative, requireNonWritable: requireImmutable)
      guard WorkflowHistoryCanonicalCoding.sha256(object) == after.contentDigest,
            object.count == after.byteCount else {
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
    return proposal
  }

  private func verifyChangeSet(
    artifact: WorkflowHistoryPrivateDirectory,
    expectedIdentity: WorkflowBundleIdentity,
    expectedChangeSetId: String,
    requireImmutable: Bool = false
  ) throws -> WorkflowChangeSet {
    let bytes = try artifact.read("change-set.json", requireNonWritable: requireImmutable)
    let sidecar = try artifact.read("change-set.sha256", requireNonWritable: requireImmutable)
    guard sidecar == Data("\(WorkflowHistoryCanonicalCoding.sha256(bytes))\n".utf8) else {
      throw WorkflowHistoryValidationError.integrityMismatch
    }
    let changeSet = try WorkflowHistoryCanonicalCoding.decode(WorkflowChangeSet.self, from: bytes)
    try WorkflowHistoryCanonicalCoding.validate(changeSet)
    guard changeSet.changeSetId == expectedChangeSetId,
          changeSet.proposal.target == expectedIdentity else {
      throw CLIUsageError("change-set identity does not match the resolved workflow")
    }
    try artifact.verifyTopology(
      files: ["change-set.json", "change-set.sha256"],
      directories: [],
      requireNonWritable: requireImmutable
    )
    return changeSet
  }

  private func contained(_ url: URL) throws -> URL {
    let lexicalRoot = root.standardizedFileURL.path
    let lexicalURL = url.standardizedFileURL
    guard lexicalURL.path == lexicalRoot || lexicalURL.path.hasPrefix(lexicalRoot + "/") else {
      throw CLIUsageError("workflow history path escapes selected root")
    }
    var ancestor = lexicalURL
    while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
      ancestor.deleteLastPathComponent()
    }
    var rootAncestor = root
    while !FileManager.default.fileExists(atPath: rootAncestor.path), rootAncestor.path != "/" {
      rootAncestor.deleteLastPathComponent()
    }
    guard ancestor.resolvingSymlinksInPath().standardizedFileURL == rootAncestor.resolvingSymlinksInPath().standardizedFileURL
            || WorkflowHistoryIdentityResolver.contained(ancestor, in: root) else {
      throw CLIUsageError("workflow history path escapes selected root through a symbolic link")
    }
    return lexicalURL
  }

  private func regularBytes(at url: URL, requireImmutable: Bool = false) throws -> Data {
    let read = try WorkflowDescriptorRelativeReader.read(url, within: root)
    if requireImmutable, read.writable {
      throw CLIUsageError("workflow history artifact is mutable: \(url.path)")
    }
    return read.bytes
  }

  private func makeImmutable(_ directory: URL) throws {
    var enumerationError: Error?
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey],
      errorHandler: { url, error in
        enumerationError = CLIUsageError("unable to enumerate workflow history entry \(url.path): \(error)")
        return false
      }
    ) else { throw CLIUsageError("unable to enumerate workflow history artifact for publication") }
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
        enumerationError = CLIUsageError("unable to enumerate workflow history entry \(url.path): \(error)")
        return false
      }
    ) else { throw CLIUsageError("unable to enumerate workflow history artifact for fsync") }
    var directories = [directory]
    for case let url as URL in enumerator {
      if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        directories.append(url)
      } else {
        try sync(url)
      }
    }
    if let enumerationError { throw enumerationError }
    for url in directories.reversed() { try sync(url) }
  }

  private func sync(_ url: URL) throws {
    let descriptor = open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw CLIUsageError("unable to open workflow history artifact for fsync: \(url.path)") }
    defer { _ = close(descriptor) }
    guard fsync(descriptor) == 0 else { throw CLIUsageError("unable to fsync workflow history artifact: \(url.path)") }
  }
}

private extension WorkflowFileState {
  init(_ file: WorkflowBundleSnapshotFile) {
    self.init(
      contentDigest: file.contentDigest,
      byteCount: file.byteCount,
      artifactKind: file.artifactKind,
      executable: file.executable
    )
  }
}
