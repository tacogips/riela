import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitWorkflowAddonTests: XCTestCase {
  func testDeterministicWorkflowDispatchesGitCommitAddon() async throws {
    let repository = try GitTestRepository()
    try repository.write("workflow", to: "workflow.txt")
    let addon = WorkflowNodeAddonRef(
      name: BuiltinGitAddon.commit.rawValue,
      version: "1",
      config: [
        "allowCommit": .bool(true),
        "commitMessageTemplate": .string("{{inbox.latest.output.payload.commitMessage}}"),
        "committedFilesTemplate": .string("{{inbox.latest.output.payload.committedFiles}}")
      ]
    )
    let workflow = WorkflowDefinition(
      workflowId: "git-workflow-test",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "commit",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "commit", addon: addon)],
      steps: [WorkflowStepRef(id: "commit", nodeId: "commit")],
      nodes: [WorkflowNodeRef(id: "commit", addon: addon)]
    )
    let runner = DeterministicWorkflowRunner(addonResolver: repository.resolver)

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      variables: step9Variables(message: "test: workflow dispatch", files: ["workflow.txt"])
    ))

    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(gitPayload(try XCTUnwrap(result.rootOutput))["status"], .string("committed"))
  }

  func testCommitRequiresExplicitAuthorization() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(allowCommit: false, files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitStagesOnlyAllowlistedPathsWithoutShellInterpolation() async throws {
    let repository = try GitTestRepository()
    let literalPath = "safe;touch-not-executed.txt"
    try repository.write("literal", to: literalPath)

    let output = try await repository.resolver.execute(
      commitInput(message: "test: literal path", files: [literalPath]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(output.payload)["status"], .string("committed"))
    XCTAssertEqual(try repository.git(["show", "--format=", "--name-only", "HEAD"]).trimmed, literalPath)
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.root.appendingPathComponent("touch-not-executed.txt").path))
  }

  func testCommitRejectsRepositoryExternalPath() async throws {
    let repository = try GitTestRepository()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(files: ["../outside.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitRejectsSymlinkedPathAncestryBeforeHashing() async throws {
    let repository = try GitTestRepository()
    try repository.write("confined", to: "real/confined.txt")
    try FileManager.default.createSymbolicLink(
      at: repository.root.appendingPathComponent("alias"),
      withDestinationURL: repository.root.appendingPathComponent("real", isDirectory: true)
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(files: ["alias/confined.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "1")
  }

  func testCommitRejectsMalformedCommittedFilePayload() async throws {
    let repository = try GitTestRepository()
    let input = WorkflowAddonExecutionInput(
      workflowId: "git-addon-test",
      stepId: "commit",
      nodeId: "commit",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.commit.rawValue,
        version: "1",
        config: [
          "allowCommit": .bool(true),
          "commitMessageTemplate": .string("test: malformed"),
          "committedFilesTemplate": .string("{{files}}")
        ]
      ),
      variables: ["files": .string("tracked.txt")],
      executionIdentity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: "git-addon-test-session",
        stepExecutionId: "malformed-exec",
        attempt: 1
      )
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(input, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitRejectsPreexistingStagedPathOutsideAllowlist() async throws {
    let repository = try GitTestRepository()
    try repository.write("allowed", to: "allowed.txt")
    try repository.write("outside", to: "outside.txt")
    _ = try repository.git(["add", "--", "outside.txt"])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(files: ["allowed.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("pre-existing staged path") == true)
    }
  }

  func testCommitRetryIsIdempotentAndDifferentEmptyCommitFails() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "retry.txt")
    let input = commitInput(
      message: "test: retry",
      files: ["retry.txt"],
      executionId: "commit-exec-1",
      attempt: 1
    )

    let committed = try await repository.resolver.execute(input, context: AdapterExecutionContext())
    let committedEvidence = gitPayload(committed.payload)
    let retry = try await repository.resolver.execute(
      commitInput(
        message: "test: retry",
        files: ["retry.txt"],
        executionId: "commit-exec-2",
        attempt: 2,
        predecessor: "commit-exec-1"
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertGitCommitEvidence(
      retry.payload,
      status: "already-committed",
      revision: try XCTUnwrap(committedEvidence["commitHash"]?.stringValue),
      message: "test: retry",
      files: ["retry.txt"]
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(message: "test: different", files: ["retry.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("mismatch") == true)
    }
  }

  func testPushRequiresAuthorizationAndRetriesIdempotently() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.write("push", to: "push.txt")
    _ = try await repository.resolver.execute(
      commitInput(message: "test: push", files: ["push.txt"]),
      context: AdapterExecutionContext()
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository, allowPush: false), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    let pushed = try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    let pushedRevision = try XCTUnwrap(gitPayload(pushed.payload)["commitHash"]?.stringValue)
    XCTAssertGitPushEvidence(
      pushed.payload,
      status: "pushed",
      revision: pushedRevision,
      remote: "origin",
      branch: "main"
    )
    let retry = try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    XCTAssertGitPushEvidence(
      retry.payload,
      status: "already-pushed",
      revision: pushedRevision,
      remote: "origin",
      branch: "main"
    )
  }

  func testPushRejectsUnreviewedCommitBeforeAcceptedCommit() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let remote = try XCTUnwrap(repository.remoteRoot)
    let remoteBefore = try GitTestRepository.runGit(
      ["rev-parse", "refs/heads/main"],
      at: remote
    ).trimmed
    try repository.write("unreviewed", to: "unreviewed.txt")
    _ = try repository.git(["add", "--", "unreviewed.txt"])
    _ = try repository.git(["commit", "-m", "test: unreviewed predecessor"])
    try repository.write("accepted", to: "accepted.txt")
    _ = try await repository.resolver.execute(
      commitInput(message: "test: accepted commit", files: ["accepted.txt"]),
      context: AdapterExecutionContext()
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        pushInput(repository: repository),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("commit range") == true)
    }
    XCTAssertEqual(
      try GitTestRepository.runGit(["rev-parse", "refs/heads/main"], at: remote).trimmed,
      remoteBefore
    )
  }

  func testPushUsesSourceSHA256ObjectFormatForIsolatedTransportRepository() async throws {
    let repository = try GitTestRepository(withBareRemote: true, objectFormat: .sha256)
    try repository.write("sha256 push", to: "sha256.txt")
    let committed = try await repository.resolver.execute(
      commitInput(message: "test: sha256 push", files: ["sha256.txt"]),
      context: AdapterExecutionContext()
    )
    let revision = try XCTUnwrap(gitPayload(committed.payload)["commitHash"]?.stringValue)

    let pushed = try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())

    XCTAssertEqual(revision.count, 64)
    XCTAssertGitPushEvidence(
      pushed.payload,
      status: "pushed",
      revision: revision,
      remote: "origin",
      branch: "main"
    )
    XCTAssertEqual(
      try GitTestRepository.runGit(["rev-parse", "refs/heads/main"], at: try XCTUnwrap(repository.remoteRoot)).trimmed,
      revision
    )
  }

  func testPushRejectsDetachedHeadAndMismatchedUpstream() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git(["checkout", "--detach"])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("detached HEAD") == true)
    }

    _ = try repository.git(["checkout", "main"])
    _ = try repository.git(["push", "origin", "main:other"])
    _ = try repository.git(["branch", "--set-upstream-to=origin/other", "main"])
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("matching the current branch") == true)
    }
  }

  func testPushRejectsBranchBehindUpstream() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.advanceRemoteFromAnotherClone()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("behind its upstream") == true)
    }
  }

  func testPushRejectsCredentialBearingRemoteBeforeNetworkAccess() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git([
      "remote", "set-url", "--push", "origin", "https://user:secret@example.invalid/repository.git"
    ])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("credential-bearing") == true)
    }
  }

  func testResolverDispatchReportsGitCommandFailureAsRetryable() async {
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [:],
      workingDirectory: URL(fileURLWithPath: "/repository", isDirectory: true),
      gitCommandRunner: FailingGitCommandRunner()
    )

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(commitInput(files: ["tracked.txt"]), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .providerError)
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
  }

  func testMutatingGitAddonsRequireExactVersionAndRuntimeIdentity() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    var omittedVersion = commitInput(files: ["tracked.txt"])
    omittedVersion.addon.version = nil

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(omittedVersion, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    var missingIdentity = commitInput(files: ["tracked.txt"])
    missingIdentity.executionIdentity = nil
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(missingIdentity, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitRejectsDirectoryAndPreservesCanonicalIndex() async throws {
    let repository = try GitTestRepository()
    try repository.write("nested", to: "folder/nested.txt")
    let indexBefore = try repository.indexData()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(commitInput(files: ["folder"]), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "?? folder/")
  }

  func testCommitTreatsWildcardCharactersAsLiteralPathBytes() async throws {
    let repository = try GitTestRepository()
    let literalPath = "literal[*].txt"
    try repository.write("literal", to: literalPath)
    try repository.write("outside", to: "literalx.txt")

    let output = try await repository.resolver.execute(
      commitInput(message: "test: literal wildcard", files: [literalPath]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(output.payload)["committedFiles"], .array([.string(literalPath)]))
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "?? literalx.txt")
  }

  func testCommitIgnoresInheritedGitIndexAndPathOverrides() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    let poisonIndex = repository.root.deletingLastPathComponent().appendingPathComponent("poison.index")
    try Data("poison".utf8).write(to: poisonIndex)
    var poisonedEnvironment = ProcessInfo.processInfo.environment
    poisonedEnvironment["GIT_INDEX_FILE"] = poisonIndex.path
    poisonedEnvironment["GIT_EXEC_PATH"] = repository.root.path
    poisonedEnvironment["PATH"] = repository.root.path

    let output = try await repository.makeResolver(environment: poisonedEnvironment).execute(
      commitInput(message: "test: sanitize environment", files: ["tracked.txt"]),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(output.payload)["status"], .string("committed"))
    XCTAssertEqual(try Data(contentsOf: poisonIndex), Data("poison".utf8))
  }

  func testCommitRejectsCustomCleanFilterWithoutExecutingIt() async throws {
    let repository = try GitTestRepository()
    try repository.write("*.filtered filter=unsafe\n", to: ".gitattributes")
    try repository.write("content", to: "unsafe.filtered")
    let sentinel = repository.root.appendingPathComponent("filter-ran")
    _ = try repository.git(["config", "filter.unsafe.clean", "touch \(sentinel.path)"])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(files: ["unsafe.filtered"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
  }

  func testCommitPreservesForeignIndexLock() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    let lockURL = try repository.indexLockURL()
    try Data("foreign-lock".utf8).write(to: lockURL)
    defer { try? FileManager.default.removeItem(at: lockURL) }

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(commitInput(files: ["tracked.txt"]), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }

    XCTAssertEqual(try Data(contentsOf: lockURL), Data("foreign-lock".utf8))
  }

  func testCommitRecoversAfterRefPublicationWithoutCreatingSecondCommit() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    let injector = ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
    let first = commitInput(
      message: "test: crash recovery",
      files: ["tracked.txt"],
      executionId: "crash-exec-1",
      attempt: 1
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(first, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true)
    }
    let recovered = try await repository.resolver.execute(
      commitInput(
        message: "test: crash recovery",
        files: ["tracked.txt"],
        executionId: "crash-exec-2",
        attempt: 2,
        predecessor: "crash-exec-1"
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(gitPayload(recovered.payload)["status"], .string("already-committed"))
    XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2")
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "")
  }

  func testCommitRecoversAcrossEveryFinalizationFailurePhase() async throws {
    let phases: [GitFinalizationFailurePhase] = [
      .preparedIndex,
      .journal,
      .indexLock,
      .refUpdate,
      .indexPublication,
      .outputPublication
    ]
    for phase in phases {
      let repository = try GitTestRepository()
      try repository.write("change-\(phase.rawValue)", to: "tracked.txt")
      let firstExecutionId = "phase-\(phase.rawValue)-1"
      let injector = ThrowOnceGitFinalizationFailureInjector(phase: phase)
      await XCTAssertThrowsErrorAsync(
        try await repository.makeResolver(failureInjector: injector).execute(
          commitInput(
            message: "test: recover \(phase.rawValue)",
            files: ["tracked.txt"],
            executionId: firstExecutionId,
            attempt: 1
          ),
          context: AdapterExecutionContext()
        )
      ) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.isRetryable, true, "phase \(phase.rawValue)")
      }

      let recovered = try await repository.resolver.execute(
        commitInput(
          message: "test: recover \(phase.rawValue)",
          files: ["tracked.txt"],
          executionId: "phase-\(phase.rawValue)-2",
          attempt: 2,
          predecessor: firstExecutionId
        ),
        context: AdapterExecutionContext()
      )

      XCTAssertNotNil(gitPayload(recovered.payload)["commitHash"], "phase \(phase.rawValue)")
      XCTAssertEqual(try repository.git(["rev-list", "--count", "HEAD"]).trimmed, "2", "phase \(phase.rawValue)")
      XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "", "phase \(phase.rawValue)")
    }
  }

  func testCommitRetryRejectsTokenedUpdateFollowedByReset() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    let injector = ThrowOnceGitFinalizationFailureInjector(phase: .refUpdate)
    let first = commitInput(
      message: "test: reset guard",
      files: ["tracked.txt"],
      executionId: "reset-exec-1",
      attempt: 1
    )
    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(first, context: AdapterExecutionContext())
    ) { _ in }
    _ = try repository.git(["reset", "--hard", "HEAD^"])

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        commitInput(
          message: "test: reset guard",
          files: ["tracked.txt"],
          executionId: "reset-exec-2",
          attempt: 2,
          predecessor: "reset-exec-1"
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitRetryRejectsCrossSessionReplay() async throws {
    let repository = try GitTestRepository()
    try repository.write("change", to: "tracked.txt")
    let first = commitInput(
      message: "test: session isolation",
      files: ["tracked.txt"],
      executionId: "session-exec-1",
      attempt: 1
    )
    _ = try await repository.resolver.execute(first, context: AdapterExecutionContext())
    var replay = commitInput(
      message: "test: session isolation",
      files: ["tracked.txt"],
      executionId: "session-exec-2",
      attempt: 2,
      predecessor: "session-exec-1"
    )
    replay.executionIdentity?.workflowExecutionId = "foreign-session"

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(replay, context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testPushRejectsStaleTrackingStateAgainstLiveRemote() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.advanceRemoteFromAnotherClone(fetch: false)

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("live remote state") == true)
    }
  }

  func testPushRejectsConfiguredHelpersAndInvalidRemoteNamesBeforeNetwork() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    _ = try repository.git(["config", "remote.origin.receivepack", "evil-receive-pack"])
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    _ = try repository.git(["config", "--unset", "remote.origin.receivepack"])
    _ = try repository.git(["config", "branch.main.remote", "-unsafe"])
    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testCommitAndPushEmitCompleteEvidenceWithoutRemoteURL() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    try repository.write("evidence", to: "evidence.txt")
    let committed = try await repository.resolver.execute(
      commitInput(message: "test: evidence", files: ["evidence.txt"]),
      context: AdapterExecutionContext()
    )
    let commitEvidence = gitPayload(committed.payload)
    XCTAssertEqual(commitEvidence["operation"], .string("commit"))
    XCTAssertEqual(commitEvidence["commitMessage"], .string("test: evidence"))
    XCTAssertEqual(commitEvidence["committedFiles"], .array([.string("evidence.txt")]))
    XCTAssertNotNil(commitEvidence["commitHash"])

    let pushed = try await repository.resolver.execute(pushInput(repository: repository), context: AdapterExecutionContext())
    let pushEvidence = gitPayload(pushed.payload)
    XCTAssertEqual(pushEvidence["operation"], .string("push"))
    XCTAssertEqual(pushEvidence["pushedRemote"], .string("origin"))
    XCTAssertEqual(pushEvidence["pushedBranch"], .string("main"))
    XCTAssertEqual(pushEvidence["commitHash"], commitEvidence["commitHash"])
    XCTAssertFalse(String(describing: pushed.payload).contains(repository.remoteRoot?.path ?? "unreachable"))
  }

  private func commitInput(
    allowCommit: Bool = true,
    message: String = "test: commit",
    files: [String],
    executionId: String = UUID().uuidString,
    attempt: Int = 1,
    predecessor: String? = nil
  ) -> WorkflowAddonExecutionInput {
    return WorkflowAddonExecutionInput(
      workflowId: "git-addon-test",
      stepId: "commit",
      nodeId: "commit",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.commit.rawValue,
        version: "1",
        config: [
          "allowCommit": .bool(allowCommit),
          "commitMessageTemplate": .string("{{inbox.latest.output.payload.commitMessage}}"),
          "committedFilesTemplate": .string("{{inbox.latest.output.payload.committedFiles}}")
        ]
      ),
      variables: step9Variables(message: message, files: files),
      executionIdentity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: "git-addon-test-session",
        stepExecutionId: executionId,
        attempt: attempt,
        predecessorStepExecutionId: predecessor
      )
    )
  }

  private func step9Variables(message: String, files: [String]) -> JSONObject {
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

  private func pushInput(
    repository: GitTestRepository,
    allowPush: Bool = true,
    expectedCommitHash: String? = nil
  ) throws -> WorkflowAddonExecutionInput {
    let expectedCommitHash = try expectedCommitHash ?? repository.git(["rev-parse", "HEAD"]).trimmed
    return WorkflowAddonExecutionInput(
      workflowId: "git-addon-test",
      stepId: "push",
      nodeId: "push",
      addon: WorkflowNodeAddonRef(
        name: BuiltinGitAddon.push.rawValue,
        version: "1",
        config: [
          "allowPush": .bool(allowPush),
          "expectedCommitHashTemplate": .string("{{expectedCommitHash}}")
        ]
      ),
      variables: ["expectedCommitHash": .string(expectedCommitHash)],
      executionIdentity: WorkflowAddonExecutionIdentity(
        workflowExecutionId: "git-addon-test-session",
        stepExecutionId: UUID().uuidString,
        attempt: 1
      )
    )
  }
}

struct FailingGitCommandRunner: GitCommandRunning {
  func run(_: GitCommandInvocation) throws -> GitCommandResult {
    GitCommandResult(exitCode: 128, output: "failure")
  }
}

final class ThrowOnceGitFinalizationFailureInjector: GitFinalizationFailureInjecting, @unchecked Sendable {
  private let lock = NSLock()
  private let phase: GitFinalizationFailurePhase
  private var didThrow = false

  init(phase: GitFinalizationFailurePhase) {
    self.phase = phase
  }

  func check(_ phase: GitFinalizationFailurePhase) throws {
    lock.lock()
    defer { lock.unlock() }
    guard phase == self.phase, !didThrow else {
      return
    }
    didThrow = true
    throw AdapterExecutionError(.providerError, "injected git finalization failure", isRetryable: true)
  }
}

final class GitTestRepository {
  let root: URL
  let resolver: BuiltinWorkflowAddonResolver
  let remoteRoot: URL?
  let finalizationRoot: URL

  init(withBareRemote: Bool = false, objectFormat: GitObjectFormat = .sha1) throws {
    let fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/git-addon-tests/\(UUID().uuidString)", isDirectory: true)
    root = fixtureRoot.appendingPathComponent("repository", isDirectory: true)
    remoteRoot = withBareRemote ? fixtureRoot.appendingPathComponent("remote.git", isDirectory: true) : nil
    finalizationRoot = fixtureRoot.appendingPathComponent("finalization", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: root,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: finalizationRoot),
      gitPushTransportPolicy: GitTestLocalPushTransportPolicy()
    )
    _ = try git(["init", "-b", "main", "--object-format=\(objectFormat.rawValue)"])
    _ = try git(["config", "user.name", "Riela Test"])
    _ = try git(["config", "user.email", "riela-test@example.invalid"])
    try write("initial", to: "tracked.txt")
    _ = try git(["add", "--", "tracked.txt"])
    _ = try git(["commit", "-m", "test: initial"])

    if let remoteRoot {
      try FileManager.default.createDirectory(at: remoteRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
      _ = try Self.runGit(
        ["init", "--bare", "--object-format=\(objectFormat.rawValue)", remoteRoot.path],
        at: fixtureRoot
      )
      _ = try git(["remote", "add", "origin", remoteRoot.path])
      _ = try git(["push", "-u", "origin", "main"])
    }
  }

  deinit {
    try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
  }

  func write(_ content: String, to relativePath: String) throws {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(relativePath).deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try content.write(
      to: root.appendingPathComponent(relativePath),
      atomically: true,
      encoding: .utf8
    )
  }

  func advanceRemoteFromAnotherClone(fetch: Bool = true) throws {
    let remoteRoot = try XCTUnwrap(remoteRoot)
    let cloneRoot = root.deletingLastPathComponent().appendingPathComponent("other", isDirectory: true)
    _ = try Self.runGit(["clone", remoteRoot.path, cloneRoot.path], at: root.deletingLastPathComponent())
    _ = try Self.runGit(["config", "user.name", "Riela Test"], at: cloneRoot)
    _ = try Self.runGit(["config", "user.email", "riela-test@example.invalid"], at: cloneRoot)
    try "remote".write(
      to: cloneRoot.appendingPathComponent("remote.txt"),
      atomically: true,
      encoding: .utf8
    )
    _ = try Self.runGit(["add", "--", "remote.txt"], at: cloneRoot)
    _ = try Self.runGit(["commit", "-m", "test: remote advance"], at: cloneRoot)
    _ = try Self.runGit(["push", "origin", "main"], at: cloneRoot)
    if fetch {
      _ = try git(["fetch", "origin"])
    }
  }

  func makeResolver(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    commandRunner: any GitCommandRunning = FoundationGitCommandRunner(),
    failureInjector: any GitFinalizationFailureInjecting = NoGitFinalizationFailureInjector()
  ) -> BuiltinWorkflowAddonResolver {
    BuiltinWorkflowAddonResolver(
      environment: environment,
      workingDirectory: root,
      gitCommandRunner: commandRunner,
      gitFinalizationStore: GitFinalizationStore(rootDirectory: finalizationRoot),
      gitFailureInjector: failureInjector,
      gitPushTransportPolicy: GitTestLocalPushTransportPolicy()
    )
  }

  func finalizationArtifacts(in directory: String) throws -> [String] {
    let url = finalizationRoot.appendingPathComponent(directory, isDirectory: true)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return []
    }
    return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
  }

  func indexData() throws -> Data {
    let path = try git(["rev-parse", "--git-path", "index"]).trimmed
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    return try Data(contentsOf: url)
  }

  func indexLockURL() throws -> URL {
    let path = try git(["rev-parse", "--git-path", "index"]).trimmed
    let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
    return URL(fileURLWithPath: url.path + ".lock")
  }

  @discardableResult
  func git(_ arguments: [String]) throws -> String {
    try Self.runGit(arguments, at: root)
  }

  static func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let result = try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: GitExecutablePolicy.versionOneURL,
      arguments: arguments,
      workingDirectory: directory,
      environment: ProcessInfo.processInfo.environment,
      standardInput: nil
    ))
    guard result.exitCode == 0 else {
      throw NSError(domain: "GitTestRepository", code: Int(result.exitCode))
    }
    return result.output
  }
}

private struct GitTestLocalPushTransportPolicy: GitPushTransportValidating {
  func validate(_: GitPushTransport) throws {}
}

func gitPayload(_ payload: JSONObject) -> JSONObject {
  guard case let .object(git)? = payload["git"] else {
    return [:]
  }
  return git
}

func XCTAssertGitCommitEvidence(
  _ payload: JSONObject,
  status: String,
  revision: String,
  message: String,
  files: [String],
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let evidence = gitPayload(payload)
  XCTAssertEqual(evidence["operation"], .string("commit"), file: file, line: line)
  XCTAssertEqual(evidence["status"], .string(status), file: file, line: line)
  XCTAssertEqual(evidence["commitHash"], .string(revision), file: file, line: line)
  XCTAssertEqual(evidence["commitMessage"], .string(message), file: file, line: line)
  XCTAssertEqual(evidence["committedFiles"], .array(files.map(JSONValue.string)), file: file, line: line)
  XCTAssertEqual(Set(evidence.keys), ["operation", "status", "commitHash", "commitMessage", "committedFiles"])
}

func XCTAssertGitPushEvidence(
  _ payload: JSONObject,
  status: String,
  revision: String,
  remote: String,
  branch: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  let evidence = gitPayload(payload)
  XCTAssertEqual(evidence["operation"], .string("push"), file: file, line: line)
  XCTAssertEqual(evidence["status"], .string(status), file: file, line: line)
  XCTAssertEqual(evidence["commitHash"], .string(revision), file: file, line: line)
  XCTAssertEqual(evidence["pushedRemote"], .string(remote), file: file, line: line)
  XCTAssertEqual(evidence["pushedBranch"], .string(branch), file: file, line: line)
  XCTAssertEqual(Set(evidence.keys), ["operation", "status", "commitHash", "pushedRemote", "pushedBranch"])
}

extension String {
  var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  file: StaticString = #filePath,
  line: UInt = #line,
  _ errorHandler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("expected expression to throw", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
