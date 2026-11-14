import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeGitCommit(
    _ input: WorkflowAddonExecutionInput,
    identity: WorkflowAddonExecutionIdentity
  ) throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    guard boolValue(config["allowCommit"]) == true else {
      throw policyError("riela/git-commit requires config.allowCommit=true")
    }
    let variables = addonVariables(for: input)
    let message = try renderedCommitMessage(config["commitMessageTemplate"], variables: variables)
    let files = try renderedCommittedFiles(config["committedFilesTemplate"], variables: variables)
    let repository = try loadGitRepository()
    try prepareGitFinalizationStore(repository: repository)
    let inputDigest = try gitFinalizationStore.renderedInputDigest(
      operation: BuiltinGitAddon.commit.rawValue,
      message: message,
      files: files
    )

    if let journal = try retryJournal(identity: identity) {
      try gitFinalizationStore.linkJournal(journal, to: identity.stepExecutionId)
      try validateRetryJournal(
        journal,
        input: input,
        identity: identity,
        repository: repository,
        renderedInputDigest: inputDigest
      )
      try reconcileCommit(journal, repository: repository)
      try gitFailureInjector.check(.outputPublication)
      try requireCurrentBranchState(
        journal.branchRef,
        expectedRevision: journal.candidateCommit,
        repository: repository
      )
      return commitOutput(
        status: "already-committed",
        revision: journal.candidateCommit,
        message: journal.commitMessage,
        files: journal.committedFiles,
        token: gitFinalizationStore.finalizationToken(for: journal)
      )
    }

    try requireIndexUnlocked(repository)
    try validateCommitPaths(files, repository: repository)
    try gitFailureInjector.check(.canonicalIndexRead)
    let originalIndex = try boundedIndexData(
      at: repository.indexURL,
      expectedIdentity: repository.indexEntryIdentity
    )
    let originalIndexDigest = sha256(originalIndex)
    let stagedBefore = try stagedPaths(repository: repository)
    try requireStagedPathsAreAllowlisted(
      stagedBefore,
      allowed: files,
      diagnostic: "pre-existing staged path"
    )
    let modePolicy = try gitWorktreeModePolicy(repository: repository)

    let attemptIndex = try gitFinalizationStore.makeAttemptIndex(copying: originalIndex)
    defer { try? FileManager.default.removeItem(at: attemptIndex) }
    let indexEnvironment = ["GIT_INDEX_FILE": attemptIndex.path]
    try stageCommitPaths(
      files,
      repository: repository,
      indexURL: attemptIndex,
      modePolicy: modePolicy
    )
    let stagedAfter = try stagedPaths(repository: repository, indexURL: attemptIndex)
    try requireExactStagedPaths(stagedAfter, allowed: files, diagnostic: "prepared staged set")

    let tree = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["write-tree"],
      repository: repository,
      environment: indexEnvironment
    ).output, name: "tree object id"))
    let parent = try headRevision(repository: repository)
    let parentTree = try treeForCommit(parent, repository: repository)
    guard tree != parentTree else {
      throw policyError("riela/git-commit refuses an empty commit")
    }
    let branchRef = try validatedBranchRef(repository: repository)
    let author = try gitCommitIdentity(repository: repository, prefix: "author")
    let committer = try gitCommitIdentity(repository: repository, prefix: "committer")
    var commitEnvironment = indexEnvironment
    commitEnvironment["GIT_AUTHOR_NAME"] = author.name
    commitEnvironment["GIT_AUTHOR_EMAIL"] = author.email
    commitEnvironment["GIT_COMMITTER_NAME"] = committer.name
    commitEnvironment["GIT_COMMITTER_EMAIL"] = committer.email
    let candidate = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["commit-tree", tree, "-p", parent],
      repository: repository,
      environment: commitEnvironment,
      standardInput: Data((message + "\n").utf8)
    ).output, name: "commit object id"))
    guard candidate != parent else {
      throw policyError("riela/git-commit refuses an empty commit")
    }

    let preparedIndex = try boundedIndexData(at: attemptIndex)
    let preparedIndexDigest = sha256(preparedIndex)
    let journalKey = try gitFinalizationStore.journalKey(
      repository: repository.identity,
      identity: identity,
      renderedInputDigest: inputDigest
    )
    _ = try gitFinalizationStore.writePreparedIndex(preparedIndex, journalKey: journalKey)
    try gitFailureInjector.check(.preparedIndex)
    let journal = GitCommitJournal(
      schemaVersion: 1,
      repository: repository.identity,
      workflowExecutionId: identity.workflowExecutionId,
      logicalStepId: input.stepId,
      stepExecutionId: identity.stepExecutionId,
      attempt: identity.attempt,
      renderedInputDigest: inputDigest,
      branchRef: branchRef,
      parentCommit: parent,
      tree: tree,
      candidateCommit: candidate,
      commitMessage: message,
      committedFiles: files,
      authorName: author.name,
      authorEmail: author.email,
      committerName: committer.name,
      committerEmail: committer.email,
      originalIndexDigest: originalIndexDigest,
      preparedIndexDigest: preparedIndexDigest,
      operationToken: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
      journalKey: journalKey
    )
    try gitFinalizationStore.writeJournal(journal)
    try gitFailureInjector.check(.journal)
    try publishCommit(journal, repository: repository, advancesRef: true)
    try gitFailureInjector.check(.outputPublication)
    try requireCurrentBranchState(
      journal.branchRef,
      expectedRevision: journal.candidateCommit,
      repository: repository
    )
    return commitOutput(
      status: "committed",
      revision: candidate,
      message: message,
      files: files,
      token: gitFinalizationStore.finalizationToken(for: journal)
    )
  }

  private func retryJournal(identity: WorkflowAddonExecutionIdentity) throws -> GitCommitJournal? {
    let predecessors = identity.predecessorStepExecutionIds
      ?? identity.predecessorStepExecutionId.map { [$0] }
      ?? []
    guard predecessors.count <= max(identity.attempt - 1, 0),
          Set(predecessors).count == predecessors.count,
          predecessors.allSatisfy({ !$0.isEmpty }),
          predecessors.first == identity.predecessorStepExecutionId else {
      throw policyError("git commit retry ancestry is invalid")
    }
    for predecessor in predecessors {
      if let journal = try gitFinalizationStore.loadJournalIfPresent(
        predecessorStepExecutionId: predecessor
      ) {
        return journal
      }
    }
    return nil
  }

  private func validateRetryJournal(
    _ journal: GitCommitJournal,
    input: WorkflowAddonExecutionInput,
    identity: WorkflowAddonExecutionIdentity,
    repository: GitRepositoryContext,
    renderedInputDigest: String
  ) throws {
    guard journal.schemaVersion == 1,
          retryRepositoryIdentityMatches(journal.repository, current: repository.identity),
          journal.workflowExecutionId == identity.workflowExecutionId,
          journal.logicalStepId == input.stepId,
          journal.attempt < identity.attempt,
          journal.renderedInputDigest == renderedInputDigest else {
      throw policyError("git commit retry journal does not match this runtime attempt")
    }
    try validateRetryJournalContents(journal, repository: repository)
  }

  private func validateRetryJournalContents(
    _ journal: GitCommitJournal,
    repository: GitRepositoryContext
  ) throws {
    guard journal.commitMessage == journal.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines),
          !journal.commitMessage.isEmpty,
          journal.commitMessage.utf8.count <= 4_096,
          !journal.commitMessage.contains("\0"),
          !journal.committedFiles.isEmpty,
          journal.committedFiles.count <= 2_048,
          Set(journal.committedFiles).count == journal.committedFiles.count,
          journal.operationToken.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
          journal.journalKey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          journal.originalIndexDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          journal.preparedIndexDigest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          journal.branchRef.hasPrefix("refs/heads/") else {
      throw policyError("git commit retry journal contains invalid canonical fields")
    }
    for path in journal.committedFiles {
      try validateRepositoryRelativePath(path)
    }
    let recomputedInputDigest = try gitFinalizationStore.renderedInputDigest(
      operation: BuiltinGitAddon.commit.rawValue,
      message: journal.commitMessage,
      files: journal.committedFiles
    )
    guard recomputedInputDigest == journal.renderedInputDigest else {
      throw policyError("git commit retry journal input evidence is corrupt")
    }
    let recomputedJournalKey = try gitFinalizationStore.journalKey(
      repository: journal.repository,
      identity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: journal.workflowExecutionId,
        stepExecutionId: journal.stepExecutionId,
        attempt: journal.attempt
      ),
      renderedInputDigest: journal.renderedInputDigest
    )
    guard recomputedJournalKey == journal.journalKey else {
      throw policyError("git commit retry journal identity is corrupt")
    }

    let parent = try validatedObjectID(journal.parentCommit)
    let tree = try validatedObjectID(journal.tree)
    let candidate = try validatedObjectID(journal.candidateCommit)
    let refValidation = try runRepositoryGitResult(
      ["check-ref-format", journal.branchRef],
      repository: repository
    )
    guard refValidation.exitCode == 0 else {
      throw policyError("git commit retry journal branch is invalid")
    }
    _ = try gitFinalizationStore.preparedIndexData(for: journal)
    let preparedTree = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["write-tree"],
      repository: repository,
      environment: ["GIT_INDEX_FILE": gitFinalizationStore.preparedURL(for: journal.journalKey).path]
    ).output, name: "prepared retry tree"))
    guard preparedTree == tree else {
      throw policyError("git commit retry prepared index does not match its journaled tree")
    }

    let metadataOutput = try runRepositoryGit(
      ["show", "-s", "--format=%T%x00%P%x00%an%x00%ae%x00%cn%x00%ce%x00%B", candidate],
      repository: repository
    ).output
    let fields = metadataOutput.split(
      separator: "\0",
      maxSplits: 6,
      omittingEmptySubsequences: false
    ).map(String.init)
    guard fields.count == 7 else {
      throw policyError("git commit retry candidate metadata is invalid")
    }
    let candidateTree = try validatedObjectID(requiredSingleLine(fields[0], name: "candidate tree"))
    let candidateParents = fields[1].split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let authorName = try boundedIdentityValue(fields[2], field: "retry author name")
    let authorEmail = try boundedIdentityValue(fields[3], field: "retry author email")
    let committerName = try boundedIdentityValue(fields[4], field: "retry committer name")
    let committerEmail = try boundedIdentityValue(fields[5], field: "retry committer email")
    let commitMessage = fields[6].trimmingCharacters(in: .newlines)
    guard candidateParents == [parent],
          candidateTree == tree,
          authorName == journal.authorName,
          authorEmail == journal.authorEmail,
          committerName == journal.committerName,
          committerEmail == journal.committerEmail,
          commitMessage == journal.commitMessage else {
      throw policyError("git commit retry candidate does not match its journaled evidence")
    }
  }

  private func reconcileCommit(_ journal: GitCommitJournal, repository: GitRepositoryContext) throws {
    try requireIndexUnlocked(repository)
    try requireCurrentBranchRef(journal.branchRef, repository: repository)
    let head = try headRevision(repository: repository)
    let index = try indexDigest(
      at: repository.indexURL,
      expectedIdentity: repository.indexEntryIdentity
    )
    let reflogProvesUpdate = try reflogProves(journal, repository: repository)
    if head == journal.parentCommit && index == journal.originalIndexDigest {
      try requireJournaledOriginalIndexEntry(journal, repository: repository)
      guard !reflogProvesUpdate else {
        throw policyError("git commit retry detected a tokened update followed by a reset")
      }
      try publishCommit(journal, repository: repository, advancesRef: true)
      return
    }
    if head == journal.candidateCommit && index == journal.originalIndexDigest {
      try requireJournaledOriginalIndexEntry(journal, repository: repository)
      guard reflogProvesUpdate else {
        throw policyError("git commit retry lacks exact reflog proof")
      }
      try publishCommit(journal, repository: repository, advancesRef: false)
      return
    }
    if head == journal.candidateCommit && index == journal.preparedIndexDigest {
      guard reflogProvesUpdate else {
        throw policyError("git commit retry lacks exact reflog proof")
      }
      return
    }
    throw policyError("git commit retry state is ambiguous or was concurrently changed")
  }

  private func retryRepositoryIdentityMatches(
    _ journaled: GitRepositoryIdentity,
    current: GitRepositoryIdentity
  ) -> Bool {
    var normalizedCurrent = current
    normalizedCurrent.indexPath = journaled.indexPath
    normalizedCurrent.indexDevice = journaled.indexDevice
    normalizedCurrent.indexInode = journaled.indexInode
    return normalizedCurrent == journaled
  }

  private func requireJournaledOriginalIndexEntry(
    _ journal: GitCommitJournal,
    repository: GitRepositoryContext
  ) throws {
    try requireIndexEntryIdentity(repository)
    guard repository.identity.indexPath == journal.repository.indexPath,
          repository.identity.indexDevice == journal.repository.indexDevice,
          repository.identity.indexInode == journal.repository.indexInode else {
      throw policyError("git canonical index identity changed across retry attempts", retryable: true)
    }
  }

  private func publishCommit(
    _ journal: GitCommitJournal,
    repository: GitRepositoryContext,
    advancesRef: Bool
  ) throws {
    try requireRepositoryIdentity(repository)
    try requireIndexEntryIdentity(repository)
    try requireIndexUnlocked(repository)
    let preparedIndex = try gitFinalizationStore.preparedIndexData(for: journal)
    let ownedLock = try createOwnedIndexLock(repository.indexLockURL, data: preparedIndex)
    var publishedIndex = false
    defer {
      if !publishedIndex {
        removeOwnedIndexLock(ownedLock, at: repository.indexLockURL)
      }
      close(ownedLock.descriptor)
    }
    try gitFailureInjector.check(.indexLock)
    try requireRepositoryIdentity(repository)
    try requireIndexEntryIdentity(repository)
    guard try indexDigest(
      at: repository.indexURL,
      expectedIdentity: repository.indexEntryIdentity
    ) == journal.originalIndexDigest else {
      throw policyError("git canonical index changed before publication")
    }
    try requireOwnedIndexLock(ownedLock, at: repository.indexLockURL)
    try verifyAndUpdateCurrentBranch(
      journal,
      expectedRevision: advancesRef ? journal.parentCommit : journal.candidateCommit,
      advancesRef: advancesRef,
      repository: repository
    )
    try gitFailureInjector.check(.refUpdate)
    try requireCurrentBranchState(
      journal.branchRef,
      expectedRevision: journal.candidateCommit,
      repository: repository
    )
    try requireOwnedIndexLock(ownedLock, at: repository.indexLockURL)
    try requireRepositoryIdentity(repository)
    try requireIndexEntryIdentity(repository)
    guard rename(repository.indexLockURL.path, repository.indexURL.path) == 0 else {
      throw policyError("git prepared index could not be published")
    }
    publishedIndex = true
    try synchronizeDirectory(repository.gitDirectory)
    try gitFailureInjector.check(.indexPublication)
    try requireCurrentBranchState(
      journal.branchRef,
      expectedRevision: journal.candidateCommit,
      repository: repository
    )
  }

  private func requireIndexUnlocked(_ repository: GitRepositoryContext) throws {
    guard !FileManager.default.fileExists(atPath: repository.indexLockURL.path) else {
      throw policyError("git index lock is owned by another process or requires operator resolution", retryable: true)
    }
  }

  private func validatedBranchRef(repository: GitRepositoryContext) throws -> String {
    let value = try requiredSingleLine(runRepositoryGit(
      ["symbolic-ref", "--quiet", "HEAD"],
      repository: repository
    ).output, name: "branch ref")
    guard value.hasPrefix("refs/heads/"), value.utf8.count <= 1_035 else {
      throw policyError("riela/git-commit requires a named local branch")
    }
    return value
  }

  private func requireCurrentBranchRef(
    _ expectedBranchRef: String,
    repository: GitRepositoryContext
  ) throws {
    let currentBranchRef = try requiredSingleLine(runRepositoryGit(
      ["symbolic-ref", "--quiet", "HEAD"],
      repository: repository
    ).output, name: "current branch ref")
    guard currentBranchRef == expectedBranchRef else {
      throw policyError("git current branch changed during commit finalization", retryable: true)
    }
  }

  private func verifyAndUpdateCurrentBranch(
    _ journal: GitCommitJournal,
    expectedRevision: String,
    advancesRef: Bool,
    repository: GitRepositoryContext
  ) throws {
    try requireCurrentBranchState(
      journal.branchRef,
      expectedRevision: expectedRevision,
      repository: repository
    )
    if advancesRef {
      try requireIndexEntryIdentity(repository)
      _ = try runRepositoryGit(
        [
          "update-ref",
          "--create-reflog",
          "-m", "riela-finalization:\(journal.operationToken)",
          journal.branchRef,
          journal.candidateCommit,
          journal.parentCommit
        ],
        repository: repository
      )
      guard try reflogProves(journal, repository: repository) else {
        throw policyError("git ref update did not create exact recovery proof")
      }
    }
    try requireCurrentBranchState(
      journal.branchRef,
      expectedRevision: journal.candidateCommit,
      repository: repository
    )
  }

  private func requireCurrentBranchState(
    _ expectedBranchRef: String,
    expectedRevision: String,
    repository: GitRepositoryContext
  ) throws {
    try requireCurrentBranchRef(expectedBranchRef, repository: repository)
    guard try headRevision(repository: repository) == expectedRevision else {
      throw policyError("git current HEAD changed during commit finalization", retryable: true)
    }
  }

  private func gitCommitIdentity(
    repository: GitRepositoryContext,
    prefix: String
  ) throws -> (name: String, email: String) {
    let name = try configuredIdentityValue(
      preferredKey: "\(prefix).name",
      fallbackKey: "user.name",
      field: "\(prefix) name",
      repository: repository
    )
    let email = try configuredIdentityValue(
      preferredKey: "\(prefix).email",
      fallbackKey: "user.email",
      field: "\(prefix) email",
      repository: repository
    )
    return (name, email)
  }

  private func configuredIdentityValue(
    preferredKey: String,
    fallbackKey: String,
    field: String,
    repository: GitRepositoryContext
  ) throws -> String {
    let preferred = try runRepositoryGitResult(
      ["config", "--get", preferredKey],
      repository: repository
    )
    if preferred.exitCode == 0 {
      return try boundedIdentityValue(preferred.output, field: field)
    }
    guard preferred.exitCode == 1 else {
      throw AdapterExecutionError(
        .providerError,
        "git identity configuration failed with exit code \(preferred.exitCode)",
        isRetryable: true
      )
    }
    return try boundedIdentityValue(
      runRepositoryGit(["config", "--get", fallbackKey], repository: repository).output,
      field: field
    )
  }

  private func boundedIdentityValue(_ output: String, field: String) throws -> String {
    let value = try requiredSingleLine(output, name: field)
    guard value.utf8.count <= 1_024 else {
      throw policyError("git \(field) exceeds its size limit")
    }
    return value
  }

  private func gitWorktreeModePolicy(repository: GitRepositoryContext) throws -> GitWorktreeModePolicy {
    GitWorktreeModePolicy(
      tracksExecutableBit: try gitBooleanConfiguration(
        "core.filemode",
        defaultValue: true,
        repository: repository
      ),
      checksOutSymlinks: try gitBooleanConfiguration(
        "core.symlinks",
        defaultValue: true,
        repository: repository
      )
    )
  }

  private func gitBooleanConfiguration(
    _ key: String,
    defaultValue: Bool,
    repository: GitRepositoryContext
  ) throws -> Bool {
    let result = try runRepositoryGitResult(
      ["config", "--bool", "--get", key],
      repository: repository
    )
    if result.exitCode == 1 {
      return defaultValue
    }
    guard result.exitCode == 0 else {
      throw AdapterExecutionError(
        .providerError,
        "git worktree-mode configuration failed with exit code \(result.exitCode)",
        isRetryable: true
      )
    }
    switch try requiredSingleLine(result.output, name: key) {
    case "true":
      return true
    case "false":
      return false
    default:
      throw AdapterExecutionError(.invalidOutput, "git returned an invalid worktree-mode value")
    }
  }

  private func treeForCommit(_ commit: String, repository: GitRepositoryContext) throws -> String {
    try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["show", "-s", "--format=%T", commit],
      repository: repository
    ).output, name: "commit tree"))
  }

  private func reflogProves(_ journal: GitCommitJournal, repository: GitRepositoryContext) throws -> Bool {
    let output = try runRepositoryGitResult(
      ["reflog", "show", "--format=%H%x00%gs", "-z", "-n", "1", journal.branchRef],
      repository: repository
    )
    guard output.exitCode == 0 else {
      return false
    }
    let fields = output.output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    guard fields == [journal.candidateCommit, "riela-finalization:\(journal.operationToken)"] else {
      return false
    }
    let previousBranchRevision = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["rev-parse", "\(journal.branchRef)@{1}^{commit}"],
      repository: repository
    ).output, name: "previous branch revision"))
    let candidateParent = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["rev-parse", "\(journal.candidateCommit)^"],
      repository: repository
    ).output, name: "candidate parent"))
    return previousBranchRevision == journal.parentCommit && candidateParent == journal.parentCommit
  }
}

private struct GitOwnedIndexLock {
  var descriptor: Int32
  var identity: GitOwnedLockIdentity
}

private struct GitOwnedLockIdentity: Equatable {
  var device: UInt64
  var inode: UInt64
}

private func createOwnedIndexLock(_ url: URL, data: Data) throws -> GitOwnedIndexLock {
  let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  guard descriptor >= 0 else {
    if errno == EEXIST {
      throw policyError("git index lock is owned by another process or requires operator resolution", retryable: true)
    }
    throw policyError("git index lock could not be created", retryable: true)
  }
  var status = stat()
  var ownedIdentity: GitOwnedLockIdentity?
  do {
    guard fstat(descriptor, &status) == 0 else {
      throw policyError("git index lock identity could not be read")
    }
    ownedIdentity = GitOwnedLockIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino)
    )
    try data.withUnsafeBytes { rawBuffer in
      guard var baseAddress = rawBuffer.baseAddress else { return }
      var remaining = rawBuffer.count
      while remaining > 0 {
        let written = write(descriptor, baseAddress, remaining)
        guard written > 0 else {
          throw policyError("git prepared index could not be written")
        }
        remaining -= written
        baseAddress = baseAddress.advanced(by: written)
      }
    }
    guard fsync(descriptor) == 0 else {
      throw policyError("git prepared index could not be synchronized")
    }
  } catch {
    if let ownedIdentity {
      removeOwnedIndexLock(
        GitOwnedIndexLock(descriptor: descriptor, identity: ownedIdentity),
        at: url
      )
    }
    close(descriptor)
    throw error
  }
  guard let ownedIdentity else {
    close(descriptor)
    throw policyError("git index lock identity could not be retained")
  }
  return GitOwnedIndexLock(descriptor: descriptor, identity: ownedIdentity)
}

private func lockIdentity(at url: URL) -> GitOwnedLockIdentity? {
  var status = stat()
  guard lstat(url.path, &status) == 0 else {
    return nil
  }
  return GitOwnedLockIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
}

private func requireOwnedIndexLock(_ lock: GitOwnedIndexLock, at url: URL) throws {
  var status = stat()
  guard fstat(lock.descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG,
        status.st_nlink == 1,
        GitOwnedLockIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino)) == lock.identity,
        lockIdentity(at: url) == lock.identity else {
    throw policyError("git index lock ownership changed before publication")
  }
}

private func removeOwnedIndexLock(_ lock: GitOwnedIndexLock, at url: URL) {
  guard lockIdentity(at: url) == lock.identity else {
    return
  }
  try? FileManager.default.removeItem(at: url)
}

private func synchronizeDirectory(_ directory: URL) throws {
  let descriptor = open(directory.path, O_RDONLY)
  guard descriptor >= 0 else {
    throw policyError("git directory could not be opened for synchronization")
  }
  defer { close(descriptor) }
  guard fsync(descriptor) == 0 else {
    throw policyError("git directory could not be synchronized")
  }
}
