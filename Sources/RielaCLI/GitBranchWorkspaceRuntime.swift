import Foundation
import RielaCore
import RielaWork

public struct GitBranchWorkspaceError: Error, LocalizedError, Equatable, Sendable {
  public var command: String
  public var stderrHead: String

  public init(command: String, stderrHead: String) {
    self.command = command
    self.stderrHead = stderrHead
  }

  public var errorDescription: String? {
    "git command failed (\(command)): \(stderrHead)"
  }
}

public actor GitBranchWorkspaceRuntime: WorkspaceHandoverRuntime {
  private static let gitExecutableURL = URL(fileURLWithPath: "/usr/bin/git")
  private let git: any GitCommandRunning
  private let environment: [String: String]

  public init() {
    git = FoundationGitCommandRunner()
    environment = ProcessInfo.processInfo.environment
  }

  init(git: any GitCommandRunning, environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.git = git
    self.environment = environment
  }

  public func ensureBranch(
    root: String,
    attempt: AttemptID,
    task: TaskID,
    generation: Int,
    base: String?,
    isolation: RepositoryIsolation,
    template: String
  ) async throws -> IsolationRef {
    let branch = template
      .replacingOccurrences(of: "{taskId}", with: task.rawValue)
      .replacingOccurrences(of: "{generation}", with: String(generation))
    try validateBranch(branch, in: URL(fileURLWithPath: root, isDirectory: true))
    let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    let baseRevision = try resolveBase(base, root: rootURL)
    switch isolation {
    case .shared:
      let dirty = try statusPaths(rootURL).filter { !isRielaPath($0) }
      guard dirty.isEmpty else {
        throw GitBranchWorkspaceError(command: "git status --porcelain=v1 -z", stderrHead: "shared repository is dirty")
      }
      let branchExists = try run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], at: rootURL, allowFailure: true)
      if branchExists.exitCode == 0 {
        _ = try run(["checkout", branch], at: rootURL)
      } else {
        _ = try run(["checkout", "-B", branch, baseRevision], at: rootURL)
      }
      return IsolationRef(path: rootURL.path, branch: branch, baseRevision: baseRevision)
    case .worktree:
      let worktreeURL = rootURL.appendingPathComponent(".riela/worktrees/\(attempt.rawValue)", isDirectory: true)
      try FileManager.default.createDirectory(at: worktreeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      _ = try run(["worktree", "add", "-B", branch, worktreeURL.path, baseRevision], at: rootURL)
      return IsolationRef(path: worktreeURL.path, branch: branch, baseRevision: baseRevision)
    }
  }

  public func checkpoint(
    _ isolation: IsolationRef,
    message: String,
    trailer: String,
    paths: [String]?
  ) async throws -> String? {
    let root = URL(fileURLWithPath: isolation.path, isDirectory: true)
    guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !trailer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GitBranchWorkspaceError(command: "git commit", stderrHead: "checkpoint message and trailer are required")
    }
    guard let branch = isolation.branch, !branch.isEmpty else {
      throw GitBranchWorkspaceError(command: "git symbolic-ref --quiet HEAD", stderrHead: "branch is unavailable")
    }
    try requireCurrentIsolationBranch(branch, head: nil, root: root)
    let selectedPaths = paths.flatMap { $0.isEmpty ? nil : $0 } ?? ["."]
    _ = try run(["add", "-A", "--"] + selectedPaths + [":(exclude).riela"], at: root)
    let staged = try run(["diff", "--cached", "--quiet"], at: root, allowFailure: true)
    if staged.exitCode == 0 { return nil }
    guard staged.exitCode == 1 else {
      throw commandError(["diff", "--cached", "--quiet"], output: staged.output)
    }
    _ = try run(["commit", "-m", message, "-m", trailer], at: root)
    return try revision("HEAD", root: root)
  }

  public func publish(
    _ isolation: IsolationRef,
    remote: String,
    allowCreate: Bool,
    branchAllowlist: String
  ) async throws -> PublishedBranch {
    let root = URL(fileURLWithPath: isolation.path, isDirectory: true)
    guard let branch = isolation.branch, !branch.isEmpty else {
      throw GitBranchWorkspaceError(command: "git symbolic-ref --quiet HEAD", stderrHead: "branch is unavailable")
    }
    guard matchesAllowlist(branch, pattern: branchAllowlist) else {
      throw GitBranchWorkspaceError(command: "branch allowlist", stderrHead: "branch is outside the publication allowlist")
    }
    try validateBranch(branch, in: root)
    try validateRemote(remote)
    try requireCurrentIsolationBranch(branch, head: nil, root: root)
    let head = try revision("HEAD", root: root)
    let listing = try run(["ls-remote", "--heads", remote, branch], at: root)
    let remoteRevision = listing.output
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count == 2 && fields[1] == Substring("refs/heads/\(branch)") ? String(fields[0]) : nil
      }
      .first
    let created = remoteRevision == nil
    guard !created || allowCreate else {
      throw GitBranchWorkspaceError(command: "git ls-remote --heads \(remote) \(branch)", stderrHead: "remote branch does not exist and creation is disabled")
    }
    if let remoteRevision {
      if remoteRevision == head {
        return PublishedBranch(remote: remote, branch: branch, sha: head, created: false)
      }
      _ = try run(["fetch", remote, "refs/heads/\(branch)"], at: root)
      let ancestor = try run(["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], at: root, allowFailure: true)
      guard ancestor.exitCode == 0 else {
        throw GitBranchWorkspaceError(command: "git merge-base --is-ancestor FETCH_HEAD HEAD", stderrHead: "local branch is behind or diverged from remote")
      }
    }
    try requireCurrentIsolationBranch(branch, head: head, root: root)
    let pushArguments = created
      ? ["push", "--set-upstream", remote, "HEAD:refs/heads/\(branch)"]
      : ["push", remote, "HEAD:refs/heads/\(branch)"]
    _ = try run(pushArguments, at: root)
    return PublishedBranch(remote: remote, branch: branch, sha: head, created: created)
  }

  public func materialize(
    _ deliverable: RepositoryDeliverable,
    into root: String,
    worktree: Bool,
    attempt: AttemptID
  ) async throws -> IsolationRef {
    let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
    try validateBranch(deliverable.branch, in: rootURL)
    try validateRemote(deliverable.remote)
    let fetch = try run(["fetch", deliverable.remote, "refs/heads/\(deliverable.branch)"], at: rootURL, allowFailure: true)
    let commit: String
    switch deliverable.state {
    case .published:
      guard fetch.exitCode == 0 else {
        throw commandError(["fetch", deliverable.remote, "refs/heads/\(deliverable.branch)"], output: fetch.output)
      }
      let fetched = try revision("FETCH_HEAD", root: rootURL)
      guard let expected = deliverable.headCommit, fetched == expected else {
        throw GitBranchWorkspaceError(command: "git fetch \(deliverable.remote) refs/heads/\(deliverable.branch)", stderrHead: "remote branch moved")
      }
      commit = fetched
    case let .unpublished(lastKnown):
      if let lastKnown, (try? run(["cat-file", "-e", "\(lastKnown)^{commit}"], at: rootURL, allowFailure: true).exitCode) == 0 {
        commit = try revision("\(lastKnown)^{commit}", root: rootURL)
      } else {
        commit = try revision("\(deliverable.baseRevision)^{commit}", root: rootURL)
      }
    case let .checkpointFailed(reason):
      throw GitBranchWorkspaceError(command: "materialize", stderrHead: "checkpoint failed: \(String(reason.prefix(240)))")
    }

    if worktree {
      let worktreeURL = rootURL.appendingPathComponent(".riela/worktrees/\(attempt.rawValue)", isDirectory: true)
      try FileManager.default.createDirectory(at: worktreeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      _ = try run(["worktree", "add", "-B", deliverable.branch, worktreeURL.path, commit], at: rootURL)
      return IsolationRef(path: worktreeURL.path, branch: deliverable.branch, baseRevision: deliverable.baseRevision)
    }
    let dirty = try statusPaths(rootURL).filter { !isRielaPath($0) }
    guard dirty.isEmpty else {
      throw GitBranchWorkspaceError(command: "git status --porcelain=v1 -z", stderrHead: "shared repository is dirty")
    }
    _ = try run(["checkout", "-B", deliverable.branch, commit], at: rootURL)
    return IsolationRef(path: rootURL.path, branch: deliverable.branch, baseRevision: deliverable.baseRevision)
  }

  public func dirtyPaths(_ isolation: IsolationRef) async throws -> [String] {
    try statusPaths(URL(fileURLWithPath: isolation.path, isDirectory: true))
      .filter { !isRielaPath($0) }
      .uniquedSortedPrefix(512)
  }

  private func validateBranch(_ branch: String, in root: URL) throws {
    let check = try run(["check-ref-format", "--branch", branch], at: root, allowFailure: true)
    guard check.exitCode == 0 else {
      throw commandError(["check-ref-format", "--branch", branch], output: check.output)
    }
  }

  private func resolveBase(_ base: String?, root: URL) throws -> String {
    try revision("\(base ?? "HEAD")^{commit}", root: root)
  }

  private func revision(_ expression: String, root: URL) throws -> String {
    let result = try run(["rev-parse", "--verify", expression], at: root)
    let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil else {
      throw GitBranchWorkspaceError(command: "git rev-parse --verify \(expression)", stderrHead: "git returned an invalid object id")
    }
    return value
  }

  private func requireCurrentIsolationBranch(_ branch: String, head: String?, root: URL) throws {
    let result = try run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
    let currentBranch = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let headMatches = try head.map { try revision("HEAD", root: root) == $0 } ?? true
    guard currentBranch == branch, headMatches else {
      throw GitBranchWorkspaceError(command: "git symbolic-ref --quiet --short HEAD", stderrHead: "isolation branch or HEAD changed during publication")
    }
  }

  private func statusPaths(_ root: URL) throws -> [String] {
    let output = try run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root).output
    let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    var paths: [String] = []
    var index = 0
    while index < entries.count {
      let entry = entries[index]
      guard entry.utf8.count >= 4 else {
        throw GitBranchWorkspaceError(command: "git status --porcelain=v1 -z", stderrHead: "malformed porcelain status entry")
      }
      paths.append(String(entry.dropFirst(3)))
      let status = entry.prefix(2)
      if status.contains("R") || status.contains("C"), index + 1 < entries.count {
        index += 1
        paths.append(entries[index])
      }
      index += 1
    }
    return paths
  }

  private func run(
    _ arguments: [String],
    at root: URL,
    allowFailure: Bool = false
  ) throws -> GitCommandResult {
    var commandEnvironment = environment
    commandEnvironment["GIT_TERMINAL_PROMPT"] = "0"
    let invocation = GitCommandInvocation(
      executableURL: Self.gitExecutableURL,
      arguments: arguments,
      workingDirectory: root,
      environment: commandEnvironment,
      standardInput: nil
    )
    let result: GitCommandResult
    do {
      result = try git.run(invocation)
    } catch {
      throw GitBranchWorkspaceError(
        command: "git \(arguments.joined(separator: " "))",
        stderrHead: String(String(describing: error).prefix(240))
      )
    }
    guard allowFailure || result.exitCode == 0 else {
      throw commandError(arguments, output: result.output)
    }
    return result
  }

  private func commandError(_ arguments: [String], output: String) -> GitBranchWorkspaceError {
    GitBranchWorkspaceError(command: "git \(arguments.joined(separator: " "))", stderrHead: String(output.prefix(240)))
  }

  private func validateRemote(_ remote: String) throws {
    guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("\0") else {
      throw GitBranchWorkspaceError(command: "git remote", stderrHead: "remote is invalid")
    }
  }

  private func matchesAllowlist(_ branch: String, pattern: String) -> Bool {
    guard !pattern.isEmpty else { return false }
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
    let expression = "^" + escaped.replacingOccurrences(of: "\\*", with: ".*") + "$"
    return branch.range(of: expression, options: .regularExpression) != nil
  }

  private func isRielaPath(_ path: String) -> Bool {
    path == ".riela" || path.hasPrefix(".riela/")
  }
}

private extension Array where Element == String {
  func uniquedSortedPrefix(_ limit: Int) -> [String] {
    Array(Set(self).sorted().prefix(limit))
  }
}
