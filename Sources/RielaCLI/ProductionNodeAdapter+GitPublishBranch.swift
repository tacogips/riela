import Foundation
import RielaAddonSupport
import RielaCore

extension BuiltinWorkflowAddonResolver {
  func executeGitPublishBranch(_ input: WorkflowAddonExecutionInput) throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    let knownKeys: Set<String> = ["remote", "branchAllowlist", "allowCreateBranch"]
    guard Set(config.keys).isSubset(of: knownKeys) else {
      throw policyError("riela/git-publish-branch has unknown config keys")
    }
    let remote = try stringConfig(config["remote"], defaultValue: "origin", key: "remote")
    let branchAllowlist = try stringConfig(
      config["branchAllowlist"],
      defaultValue: "riela/task/*",
      key: "branchAllowlist"
    )
    let allowCreate: Bool
    if let value = config["allowCreateBranch"] {
      guard case let .bool(selected) = value else {
        throw policyError("riela/git-publish-branch config.allowCreateBranch must be a boolean")
      }
      allowCreate = selected
    } else {
      allowCreate = true
    }
    guard isValidBranchAllowlist(branchAllowlist) else {
      throw policyError("riela/git-publish-branch branch allowlist is invalid")
    }
    guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains("\0") else {
      throw policyError("riela/git-publish-branch remote is invalid")
    }

    let repository = try loadGitRepository()
    let branchResult = try runRepositoryGitResult(
      ["symbolic-ref", "--quiet", "--short", "HEAD"],
      repository: repository
    )
    guard branchResult.exitCode == 0 else {
      throw policyError("riela/git-publish-branch refuses a detached HEAD")
    }
    let branch = try requiredSingleLine(branchResult.output, name: "current branch")
    guard matchesBranchAllowlist(branch, pattern: branchAllowlist) else {
      throw policyError("riela/git-publish-branch refuses branch outside configured allowlist")
    }

    let head = try headRevision(repository: repository)
    let remoteResult = try runRepositoryGitResult(["ls-remote", "--heads", remote, branch], repository: repository)
    let remoteHead = remoteResult.output
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count == 2 && fields[1] == Substring("refs/heads/\(branch)") ? String(fields[0]) : nil
      }
      .first
    let wasUpToDate = remoteHead == head
    let created = remoteHead == nil
    guard !created || allowCreate else {
      throw policyError("riela/git-publish-branch refuses to create a missing remote branch")
    }
    if let remoteHead {
      let fetch = try runRepositoryGitResult(["fetch", remote, "refs/heads/\(branch)"], repository: repository)
      guard fetch.exitCode == 0 else {
        throw AdapterExecutionError(.providerError, "git fetch failed while preparing branch publication", isRetryable: true)
      }
      let ancestor = try runRepositoryGitResult(["merge-base", "--is-ancestor", "FETCH_HEAD", "HEAD"], repository: repository)
      guard ancestor.exitCode == 0 else {
        throw policyError("riela/git-publish-branch refuses a branch behind or diverged from remote")
      }
      guard remoteHead != head else {
        return gitPublishBranchOutput(input: input, status: "up-to-date", remote: remote, branch: branch, created: false, head: head)
      }
    }
    guard try headRevision(repository: repository) == head,
          try requiredSingleLine(runRepositoryGit(["symbolic-ref", "--quiet", "--short", "HEAD"], repository: repository).output, name: "current branch") == branch else {
      throw policyError("riela/git-publish-branch branch or HEAD changed during publication", retryable: true)
    }
    let pushArguments = created
      ? ["push", "--set-upstream", remote, "HEAD:refs/heads/\(branch)"]
      : ["push", remote, "HEAD:refs/heads/\(branch)"]
    let pushed = try runRepositoryGitResult(pushArguments, repository: repository)
    guard pushed.exitCode == 0 else {
      throw AdapterExecutionError(.providerError, "git push failed while publishing task branch", isRetryable: true)
    }
    let verified = try runRepositoryGitResult(["ls-remote", "--heads", remote, branch], repository: repository)
    let verifiedHead = verified.output
      .split(whereSeparator: \.isNewline)
      .compactMap { line -> String? in
        let fields = line.split(whereSeparator: \.isWhitespace)
        return fields.count == 2 && fields[1] == Substring("refs/heads/\(branch)") ? String(fields[0]) : nil
      }
      .first
    guard verifiedHead == head else {
      throw AdapterExecutionError(.providerError, "git push could not be verified against the published branch", isRetryable: true)
    }
    let status = wasUpToDate ? "up-to-date" : "published"
    return gitPublishBranchOutput(input: input, status: status, remote: remote, branch: branch, created: created, head: head)
  }

  private func gitPublishBranchOutput(
    input: WorkflowAddonExecutionInput,
    status: String,
    remote: String,
    branch: String,
    created: Bool,
    head: String
  ) -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: input.addon.name,
      model: "builtin",
      promptText: "",
      completionPassed: true,
      payload: ["git": .object([
        "operation": .string("publish"),
        "status": .string(status),
        "pushedRemote": .string(remote),
        "pushedBranch": .string(branch),
        "created": .bool(created),
        "headCommit": .string(head)
      ])]
    )
  }

  private func stringConfig(_ value: JSONValue?, defaultValue: String, key: String) throws -> String {
    guard let value else { return defaultValue }
    guard case let .string(string) = value, !string.isEmpty, !string.contains("\0") else {
      throw policyError("riela/git-publish-branch config.\(key) must be a non-empty string")
    }
    return string
  }

  private func isValidBranchAllowlist(_ pattern: String) -> Bool {
    !pattern.isEmpty && pattern.range(of: "[\\s\0]", options: .regularExpression) == nil
  }

  private func matchesBranchAllowlist(_ branch: String, pattern: String) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: pattern)
    let expression = "^" + escaped.replacingOccurrences(of: "\\*", with: ".*") + "$"
    return branch.range(of: expression, options: .regularExpression) != nil
  }
}
