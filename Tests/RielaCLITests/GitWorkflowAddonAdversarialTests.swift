import Foundation
import RielaAdapters
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitWorkflowAddonAdversarialTests: XCTestCase {
  func testCompositeResolverAcknowledgesAndCleansAcceptedCommitArtifacts() async throws {
    let repository = try GitTestRepository()
    try repository.write("composite", to: "composite.txt")
    let resolver = CompositeWorkflowAddonResolver(
      primary: repository.resolver,
      fallback: RejectingWorkflowAddonResolver()
    )

    let result = try await DeterministicWorkflowRunner(addonResolver: resolver).run(
      DeterministicWorkflowRunRequest(
        workflow: commitWorkflow(),
        variables: commitVariables(message: "test: composite cleanup", files: ["composite.txt"])
      )
    )

    XCTAssertEqual(result.status, .completed)
    try assertAcceptedFinalizationCleaned(repository)
  }

  func testScenarioFallbackAcknowledgesAndCleansAcceptedCommitArtifacts() async throws {
    let repository = try GitTestRepository()
    try repository.write("scenario", to: "scenario.txt")
    let resolver = ScenarioWorkflowAddonResolver(
      scenario: WorkflowMockScenario(responses: [:]),
      fallback: repository.resolver
    )

    let result = try await DeterministicWorkflowRunner(addonResolver: resolver).run(
      DeterministicWorkflowRunRequest(
        workflow: commitWorkflow(),
        variables: commitVariables(message: "test: scenario cleanup", files: ["scenario.txt"])
      )
    )

    XCTAssertEqual(result.status, .completed)
    try assertAcceptedFinalizationCleaned(repository)
  }

  func testHTTPSPushRequiresTrustedCredentialHelper() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git(["config", "--add", "credential.helper", ""])
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "https://example.invalid/repository.git"
    ])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("credential helper") == true)
    }
  }

  func testHTTPSPushAcceptsTrustedInstallRootHelperWithoutNetwork() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git(["config", "credential.helper", "osxkeychain"])
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "https://example.invalid/repository.git"
    ])
    let head = try repository.git(["rev-parse", "HEAD"]).trimmed
    let runner = ScriptedGitCommandRunner(mode: .fixedLiveTip(head))

    let output = try await repository.makeResolver(commandRunner: runner).execute(
      pushInput(repository: repository),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(output.payload)["status"], .string("already-pushed"))
    XCTAssertGreaterThan(runner.liveQueryCount, 0)
  }

  func testHTTPSCredentialHelperResetDiscardsEarlierUntrustedEntry() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let untrusted = repository.root.appendingPathComponent("discarded-helper")
    try "#!/bin/sh\nexit 1\n".write(to: untrusted, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: untrusted.path)
    _ = try repository.git(["config", "--add", "credential.helper", untrusted.path])
    _ = try repository.git(["config", "--add", "credential.helper", ""])
    _ = try repository.git(["config", "--add", "credential.helper", "osxkeychain"])
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "https://example.invalid/repository.git"
    ])
    let head = try repository.git(["rev-parse", "HEAD"]).trimmed

    let output = try await repository.makeResolver(
      commandRunner: ScriptedGitCommandRunner(mode: .fixedLiveTip(head))
    ).execute(pushInput(repository: repository), context: AdapterExecutionContext())

    XCTAssertEqual(gitPayload(output.payload)["status"], .string("already-pushed"))
  }

  func testHTTPSPushRejectsRepositoryCredentialHelper() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let helper = repository.root.appendingPathComponent("credential-helper")
    try "#!/bin/sh\nexit 1\n".write(to: helper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    _ = try repository.git(["config", "credential.helper", helper.path])
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "https://example.invalid/repository.git"
    ])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testPushRejectsExternalRemoteHelperAndRewriteResult() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git(["remote", "set-url", "--push", "origin", "ext::unsafe-command"])
    await assertPushPolicyBlocked(repository)

    _ = try repository.git(["config", "url.ext::rewritten.insteadOf", "alias:"])
    _ = try repository.git(["remote", "set-url", "--push", "origin", "alias:repository"])
    await assertPushPolicyBlocked(repository)
  }

  func testRepositoryHookIsNeverExecutedByCommit() async throws {
    let repository = try GitTestRepository()
    try repository.write("hook-safe", to: "hook-safe.txt")
    let sentinel = repository.root.appendingPathComponent("hook-executed")
    let hook = repository.root.appendingPathComponent(".git/hooks/pre-commit")
    try "#!/bin/sh\ntouch \"\(sentinel.path)\"\nexit 1\n".write(
      to: hook,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

    let output = try await repository.resolver.execute(
      commitInput(message: "test: hook isolation", files: ["hook-safe.txt"]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(output.payload)["status"], .string("committed"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
  }

  func testProductionPushRejectsLocalReceiverBeforeHookExecution() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let remote = try XCTUnwrap(repository.remoteRoot)
    let remoteHeadBefore = try remoteHead(repository)
    let sentinel = repository.root.deletingLastPathComponent().appendingPathComponent("receiver-hook-executed")
    let hook = remote.appendingPathComponent("hooks/post-receive")
    try "#!/bin/sh\ntouch \"\(sentinel.path)\"\n".write(
      to: hook,
      atomically: true,
      encoding: .utf8
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    try repository.write("local receiver", to: "tracked.txt")
    _ = try repository.git(["add", "--", "tracked.txt"])
    _ = try repository.git(["commit", "-m", "test: local receiver isolation"])
    let productionResolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: repository.root,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: repository.finalizationRoot)
    )

    await XCTAssertThrowsErrorAsync(
      try await productionResolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("local and file transports") == true)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    XCTAssertEqual(try remoteHead(repository), remoteHeadBefore)
  }

  func testGlobalIdentityIsSnapshottedBeforeCommitMutation() async throws {
    let repository = try GitTestRepository()
    try repository.write("identity", to: "identity.txt")
    _ = try repository.git(["config", "--unset", "user.name"])
    _ = try repository.git(["config", "--unset", "user.email"])
    let home = repository.root.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let config = home.appendingPathComponent(".gitconfig")
    try "[user]\n\tname = Snapshot User\n\temail = snapshot@example.invalid\n".write(
      to: config,
      atomically: true,
      encoding: .utf8
    )
    let runner = ScriptedGitCommandRunner(mode: .beforeCommitTree {
      try "[user]\n\tname = Mutated User\n\temail = mutated@example.invalid\n".write(
        to: config,
        atomically: true,
        encoding: .utf8
      )
    })
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path

    _ = try await repository.makeResolver(environment: environment, commandRunner: runner).execute(
      commitInput(message: "test: identity snapshot", files: ["identity.txt"]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(
      try repository.git(["show", "-s", "--format=%an <%ae>", "HEAD"]).trimmed,
      "Snapshot User <snapshot@example.invalid>"
    )
  }

  func testJournalCollisionFailsWithoutPublishingRefOrIndex() async throws {
    let repository = try GitTestRepository()
    try repository.write("collision", to: "tracked.txt")
    let input = commitInput(
      message: "test: journal collision",
      files: ["tracked.txt"],
      executionId: "collision-exec"
    )
    let identity = try XCTUnwrap(input.executionIdentity)
    let context = try repository.resolver.loadGitRepository()
    let store = GitFinalizationStore(rootDirectory: repository.finalizationRoot)
    let digest = try store.renderedInputDigest(
      operation: BuiltinGitAddon.commit.rawValue,
      message: "test: journal collision",
      files: ["tracked.txt"]
    )
    let key = try store.journalKey(
      repository: context.identity,
      identity: identity,
      renderedInputDigest: digest
    )
    try store.prepare()
    try Data("{\"conflict\":true}".utf8).write(
      to: store.journalsDirectory.appendingPathComponent(key + ".json")
    )
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(input, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
  }

  func testTrustedExecutablePolicyRejectsInjectedSymlink() throws {
    let repository = try GitTestRepository()
    XCTAssertEqual(
      try GitExecutablePolicy().validateGit(
        at: GitExecutablePolicy.versionOneURL,
        repositoryRoot: repository.root
      ),
      GitExecutablePolicy.versionOneURL.resolvingSymlinksInPath().standardizedFileURL
    )
    let symlink = repository.root.appendingPathComponent("git-link")
    try FileManager.default.createSymbolicLink(
      at: symlink,
      withDestinationURL: GitExecutablePolicy.versionOneURL
    )

    XCTAssertThrowsError(
      try GitExecutablePolicy().validateGit(at: symlink, repositoryRoot: repository.root)
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testConcurrentRemoteAdvanceFailsNonForcePush() async throws {
    let repository = try locallyAheadRepository()
    let localHead = try repository.git(["rev-parse", "HEAD"]).trimmed
    let runner = ScriptedGitCommandRunner(mode: .beforePush {
      try repository.advanceRemoteFromAnotherClone(fetch: false)
    })

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        pushInput(repository: repository),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertNotEqual(try remoteHead(repository), localHead)
  }

  func testPostPushVerificationFailureDoesNotPublishSuccess() async throws {
    let repository = try locallyAheadRepository()
    let oldTracking = try repository.git(["rev-parse", "refs/remotes/origin/main"]).trimmed
    let localHead = try repository.git(["rev-parse", "HEAD"]).trimmed
    let runner = ScriptedGitCommandRunner(mode: .secondLiveTip(oldTracking))

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        pushInput(repository: repository),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try remoteHead(repository), localHead)
  }

  func testAlreadyPushedRejectsConcurrentBranchSwitchWithSameOrDifferentHead() async throws {
    for usesSameHead in [true, false] {
      let repository = try GitTestRepository(withBareRemote: true)
      let mainHead = try repository.git(["rev-parse", "HEAD"]).trimmed
      _ = try repository.git(["branch", "other", mainHead])
      if !usesSameHead {
        _ = try repository.git(["checkout", "other"])
        try repository.write("other", to: "other.txt")
        _ = try repository.git(["add", "--", "other.txt"])
        _ = try repository.git(["commit", "-m", "test: other branch"])
        _ = try repository.git(["checkout", "main"])
      }
      let runner = ScriptedGitCommandRunner(mode: .beforeLiveQuery(1) {
        _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
      })

      await XCTAssertThrowsErrorAsync(
        try await repository.makeResolver(commandRunner: runner).execute(
          pushInput(repository: repository),
          context: AdapterExecutionContext()
        )
      ) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
        XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
      }
      XCTAssertEqual(try remoteHead(repository), mainHead)
    }
  }

  func testPushedRejectsConcurrentSameCommitBranchSwitchDuringPostVerification() async throws {
    let repository = try locallyAheadRepository()
    let localHead = try repository.git(["rev-parse", "HEAD"]).trimmed
    _ = try repository.git(["branch", "other", localHead])
    let runner = ScriptedGitCommandRunner(mode: .beforeLiveQuery(2) {
      _ = try repository.git(["symbolic-ref", "HEAD", "refs/heads/other"])
    })

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        pushInput(repository: repository),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    XCTAssertEqual(try remoteHead(repository), localHead)
  }

  private func assertAcceptedFinalizationCleaned(_ repository: GitTestRepository) throws {
    XCTAssertEqual(try repository.finalizationArtifacts(in: "journals"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "prepared"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "links"), [])
    XCTAssertEqual(try repository.finalizationArtifacts(in: "accepted").count, 1)
  }

  private func assertPushPolicyBlocked(_ repository: GitTestRepository) async {
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  private func locallyAheadRepository() throws -> GitTestRepository {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.write("ahead", to: "tracked.txt")
    _ = try repository.git(["add", "--", "tracked.txt"])
    _ = try repository.git(["commit", "-m", "test: local ahead"])
    return repository
  }

  private func remoteHead(_ repository: GitTestRepository) throws -> String {
    let remote = try XCTUnwrap(repository.remoteRoot)
    return try GitTestRepository.runGit(["rev-parse", "refs/heads/main"], at: remote).trimmed
  }

  private func commitWorkflow() -> WorkflowDefinition {
    let addon = WorkflowNodeAddonRef(
      name: BuiltinGitAddon.commit.rawValue,
      version: "1",
      config: [
        "allowCommit": .bool(true),
        "commitMessageTemplate": .string("{{inbox.latest.output.payload.commitMessage}}"),
        "committedFilesTemplate": .string("{{inbox.latest.output.payload.committedFiles}}")
      ]
    )
    return WorkflowDefinition(
      workflowId: "git-cleanup-test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "commit",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "commit", addon: addon)],
      steps: [WorkflowStepRef(id: "commit", nodeId: "commit")],
      nodes: [WorkflowNodeRef(id: "commit", addon: addon)]
    )
  }

  private func commitVariables(message: String, files: [String]) -> JSONObject {
    [
      "inbox": .object([
        "latest": .object([
          "output": .object([
            "payload": .object([
              "commitMessage": .string(message),
              "committedFiles": .array(files.map(JSONValue.string))
            ])
          ])
        ])
      ])
    ]
  }

  private func commitInput(
    message: String,
    files: [String],
    executionId: String = UUID().uuidString
  ) -> WorkflowAddonExecutionInput {
    return WorkflowAddonExecutionInput(
      workflowId: "git-adversarial-test",
      stepId: "commit",
      nodeId: "commit",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.commit.rawValue,
        version: "1",
        config: [
          "allowCommit": .bool(true),
          "commitMessageTemplate": .string("{{message}}"),
          "committedFilesTemplate": .string("{{files}}")
        ]
      ),
      variables: [
        "message": .string(message),
        "files": .array(files.map(JSONValue.string))
      ],
      executionIdentity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: "git-adversarial-session",
        stepExecutionId: executionId,
        attempt: 1
      )
    )
  }

  private func pushInput(
    repository: GitTestRepository,
    expectedCommitHash: String? = nil
  ) throws -> WorkflowAddonExecutionInput {
    let expectedCommitHash = try expectedCommitHash ?? repository.git(["rev-parse", "HEAD"]).trimmed
    return WorkflowAddonExecutionInput(
      workflowId: "git-adversarial-test",
      stepId: "push",
      nodeId: "push",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.push.rawValue,
        version: "1",
        config: [
          "allowPush": .bool(true),
          "expectedCommitHashTemplate": .string("{{expectedCommitHash}}")
        ]
      ),
      variables: ["expectedCommitHash": .string(expectedCommitHash)],
      executionIdentity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: "git-adversarial-session",
        stepExecutionId: UUID().uuidString,
        attempt: 1
      )
    )
  }
}

private struct RejectingWorkflowAddonResolver: WorkflowAddonResolving {
  func execute(
    _: WorkflowAddonExecutionInput,
    context _: AdapterExecutionContext
  ) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(.policyBlocked, "unexpected fallback")
  }
}

final class ScriptedGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  enum Mode {
    case fixedLiveTip(String)
    case secondLiveTip(String)
    case beforeLiveQuery(Int, () throws -> Void)
    case beforePush(() throws -> Void)
    case beforeCommitTree(() throws -> Void)
  }

  private let lock = NSLock()
  private let mode: Mode
  private var liveQueries = 0
  private var actionRan = false
  private let underlying = FoundationGitCommandRunner()

  init(mode: Mode) {
    self.mode = mode
  }

  var liveQueryCount: Int {
    lock.withLock { liveQueries }
  }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    if invocation.arguments.contains("ls-remote") {
      let query = lock.withLock { () -> Int in
        liveQueries += 1
        return liveQueries
      }
      if case let .beforeLiveQuery(targetQuery, action) = mode, query == targetQuery {
        try runOnce(action)
      }
      switch mode {
      case let .fixedLiveTip(revision):
        return liveTipResult(revision, invocation: invocation)
      case let .secondLiveTip(revision) where query == 2:
        return liveTipResult(revision, invocation: invocation)
      default:
        break
      }
    }
    if invocation.arguments.contains("push"), case let .beforePush(action) = mode {
      try runOnce(action)
    }
    if invocation.arguments.contains("commit-tree"), case let .beforeCommitTree(action) = mode {
      try runOnce(action)
    }
    return try underlying.run(invocation)
  }

  private func liveTipResult(_ revision: String, invocation: GitCommandInvocation) -> GitCommandResult {
    let ref = invocation.arguments.last ?? "refs/heads/main"
    return GitCommandResult(exitCode: 0, output: "\(revision)\t\(ref)\n")
  }

  private func runOnce(_ action: () throws -> Void) throws {
    let shouldRun = lock.withLock { () -> Bool in
      guard !actionRan else { return false }
      actionRan = true
      return true
    }
    if shouldRun {
      try action()
    }
  }
}
