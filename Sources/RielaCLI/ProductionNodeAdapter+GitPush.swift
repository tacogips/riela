import Foundation
import RielaCore

enum GitPushTransport: Equatable, Sendable {
  case local
  case https
  case ssh
}

protocol GitPushTransportValidating: Sendable {
  func validate(_ transport: GitPushTransport) throws
}

struct VersionOneGitPushTransportPolicy: GitPushTransportValidating {
  func validate(_ transport: GitPushTransport) throws {
    guard transport != .local else {
      throw policyError("riela/git-push version 1 refuses local and file transports")
    }
  }
}

private struct GitPushSnapshot {
  var branch: String
  var branchRef: String
  var remote: String
  var mergeRef: String
  var trackingRef: String
  var trackingRevision: String
  var pushURL: String
  var transport: GitPushTransport
  var transportArguments: [String]
  var transportEnvironment: [String: String]
}

extension BuiltinWorkflowAddonResolver {
  func executeGitPush(
    _ input: WorkflowAddonExecutionInput,
    identity _: WorkflowAddonExecutionIdentity
  ) throws -> AdapterExecutionOutput {
    let config = input.addon.config ?? [:]
    guard boolValue(config["allowPush"]) == true else {
      throw policyError("riela/git-push requires config.allowPush=true")
    }
    let expectedCommit = try renderedExpectedPushCommit(
      config["expectedCommitHashTemplate"],
      variables: addonVariables(for: input)
    )
    let repository = try loadGitRepository()
    try prepareGitFinalizationStore(repository: repository)
    let head = try headRevision(repository: repository)
    guard head == expectedCommit else {
      throw policyError("riela/git-push current HEAD does not match the accepted commit evidence")
    }
    var snapshot = try gitPushSnapshot(repository: repository)
    let counts = try aheadBehindCounts(
      trackingRef: snapshot.trackingRef,
      repository: repository,
      transportArguments: snapshot.transportArguments,
      transportEnvironment: snapshot.transportEnvironment
    )
    guard counts.behind == 0 else {
      throw policyError("riela/git-push refuses a branch behind its upstream")
    }

    let transportRepository = try gitFinalizationStore.makeTransportRepositoryDirectory()
    defer { _ = try? gitFinalizationStore.removeOwnedTransportRepository(transportRepository) }
    snapshot = try isolatedTransportSnapshot(
      snapshot,
      head: head,
      repository: repository,
      transportRepository: transportRepository
    )
    try requireCurrentPushBranch(snapshot, head: head, repository: repository)
    let liveTip = try liveRemoteTip(snapshot: snapshot, repository: repository)
    guard let liveTip else {
      throw policyError("riela/git-push requires an existing live remote branch")
    }
    try requireCurrentPushBranch(snapshot, head: head, repository: repository)
    if liveTip == head {
      return pushOutput(status: "already-pushed", revision: head, remote: snapshot.remote, branch: snapshot.branch)
    }
    guard liveTip == snapshot.trackingRevision else {
      throw policyError("riela/git-push live remote state diverged from the validated tracking snapshot")
    }
    let authorizedParent = try singleParentRevision(head, repository: repository)
    guard liveTip == authorizedParent,
          counts.ahead == 1 else {
      throw policyError("riela/git-push refuses an unauthorized local commit range")
    }

    _ = try runGit(
      snapshot.transportArguments + [
        "push",
        "--porcelain",
        snapshot.pushURL,
        "HEAD:\(snapshot.mergeRef)"
      ],
      environment: snapshot.transportEnvironment,
      executableURL: repository.executableURL
    )
    let verifiedTip = try liveRemoteTip(snapshot: snapshot, repository: repository)
    guard verifiedTip == head else {
      throw AdapterExecutionError(
        .providerError,
        "git push post-verification failed",
        isRetryable: true
      )
    }
    try requireCurrentPushBranch(snapshot, head: head, repository: repository)
    return pushOutput(status: "pushed", revision: head, remote: snapshot.remote, branch: snapshot.branch)
  }

  private func renderedExpectedPushCommit(_ value: JSONValue?, variables: JSONObject) throws -> String {
    guard case let .string(template) = value else {
      throw policyError("riela/git-push config.expectedCommitHashTemplate is required")
    }
    let rendered = renderJSONTemplates(.string(template), variables: variables)
    guard case let .string(commit) = rendered,
          commit.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{64})$", options: .regularExpression) != nil else {
      throw policyError("riela/git-push expected commit hash is invalid")
    }
    return commit
  }

  private func requireCurrentPushBranch(
    _ snapshot: GitPushSnapshot,
    head: String,
    repository: GitRepositoryContext
  ) throws {
    let branchRefResult = try runRepositoryGitResult(
      ["symbolic-ref", "--quiet", "HEAD"],
      repository: repository
    )
    guard branchRefResult.exitCode == 0,
          try requiredSingleLine(branchRefResult.output, name: "branch ref") == snapshot.branchRef,
          try headRevision(repository: repository) == head else {
      throw policyError("riela/git-push local branch or HEAD changed after preflight", retryable: true)
    }
  }

  private func isolatedTransportSnapshot(
    _ snapshot: GitPushSnapshot,
    head: String,
    repository: GitRepositoryContext,
    transportRepository: GitOwnedTransportRepository
  ) throws -> GitPushSnapshot {
    try requireRepositoryIdentity(repository)
    let isolatedEnvironment = [
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
      "HOME": gitFinalizationStore.emptyHomeDirectory.path,
      "XDG_CONFIG_HOME": gitFinalizationStore.emptyHomeDirectory.path
    ]
    _ = try runGit(
      ["init", "--bare", "--object-format=\(repository.objectFormat.rawValue)", transportRepository.url.path],
      environment: isolatedEnvironment,
      executableURL: repository.executableURL,
      workingDirectory: gitFinalizationStore.rootDirectory
    )
    try requireRepositoryIdentity(repository)
    try gitFinalizationStore.configureTransportObjectDatabase(
      transportRepository: transportRepository,
      objectDirectory: repository.objectDirectory
    )
    let commandEnvironment = isolatedEnvironment
    let gitDirectoryArgument = "--git-dir=\(transportRepository.url.path)"
    _ = try runGit(
      [gitDirectoryArgument, "symbolic-ref", "HEAD", "refs/heads/riela-source"],
      environment: commandEnvironment,
      executableURL: repository.executableURL,
      workingDirectory: gitFinalizationStore.rootDirectory
    )
    try gitFinalizationStore.requireOwnedTransportRepository(transportRepository)
    _ = try runGit(
      [gitDirectoryArgument, "update-ref", "refs/heads/riela-source", head],
      environment: commandEnvironment,
      executableURL: repository.executableURL,
      workingDirectory: gitFinalizationStore.rootDirectory
    )
    try gitFinalizationStore.requireOwnedTransportRepository(transportRepository)
    var result = snapshot
    result.transportArguments = [gitDirectoryArgument] + snapshot.transportArguments
    result.transportEnvironment.merge(commandEnvironment) { _, runtimeOwned in runtimeOwned }
    return result
  }

  private func singleParentRevision(
    _ revision: String,
    repository: GitRepositoryContext
  ) throws -> String {
    let output = try runRepositoryGit(
      ["show", "-s", "--format=%P", revision],
      repository: repository
    ).output
    let parents = output.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard parents.count == 1 else {
      throw policyError("riela/git-push requires an accepted commit with exactly one parent")
    }
    return try validatedObjectID(parents[0])
  }

  private func gitPushSnapshot(repository: GitRepositoryContext) throws -> GitPushSnapshot {
    let branchRefResult = try runRepositoryGitResult(
      ["symbolic-ref", "--quiet", "HEAD"],
      repository: repository
    )
    guard branchRefResult.exitCode == 0 else {
      throw policyError("riela/git-push refuses a detached HEAD")
    }
    let branchRef = try requiredSingleLine(branchRefResult.output, name: "branch ref")
    guard branchRef.hasPrefix("refs/heads/") else {
      throw policyError("riela/git-push requires a named local branch")
    }
    let branch = String(branchRef.dropFirst("refs/heads/".count))
    try validateBranchName(branch, repository: repository)

    let remote = try requiredConfigValue(
      "branch.\(branch).remote",
      repository: repository,
      diagnostic: "configured upstream remote"
    )
    try validateRemoteName(remote)
    let mergeRef = try requiredConfigValue(
      "branch.\(branch).merge",
      repository: repository,
      diagnostic: "configured upstream merge ref"
    )
    guard mergeRef == branchRef else {
      throw policyError("riela/git-push requires an upstream matching the current branch")
    }
    let trackingRef = "refs/remotes/\(remote)/\(branch)"
    let trackingRevision = try validatedObjectID(requiredSingleLine(runRepositoryGit(
      ["rev-parse", "--verify", "\(trackingRef)^{commit}"],
      repository: repository
    ).output, name: "upstream tracking revision"))
    try rejectConfiguredReceivePack(remote: remote, repository: repository)
    let pushURL = try requiredSingleLine(runRepositoryGit(
      ["remote", "get-url", "--push", remote],
      repository: repository
    ).output, name: "effective push URL")
    let transport = try validatePushURL(pushURL)
    try gitPushTransportPolicy.validate(transport)
    let transportPolicy = try transportPolicy(
      transport,
      repository: repository
    )
    return GitPushSnapshot(
      branch: branch,
      branchRef: branchRef,
      remote: remote,
      mergeRef: mergeRef,
      trackingRef: trackingRef,
      trackingRevision: trackingRevision,
      pushURL: pushURL,
      transport: transport,
      transportArguments: transportPolicy.arguments,
      transportEnvironment: transportPolicy.environment
    )
  }

  private func validateBranchName(_ branch: String, repository: GitRepositoryContext) throws {
    guard !branch.isEmpty,
          branch.utf8.count <= 1_024,
          !branch.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
      throw policyError("riela/git-push current branch name is invalid")
    }
    let result = try runRepositoryGitResult(
      ["check-ref-format", "--branch", branch],
      repository: repository
    )
    guard result.exitCode == 0 else {
      throw policyError("riela/git-push current branch name is invalid")
    }
  }

  private func validateRemoteName(_ remote: String) throws {
    guard remote.utf8.count <= 255,
          remote != ".",
          remote != "..",
          !remote.hasSuffix(".lock"),
          remote.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil else {
      throw policyError("riela/git-push configured remote name is invalid")
    }
  }

  private func requiredConfigValue(
    _ key: String,
    repository: GitRepositoryContext,
    diagnostic: String
  ) throws -> String {
    let result = try runRepositoryGitResult(["config", "--get", key], repository: repository)
    guard result.exitCode == 0 else {
      throw policyError("riela/git-push requires a \(diagnostic)")
    }
    return try requiredSingleLine(result.output, name: diagnostic)
  }

  private func rejectConfiguredReceivePack(remote: String, repository: GitRepositoryContext) throws {
    for key in ["remote.\(remote).receivepack", "remote.\(remote).uploadpack"] {
      let result = try runRepositoryGitResult(["config", "--get", key], repository: repository)
      guard result.exitCode != 0 else {
        throw policyError("riela/git-push refuses configured remote helper commands")
      }
    }
  }

  private func validatePushURL(_ value: String) throws -> GitPushTransport {
    guard value.utf8.count <= 8_192,
          !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 }),
          !value.hasPrefix("ext::") else {
      throw policyError("riela/git-push effective URL is unsafe")
    }
    if value.hasPrefix("/") {
      return .local
    }
    if let components = URLComponents(string: value), let scheme = components.scheme?.lowercased() {
      guard components.query == nil, components.fragment == nil else {
        throw policyError("riela/git-push effective URL query or fragment is not allowed")
      }
      switch scheme {
      case "file":
        guard components.user == nil,
              components.password == nil,
              components.host == nil || components.host?.isEmpty == true,
              components.path.hasPrefix("/") else {
          throw policyError("riela/git-push file URL is invalid")
        }
        return .local
      case "https":
        guard components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              !host.hasPrefix("-"),
              !containsUnsafeURLComponent(host),
              !containsUnsafeURLComponent(components.path) else {
          throw policyError("riela/git-push refuses a credential-bearing or invalid HTTPS URL")
        }
        try validateHTTPSAuthority(value, decodedHost: host)
        return .https
      case "ssh":
        guard components.password == nil,
              let host = components.host,
              !host.isEmpty,
              !host.hasPrefix("-"),
              host.range(of: "^[A-Za-z0-9.:-]+$", options: .regularExpression) != nil,
              components.user == nil || (
                components.user?.hasPrefix("-") == false &&
                  components.user?.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
              ),
              components.path.range(of: "^/[A-Za-z0-9._~/%+-]+$", options: .regularExpression) != nil else {
          throw policyError("riela/git-push SSH URL is invalid")
        }
        return .ssh
      default:
        throw policyError("riela/git-push URL scheme is unsupported")
      }
    }
    let pattern = "^(?:([A-Za-z0-9._-]+)@)?([A-Za-z0-9.-]+):([A-Za-z0-9._~/%+-]+)$"
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let hostRange = Range(match.range(at: 2), in: value),
          let pathRange = Range(match.range(at: 3), in: value),
          !value[hostRange].hasPrefix("-"),
          !value[pathRange].hasPrefix("-"),
          match.range(at: 1).location == NSNotFound || (
            Range(match.range(at: 1), in: value).map { !value[$0].hasPrefix("-") } == true
          ) else {
      throw policyError("riela/git-push SCP-style SSH location is invalid")
    }
    return .ssh
  }

  private func validateHTTPSAuthority(_ value: String, decodedHost: String) throws {
    guard let schemeSeparator = value.range(of: "://", options: [.caseInsensitive]) else {
      throw policyError("riela/git-push HTTPS URL authority is invalid")
    }
    let remainder = value[schemeSeparator.upperBound...]
    let authorityEnd = remainder.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" })
      ?? remainder.endIndex
    let authority = remainder[..<authorityEnd]
    guard !authority.isEmpty, !authority.contains("@") else {
      throw policyError("riela/git-push HTTPS URL authority is invalid")
    }

    if authority.first == "[" {
      guard let closingBracket = authority.firstIndex(of: "]"),
            decodedHost.contains(":"),
            authority[authority.index(after: closingBracket)...].isEmpty
              || validHTTPSPort(authority[authority.index(after: closingBracket)...]) else {
        throw policyError("riela/git-push HTTPS URL authority is invalid")
      }
      return
    }

    guard !decodedHost.contains(":") else {
      throw policyError("riela/git-push HTTPS URL authority is invalid")
    }
    let separators = authority.indices.filter { authority[$0] == ":" }
    guard separators.count <= 1 else {
      throw policyError("riela/git-push HTTPS URL authority is invalid")
    }
    if let separator = separators.first {
      guard validHTTPSPort(authority[separator...]) else {
        throw policyError("riela/git-push HTTPS URL port is invalid")
      }
    }
  }

  private func validHTTPSPort(_ suffix: Substring) -> Bool {
    guard suffix.first == ":" else {
      return false
    }
    let digits = suffix.dropFirst()
    guard !digits.isEmpty,
          digits.count <= 5,
          digits.allSatisfy({ $0.isNumber }),
          let port = Int(digits) else {
      return false
    }
    return (1...65_535).contains(port)
  }

  private func containsUnsafeURLComponent(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 0x20 || $0.value == 0x7f
    }
  }

  private func transportPolicy(
    _ transport: GitPushTransport,
    repository: GitRepositoryContext
  ) throws -> (arguments: [String], environment: [String: String]) {
    switch transport {
    case .local:
      return ([], [:])
    case .https:
      let rootOutput = try requiredSingleLine(runRepositoryGit(
        ["--exec-path"],
        repository: repository
      ).output, name: "Git helper root")
      let helperRoot = try gitExecutablePolicy.validateTrustedDirectory(
        at: URL(fileURLWithPath: rootOutput, isDirectory: true),
        repositoryRoot: repository.root
      )
      _ = try trustedHelper(
        helperRoot.appendingPathComponent("git-remote-https"),
        within: helperRoot,
        repository: repository
      )
      let credentialHelpers = try configuredCredentialHelpers(
        helperRoot: helperRoot,
        repository: repository
      )
      guard !credentialHelpers.isEmpty else {
        throw policyError("riela/git-push requires a trusted HTTPS credential helper")
      }
      var arguments = ["-c", "credential.helper="]
      for helper in credentialHelpers {
        arguments += ["-c", "credential.helper=\(helper.path)"]
      }
      return (arguments, [:])
    case .ssh:
      let configuredSSH = try runRepositoryGitResult(
        ["config", "--get", "core.sshCommand"],
        repository: repository
      )
      guard configuredSSH.exitCode != 0 else {
        throw policyError("riela/git-push refuses configured SSH command strings")
      }
      let ssh = try gitExecutablePolicy.validateTrustedExecutable(
        at: GitExecutablePolicy.sshURL,
        repositoryRoot: repository.root
      )
      let sshCommand = "\(ssh.path) -F /dev/null -oBatchMode=yes -oPermitLocalCommand=no -oProxyCommand=none"
      return (
        ["-c", "core.sshCommand=\(sshCommand)"],
        ["GIT_SSH": ssh.path, "GIT_SSH_COMMAND": sshCommand]
      )
    }
  }

  private func configuredCredentialHelpers(
    helperRoot: URL,
    repository: GitRepositoryContext
  ) throws -> [URL] {
    let result = try runRepositoryGitResult(
      ["config", "--get-all", "credential.helper"],
      repository: repository
    )
    if result.exitCode != 0 {
      return []
    }
    var effectiveHelperLines: [String] = []
    var rawLines = result.output.split(
      separator: "\n",
      omittingEmptySubsequences: false
    ).map(String.init)
    if rawLines.last?.isEmpty == true {
      rawLines.removeLast()
    }
    for rawLine in rawLines {
      if rawLine.isEmpty {
        effectiveHelperLines.removeAll()
        continue
      }
      effectiveHelperLines.append(rawLine)
    }
    var helpers: [URL] = []
    for rawLine in effectiveHelperLines {
      guard !rawLine.hasPrefix("!"),
            rawLine.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
        throw policyError("riela/git-push refuses credential helper snippets or arguments")
      }
      let candidate: URL
      if rawLine.hasPrefix("/") {
        candidate = URL(fileURLWithPath: rawLine)
      } else {
        guard rawLine.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
          throw policyError("riela/git-push credential helper name is invalid")
        }
        candidate = helperRoot.appendingPathComponent("git-credential-\(rawLine)")
      }
      let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
      if canonical.path == GitExecutablePolicy.macOSCredentialHelperURL.path {
        helpers.append(try gitExecutablePolicy.validateTrustedExecutable(at: canonical, repositoryRoot: repository.root))
      } else {
        helpers.append(try trustedHelper(canonical, within: helperRoot, repository: repository))
      }
    }
    return helpers
  }

  private func trustedHelper(
    _ candidate: URL,
    within helperRoot: URL,
    repository: GitRepositoryContext
  ) throws -> URL {
    let canonical = try gitExecutablePolicy.validateTrustedExecutable(
      at: candidate,
      repositoryRoot: repository.root
    )
    guard isURL(canonical, inside: helperRoot) else {
      throw policyError("riela/git-push helper resolves outside the trusted Git helper root")
    }
    return canonical
  }

  private func aheadBehindCounts(
    trackingRef: String,
    repository: GitRepositoryContext,
    transportArguments: [String],
    transportEnvironment: [String: String]
  ) throws -> (behind: Int, ahead: Int) {
    let output = try runRepositoryGit(
      transportArguments + ["rev-list", "--left-right", "--count", "\(trackingRef)...HEAD"],
      repository: repository,
      environment: transportEnvironment
    ).output
    let values = output.split(whereSeparator: { $0.isWhitespace }).compactMap { Int($0) }
    guard values.count == 2 else {
      throw AdapterExecutionError(.invalidOutput, "git returned invalid ahead/behind counts")
    }
    return (values[0], values[1])
  }

  private func liveRemoteTip(
    snapshot: GitPushSnapshot,
    repository: GitRepositoryContext
  ) throws -> String? {
    let result = try runGit(
      snapshot.transportArguments + ["ls-remote", snapshot.pushURL, snapshot.mergeRef],
      environment: snapshot.transportEnvironment,
      executableURL: repository.executableURL
    )
    let lines = result.output.split(whereSeparator: { $0.isNewline }).map(String.init)
    guard lines.count <= 1 else {
      throw AdapterExecutionError(.invalidOutput, "git returned ambiguous live remote state")
    }
    guard let line = lines.first else {
      return nil
    }
    let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard fields.count == 2, fields[1] == snapshot.mergeRef else {
      throw AdapterExecutionError(.invalidOutput, "git returned invalid live remote state")
    }
    return try validatedObjectID(fields[0])
  }
}
