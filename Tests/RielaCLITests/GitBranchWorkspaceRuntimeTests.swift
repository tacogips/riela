import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
@testable import RielaWork

final class GitBranchWorkspaceRuntimeTests: XCTestCase {
  func testEnsureBranchSharedRejectsDirtyRootAndWorktreeCreatesAttemptPath() async throws {
    let repository = try BranchRuntimeRepository()
    let runtime = GitBranchWorkspaceRuntime()
    let task = TaskID("task-7")
    let attempt = AttemptID("attempt-7")
    let shared = try await runtime.ensureBranch(
      root: repository.root.path,
      attempt: attempt,
      task: task,
      generation: 2,
      base: nil,
      isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    XCTAssertEqual(shared.branch, "riela/task/task-7/g2")
    XCTAssertEqual(try repository.git(["branch", "--show-current"]), shared.branch)

    try repository.write("dirty", to: "dirty.txt")
    do {
      _ = try await runtime.ensureBranch(
        root: repository.root.path,
        attempt: AttemptID("attempt-dirty"),
        task: task,
        generation: 3,
        base: nil,
        isolation: .shared,
        template: "riela/task/{taskId}/g{generation}"
      )
      XCTFail("dirty shared repository should be refused")
    } catch let error as GitBranchWorkspaceError {
      XCTAssertTrue(error.stderrHead.contains("dirty"))
    }

    let worktreeRepository = try BranchRuntimeRepository()
    let worktree = try await runtime.ensureBranch(
      root: worktreeRepository.root.path,
      attempt: attempt,
      task: task,
      generation: 4,
      base: nil,
      isolation: .worktree,
      template: "riela/task/{taskId}/g{generation}"
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))
    XCTAssertEqual(try BranchRuntimeRepository.runGit(["branch", "--show-current"], at: URL(fileURLWithPath: worktree.path)), worktree.branch)
    XCTAssertEqual(worktree.branch, "riela/task/task-7/g4")
  }

  func testCheckpointCommitsTrailerAndExcludesRielaAndReturnsNilWhenClean() async throws {
    let repository = try BranchRuntimeRepository()
    let runtime = GitBranchWorkspaceRuntime()
    try repository.write("checkpoint", to: "checkpoint.txt")
    try repository.write("private", to: ".riela/private.txt")
    let isolation = IsolationRef(path: repository.root.path, branch: "main")

    let revision = try await runtime.checkpoint(
      isolation,
      message: "riela: checkpoint task-1 step-1",
      trailer: "Riela-Checkpoint: attempt-1/step-execution-1",
      paths: nil
    )

    let committed = try XCTUnwrap(revision)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]), committed)
    XCTAssertTrue(try repository.git(["show", "-s", "--format=%B", "HEAD"]).contains("Riela-Checkpoint: attempt-1/step-execution-1"))
    XCTAssertEqual(try repository.git(["ls-tree", "-r", "--name-only", "HEAD"]).contains(".riela/private.txt"), false)
    let emptyCheckpoint = try await runtime.checkpoint(isolation, message: "checkpoint", trailer: "Riela-Checkpoint: clean", paths: nil)
    XCTAssertNil(emptyCheckpoint)
    let dirtyPaths = try await runtime.dirtyPaths(isolation)
    XCTAssertEqual(dirtyPaths, [])
  }

  func testCheckpointRefusesWhenHeadLeftIsolationBranch() async throws {
    let repository = try BranchRuntimeRepository()
    let runtime = GitBranchWorkspaceRuntime()
    let base = try repository.git(["rev-parse", "HEAD"])
    let isolation = try await runtime.ensureBranch(
      root: repository.root.path,
      attempt: AttemptID("attempt-1"),
      task: TaskID("task-1"),
      generation: 1,
      base: nil,
      isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    let isolationBranch = try XCTUnwrap(isolation.branch)
    _ = try repository.git(["checkout", "main"])
    let mainHead = try repository.git(["rev-parse", "HEAD"])
    try repository.write("leaked", to: "leaked.txt")

    do {
      _ = try await runtime.checkpoint(
        isolation,
        message: "riela: checkpoint task-1 step-1",
        trailer: "Riela-Checkpoint: attempt-1/step-execution-1",
        paths: nil
      )
      XCTFail("checkpoint must refuse when HEAD is not on the isolation branch")
    } catch is GitBranchWorkspaceError {}

    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]), mainHead)
    XCTAssertEqual(try repository.git(["rev-parse", isolationBranch]), base)
    XCTAssertEqual(try repository.git(["diff", "--cached", "--name-only"]), "")
  }

  func testPublishCreatesAndFastForwardsOnlyTaskBranchAndRejectsRemoteAhead() async throws {
    let repository = try BranchRuntimeRepository(withRemote: true)
    let runtime = GitBranchWorkspaceRuntime()
    let isolation = IsolationRef(path: repository.root.path, branch: "riela/task/T1/g1")
    _ = try await runtime.ensureBranch(
      root: repository.root.path,
      attempt: AttemptID("attempt-publish"),
      task: TaskID("T1"),
      generation: 1,
      base: nil,
      isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    try repository.write("first", to: "first.txt")
    _ = try await runtime.checkpoint(isolation, message: "first", trailer: "Riela-Checkpoint: first", paths: nil)
    let first = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")
    XCTAssertTrue(first.created)

    let repeatPublish = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")
    XCTAssertFalse(repeatPublish.created)
    XCTAssertEqual(repeatPublish.sha, first.sha)

    try repository.write("second", to: "second.txt")
    _ = try await runtime.checkpoint(isolation, message: "second", trailer: "Riela-Checkpoint: second", paths: nil)
    let fastForward = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")
    XCTAssertEqual(fastForward.sha, try repository.git(["rev-parse", "HEAD"]))

    try repository.advanceRemoteBranch("riela/task/T1/g1")
    try repository.write("local divergence", to: "local.txt")
    _ = try await runtime.checkpoint(isolation, message: "local", trailer: "Riela-Checkpoint: local", paths: nil)
    do {
      _ = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")
      XCTFail("remote-ahead branch must be refused")
    } catch let error as GitBranchWorkspaceError {
      XCTAssertTrue(error.stderrHead.contains("behind or diverged"))
    }
  }

  func testPublishRejectsNonAllowlistedBranchBeforeRunningGit() async throws {
    let runner = BranchRuntimeCountingGitRunner()
    let runtime = GitBranchWorkspaceRuntime(git: runner, environment: [:])
    do {
      _ = try await runtime.publish(
        IsolationRef(path: "/tmp/not-opened", branch: "main"),
        remote: "origin",
        allowCreate: true,
        branchAllowlist: "riela/task/*"
      )
      XCTFail("main should not be publishable")
    } catch let error as GitBranchWorkspaceError {
      XCTAssertEqual(error.command, "branch allowlist")
    }
    XCTAssertEqual(runner.invocationCount, 0)
  }

  func testMaterializePublishedBranchChecksRemoteHeadAndUsesSecondClone() async throws {
    let source = try BranchRuntimeRepository(withRemote: true)
    let runtime = GitBranchWorkspaceRuntime()
    _ = try await runtime.ensureBranch(
      root: source.root.path,
      attempt: AttemptID("attempt-source"),
      task: TaskID("T2"),
      generation: 1,
      base: nil,
      isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    try source.write("published", to: "published.txt")
    let isolation = IsolationRef(path: source.root.path, branch: "riela/task/T2/g1")
    _ = try await runtime.checkpoint(isolation, message: "publish", trailer: "Riela-Checkpoint: publish", paths: nil)
    let published = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")

    let clone = try BranchRuntimeRepository(cloning: try XCTUnwrap(source.remoteRoot))
    let deliverable = RepositoryDeliverable(
      root: source.root.path,
      remote: try XCTUnwrap(source.remoteRoot).path,
      branch: published.branch,
      baseRevision: try source.git(["rev-parse", "main"]),
      headCommit: published.sha,
      state: .published
    )
    let materialized = try await runtime.materialize(
      deliverable,
      into: clone.root.path,
      worktree: false,
      attempt: AttemptID("attempt-successor")
    )
    XCTAssertEqual(try clone.git(["rev-parse", "HEAD"]), published.sha)
    XCTAssertEqual(materialized.branch, published.branch)
  }

  func testMaterializeRefusesMovedRemoteAndUsesUnpublishedLocalLastKnown() async throws {
    let source = try BranchRuntimeRepository(withRemote: true)
    let runtime = GitBranchWorkspaceRuntime()
    _ = try await runtime.ensureBranch(
      root: source.root.path,
      attempt: AttemptID("attempt-source"),
      task: TaskID("T3"),
      generation: 1,
      base: nil,
      isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    let isolation = IsolationRef(path: source.root.path, branch: "riela/task/T3/g1")
    try source.write("published", to: "published.txt")
    _ = try await runtime.checkpoint(isolation, message: "publish", trailer: "Riela-Checkpoint: publish", paths: nil)
    let published = try await runtime.publish(isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*")
    try source.advanceRemoteBranch(published.branch)

    let clone = try BranchRuntimeRepository(cloning: try XCTUnwrap(source.remoteRoot))
    let moved = RepositoryDeliverable(
      root: source.root.path,
      remote: try XCTUnwrap(source.remoteRoot).path,
      branch: published.branch,
      baseRevision: try source.git(["rev-parse", "main"]),
      headCommit: published.sha,
      state: .published
    )
    do {
      _ = try await runtime.materialize(moved, into: clone.root.path, worktree: false, attempt: AttemptID("attempt-moved"))
      XCTFail("moved remote must be refused")
    } catch let error as GitBranchWorkspaceError {
      XCTAssertTrue(error.stderrHead.contains("remote branch moved"))
    }

    let lastKnown = try source.git(["rev-parse", "HEAD"])
    let unpublished = RepositoryDeliverable(
      root: source.root.path,
      remote: try XCTUnwrap(source.remoteRoot).path,
      branch: "riela/task/T3/g1",
      baseRevision: try source.git(["rev-parse", "main"]),
      state: .unpublished(lastKnown: lastKnown)
    )
    let materialized = try await runtime.materialize(
      unpublished,
      into: source.root.path,
      worktree: false,
      attempt: AttemptID("attempt-unpublished")
    )
    XCTAssertEqual(try source.git(["rev-parse", "HEAD"]), lastKnown)
    XCTAssertEqual(materialized.baseRevision, unpublished.baseRevision)
  }

  func testDirtyPathsSortsExcludesRielaAndCapsAt512() async throws {
    let repository = try BranchRuntimeRepository()
    try repository.write("tracked baseline", to: "aaa-tracked.txt")
    _ = try repository.git(["add", "--", "aaa-tracked.txt"])
    _ = try repository.git(["commit", "-m", "add tracked path"])
    for number in stride(from: 519, through: 0, by: -1) {
      try repository.write("x", to: String(format: "dirty-%03d.txt", number))
    }
    try repository.write("modified", to: "aaa-tracked.txt")
    try repository.write("private", to: ".riela/internal")
    let paths = try await GitBranchWorkspaceRuntime().dirtyPaths(IsolationRef(path: repository.root.path))
    XCTAssertEqual(paths.count, 512)
    XCTAssertEqual(paths, paths.sorted())
    XCTAssertFalse(paths.contains { $0 == ".riela" || $0.hasPrefix(".riela/") })
    XCTAssertTrue(paths.contains("dirty-000.txt"))
    XCTAssertTrue(paths.contains("aaa-tracked.txt"))
  }

  func testDirtyPathsIncludesBothSidesOfRename() async throws {
    let repository = try BranchRuntimeRepository()
    _ = try repository.git(["mv", "initial.txt", "renamed.txt"])

    let paths = try await GitBranchWorkspaceRuntime().dirtyPaths(IsolationRef(path: repository.root.path))

    XCTAssertEqual(paths, ["initial.txt", "renamed.txt"])
  }
}

private final class BranchRuntimeRepository {
  let root: URL
  let remoteRoot: URL?
  private let fixtureRoot: URL

  init(withRemote: Bool = false, cloning remote: URL? = nil) throws {
    fixtureRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/work-handover/wh-07-git-branch-runtime/repos/\(UUID().uuidString)", isDirectory: true)
    root = fixtureRoot.appendingPathComponent("repository", isDirectory: true)
    if let remote {
      remoteRoot = nil
      try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
      _ = try Self.runGit(["clone", remote.path, root.path], at: fixtureRoot)
    } else {
      remoteRoot = withRemote ? fixtureRoot.appendingPathComponent("remote.git", isDirectory: true) : nil
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      _ = try Self.runGit(["init", "-b", "main", root.path], at: fixtureRoot)
      _ = try git(["config", "user.name", "Riela Test"])
      _ = try git(["config", "user.email", "riela-test@example.invalid"])
      try write("initial", to: "initial.txt")
      _ = try git(["add", "--", "initial.txt"])
      _ = try git(["commit", "-m", "initial"])
      if let remoteRoot {
        _ = try Self.runGit(["init", "--bare", remoteRoot.path], at: fixtureRoot)
        _ = try git(["remote", "add", "origin", remoteRoot.path])
        _ = try git(["push", "-u", "origin", "main"])
      }
    }
    if remote != nil {
      _ = try Self.runGit(["config", "user.name", "Riela Test"], at: root)
      _ = try Self.runGit(["config", "user.email", "riela-test@example.invalid"], at: root)
    }
  }

  deinit { try? FileManager.default.removeItem(at: fixtureRoot) }

  func write(_ content: String, to path: String) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
  }

  func git(_ arguments: [String]) throws -> String { try Self.runGit(arguments, at: root) }

  func advanceRemoteBranch(_ branch: String) throws {
    guard let remoteRoot else { throw NSError(domain: "BranchRuntimeRepository", code: 1) }
    let clone = fixtureRoot.appendingPathComponent("advancer", isDirectory: true)
    _ = try Self.runGit(["clone", remoteRoot.path, clone.path], at: fixtureRoot)
    _ = try Self.runGit(["config", "user.name", "Riela Test"], at: clone)
    _ = try Self.runGit(["config", "user.email", "riela-test@example.invalid"], at: clone)
    _ = try Self.runGit(["checkout", "-B", branch, "origin/\(branch)"], at: clone)
    try "remote advance".write(to: clone.appendingPathComponent("remote.txt"), atomically: true, encoding: .utf8)
    _ = try Self.runGit(["add", "--", "remote.txt"], at: clone)
    _ = try Self.runGit(["commit", "-m", "remote advance"], at: clone)
    _ = try Self.runGit(["push", "origin", "HEAD:refs/heads/\(branch)"], at: clone)
  }

  static func runGit(_ arguments: [String], at directory: URL) throws -> String {
    let result = try FoundationGitCommandRunner().run(GitCommandInvocation(
      executableURL: URL(fileURLWithPath: "/usr/bin/git"),
      arguments: arguments,
      workingDirectory: directory,
      environment: ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { _, value in value },
      standardInput: nil
    ))
    guard result.exitCode == 0 else {
      throw NSError(domain: "BranchRuntimeRepository", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: result.output])
    }
    return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class BranchRuntimeCountingGitRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var invocationCount: Int { lock.withLock { count } }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    lock.withLock { count += 1 }
    return try FoundationGitCommandRunner().run(invocation)
  }
}
