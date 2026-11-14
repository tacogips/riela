import Foundation

/// Result of running a single git subprocess-style command.
struct WorkflowPackageGitCommandResult: Sendable {
  var exitCode: Int32
  var standardOutput: String
  var standardError: String

  var trimmedStandardOutput: String {
    standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Injectable command execution boundary so publish git behavior can be unit
/// tested with a fake instead of shelling out to a real repository.
protocol WorkflowPackageCommandExecutor: Sendable {
  func run(_ executable: String, arguments: [String], workingDirectory: URL?) throws -> WorkflowPackageGitCommandResult
}

/// Foundation `Process`-backed executor. Never interpolates a shell string:
/// arguments are always passed as an array through `/usr/bin/env`.
struct ProcessWorkflowPackageCommandExecutor: WorkflowPackageCommandExecutor {
  func run(_ executable: String, arguments: [String], workingDirectory: URL?) throws -> WorkflowPackageGitCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    if let workingDirectory {
      process.currentDirectoryURL = workingDirectory
    }
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return WorkflowPackageGitCommandResult(
      exitCode: process.terminationStatus,
      standardOutput: String(data: outputData, encoding: .utf8) ?? "",
      standardError: String(data: errorData, encoding: .utf8) ?? ""
    )
  }
}

/// Publish transport mode selected for a run.
enum WorkflowPackagePublishMode: String, Sendable {
  case direct
  case pullRequest = "pull-request"
}

/// Inputs for creating a pull request through the PR adapter.
struct WorkflowPackagePullRequestRequest: Sendable {
  var checkoutDirectory: URL
  var branch: String
  var base: String
  var title: String
  var body: String
}

/// PR creation boundary. The default implementation wraps `gh pr create`, but
/// tests inject a fake so PR success/failure can be exercised offline.
protocol WorkflowPackagePullRequestAdapter: Sendable {
  func createPullRequest(_ request: WorkflowPackagePullRequestRequest) throws -> String
}

struct GhWorkflowPackagePullRequestAdapter: WorkflowPackagePullRequestAdapter {
  var executor: WorkflowPackageCommandExecutor

  func createPullRequest(_ request: WorkflowPackagePullRequestRequest) throws -> String {
    let result = try executor.run(
      "gh",
      arguments: [
        "pr", "create",
        "--head", request.branch,
        "--base", request.base,
        "--title", request.title,
        "--body", request.body
      ],
      workingDirectory: request.checkoutDirectory
    )
    guard result.exitCode == 0 else {
      throw WorkflowPackagePublishGitError.pullRequestFailed(result.standardError.isEmpty ? result.standardOutput : result.standardError)
    }
    let url = result.trimmedStandardOutput
    guard !url.isEmpty else {
      throw WorkflowPackagePublishGitError.pullRequestFailed("gh pr create returned no URL")
    }
    return url
  }
}

enum WorkflowPackagePublishGitError: Error, CustomStringConvertible, Equatable {
  case commandFailed(command: String, message: String)
  case remoteMismatch(expected: String, actual: String)
  case dirtyWorktree(String)
  case pushPermissionDenied(branch: String)
  case pullRequestFailed(String)

  var description: String {
    switch self {
    case let .commandFailed(command, message):
      return "git \(command) failed: \(message)"
    case let .remoteMismatch(expected, actual):
      return "registry checkout remote mismatch: expected \(expected), found \(actual)"
    case let .dirtyWorktree(status):
      return "registry checkout has uncommitted changes; refusing to stage publish files: \(status)"
    case let .pushPermissionDenied(branch):
      return "no permission to push to '\(branch)'; retry with --create-pr to open a pull request"
    case let .pullRequestFailed(message):
      return "pull request creation failed: \(message)"
    }
  }
}

/// Git operations used by the publish transport. Keeps subprocess concerns in
/// one place so `publishPackage` stays focused on staging.
struct WorkflowPackagePublishGit: Sendable {
  var executor: WorkflowPackageCommandExecutor

  private func git(_ arguments: [String], in directory: URL) throws -> WorkflowPackageGitCommandResult {
    try executor.run("git", arguments: arguments, workingDirectory: directory)
  }

  @discardableResult
  private func requireGit(_ arguments: [String], in directory: URL) throws -> WorkflowPackageGitCommandResult {
    let result = try git(arguments, in: directory)
    guard result.exitCode == 0 else {
      let message = result.standardError.isEmpty ? result.standardOutput : result.standardError
      throw WorkflowPackagePublishGitError.commandFailed(
        command: arguments.joined(separator: " "),
        message: message.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    return result
  }

  /// Ensure a checkout exists at `checkout` for `remoteURL`. Missing checkouts
  /// are cloned; existing checkouts must have a matching `origin` remote.
  func ensureCheckout(remoteURL: String, branch: String, checkout: URL) throws {
    let gitDir = checkout.appendingPathComponent(".git")
    if FileManager.default.fileExists(atPath: gitDir.path) {
      let remote = try requireGit(["remote", "get-url", "origin"], in: checkout).trimmedStandardOutput
      guard remotesEquivalent(remote, remoteURL) else {
        throw WorkflowPackagePublishGitError.remoteMismatch(expected: remoteURL, actual: remote)
      }
      return
    }
    try FileManager.default.createDirectory(at: checkout.deletingLastPathComponent(), withIntermediateDirectories: true)
    let parent = checkout.deletingLastPathComponent()
    try requireGit(["clone", "--branch", branch, remoteURL, checkout.lastPathComponent], in: parent)
  }

  /// Refuse to proceed when the checkout has staged or unstaged changes.
  func assertCleanWorktree(checkout: URL) throws {
    let status = try requireGit(["status", "--porcelain"], in: checkout).trimmedStandardOutput
    guard status.isEmpty else {
      throw WorkflowPackagePublishGitError.dirtyWorktree(status)
    }
  }

  /// Non-destructive probe of push permission for `branch`.
  func canPush(branch: String, checkout: URL) throws -> Bool {
    let result = try git(["push", "--dry-run", "origin", "HEAD:\(branch)"], in: checkout)
    return result.exitCode == 0
  }

  func checkoutBranch(_ branch: String, checkout: URL) throws {
    let existing = try git(["rev-parse", "--verify", branch], in: checkout)
    if existing.exitCode == 0 {
      try requireGit(["checkout", branch], in: checkout)
    } else {
      try requireGit(["checkout", "-b", branch], in: checkout)
    }
  }

  func commitAll(message: String, checkout: URL) throws -> String {
    try requireGit(["add", "--all"], in: checkout)
    try requireGit(["commit", "--message", message], in: checkout)
    return try requireGit(["rev-parse", "HEAD"], in: checkout).trimmedStandardOutput
  }

  func push(branch: String, checkout: URL) throws {
    try requireGit(["push", "origin", "HEAD:\(branch)"], in: checkout)
  }

  private func remotesEquivalent(_ lhs: String, _ rhs: String) -> Bool {
    normalizedRemote(lhs) == normalizedRemote(rhs)
  }

  private func normalizedRemote(_ value: String) -> String {
    var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix(".git") {
      trimmed = String(trimmed.dropLast(4))
    }
    if trimmed.hasSuffix("/") {
      trimmed = String(trimmed.dropLast())
    }
    return trimmed
  }
}
