import Foundation
#if canImport(Darwin)
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif
#else
import Glibc
#endif
import RielaCore

struct GitRepositoryContext: Sendable {
  var root: URL
  var gitDirectory: URL
  var commonDirectory: URL
  var objectDirectory: URL
  var objectFormat: GitObjectFormat
  var indexURL: URL
  var indexLockURL: URL
  var indexEntryIdentity: GitIndexEntryIdentity
  var identity: GitRepositoryIdentity
  var executableURL: URL
}

enum GitObjectFormat: String, Codable, Equatable, Sendable {
  case sha1
  case sha256
}

struct GitIndexEntryIdentity: Equatable, Sendable {
  var device: UInt64
  var inode: UInt64
}

struct GitWorktreeModePolicy: Equatable, Sendable {
  var tracksExecutableBit: Bool
  var checksOutSymlinks: Bool
}

private struct GitRepositoryPathSnapshot: Equatable {
  var gitDirectory: URL
  var commonDirectory: URL
  var objectDirectory: URL
  var objectDirectoryIdentity: GitIndexEntryIdentity
  var objectFormat: GitObjectFormat
  var indexURL: URL
}

private struct GitCommonDirectoryLinkSnapshot: Equatable {
  var path: URL
  var device: UInt64
  var inode: UInt64
  var fileDigest: String
}

private struct GitDiscoverySnapshot: Equatable {
  var device: UInt64
  var inode: UInt64
  var fileDigest: String?
  var expectedGitDirectory: URL
  var backpointer: GitBackpointerSnapshot?
}

private struct GitBackpointerSnapshot: Equatable {
  var path: URL
  var device: UInt64
  var inode: UInt64
  var fileDigest: String
}

extension BuiltinWorkflowAddonResolver {
  func prepareGitFinalizationStore(repository: GitRepositoryContext) throws {
    try gitFinalizationStore.prepare(repositoryRoot: repository.root)
    try gitFinalizationStore.garbageCollectFailedArtifacts()
  }

  func loadGitRepository() throws -> GitRepositoryContext {
    let prevalidatedExecutable = try validateProductionGitExecutable(repositoryRoot: workingDirectory)
    let root = try canonicalDirectory(
      gitPathOutput(["rev-parse", "--show-toplevel"], executableURL: prevalidatedExecutable),
      relativeTo: workingDirectory
    )
    let resolvedWorkingDirectory = workingDirectory.resolvingSymlinksInPath().standardizedFileURL
    guard root.path == resolvedWorkingDirectory.path else {
      throw policyError("git workflow add-ons must run from the repository root")
    }
    let executable = try validateProductionGitExecutable(repositoryRoot: root)
    let gitDiscoveryURL = root.appendingPathComponent(".git").standardizedFileURL
    let gitDiscovery = try gitDiscoverySnapshot(gitDiscoveryURL)
    let repositoryPaths = try repositoryPathSnapshot(executableURL: executable, root: root)
    let gitDirectory = repositoryPaths.gitDirectory
    let commonDirectory = repositoryPaths.commonDirectory
    let commonDirectoryLink = try commonDirectoryLinkSnapshot(
      gitDirectory: gitDirectory,
      commonDirectory: commonDirectory
    )
    let objectDirectory = repositoryPaths.objectDirectory
    let objectFormat = repositoryPaths.objectFormat
    let indexURL = repositoryPaths.indexURL
    let indexEntryIdentity = try regularPathEntryIdentity(indexURL)
    let indexParent = indexURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    let indexLockURL = URL(fileURLWithPath: indexURL.path + ".lock").standardizedFileURL
    let verifiedPaths = try repositoryPathSnapshot(executableURL: executable, root: root)
    let verifiedCommonDirectoryLink = try commonDirectoryLinkSnapshot(
      gitDirectory: verifiedPaths.gitDirectory,
      commonDirectory: verifiedPaths.commonDirectory
    )
    let verifiedDiscovery = try gitDiscoverySnapshot(gitDiscoveryURL)
    guard verifiedPaths == repositoryPaths,
          verifiedDiscovery == gitDiscovery,
          verifiedCommonDirectoryLink == commonDirectoryLink,
          repositoryPaths.gitDirectory == gitDiscovery.expectedGitDirectory else {
      throw policyError("git repository paths changed during preflight", retryable: true)
    }
    return GitRepositoryContext(
      root: root,
      gitDirectory: gitDirectory,
      commonDirectory: commonDirectory,
      objectDirectory: objectDirectory,
      objectFormat: objectFormat,
      indexURL: indexURL,
      indexLockURL: indexLockURL,
      indexEntryIdentity: indexEntryIdentity,
      identity: GitRepositoryIdentity(
        worktreePath: root.path,
        worktreeDevice: try fileIdentity(root).device,
        worktreeInode: try fileIdentity(root).inode,
        gitDiscoveryPath: gitDiscoveryURL.path,
        gitDiscoveryDevice: gitDiscovery.device,
        gitDiscoveryInode: gitDiscovery.inode,
        gitDiscoveryFileDigest: gitDiscovery.fileDigest,
        gitBackpointerPath: gitDiscovery.backpointer?.path.path,
        gitBackpointerDevice: gitDiscovery.backpointer?.device,
        gitBackpointerInode: gitDiscovery.backpointer?.inode,
        gitBackpointerFileDigest: gitDiscovery.backpointer?.fileDigest,
        gitDirectoryPath: gitDirectory.path,
        gitDirectoryDevice: try fileIdentity(gitDirectory).device,
        gitDirectoryInode: try fileIdentity(gitDirectory).inode,
        commonDirectoryPath: commonDirectory.path,
        commonDirectoryDevice: try fileIdentity(commonDirectory).device,
        commonDirectoryInode: try fileIdentity(commonDirectory).inode,
        commonDirectoryLinkPath: commonDirectoryLink?.path.path,
        commonDirectoryLinkDevice: commonDirectoryLink?.device,
        commonDirectoryLinkInode: commonDirectoryLink?.inode,
        commonDirectoryLinkDigest: commonDirectoryLink?.fileDigest,
        objectDirectoryPath: objectDirectory.path,
        objectDirectoryDevice: repositoryPaths.objectDirectoryIdentity.device,
        objectDirectoryInode: repositoryPaths.objectDirectoryIdentity.inode,
        objectFormat: objectFormat,
        indexPath: indexURL.path,
        indexDevice: indexEntryIdentity.device,
        indexInode: indexEntryIdentity.inode,
        indexParentPath: indexParent.path,
        indexParentDevice: try fileIdentity(indexParent).device,
        indexParentInode: try fileIdentity(indexParent).inode
      ),
      executableURL: executable
    )
  }

  func requireRepositoryIdentity(_ repository: GitRepositoryContext) throws {
    let identity = repository.identity
    try requireFileIdentity(
      repository.root,
      path: identity.worktreePath,
      device: identity.worktreeDevice,
      inode: identity.worktreeInode,
      diagnostic: "worktree"
    )
    let gitDiscoveryURL = repository.root.appendingPathComponent(".git").standardizedFileURL
    let gitDiscovery = try gitDiscoverySnapshot(gitDiscoveryURL)
    guard gitDiscoveryURL.path == identity.gitDiscoveryPath,
          gitDiscovery.device == identity.gitDiscoveryDevice,
          gitDiscovery.inode == identity.gitDiscoveryInode,
          gitDiscovery.fileDigest == identity.gitDiscoveryFileDigest,
          gitDiscovery.expectedGitDirectory == repository.gitDirectory,
          gitDiscovery.backpointer?.path.path == identity.gitBackpointerPath,
          gitDiscovery.backpointer?.device == identity.gitBackpointerDevice,
          gitDiscovery.backpointer?.inode == identity.gitBackpointerInode,
          gitDiscovery.backpointer?.fileDigest == identity.gitBackpointerFileDigest else {
      throw policyError("git repository discovery metadata changed after preflight", retryable: true)
    }
    try requireFileIdentity(
      repository.gitDirectory,
      path: identity.gitDirectoryPath,
      device: identity.gitDirectoryDevice,
      inode: identity.gitDirectoryInode,
      diagnostic: "per-worktree git directory"
    )
    try requireFileIdentity(
      repository.commonDirectory,
      path: identity.commonDirectoryPath,
      device: identity.commonDirectoryDevice,
      inode: identity.commonDirectoryInode,
      diagnostic: "common git directory"
    )
    let commonDirectoryLink = try commonDirectoryLinkSnapshot(
      gitDirectory: repository.gitDirectory,
      commonDirectory: repository.commonDirectory
    )
    guard commonDirectoryLink?.path.path == identity.commonDirectoryLinkPath,
          commonDirectoryLink?.device == identity.commonDirectoryLinkDevice,
          commonDirectoryLink?.inode == identity.commonDirectoryLinkInode,
          commonDirectoryLink?.fileDigest == identity.commonDirectoryLinkDigest else {
      throw policyError("git common-directory binding changed after preflight", retryable: true)
    }
    let objectDirectoryIdentity = try directoryPathEntryIdentity(repository.objectDirectory)
    guard repository.objectDirectory.path == identity.objectDirectoryPath,
          objectDirectoryIdentity.device == identity.objectDirectoryDevice,
          objectDirectoryIdentity.inode == identity.objectDirectoryInode else {
      throw policyError("git object directory changed after preflight", retryable: true)
    }
    try requireFileIdentity(
      repository.indexURL.deletingLastPathComponent(),
      path: identity.indexParentPath,
      device: identity.indexParentDevice,
      inode: identity.indexParentInode,
      diagnostic: "index parent"
    )
  }

  func requireIndexEntryIdentity(_ repository: GitRepositoryContext) throws {
    let expectedIndexURL = repository.gitDirectory.appendingPathComponent("index").standardizedFileURL
    let identity = try regularPathEntryIdentity(repository.indexURL)
    guard repository.indexURL.path == expectedIndexURL.path,
          repository.indexURL.path == repository.identity.indexPath,
          identity == repository.indexEntryIdentity,
          identity.device == repository.identity.indexDevice,
          identity.inode == repository.identity.indexInode else {
      throw policyError("git per-worktree index identity changed after preflight", retryable: true)
    }
  }

  func runRepositoryGit(
    _ arguments: [String],
    repository: GitRepositoryContext,
    environment: [String: String] = [:],
    standardInput: Data? = nil,
    standardInputFileDescriptor: Int32? = nil
  ) throws -> GitCommandResult {
    try requireRepositoryIdentity(repository)
    return try runGit(
      pinnedRepositoryArguments(arguments, repository: repository),
      environment: environment,
      standardInput: standardInput,
      standardInputFileDescriptor: standardInputFileDescriptor,
      executableURL: repository.executableURL,
      workingDirectory: repository.root
    )
  }

  func runRepositoryGitResult(
    _ arguments: [String],
    repository: GitRepositoryContext,
    environment: [String: String] = [:]
  ) throws -> GitCommandResult {
    try requireRepositoryIdentity(repository)
    return try runGitResult(
      pinnedRepositoryArguments(arguments, repository: repository),
      environment: environment,
      executableURL: repository.executableURL,
      workingDirectory: repository.root
    )
  }

  private func pinnedRepositoryArguments(
    _ arguments: [String],
    repository: GitRepositoryContext
  ) -> [String] {
    [
      "--git-dir=\(repository.gitDirectory.path)",
      "--work-tree=\(repository.root.path)"
    ] + arguments
  }

  private func requireFileIdentity(
    _ url: URL,
    path: String,
    device: UInt64,
    inode: UInt64,
    diagnostic: String
  ) throws {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    guard canonical.path == path else {
      throw policyError("git \(diagnostic) path changed after preflight", retryable: true)
    }
    let current = try fileIdentity(canonical)
    guard current.device == device, current.inode == inode else {
      throw policyError("git \(diagnostic) identity changed after preflight", retryable: true)
    }
  }

  func validateCommitPaths(_ paths: [String], repository: GitRepositoryContext) throws {
    for path in paths {
      try validateRepositoryRelativePath(path)
      let url = repository.root.appendingPathComponent(path).standardizedFileURL
      guard isURL(url, inside: repository.root) else {
        throw policyError("riela/git-commit path escapes the repository")
      }
      switch try openConfinedGitCommitPath(path, repository: repository) {
      case let .regularFile(openedFile):
        close(openedFile.descriptor)
      case .missing:
        let tracked = try runRepositoryGitResult(
          ["ls-files", "--error-unmatch", "--", path],
          repository: repository
        )
        guard tracked.exitCode == 0 else {
          throw policyError("riela/git-commit missing path is not an exact tracked deletion")
        }
      }
    }
    try rejectCustomCleanFilters(paths, repository: repository)
  }

  func validateRepositoryRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.hasPrefix(":"),
          !path.contains("\0"),
          !path.contains("\n"),
          !path.contains("\r"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
          components.first != ".git" else {
      throw policyError("riela/git-commit contains an invalid repository-relative path")
    }
  }

  func stagedPaths(
    repository: GitRepositoryContext,
    indexURL: URL? = nil
  ) throws -> [String] {
    var gitEnvironment: [String: String] = [:]
    if let indexURL {
      gitEnvironment["GIT_INDEX_FILE"] = indexURL.path
    }
    return try nulSeparatedPaths(runRepositoryGit(
      ["diff", "--cached", "--name-only", "-z", "--"],
      repository: repository,
      environment: gitEnvironment
    ).output)
  }

  func stageCommitPaths(
    _ paths: [String],
    repository: GitRepositoryContext,
    indexURL: URL,
    modePolicy: GitWorktreeModePolicy
  ) throws {
    let indexEnvironment = ["GIT_INDEX_FILE": indexURL.path]
    for path in paths {
      switch try openConfinedGitCommitPath(path, repository: repository) {
      case let .regularFile(openedFile):
        let objectID: String
        do {
          defer { close(openedFile.descriptor) }
          objectID = try validatedObjectID(requiredSingleLine(runRepositoryGit(
            ["hash-object", "-w", "--no-filters", "--stdin"],
            repository: repository,
            standardInputFileDescriptor: openedFile.descriptor
          ).output, name: "blob object id"))
        }
        let mode = try preparedIndexMode(
          for: path,
          repository: repository,
          indexURL: indexURL
        ).map { existingMode in
          if existingMode == "120000" {
            return modePolicy.checksOutSymlinks ? openedFile.mode : existingMode
          }
          return modePolicy.tracksExecutableBit ? openedFile.mode : existingMode
        } ?? openedFile.mode
        _ = try runRepositoryGit(
          ["update-index", "--add", "--cacheinfo", "\(mode),\(objectID),\(path)"],
          repository: repository,
          environment: indexEnvironment
        )
      case .missing:
        _ = try runRepositoryGit(
          ["update-index", "--remove", "--", path],
          repository: repository,
          environment: indexEnvironment
        )
      }
    }
  }

  private func preparedIndexMode(
    for path: String,
    repository: GitRepositoryContext,
    indexURL: URL
  ) throws -> String? {
    let output = try runRepositoryGit(
      ["ls-files", "--stage", "-z", "--", path],
      repository: repository,
      environment: ["GIT_INDEX_FILE": indexURL.path]
    ).output
    guard !output.isEmpty else {
      return nil
    }
    let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    guard records.count == 1,
          let separator = records[0].firstIndex(of: "\t"),
          String(records[0][records[0].index(after: separator)...]) == path else {
      throw policyError("riela/git-commit prepared index mode is ambiguous")
    }
    let fields = records[0][..<separator].split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count == 3,
          fields[2] == "0",
          ["100644", "100755", "120000"].contains(fields[0]) else {
      throw policyError("riela/git-commit prepared index mode is unsupported")
    }
    return fields[0]
  }

  func requireExactStagedPaths(_ staged: [String], allowed: [String], diagnostic: String) throws {
    guard Set(staged) == Set(allowed), staged.count == allowed.count else {
      throw policyError("riela/git-commit refuses a \(diagnostic) mismatch")
    }
  }

  func requireStagedPathsAreAllowlisted(_ staged: [String], allowed: [String], diagnostic: String) throws {
    let allowedSet = Set(allowed)
    guard staged.allSatisfy(allowedSet.contains) else {
      throw policyError("riela/git-commit refuses an allowlist-external \(diagnostic)")
    }
  }

  func headRevision(repository: GitRepositoryContext) throws -> String {
    let revision = try requiredSingleLine(runRepositoryGit(
      ["rev-parse", "--verify", "HEAD^{commit}"],
      repository: repository
    ).output, name: "HEAD revision")
    return try validatedObjectID(revision)
  }

  func validatedObjectID(_ value: String) throws -> String {
    guard value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil else {
      throw AdapterExecutionError(.invalidOutput, "git returned an invalid object id")
    }
    return value
  }

  func requiredSingleLine(_ output: String, name: String) throws -> String {
    let value = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, !value.contains("\n"), !value.contains("\r"), !value.contains("\0") else {
      throw AdapterExecutionError(.invalidOutput, "git returned an invalid \(name)")
    }
    return value
  }

  func nulSeparatedPaths(_ output: String) throws -> [String] {
    let values = output.split(separator: "\0").map(String.init)
    guard values.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\r") }) else {
      throw AdapterExecutionError(.invalidOutput, "git returned invalid repository paths")
    }
    return values
  }

  private func rejectCustomCleanFilters(_ paths: [String], repository: GitRepositoryContext) throws {
    for path in paths {
      let output = try runRepositoryGit(
        ["check-attr", "-z", "filter", "--", path],
        repository: repository
      ).output.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
      guard output.count >= 3 else {
        throw AdapterExecutionError(.invalidOutput, "git returned invalid clean-filter attributes")
      }
      let value = output[2]
      guard value == "unspecified" || value == "unset" else {
        throw policyError("riela/git-commit refuses paths with a custom clean filter")
      }
    }
  }

  private func gitPathOutput(_ arguments: [String], executableURL: URL) throws -> String {
    try requiredSingleLine(runGit(arguments, executableURL: executableURL).output, name: "repository path")
  }

  private func repositoryPathSnapshot(
    executableURL: URL,
    root: URL
  ) throws -> GitRepositoryPathSnapshot {
    let gitDirectory = try canonicalDirectory(
      gitPathOutput(["rev-parse", "--absolute-git-dir"], executableURL: executableURL),
      relativeTo: root
    )
    let commonDirectory = try canonicalDirectory(
      gitPathOutput(["rev-parse", "--git-common-dir"], executableURL: executableURL),
      relativeTo: root
    )
    let objectDirectory = canonicalPathEntry(
      try gitPathOutput(["rev-parse", "--git-path", "objects"], executableURL: executableURL),
      relativeTo: root
    )
    let expectedObjectDirectory = commonDirectory.appendingPathComponent("objects", isDirectory: true).standardizedFileURL
    guard objectDirectory.path == expectedObjectDirectory.path else {
      throw policyError("git object directory is not confined to the common git directory")
    }
    let objectDirectoryIdentity = try directoryPathEntryIdentity(objectDirectory)
    let objectFormatValue = try requiredSingleLine(runGit(
      ["rev-parse", "--show-object-format"],
      executableURL: executableURL,
      workingDirectory: root
    ).output, name: "object format")
    guard let objectFormat = GitObjectFormat(rawValue: objectFormatValue) else {
      throw policyError("git repository object format is unsupported")
    }
    let indexURL = canonicalPathEntry(
      try gitPathOutput(["rev-parse", "--git-path", "index"], executableURL: executableURL),
      relativeTo: root
    )
    let expectedIndexURL = gitDirectory.appendingPathComponent("index").standardizedFileURL
    guard indexURL.path == expectedIndexURL.path else {
      throw policyError("git index path is not confined to the per-worktree git directory")
    }
    return GitRepositoryPathSnapshot(
      gitDirectory: gitDirectory,
      commonDirectory: commonDirectory,
      objectDirectory: objectDirectory,
      objectDirectoryIdentity: objectDirectoryIdentity,
      objectFormat: objectFormat,
      indexURL: indexURL
    )
  }

  private func commonDirectoryLinkSnapshot(
    gitDirectory: URL,
    commonDirectory: URL
  ) throws -> GitCommonDirectoryLinkSnapshot? {
    let linkURL = gitDirectory.appendingPathComponent("commondir").standardizedFileURL
    let descriptor = open(linkURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if descriptor < 0, errno == ENOENT {
      guard gitDirectory == commonDirectory else {
        throw policyError("git linked worktree is missing its common-directory binding")
      }
      return nil
    }
    guard descriptor >= 0 else {
      throw policyError("git common-directory binding could not be opened")
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1 else {
      throw policyError("git common-directory binding must be a single-link regular file")
    }
    let data = try readBoundedDiscoveryFile(descriptor, maximumBytes: 8 * 1024)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw policyError("git common-directory binding is not valid UTF-8")
    }
    let value = rawValue.trimmingCharacters(in: .newlines)
    guard !value.isEmpty,
          !value.contains("\n"),
          !value.contains("\r"),
          !value.contains("\0") else {
      throw policyError("git common-directory binding is invalid")
    }
    let boundCommonDirectory = try canonicalDirectory(value, relativeTo: gitDirectory)
    let expectedWorktreesDirectory = commonDirectory.appendingPathComponent("worktrees", isDirectory: true)
      .standardizedFileURL
    guard boundCommonDirectory == commonDirectory,
          gitDirectory != commonDirectory,
          gitDirectory.deletingLastPathComponent() == expectedWorktreesDirectory else {
      throw policyError("git common-directory binding is outside the validated worktree layout")
    }
    return GitCommonDirectoryLinkSnapshot(
      path: linkURL,
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      fileDigest: sha256(data)
    )
  }

  private func canonicalDirectory(_ path: String, relativeTo base: URL) throws -> URL {
    let url = canonicalURL(path, relativeTo: base)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw policyError("git returned a missing repository directory")
    }
    return url
  }

  private func canonicalPathEntry(_ path: String, relativeTo base: URL) -> URL {
    let lexicalURL = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    let canonicalParent = lexicalURL.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    return canonicalParent.appendingPathComponent(lexicalURL.lastPathComponent).standardizedFileURL
  }

  private func canonicalURL(_ path: String, relativeTo base: URL) -> URL {
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)
    return url.standardizedFileURL.resolvingSymlinksInPath()
  }

  private func fileIdentity(_ url: URL) throws -> (device: UInt64, inode: UInt64) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let device = attributes[.systemNumber] as? NSNumber,
          let inode = attributes[.systemFileNumber] as? NSNumber else {
      throw policyError("repository filesystem identity could not be read")
    }
    return (device.uint64Value, inode.uint64Value)
  }

  private func regularPathEntryIdentity(_ url: URL) throws -> GitIndexEntryIdentity {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG,
          status.st_nlink == 1 else {
      throw policyError("git per-worktree index must be a single-link regular file")
    }
    return GitIndexEntryIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino)
    )
  }

  private func directoryPathEntryIdentity(_ url: URL) throws -> GitIndexEntryIdentity {
    var status = stat()
    guard lstat(url.path, &status) == 0,
          status.st_mode & S_IFMT == S_IFDIR else {
      throw policyError("git object directory must be a non-symlink directory")
    }
    return GitIndexEntryIdentity(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino)
    )
  }

  private func gitDiscoverySnapshot(_ url: URL) throws -> GitDiscoverySnapshot {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw policyError("git repository discovery metadata could not be opened")
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw policyError("git repository discovery metadata identity could not be read")
    }
    let entryType = status.st_mode & S_IFMT
    if entryType == S_IFDIR {
      return GitDiscoverySnapshot(
        device: UInt64(status.st_dev),
        inode: UInt64(status.st_ino),
        fileDigest: nil,
        expectedGitDirectory: url.standardizedFileURL,
        backpointer: nil
      )
    }
    guard entryType == S_IFREG else {
      throw policyError("git repository discovery metadata must be a directory or regular file")
    }
    let data = try readBoundedDiscoveryFile(descriptor, maximumBytes: 8 * 1024)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw policyError("git repository discovery metadata is not valid UTF-8")
    }
    let value = rawValue.trimmingCharacters(in: .newlines)
    let prefix = "gitdir: "
    guard value.hasPrefix(prefix),
          !value.contains("\n"),
          !value.contains("\r"),
          !value.contains("\0") else {
      throw policyError("git repository discovery metadata is invalid")
    }
    let path = String(value.dropFirst(prefix.count))
    guard !path.isEmpty else {
      throw policyError("git repository discovery metadata is invalid")
    }
    let expectedGitDirectory = try canonicalDirectory(path, relativeTo: url.deletingLastPathComponent())
    return GitDiscoverySnapshot(
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      fileDigest: sha256(data),
      expectedGitDirectory: expectedGitDirectory,
      backpointer: try gitBackpointerSnapshot(
        gitDirectory: expectedGitDirectory,
        expectedDiscoveryURL: url
      )
    )
  }

  private func gitBackpointerSnapshot(
    gitDirectory: URL,
    expectedDiscoveryURL: URL
  ) throws -> GitBackpointerSnapshot {
    let backpointerURL = gitDirectory.appendingPathComponent("gitdir").standardizedFileURL
    let descriptor = open(backpointerURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else {
      throw policyError("git linked-worktree backpointer could not be opened")
    }
    defer { close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0,
          status.st_mode & S_IFMT == S_IFREG else {
      throw policyError("git linked-worktree backpointer is not a regular file")
    }
    let data = try readBoundedDiscoveryFile(descriptor, maximumBytes: 8 * 1024)
    guard let rawValue = String(data: data, encoding: .utf8) else {
      throw policyError("git linked-worktree backpointer is not valid UTF-8")
    }
    let value = rawValue.trimmingCharacters(in: .newlines)
    guard !value.isEmpty,
          !value.contains("\n"),
          !value.contains("\r"),
          !value.contains("\0") else {
      throw policyError("git linked-worktree backpointer is invalid")
    }
    let referencedDiscoveryURL = canonicalPathEntry(value, relativeTo: gitDirectory)
    guard referencedDiscoveryURL == expectedDiscoveryURL else {
      throw policyError("git repository discovery metadata backpointer does not match the worktree discovery path")
    }
    return GitBackpointerSnapshot(
      path: backpointerURL,
      device: UInt64(status.st_dev),
      inode: UInt64(status.st_ino),
      fileDigest: sha256(data)
    )
  }
}

private func readBoundedDiscoveryFile(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
  var data = Data()
  var buffer = [UInt8](repeating: 0, count: 4 * 1024)
  while true {
    let bytesRead = read(descriptor, &buffer, buffer.count)
    if bytesRead > 0 {
      guard data.count + bytesRead <= maximumBytes else {
        throw policyError("git repository discovery metadata is oversized")
      }
      data.append(buffer, count: bytesRead)
      continue
    }
    if bytesRead == 0 {
      return data
    }
    if errno == EINTR {
      continue
    }
    throw policyError("git repository discovery metadata could not be read")
  }
}

private struct GitOpenedWorktreeFile {
  var descriptor: Int32
  var mode: String
}

private enum GitCommitWorktreeEntry {
  case regularFile(GitOpenedWorktreeFile)
  case missing
}

private func openConfinedGitCommitPath(
  _ path: String,
  repository: GitRepositoryContext
) throws -> GitCommitWorktreeEntry {
  let components = path.split(separator: "/").map(String.init)
  guard let fileName = components.last else {
    throw policyError("riela/git-commit path is empty")
  }
  var directoryDescriptor = open(repository.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard directoryDescriptor >= 0 else {
    throw policyError("riela/git-commit repository root could not be opened")
  }
  defer { close(directoryDescriptor) }
  var rootStatus = stat()
  guard fstat(directoryDescriptor, &rootStatus) == 0,
        UInt64(rootStatus.st_dev) == repository.identity.worktreeDevice,
        UInt64(rootStatus.st_ino) == repository.identity.worktreeInode else {
    throw policyError("riela/git-commit repository identity changed before staging")
  }
  for component in components.dropLast() {
    let nextDescriptor = openat(
      directoryDescriptor,
      component,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    if nextDescriptor < 0, errno == ENOENT {
      return .missing
    }
    guard nextDescriptor >= 0 else {
      throw policyError("riela/git-commit path ancestry changed before staging")
    }
    close(directoryDescriptor)
    directoryDescriptor = nextDescriptor
  }
  let fileDescriptor = openat(
    directoryDescriptor,
    fileName,
    O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
  )
  if fileDescriptor < 0, errno == ENOENT {
    return .missing
  }
  guard fileDescriptor >= 0 else {
    throw policyError("riela/git-commit file changed before staging")
  }
  var fileStatus = stat()
  guard fstat(fileDescriptor, &fileStatus) == 0,
        fileStatus.st_mode & S_IFMT == S_IFREG else {
    close(fileDescriptor)
    throw policyError("riela/git-commit staged input is not a regular file")
  }
  let mode = fileStatus.st_mode & mode_t(0o111) == 0 ? "100644" : "100755"
  return .regularFile(GitOpenedWorktreeFile(descriptor: fileDescriptor, mode: mode))
}

func indexDigest(
  at url: URL,
  expectedIdentity: GitIndexEntryIdentity? = nil
) throws -> String {
  sha256(try boundedIndexData(at: url, expectedIdentity: expectedIdentity))
}

func boundedIndexData(
  at url: URL,
  expectedIdentity: GitIndexEntryIdentity? = nil
) throws -> Data {
  let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
  guard descriptor >= 0 else {
    throw policyError("git index could not be opened without following links", retryable: true)
  }
  defer { close(descriptor) }
  var status = stat()
  guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG,
        status.st_nlink == 1,
        status.st_size >= 0,
        status.st_size <= 64 * 1024 * 1024 else {
    throw policyError("git index is not a bounded single-link regular file", retryable: true)
  }
  let actualIdentity = GitIndexEntryIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
  if let expectedIdentity, actualIdentity != expectedIdentity {
    throw policyError("git index identity changed before its bounded read", retryable: true)
  }
  var data = Data()
  data.reserveCapacity(Int(status.st_size))
  var buffer = [UInt8](repeating: 0, count: 64 * 1024)
  while true {
    if let deadline = GitCommandRuntimeContext.deadline,
       !deadline.timeIntervalSinceNow.isFinite || deadline <= Date() {
      throw AdapterExecutionError(.timeout, "git index read exceeded its workflow deadline")
    }
    let bytesRead = read(descriptor, &buffer, buffer.count)
    if bytesRead > 0 {
      guard data.count + bytesRead <= 64 * 1024 * 1024 else {
        throw policyError("git index exceeds its size limit")
      }
      data.append(buffer, count: bytesRead)
      continue
    }
    if bytesRead == 0 {
      return data
    }
    if errno == EINTR {
      continue
    }
    throw policyError("git index could not be read", retryable: true)
  }
}
