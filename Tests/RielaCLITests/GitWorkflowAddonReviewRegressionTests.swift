import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class GitWorkflowAddonReviewRegressionTests: XCTestCase {
  func testCommitUsesAuthorAndCommitterSpecificIdentityPrecedence() async throws {
    let repository = try GitTestRepository()
    _ = try repository.git(["config", "author.name", "Specific Author"])
    _ = try repository.git(["config", "author.email", "author@example.invalid"])
    _ = try repository.git(["config", "committer.name", "Specific Committer"])
    _ = try repository.git(["config", "committer.email", "committer@example.invalid"])
    try repository.write("identity precedence", to: "tracked.txt")

    _ = try await repository.resolver.execute(
      makeGitCommitInput(message: "test: identity precedence", files: ["tracked.txt"]),
      context: AdapterExecutionContext()
    )

    let identity = try repository.git([
      "show", "-s", "--format=%an%x00%ae%x00%cn%x00%ce", "HEAD"
    ]).split(separator: "\0", omittingEmptySubsequences: true).map {
      String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    XCTAssertEqual(
      identity,
      ["Specific Author", "author@example.invalid", "Specific Committer", "committer@example.invalid"]
    )
  }

  func testCommitPreservesTrackedExecutableModesWhenCoreFilemodeIsFalse() async throws {
    try await assertCommitPreservesTrackedMode(
      initialMode: 0o644,
      worktreeMode: 0o755,
      expectedGitMode: "100644"
    )
    try await assertCommitPreservesTrackedMode(
      initialMode: 0o755,
      worktreeMode: 0o644,
      expectedGitMode: "100755"
    )
  }

  func testCommitRecordsRegularModeWhenTrackedSymlinkIsReplacedByRegularFile() async throws {
    let repository = try GitTestRepository()
    let path = "tracked-link"
    let url = repository.root.appendingPathComponent(path)
    try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "target.txt")
    _ = try repository.git(["add", "--", path])
    _ = try repository.git(["commit", "-m", "test: establish tracked symlink"])
    _ = try repository.git(["config", "core.filemode", "false"])
    try FileManager.default.removeItem(at: url)
    try "regular replacement".write(to: url, atomically: true, encoding: .utf8)

    _ = try await repository.resolver.execute(
      makeGitCommitInput(message: "test: replace symlink with regular file", files: [path]),
      context: AdapterExecutionContext()
    )

    let mode = try repository.git(["ls-tree", "HEAD", "--", path])
      .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    XCTAssertEqual(mode, "100644")
  }

  func testCommitRejectsTrackedFileReplacedByDanglingSymlink() async throws {
    let repository = try GitTestRepository()
    let path = "tracked.txt"
    let url = repository.root.appendingPathComponent(path)
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createSymbolicLink(
      atPath: url.path,
      withDestinationPath: "missing-target"
    )

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(message: "test: reject dangling symlink", files: [path]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("file changed before staging") == true)
    }

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), "missing-target")
  }

  func testCommitSupportsNestedTrackedDeletionWhenParentDirectoryIsAbsent() async throws {
    let repository = try GitTestRepository()
    let nestedPath = "nested/tracked.txt"
    let unrelatedPath = "unrelated.txt"
    try repository.write("nested original", to: nestedPath)
    try repository.write("unrelated original", to: unrelatedPath)
    _ = try repository.git(["add", "--", nestedPath, unrelatedPath])
    _ = try repository.git(["commit", "-m", "test: establish nested tracked path"])
    try repository.write("unrelated worktree edit", to: unrelatedPath)
    try FileManager.default.removeItem(at: repository.root.appendingPathComponent("nested"))

    let output = try await repository.resolver.execute(
      makeGitCommitInput(message: "test: nested tracked deletion", files: [nestedPath]),
      context: AdapterExecutionContext()
    )
    let revision = try XCTUnwrap(gitPayload(output.payload)["commitHash"]?.stringValue)

    XCTAssertGitCommitEvidence(
      output.payload,
      status: "committed",
      revision: revision,
      message: "test: nested tracked deletion",
      files: [nestedPath]
    )
    XCTAssertEqual(
      try repository.git(["show", "--format=", "--name-status", "HEAD"]).trimmed,
      "D\t\(nestedPath)"
    )
    XCTAssertEqual(try repository.git(["show", "HEAD:\(unrelatedPath)"]).trimmed, "unrelated original")
    XCTAssertEqual(
      try String(contentsOf: repository.root.appendingPathComponent(unrelatedPath), encoding: .utf8),
      "unrelated worktree edit"
    )
    XCTAssertEqual(try repository.git(["diff", "--cached", "--name-only"]).trimmed, "")
    XCTAssertEqual(try repository.git(["status", "--short"]).trimmed, "M unrelated.txt")
  }

  func testCommitReplacementRefCannotHideUnrelatedStagedPath() async throws {
    let repository = try GitTestRepository()
    let allowedPath = "tracked.txt"
    let unrelatedPath = "unrelated.txt"
    try repository.write("unrelated original", to: unrelatedPath)
    _ = try repository.git(["add", "--", unrelatedPath])
    _ = try repository.git(["commit", "-m", "test: establish unrelated path"])
    let parent = try repository.git(["rev-parse", "HEAD"]).trimmed

    try repository.write("unrelated staged content", to: unrelatedPath)
    _ = try repository.git(["add", "--", unrelatedPath])
    let replacementTree = try repository.git(["write-tree"]).trimmed
    let replacement = try repository.git([
      "commit-tree", replacementTree,
      "-p", parent,
      "-m", "test: replacement tree"
    ]).trimmed
    _ = try repository.git(["update-ref", "refs/replace/\(parent)", replacement])
    try repository.write("allowed worktree content", to: allowedPath)
    let indexBefore = try repository.indexData()

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(
          message: "test: replacement ref allowlist confinement",
          files: [allowedPath]
        ),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("allowlist-external") == true)
    }

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, parent)
    XCTAssertEqual(try repository.indexData(), indexBefore)
  }

  func testCommitRetainsOwnedLockIdentityAfterRefUpdate() async throws {
    let repository = try GitTestRepository()
    try repository.write("post-ref lock replacement", to: "tracked.txt")
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    let indexBefore = try repository.indexData()
    let lockURL = try repository.indexLockURL()
    let foreignLock = Data("foreign-post-ref-lock".utf8)
    defer { try? FileManager.default.removeItem(at: lockURL) }
    let injector = ReviewGitFinalizationFailureInjector(phase: .refUpdate) {
      try FileManager.default.removeItem(at: lockURL)
      try foreignLock.write(to: lockURL, options: [.withoutOverwriting])
    }

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: retain lock identity", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("lock ownership changed") == true)
    }

    XCTAssertNotEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
    XCTAssertEqual(try repository.indexData(), indexBefore)
    XCTAssertEqual(try Data(contentsOf: lockURL), foreignLock)
  }

  func testPushRejectsHeadThatDoesNotMatchAcceptedCommitBeforeLiveAccess() async throws {
    let repository = try GitTestRepository(withBareRemote: true)
    let acceptedCommit = try repository.git(["rev-parse", "HEAD"]).trimmed
    try repository.write("concurrent local commit", to: "tracked.txt")
    _ = try repository.git(["add", "--", "tracked.txt"])
    _ = try repository.git(["commit", "-m", "test: concurrent local commit"])
    let currentHead = try repository.git(["rev-parse", "HEAD"]).trimmed
    let runner = ScriptedGitCommandRunner(mode: .fixedLiveTip(currentHead))

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(commandRunner: runner).execute(
        makeGitPushInput(repository: repository, expectedCommitHash: acceptedCommit),
        context: AdapterExecutionContext()
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("accepted commit evidence") == true)
    }
    XCTAssertEqual(runner.liveQueryCount, 0)
    let remote = try XCTUnwrap(repository.remoteRoot)
    XCTAssertEqual(try GitTestRepository.runGit(["rev-parse", "HEAD"], at: remote).trimmed, acceptedCommit)
  }

  func testPushRejectsDecodedHTTPSWhitespaceAndInvalidPortsBeforeNetworkAccess() async throws {
    let unsafeURLs = [
      "https://example%20.invalid/repository.git",
      "https://example.invalid/repository%0A.git",
      "https://example.invalid:bad/repository.git",
      "https://example.invalid:70000/repository.git"
    ]

    for unsafeURL in unsafeURLs {
      let repository = try GitTestRepository(withBareRemote: true)
      _ = try repository.git(["remote", "set-url", "--push", "origin", unsafeURL])

      await XCTAssertThrowsErrorAsync(
        try await repository.resolver.execute(
          makeGitPushInput(repository: repository),
          context: AdapterExecutionContext()
        )
      ) { error in
        let adapterError = error as? AdapterExecutionError
        XCTAssertEqual(adapterError?.code, .policyBlocked, unsafeURL)
        XCTAssertFalse(adapterError?.isRetryable == true, unsafeURL)
      }
    }
  }

  func testGitFilesystemFailureUsesPathFreeBoundedDiagnostic() async throws {
    let repository = try GitTestRepository()
    try Data("occupied finalization root".utf8).write(to: repository.finalizationRoot)

    await XCTAssertThrowsErrorAsync(
      try await repository.resolver.execute(
        makeGitCommitInput(message: "test: sanitized filesystem error", files: ["tracked.txt"]),
        context: AdapterExecutionContext()
      )
    ) { error in
      let adapterError = error as? AdapterExecutionError
      XCTAssertEqual(adapterError?.code, .providerError)
      XCTAssertEqual(adapterError?.isRetryable, true)
      XCTAssertEqual(
        adapterError?.message,
        "git finalization failed before producing safe diagnostics"
      )
      XCTAssertLessThan(adapterError?.message.utf8.count ?? .max, 128)
      XCTAssertFalse(adapterError?.message.contains(repository.finalizationRoot.path) == true)
      XCTAssertFalse(adapterError?.message.contains("NSFilePath") == true)
      XCTAssertFalse(adapterError?.message.contains("NSURL") == true)
    }
  }

  private func assertCommitPreservesTrackedMode(
    initialMode: Int,
    worktreeMode: Int,
    expectedGitMode: String
  ) async throws {
    let repository = try GitTestRepository()
    let trackedURL = repository.root.appendingPathComponent("tracked.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: initialMode],
      ofItemAtPath: trackedURL.path
    )
    _ = try repository.git(["add", "--", "tracked.txt"])
    _ = try repository.git(["commit", "--allow-empty", "-m", "test: establish tracked mode"])
    _ = try repository.git(["config", "core.filemode", "false"])
    try repository.write("mode change \(worktreeMode)", to: "tracked.txt")
    try FileManager.default.setAttributes(
      [.posixPermissions: worktreeMode],
      ofItemAtPath: trackedURL.path
    )

    _ = try await repository.resolver.execute(
      makeGitCommitInput(message: "test: preserve tracked mode", files: ["tracked.txt"]),
      context: AdapterExecutionContext()
    )

    let mode = try repository.git(["ls-tree", "HEAD", "--", "tracked.txt"])
      .split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    XCTAssertEqual(mode, expectedGitMode)
  }
}

private final class ReviewGitFinalizationFailureInjector: GitFinalizationFailureInjecting, @unchecked Sendable {
  private let lock = NSLock()
  private let phase: GitFinalizationFailurePhase
  private let action: () throws -> Void
  private var didRun = false

  init(phase: GitFinalizationFailurePhase, action: @escaping () throws -> Void) {
    self.phase = phase
    self.action = action
  }

  func check(_ phase: GitFinalizationFailurePhase) throws {
    let shouldRun = lock.withLock { () -> Bool in
      guard phase == self.phase, !didRun else { return false }
      didRun = true
      return true
    }
    if shouldRun {
      try action()
    }
  }
}
