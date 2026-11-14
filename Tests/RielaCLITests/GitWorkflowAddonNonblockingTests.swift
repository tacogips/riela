import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class GitWorkflowAddonNonblockingTests: XCTestCase {
  func testCommitRejectsWorktreeFIFOWithoutBlockingBeforeHashing() async throws {
    let repository = try GitTestRepository()
    let worktreeURL = repository.root.appendingPathComponent("tracked.txt")
    let originalContent = try Data(contentsOf: worktreeURL)
    let headBefore = try repository.git(["rev-parse", "HEAD"]).trimmed
    var needsRestore = false
    defer {
      if needsRestore {
        try? FileManager.default.removeItem(at: worktreeURL)
        try? originalContent.write(to: worktreeURL, options: [.atomic])
      }
    }
    let injector = FIFOFailureInjector(phase: .canonicalIndexRead) {
      try FileManager.default.removeItem(at: worktreeURL)
      guard mkfifo(worktreeURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      needsRestore = true
    }
    let startedAt = Date()

    await XCTAssertThrowsErrorAsync(
      try await repository.makeResolver(failureInjector: injector).execute(
        makeGitCommitInput(message: "test: reject worktree fifo swap", files: ["tracked.txt"]),
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(2))
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("regular file") == true)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    try FileManager.default.removeItem(at: worktreeURL)
    try originalContent.write(to: worktreeURL, options: [.atomic])
    needsRestore = false
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]).trimmed, headBefore)
  }

  func testCommitRejectsDiscoveryFIFOWithoutBlockingDuringPreflight() async throws {
    let repository = try GitTestRepository()
    let discoveryURL = repository.root.appendingPathComponent(".git")
    let backupURL = repository.root.deletingLastPathComponent().appendingPathComponent("git-directory-backup")
    var needsRestore = false
    defer {
      if needsRestore {
        try? FileManager.default.removeItem(at: discoveryURL)
        try? FileManager.default.moveItem(at: backupURL, to: discoveryURL)
      }
    }
    let runner = AfterShowTopLevelGitCommandRunner {
      try FileManager.default.moveItem(at: discoveryURL, to: backupURL)
      guard mkfifo(discoveryURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      needsRestore = true
    }
    let resolver = repository.makeResolver(commandRunner: runner)
    let startedAt = Date()

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject discovery fifo swap", files: ["tracked.txt"]),
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(2))
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("discovery metadata") == true)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    try FileManager.default.removeItem(at: discoveryURL)
    try FileManager.default.moveItem(at: backupURL, to: discoveryURL)
    needsRestore = false
  }

  func testCommitRejectsLinkedWorktreeBackpointerFIFOWithoutBlockingDuringPreflight() async throws {
    let primary = try GitTestRepository()
    let fixtureRoot = primary.root.deletingLastPathComponent()
    let linkedRoot = fixtureRoot.appendingPathComponent("backpointer-fifo-linked", isDirectory: true)
    _ = try primary.git(["worktree", "add", "-b", "backpointer-fifo-linked", linkedRoot.path])
    let gitDirectory = URL(fileURLWithPath: try GitTestRepository.runGit(
      ["rev-parse", "--absolute-git-dir"],
      at: linkedRoot
    ).trimmed)
    let backpointerURL = gitDirectory.appendingPathComponent("gitdir")
    let originalBackpointer = try Data(contentsOf: backpointerURL)
    var needsRestore = false
    defer {
      if needsRestore {
        try? FileManager.default.removeItem(at: backpointerURL)
        try? originalBackpointer.write(to: backpointerURL, options: [.atomic])
      }
    }
    let runner = AfterShowTopLevelGitCommandRunner {
      try FileManager.default.removeItem(at: backpointerURL)
      guard mkfifo(backpointerURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
      }
      needsRestore = true
    }
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ProcessInfo.processInfo.environment,
      workingDirectory: linkedRoot,
      gitCommandRunner: runner,
      gitFinalizationStore: GitFinalizationStore(
        rootDirectory: fixtureRoot.appendingPathComponent("backpointer-fifo-finalization")
      )
    )
    let startedAt = Date()

    await XCTAssertThrowsErrorAsync(
      try await resolver.execute(
        makeGitCommitInput(message: "test: reject backpointer fifo swap", files: ["tracked.txt"]),
        context: AdapterExecutionContext(deadline: Date().addingTimeInterval(2))
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      XCTAssertTrue((error as? AdapterExecutionError)?.message.contains("backpointer") == true)
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    try FileManager.default.removeItem(at: backpointerURL)
    try originalBackpointer.write(to: backpointerURL, options: [.atomic])
    needsRestore = false
  }
}

private final class FIFOFailureInjector:
  GitFinalizationFailureInjecting,
  @unchecked Sendable {
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

private final class AfterShowTopLevelGitCommandRunner: GitCommandRunning, @unchecked Sendable {
  private let lock = NSLock()
  private let action: () throws -> Void
  private let underlying = FoundationGitCommandRunner()
  private var didRun = false

  init(action: @escaping () throws -> Void) {
    self.action = action
  }

  func run(_ invocation: GitCommandInvocation) throws -> GitCommandResult {
    let result = try underlying.run(invocation)
    guard invocation.arguments.contains("--show-toplevel") else {
      return result
    }
    let shouldRun = lock.withLock { () -> Bool in
      guard !didRun else { return false }
      didRun = true
      return true
    }
    if shouldRun {
      try action()
    }
    return result
  }
}
