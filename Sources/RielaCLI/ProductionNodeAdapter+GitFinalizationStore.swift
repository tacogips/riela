import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore

struct GitRepositoryIdentity: Codable, Equatable, Sendable {
  var worktreePath: String
  var worktreeDevice: UInt64
  var worktreeInode: UInt64
  var gitDiscoveryPath: String
  var gitDiscoveryDevice: UInt64
  var gitDiscoveryInode: UInt64
  var gitDiscoveryFileDigest: String?
  var gitBackpointerPath: String?
  var gitBackpointerDevice: UInt64?
  var gitBackpointerInode: UInt64?
  var gitBackpointerFileDigest: String?
  var gitDirectoryPath: String
  var gitDirectoryDevice: UInt64
  var gitDirectoryInode: UInt64
  var commonDirectoryPath: String
  var commonDirectoryDevice: UInt64
  var commonDirectoryInode: UInt64
  var commonDirectoryLinkPath: String?
  var commonDirectoryLinkDevice: UInt64?
  var commonDirectoryLinkInode: UInt64?
  var commonDirectoryLinkDigest: String?
  var objectDirectoryPath: String
  var objectDirectoryDevice: UInt64
  var objectDirectoryInode: UInt64
  var objectFormat: GitObjectFormat
  var indexPath: String
  var indexDevice: UInt64
  var indexInode: UInt64
  var indexParentPath: String
  var indexParentDevice: UInt64
  var indexParentInode: UInt64

  func matchesAfterIndexPublication(_ current: GitRepositoryIdentity) -> Bool {
    var normalizedCurrent = current
    normalizedCurrent.indexDevice = indexDevice
    normalizedCurrent.indexInode = indexInode
    return normalizedCurrent == self
  }
}

struct GitCommitJournal: Codable, Equatable, Sendable {
  var schemaVersion: Int
  var repository: GitRepositoryIdentity
  var workflowExecutionId: String
  var logicalStepId: String
  var stepExecutionId: String
  var attempt: Int
  var renderedInputDigest: String
  var branchRef: String
  var parentCommit: String
  var tree: String
  var candidateCommit: String
  var commitMessage: String
  var committedFiles: [String]
  var authorName: String
  var authorEmail: String
  var committerName: String
  var committerEmail: String
  var originalIndexDigest: String
  var preparedIndexDigest: String
  var operationToken: String
  var journalKey: String
}

enum GitFinalizationFailurePhase: String, Sendable {
  case canonicalIndexRead
  case preparedIndex
  case journal
  case indexLock
  case refUpdate
  case indexPublication
  case outputPublication
}

protocol GitFinalizationFailureInjecting: Sendable {
  func check(_ phase: GitFinalizationFailurePhase) throws
}

struct NoGitFinalizationFailureInjector: GitFinalizationFailureInjecting {
  func check(_: GitFinalizationFailurePhase) throws {}
}

struct GitFinalizationStore: Sendable {
  private struct ExecutionLink: Codable, Equatable {
    var stepExecutionId: String
    var journalKey: String
    var journalStepExecutionId: String?
    var journalDigest: String

    init(
      stepExecutionId: String,
      journalKey: String,
      journalStepExecutionId: String? = nil,
      journalDigest: String
    ) {
      self.stepExecutionId = stepExecutionId
      self.journalKey = journalKey
      self.journalStepExecutionId = journalStepExecutionId
      self.journalDigest = journalDigest
    }
  }

  private struct AcceptedMarker: Codable, Equatable {
    var journalKey: String
    var operationToken: String
  }

  let rootDirectory: URL
  let managedDirectorySet: GitFinalizationManagedDirectories

  var journalsDirectory: URL { rootDirectory.appendingPathComponent("journals", isDirectory: true) }
  var preparedDirectory: URL { rootDirectory.appendingPathComponent("prepared", isDirectory: true) }
  var linksDirectory: URL { rootDirectory.appendingPathComponent("links", isDirectory: true) }
  var acceptedDirectory: URL { rootDirectory.appendingPathComponent("accepted", isDirectory: true) }
  var terminalDirectory: URL { rootDirectory.appendingPathComponent("terminal", isDirectory: true) }
  var hooksDirectory: URL { rootDirectory.appendingPathComponent("empty-hooks", isDirectory: true) }
  var emptyHomeDirectory: URL { rootDirectory.appendingPathComponent("empty-home", isDirectory: true) }
  var transportDirectory: URL { rootDirectory.appendingPathComponent("transport", isDirectory: true) }
  var temporaryDirectory: URL { rootDirectory.appendingPathComponent("tmp", isDirectory: true) }

  init(rootDirectory: URL = GitFinalizationStore.defaultRootDirectory()) {
    self.rootDirectory = rootDirectory.standardizedFileURL
    self.managedDirectorySet = GitFinalizationManagedDirectories(
      rootDirectory: rootDirectory.standardizedFileURL
    )
  }

  static func defaultRootDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("riela/git-finalization-v1", isDirectory: true)
  }

  func prepare() throws {
    try managedDirectorySet.prepare(managedDirectories)
  }

  func prepare(repositoryRoot: URL) throws {
    let canonicalRepositoryRoot = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
    try validateManagedLocation(rootDirectory, repositoryRoot: canonicalRepositoryRoot)
    try prepare()
    let canonicalRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
    try validateManagedLocation(canonicalRoot, repositoryRoot: canonicalRepositoryRoot)

    for directory in managedDirectories.dropFirst() {
      try validateManagedLocation(
        directory,
        repositoryRoot: canonicalRepositoryRoot,
        managedRoot: canonicalRoot
      )
      try validateManagedLocation(
        directory.resolvingSymlinksInPath().standardizedFileURL,
        repositoryRoot: canonicalRepositoryRoot,
        managedRoot: canonicalRoot
      )
    }
    let hookEntries = try managedDirectoryEntries(
      at: hooksDirectory,
      maximumEntries: 1,
      includingHidden: true
    )
    guard hookEntries.isEmpty else {
      throw policyError("git finalization hooks directory must be empty")
    }
  }

  private var managedDirectories: [URL] {
    [
      rootDirectory,
      journalsDirectory,
      preparedDirectory,
      linksDirectory,
      acceptedDirectory,
      terminalDirectory,
      hooksDirectory,
      emptyHomeDirectory,
      transportDirectory,
      temporaryDirectory
    ]
  }

  private func validateManagedLocation(
    _ location: URL,
    repositoryRoot: URL,
    managedRoot: URL? = nil
  ) throws {
    let canonical = location.resolvingSymlinksInPath().standardizedFileURL
    guard !isURL(canonical, inside: repositoryRoot) else {
      throw policyError("git finalization storage must remain outside the repository")
    }
    if let managedRoot {
      guard isURL(canonical, inside: managedRoot) else {
        throw policyError("git finalization storage resolves outside its runtime-owned root")
      }
    }
  }

  func makeTransportRepositoryDirectory() throws -> GitOwnedTransportRepository {
    try prepare()
    let name = UUID().uuidString
    let directory = transportDirectory.appendingPathComponent(name, isDirectory: true)
    return try managedDirectorySet.withDescriptor(at: transportDirectory) { descriptor in
      guard mkdirat(descriptor, name, 0o700) == 0 else {
        throw policyError("git transport repository directory could not be created")
      }
      guard fsync(descriptor) == 0 else {
        throw policyError("git transport directory could not be synchronized")
      }
      return try captureOwnedTransportRepository(in: descriptor, name: name, url: directory)
    }
  }

  func configureTransportObjectDatabase(
    transportRepository: GitOwnedTransportRepository,
    objectDirectory: URL
  ) throws {
    guard !objectDirectory.path.unicodeScalars.contains(where: {
      $0.value == 0 || $0.value == 10 || $0.value == 13
    }) else {
      throw policyError("riela/git-push object database path is unsafe")
    }
    guard transportRepository.url.deletingLastPathComponent().standardizedFileURL.path
      == transportDirectory.path else {
      throw policyError("git transport repository is outside the managed layout")
    }
    try requireOwnedTransportRepository(transportRepository)
    try managedDirectorySet.withDescriptor(at: transportDirectory) { transportDescriptor in
      let repositoryDescriptor = openat(
        transportDescriptor,
        transportRepository.url.lastPathComponent,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard repositoryDescriptor >= 0 else {
        throw policyError("git transport repository identity changed")
      }
      defer { close(repositoryDescriptor) }
      let objectsDescriptor = try openOrCreateGitFinalizationDirectory(
        in: repositoryDescriptor,
        name: "objects"
      )
      defer { close(objectsDescriptor) }
      let infoDescriptor = try openOrCreateGitFinalizationDirectory(
        in: objectsDescriptor,
        name: "info"
      )
      defer { close(infoDescriptor) }
      let alternatesDescriptor = try createGitFinalizationFile(
        in: infoDescriptor,
        name: "alternates",
        data: Data((objectDirectory.path + "\n").utf8)
      )
      close(alternatesDescriptor)
      guard fsync(infoDescriptor) == 0,
            fsync(objectsDescriptor) == 0,
            fsync(repositoryDescriptor) == 0 else {
        throw policyError("git transport object binding could not be synchronized")
      }
    }
    try requireOwnedTransportRepository(transportRepository)
  }

  func renderedInputDigest(operation: String, message: String, files: [String]) throws -> String {
    try digest(CanonicalInput(operation: operation, message: message, files: files))
  }

  func journalKey(
    repository: GitRepositoryIdentity,
    identity: WorkflowAddonExecutionIdentity,
    renderedInputDigest: String
  ) throws -> String {
    try digest(JournalIdentity(
      repository: repository,
      workflowExecutionId: identity.workflowExecutionId,
      stepExecutionId: identity.stepExecutionId,
      attempt: identity.attempt,
      renderedInputDigest: renderedInputDigest
    ))
  }

  func writePreparedIndex(_ data: Data, journalKey: String) throws -> URL {
    try prepare()
    let url = preparedURL(for: journalKey)
    try writeCreateOnly(data, to: url, maxBytes: 64 * 1024 * 1024)
    return url
  }

  func makeAttemptIndex(copying data: Data) throws -> URL {
    try prepare()
    guard data.count <= 64 * 1024 * 1024 else {
      throw policyError("git index exceeds the finalization size limit")
    }
    let name = "attempt-\(UUID().uuidString).index"
    let url = temporaryDirectory.appendingPathComponent(name)
    try managedDirectorySet.withDescriptor(at: temporaryDirectory) { directoryDescriptor in
      let descriptor: Int32
      do {
        descriptor = try createGitFinalizationFile(
          in: directoryDescriptor,
          name: name,
          data: data
        )
      } catch {
        throw policyError("git attempt index could not be created")
      }
      close(descriptor)
      guard fsync(directoryDescriptor) == 0 else {
        throw policyError("git attempt index directory could not be synchronized")
      }
    }
    return url
  }

  func writeJournal(_ journal: GitCommitJournal) throws {
    try prepare()
    let journalData = try canonicalData(journal)
    try writeCreateOnly(journalData, to: journalURL(for: journal.journalKey), maxBytes: 512 * 1024)
    let link = ExecutionLink(
      stepExecutionId: journal.stepExecutionId,
      journalKey: journal.journalKey,
      journalDigest: sha256(journalData)
    )
    let linkURL = executionLinkURL(for: journal.stepExecutionId)
    try writeCreateOnly(try canonicalData(link), to: linkURL, maxBytes: 8 * 1024)
  }

  func linkJournal(_ journal: GitCommitJournal, to stepExecutionId: String) throws {
    try prepare()
    let journalData = try canonicalData(journal)
    let link = ExecutionLink(
      stepExecutionId: stepExecutionId,
      journalKey: journal.journalKey,
      journalStepExecutionId: journal.stepExecutionId,
      journalDigest: sha256(journalData)
    )
    try writeCreateOnly(
      try canonicalData(link),
      to: executionLinkURL(for: stepExecutionId),
      maxBytes: 8 * 1024
    )
  }

  func loadJournal(predecessorStepExecutionId: String) throws -> GitCommitJournal {
    let linkURL = executionLinkURL(for: predecessorStepExecutionId)
    let linkData = try requiredRecordData(
      from: linkURL,
      maxBytes: 8 * 1024,
      missingMessage: "git finalization predecessor link is missing"
    )
    return try loadJournal(predecessorStepExecutionId: predecessorStepExecutionId, linkData: linkData)
  }

  private func loadJournal(
    predecessorStepExecutionId: String,
    linkData: Data
  ) throws -> GitCommitJournal {
    let link: ExecutionLink
    do {
      link = try JSONDecoder().decode(ExecutionLink.self, from: linkData)
    } catch is DecodingError {
      throw policyError("git finalization predecessor link is corrupt")
    }
    guard link.stepExecutionId == predecessorStepExecutionId else {
      throw policyError("git finalization predecessor link is corrupt")
    }
    let journalURL = journalURL(for: link.journalKey)
    let journalData = try requiredRecordData(
      from: journalURL,
      maxBytes: 512 * 1024,
      missingMessage: "git finalization journal is missing"
    )
    guard sha256(journalData) == link.journalDigest else {
      throw policyError("git finalization journal content is corrupt")
    }
    let journal: GitCommitJournal
    do {
      journal = try JSONDecoder().decode(GitCommitJournal.self, from: journalData)
    } catch is DecodingError {
      throw policyError("git finalization journal content is corrupt")
    }
    let expectedJournalStepExecutionId = link.journalStepExecutionId ?? predecessorStepExecutionId
    guard journal.journalKey == link.journalKey,
          journal.stepExecutionId == expectedJournalStepExecutionId else {
      throw policyError("git finalization journal identity is corrupt")
    }
    return journal
  }

  func loadJournalIfPresent(predecessorStepExecutionId: String) throws -> GitCommitJournal? {
    let linkURL = executionLinkURL(for: predecessorStepExecutionId)
    guard let linkData = try boundedDataIfPresent(from: linkURL, maxBytes: 8 * 1024) else {
      return nil
    }
    return try loadJournal(predecessorStepExecutionId: predecessorStepExecutionId, linkData: linkData)
  }

  func preparedIndexData(for journal: GitCommitJournal) throws -> Data {
    let url = preparedURL(for: journal.journalKey)
    let data: Data
    do {
      data = try boundedData(from: url, maxBytes: 64 * 1024 * 1024)
    } catch let error where isMissingFileError(error) {
      throw policyError("git finalization prepared index is missing or corrupt")
    }
    guard sha256(data) == journal.preparedIndexDigest else {
      throw policyError("git finalization prepared index is missing or corrupt")
    }
    return data
  }

  func finalizationToken(for journal: GitCommitJournal) -> WorkflowAddonFinalizationToken {
    WorkflowAddonFinalizationToken(
      value: "git-finalization-v1:\(journal.journalKey):\(journal.operationToken)"
    )
  }

  func acknowledge(_ token: WorkflowAddonFinalizationToken) throws {
    try prepare()
    let parsed = try parse(token)
    let marker = AcceptedMarker(journalKey: parsed.journalKey, operationToken: parsed.operationToken)
    let markerURL = acceptedDirectory.appendingPathComponent(sha256(Data(token.value.utf8)) + ".json")
    try writeCreateOnly(try canonicalData(marker), to: markerURL, maxBytes: 8 * 1024)

    let journalURL = journalURL(for: parsed.journalKey)
    if let journal: GitCommitJournal = try? decodeBounded(
      GitCommitJournal.self,
      from: journalURL,
      maxBytes: 512 * 1024
    ) {
      guard journal.operationToken == parsed.operationToken else {
        throw policyError("git finalization accepted token does not match its journal")
      }
      _ = try? removeEntryIfPresent(at: preparedURL(for: journal.journalKey))
      try? removeExecutionLinks(for: journal.journalKey)
      _ = try? removeEntryIfPresent(at: journalURL)
      try synchronizeDirectory(journalsDirectory)
      try synchronizeDirectory(preparedDirectory)
      try synchronizeDirectory(linksDirectory)
    }
  }

  func garbageCollectFailedArtifacts(
    olderThan cutoff: Date = Date().addingTimeInterval(-7 * 24 * 60 * 60),
    limit: Int = 64,
    entryLimit: Int = 4_096,
    beforeRemoval: (URL) throws -> Void = { _ in },
    afterRemovalValidation: (URL) throws -> Void = { _ in }
  ) throws {
    try prepare()
    var remaining = max(0, limit)
    let terminalJournalMarkers = try terminalJournalMarkers(entryLimit: entryLimit)
    let journals = try managedDirectoryEntries(
      at: journalsDirectory,
      maximumEntries: entryLimit
    )
    let linkURLsByJournalKey = try executionLinkURLsByJournalKey(entryLimit: entryLimit)
    for journalURL in journals where remaining > 0 {
      guard let journal = try? decodeBounded(GitCommitJournal.self, from: journalURL, maxBytes: 512 * 1024),
            journalURL.lastPathComponent == journal.journalKey + ".json",
            let marker = terminalJournalMarkers[journal.journalKey],
            marker.workflowExecutionId == journal.workflowExecutionId,
            marker.stepExecutionId == journal.stepExecutionId else {
        continue
      }
      let preparedURL = preparedURL(for: journal.journalKey)
      let linkURLs = linkURLsByJournalKey[journal.journalKey] ?? []
      let existingArtifacts = try ([journalURL, preparedURL] + linkURLs).filter {
        try managedFileSnapshot(at: $0) != nil
      }
      guard let snapshots = artifactSnapshots(existingArtifacts, olderThan: cutoff) else {
        continue
      }
      try removeEntryIfPresent(
        at: preparedURL,
        expected: snapshots[preparedURL.path],
        beforeRemoval: beforeRemoval,
        afterValidation: afterRemovalValidation
      )
      for linkURL in linkURLs {
        try removeEntryIfPresent(
          at: linkURL,
          expected: snapshots[linkURL.path],
          beforeRemoval: beforeRemoval,
          afterValidation: afterRemovalValidation
        )
      }
      try synchronizeDirectory(preparedDirectory)
      try synchronizeDirectory(linksDirectory)
      try removeEntryIfPresent(
        at: journalURL,
        expected: snapshots[journalURL.path],
        beforeRemoval: beforeRemoval,
        afterValidation: afterRemovalValidation
      )
      try synchronizeDirectory(journalsDirectory)
      remaining -= 1
    }

    let retainedJournalKeys = Set(try managedDirectoryEntries(
      at: journalsDirectory,
      maximumEntries: entryLimit
    ).map { $0.deletingPathExtension().lastPathComponent })
    for directory in [preparedDirectory, temporaryDirectory] where remaining > 0 {
      remaining = try garbageCollectOrphans(
        in: directory,
        retainedJournalKeys: retainedJournalKeys,
        cutoff: cutoff,
        remaining: remaining,
        entryLimit: entryLimit,
        beforeRemoval: beforeRemoval,
        afterValidation: afterRemovalValidation
      )
    }
    if remaining > 0 {
      remaining = try garbageCollectOrphanLinks(
        retainedJournalKeys: retainedJournalKeys,
        cutoff: cutoff,
        remaining: remaining,
        entryLimit: entryLimit,
        beforeRemoval: beforeRemoval,
        afterValidation: afterRemovalValidation
      )
    }
    if remaining > 0 {
      _ = try garbageCollectOrphanTransportRepositories(
        cutoff: cutoff,
        remaining: remaining,
        entryLimit: entryLimit
      )
    }
    try synchronizeDirectory(preparedDirectory)
    try synchronizeDirectory(linksDirectory)
    try synchronizeDirectory(temporaryDirectory)
    try removeUnusedTerminalJournalMarkers(entryLimit: entryLimit)
  }

  func preparedURL(for journalKey: String) -> URL {
    preparedDirectory.appendingPathComponent(journalKey + ".index")
  }

  private func journalURL(for journalKey: String) -> URL {
    journalsDirectory.appendingPathComponent(journalKey + ".json")
  }

  private func executionLinkURL(for executionId: String) -> URL {
    linksDirectory.appendingPathComponent(sha256(Data(executionId.utf8)) + ".json")
  }

  private func removeExecutionLinks(for journalKey: String) throws {
    for candidate in try executionLinkURLs(for: journalKey) {
      try removeEntryIfPresent(at: candidate)
    }
  }

  private func executionLinkURLs(for journalKey: String, entryLimit: Int = 4_096) throws -> [URL] {
    try executionLinkURLsByJournalKey(entryLimit: entryLimit)[journalKey] ?? []
  }

  private func executionLinkURLsByJournalKey(entryLimit: Int) throws -> [String: [URL]] {
    let candidates = try managedDirectoryEntries(
      at: linksDirectory,
      maximumEntries: entryLimit
    )
    var result: [String: [URL]] = [:]
    for candidate in candidates {
      guard let link = try? decodeBounded(ExecutionLink.self, from: candidate, maxBytes: 8 * 1024) else {
        continue
      }
      result[link.journalKey, default: []].append(candidate)
    }
    return result
  }

  private func artifactSnapshots(
    _ urls: [URL],
    olderThan cutoff: Date
  ) -> [String: GitFinalizationFileSnapshot]? {
    guard !urls.isEmpty else { return nil }
    var snapshots: [String: GitFinalizationFileSnapshot] = [:]
    for url in urls {
      guard let snapshot = try? managedFileSnapshot(at: url),
            snapshot.isOlder(than: cutoff) else {
        return nil
      }
      snapshots[url.path] = snapshot
    }
    return snapshots
  }

  private func garbageCollectOrphans(
    in directory: URL,
    retainedJournalKeys: Set<String>,
    cutoff: Date,
    remaining: Int,
    entryLimit: Int,
    beforeRemoval: (URL) throws -> Void,
    afterValidation: (URL) throws -> Void
  ) throws -> Int {
    var remaining = remaining
    let candidates = try managedDirectoryEntries(
      at: directory,
      maximumEntries: entryLimit
    )
    for candidate in candidates where remaining > 0 {
      if directory == preparedDirectory,
         retainedJournalKeys.contains(candidate.deletingPathExtension().lastPathComponent) {
        continue
      }
      guard let snapshot = artifactSnapshots([candidate], olderThan: cutoff)?[candidate.path] else {
        continue
      }
      if try removeEntryIfPresent(
        at: candidate,
        expected: snapshot,
        beforeRemoval: beforeRemoval,
        afterValidation: afterValidation
      ) {
        remaining -= 1
      }
    }
    return remaining
  }

  private func garbageCollectOrphanLinks(
    retainedJournalKeys: Set<String>,
    cutoff: Date,
    remaining: Int,
    entryLimit: Int,
    beforeRemoval: (URL) throws -> Void,
    afterValidation: (URL) throws -> Void
  ) throws -> Int {
    var remaining = remaining
    let candidates = try managedDirectoryEntries(
      at: linksDirectory,
      maximumEntries: entryLimit
    )
    for candidate in candidates where remaining > 0 {
      guard let link = try? decodeBounded(ExecutionLink.self, from: candidate, maxBytes: 8 * 1024),
            !retainedJournalKeys.contains(link.journalKey),
            let snapshot = artifactSnapshots([candidate], olderThan: cutoff)?[candidate.path] else {
        continue
      }
      if try removeEntryIfPresent(
        at: candidate,
        expected: snapshot,
        beforeRemoval: beforeRemoval,
        afterValidation: afterValidation
      ) {
        remaining -= 1
      }
    }
    return remaining
  }

  @discardableResult
  private func removeEntryIfPresent(
    at url: URL,
    beforeRemoval: (URL) throws -> Void = { _ in }
  ) throws -> Bool {
    guard let snapshot = try managedFileSnapshot(at: url) else { return false }
    try beforeRemoval(url)
    return try removeManagedEntryIfUnchanged(at: url, expected: snapshot)
  }

  @discardableResult
  private func removeEntryIfPresent(
    at url: URL,
    expected: GitFinalizationFileSnapshot?,
    beforeRemoval: (URL) throws -> Void,
    afterValidation: (URL) throws -> Void
  ) throws -> Bool {
    guard let expected else { return false }
    try beforeRemoval(url)
    return try removeManagedEntryIfUnchanged(
      at: url,
      expected: expected,
      afterPathValidation: afterValidation
    )
  }

  private func parse(_ token: WorkflowAddonFinalizationToken) throws -> (journalKey: String, operationToken: String) {
    let parts = token.value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
          parts[0] == "git-finalization-v1",
          parts[1].range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          !parts[2].isEmpty else {
      throw policyError("git finalization accepted token is malformed")
    }
    return (parts[1], parts[2])
  }

  func writeCreateOnly(_ data: Data, to destination: URL, maxBytes: Int) throws {
    try prepare()
    guard data.count <= maxBytes else {
      throw policyError("git finalization record exceeds its size limit")
    }
    let destinationDirectory = destination.deletingLastPathComponent()
    let temporaryName = UUID().uuidString
    try managedDirectorySet.withDescriptor(at: temporaryDirectory) { temporaryDescriptor in
      let temporaryFile = try createGitFinalizationFile(
        in: temporaryDescriptor,
        name: temporaryName,
        data: data
      )
      defer {
        unlinkGitFinalizationFileIfSame(
          in: temporaryDescriptor,
          name: temporaryName,
          openedDescriptor: temporaryFile
        )
        close(temporaryFile)
        _ = fsync(temporaryDescriptor)
      }
      try managedDirectorySet.withDescriptor(at: destinationDirectory) { destinationDescriptor in
        let linkResult = linkat(
          temporaryDescriptor,
          temporaryName,
          destinationDescriptor,
          destination.lastPathComponent,
          0
        )
        if linkResult != 0 {
          guard errno == EEXIST else {
            throw policyError("git finalization create-only record collision")
          }
          let existing: Data
          do {
            existing = try boundedData(from: destination, maxBytes: maxBytes)
          } catch let error as AdapterExecutionError where error.code == .timeout {
            throw error
          } catch is AdapterExecutionError {
            throw policyError("git finalization create-only record collision")
          } catch {
            throw error
          }
          guard existing == data else {
            throw policyError("git finalization create-only record collision")
          }
        }
        guard fsync(destinationDescriptor) == 0 else {
          throw policyError("git finalization directory could not be synchronized")
        }
      }
    }
  }

  func decodeBounded<T: Decodable>(_ type: T.Type, from url: URL, maxBytes: Int) throws -> T {
    try JSONDecoder().decode(type, from: boundedData(from: url, maxBytes: maxBytes))
  }

  private func requiredRecordData(from url: URL, maxBytes: Int, missingMessage: String) throws -> Data {
    do {
      return try boundedData(from: url, maxBytes: maxBytes)
    } catch let error as AdapterExecutionError {
      throw error
    } catch let error {
      guard isMissingFileError(error) else {
        throw error
      }
      throw policyError(missingMessage)
    }
  }

  private func isMissingFileError(_ error: Error) -> Bool {
    let foundationError = error as NSError
    if foundationError.domain == NSPOSIXErrorDomain && foundationError.code == Int(ENOENT) {
      return true
    }
    return foundationError.domain == NSCocoaErrorDomain && (
      foundationError.code == NSFileNoSuchFileError || foundationError.code == NSFileReadNoSuchFileError
    )
  }

  private func boundedData(from url: URL, maxBytes: Int) throws -> Data {
    try prepare()
    return try managedDirectorySet.withDescriptor(at: url.deletingLastPathComponent()) { directoryDescriptor in
      try managedDirectorySet.withDescriptor(at: temporaryDirectory) { temporaryDescriptor in
        try boundedGitFinalizationRecordData(
          directoryDescriptor: directoryDescriptor,
          name: url.lastPathComponent,
          maxBytes: maxBytes,
          ownedHardLinkDirectoryDescriptor: temporaryDescriptor
        )
      }
    }
  }

  private func boundedDataIfPresent(from url: URL, maxBytes: Int) throws -> Data? {
    do {
      return try boundedData(from: url, maxBytes: maxBytes)
    } catch let error where isMissingFileError(error) {
      return nil
    }
  }

  func canonicalData<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  private func digest<T: Encodable>(_ value: T) throws -> String {
    sha256(try canonicalData(value))
  }

  func synchronizeDirectory(_ directory: URL) throws {
    try prepare()
    return try managedDirectorySet.withDescriptor(at: directory) { descriptor in
      guard fsync(descriptor) == 0 else {
        throw policyError("git finalization directory could not be synchronized")
      }
    }
  }

  func managedDirectoryEntries(
    at directory: URL,
    maximumEntries: Int,
    includingHidden: Bool = false
  ) throws -> [URL] {
    try prepare()
    return try managedDirectorySet.withDescriptor(at: directory) { descriptor in
      try boundedGitFinalizationDirectoryEntries(
        directoryDescriptor: descriptor,
        directoryURL: directory,
        maximumEntries: maximumEntries,
        includingHidden: includingHidden
      )
    }
  }

  func managedFileSnapshot(at url: URL) throws -> GitFinalizationFileSnapshot? {
    try prepare()
    return try managedDirectorySet.withDescriptor(at: url.deletingLastPathComponent()) { descriptor in
      try gitFinalizationFileSnapshot(in: descriptor, name: url.lastPathComponent)
    }
  }

  @discardableResult
  func removeManagedEntryIfUnchanged(
    at url: URL,
    expected: GitFinalizationFileSnapshot,
    afterPathValidation: (URL) throws -> Void = { _ in }
  ) throws -> Bool {
    try prepare()
    return try managedDirectorySet.withDescriptor(at: url.deletingLastPathComponent()) { descriptor in
      try removeGitFinalizationEntryIfUnchanged(
        directoryDescriptor: descriptor,
        url: url,
        expected: expected,
        afterPathValidation: afterPathValidation
      )
    }
  }

  private struct CanonicalInput: Codable {
    var operation: String
    var message: String
    var files: [String]
  }

  private struct JournalIdentity: Codable {
    var repository: GitRepositoryIdentity
    var workflowExecutionId: String
    var stepExecutionId: String
    var attempt: Int
    var renderedInputDigest: String
  }
}
