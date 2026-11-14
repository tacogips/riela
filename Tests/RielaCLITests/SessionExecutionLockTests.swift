import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class SessionExecutionLockTests: XCTestCase {
  func testOrphanLockSweepRemovesAbsentSessionsAndSkipsBusyLock() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "busy")
    for id in ["orphan-a", "orphan-b"] {
      let seed = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      try seed.acquire(sessionId: id)
      seed.release(sessionId: id)
    }
    let sweep = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let result = sweep.removeOrphanLocks(dryRun: false) { _ in false }
    XCTAssertEqual(result, .init(selectedCount: 3, removedCount: 2, skippedBusy: 1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath(root, "busy")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath(root, "orphan-a")))
  }

  func testOrphanLockSweepKeepsPersistedSession() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try seed.acquire(sessionId: "present")
    seed.release(sessionId: "present")
    let result = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .removeOrphanLocks(dryRun: false) { $0 == "present" }
    XCTAssertEqual(result.removedCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath(root, "present")))
  }

  func testOrphanLockSweepDryRunOnlyCountsCandidates() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try seed.acquire(sessionId: "dry-run")
    seed.release(sessionId: "dry-run")
    let result = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .removeOrphanLocks(dryRun: true) { _ in false }
    XCTAssertEqual(result, .init(selectedCount: 1, removedCount: 0, skippedBusy: 0))
    XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath(root, "dry-run")))
  }

  func testOrphanLockSweepHonorsLimitInSortedOrder() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for id in ["z-last", "a-first"] {
      let seed = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      try seed.acquire(sessionId: id)
      seed.release(sessionId: id)
    }
    let result = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .removeOrphanLocks(limit: 1, dryRun: false) { _ in false }
    XCTAssertEqual(result.removedCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath(root, "a-first")))
    XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath(root, "z-last")))
  }

  func testOrphanLockSweepLeavesSymlinkUntouched() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lockRoot = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .appendingPathComponent("execution-locks", isDirectory: true)
    try FileManager.default.createDirectory(at: lockRoot, withIntermediateDirectories: true)
    let target = lockRoot.appendingPathComponent("target")
    try Data().write(to: target)
    let link = lockRoot.appendingPathComponent("linked.lock")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let result = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .removeOrphanLocks(dryRun: false) { _ in false }
    XCTAssertEqual(result.selectedCount, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
  }

  func testLockAcquisitionRetriesWhenPathInodeChangesAfterFlock() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lockPath = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .appendingPathComponent("execution-locks/session-race.lock")
    var replaced = false
    let contender = SessionExecutionLockRegistry(sessionStoreRoot: root.path) {
      guard !replaced else { return }
      replaced = true
      try? FileManager.default.removeItem(at: lockPath)
      FileManager.default.createFile(atPath: lockPath.path, contents: Data())
    }
    try contender.acquire(sessionId: "session-race")
    let third = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    XCTAssertThrowsError(try third.acquire(sessionId: "session-race")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .alreadyRunning("session-race"))
    }
  }

  func testMessageRetiredAdmissionAndOverrides() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try createMessageTombstone(root: root, sessionId: "message-retired")
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    XCTAssertThrowsError(try registry.acquire(sessionId: "message-retired")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .messagesRetired("message-retired"))
    }
    try registry.acquire(sessionId: "message-retired", allowMessagesRetired: true)
    registry.release(sessionId: "message-retired")
    try registry.acquire(sessionId: "message-retired", allowRetired: true)
  }

  func testResultsRetirementStillBlocksAllowMessagesRetired() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
      withIntermediateDirectories: true)
    let db = try SQLiteDatabase.open(path: path)
    try db.execute("CREATE TABLE session_retention_tombstones(session_id TEXT PRIMARY KEY)")
    try db.execute("INSERT INTO session_retention_tombstones VALUES('results-retired')")
    XCTAssertThrowsError(try SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .acquire(sessionId: "results-retired", allowMessagesRetired: true)) { error in
        XCTAssertEqual(error as? SessionExecutionLockError, .retiredSession("results-retired"))
      }
  }

  func testSessionMessagesRetiredReturnsFalseWhenTableMissing() throws {
    let root = try retentionTempRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    XCTAssertFalse(try SessionExecutionLockRegistry(sessionStoreRoot: root.path)
      .sessionMessagesRetired(sessionId: "missing"))
  }

  func testSecondRegistryCannotAcquireLiveSessionAndCanAcquireAfterRelease() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-execution-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var owner: SessionExecutionLockRegistry? = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let contender = SessionExecutionLockRegistry(sessionStoreRoot: root.path)

    try owner?.acquire(sessionId: "session-1")
    XCTAssertThrowsError(try contender.acquire(sessionId: "session-1")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .alreadyRunning("session-1"))
    }

    owner = nil
    try contender.acquire(sessionId: "session-1")
  }

  func testRegistryAllowsDifferentSessionsAndRepeatedSameOwnerAcquire() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-execution-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let second = SessionExecutionLockRegistry(sessionStoreRoot: root.path)

    try first.acquire(sessionId: "session-1")
    try first.acquire(sessionId: "session-1")
    try second.acquire(sessionId: "session-2")
  }

  func testReservingGeneratorSkipsLockedAndPersistedSessionIds() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-id-reservation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contender = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try contender.acquire(sessionId: "wf-session-1")
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let generator = LockReservingWorkflowRuntimeIDGenerator(registry: registry) { sessionId in
      sessionId == "wf-session-2"
    }

    XCTAssertEqual(try generator.nextSessionId(workflowId: "wf"), "wf-session-3")
    XCTAssertFalse(registry.holds(sessionId: "wf-session-1"))
    XCTAssertFalse(registry.holds(sessionId: "wf-session-2"), "a persisted candidate must not stay reserved")
    XCTAssertTrue(registry.holds(sessionId: "wf-session-3"))
    // Another process can still reserve the released candidate.
    try contender.acquire(sessionId: "wf-session-2")
    XCTAssertThrowsError(try contender.acquire(sessionId: "wf-session-3"))
  }

  func testRegistryRejectsUnsafeSessionIdentity() {
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: FileManager.default.temporaryDirectory.path)

    XCTAssertThrowsError(try registry.acquire(sessionId: "../session")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .invalidSessionId("../session"))
    }
  }

}

private func retentionTempRoot() throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/automatic-retention-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root.resolvingSymlinksInPath()
}

private func lockPath(_ root: URL, _ id: String) -> String {
  URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    .appendingPathComponent("execution-locks/\(id).lock").path
}

private func createMessageTombstone(root: URL, sessionId: String) throws {
  let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
  try FileManager.default.createDirectory(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path,
    withIntermediateDirectories: true)
  let db = try SQLiteDatabase.open(path: path)
  try db.execute("CREATE TABLE session_message_retention_tombstones(session_id TEXT PRIMARY KEY, workflow_id TEXT NOT NULL, pruned_at TEXT NOT NULL, message_bytes INTEGER NOT NULL)")
  try db.execute("INSERT INTO session_message_retention_tombstones VALUES(?,?,?,?)",
    bindings: [.text(sessionId), .text("workflow"), .text("2026-10-19T00:00:00Z"), .int(4)])
}

extension WorkflowCommandTests {
  func testSessionContinueRejectsLiveOwnerWithoutChangingRecoverableSnapshot() async throws {
    let repository = repositoryRoot()
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-continue-lock-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let initial = await RielaCLIApplication().run([
      "workflow", "run", "recent-change-quality-loop",
      "--workflow-definition-dir", "\(repository)/examples",
      "--mock-scenario", "\(repository)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", root.path,
      "--session-store", root.path,
      "--max-steps", "1",
      "--output", "json"
    ], environment: ["HOME": root.path])
    XCTAssertEqual(initial.exitCode, .failure, initial.stderr)
    let interrupted = try decodeJSON(WorkflowRunFailureResult.self, from: initial.stdout)
    let sessionId = try XCTUnwrap(interrupted.sessionId)
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: sessionId)

    let continued = await RielaCLIApplication().run([
      "session", "continue", sessionId,
      "--workflow-definition-dir", "\(repository)/examples",
      "--mock-scenario", "\(repository)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", root.path,
      "--session-store", root.path,
      "--output", "text"
    ], environment: ["HOME": root.path])

    XCTAssertEqual(continued.exitCode, .failure)
    XCTAssertTrue(continued.stderr.contains("owned by another live execution"), continued.stderr)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    ).load(sessionId: sessionId)
    XCTAssertEqual(snapshot.session.failureKind, .maxStepsExceeded)
    XCTAssertEqual(snapshot.session.executions.count, 1)
  }

  func testConcurrentFreshRunsReceiveDistinctSessionIds() async throws {
    let repository = repositoryRoot()
    for round in 0..<20 {
      let root = URL(fileURLWithPath: repository, isDirectory: true)
        .appendingPathComponent("tmp/concurrent-fresh-runs/\(round)-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let arguments = [
        "workflow", "run", "worker-only-single-step",
        "--workflow-definition-dir", "\(repository)/examples",
        "--mock-scenario", "\(repository)/examples/worker-only-single-step/mock-scenario.json",
        "--working-directory", root.path,
        "--session-store", root.path,
        "--output", "json"
      ]
      let environment = ["HOME": root.path]

      async let first = RielaCLIApplication().run(arguments, environment: environment)
      async let second = RielaCLIApplication().run(arguments, environment: environment)
      async let third = RielaCLIApplication().run(arguments, environment: environment)
      let results = await [first, second, third]

      var sessionIds = Set<String>()
      for result in results {
        XCTAssertEqual(result.exitCode, .success, "round \(round): \(result.stderr + result.stdout)")
        XCTAssertFalse((result.stderr + result.stdout).contains("owned by another live execution"),
                       "round \(round): \(result.stderr + result.stdout)")
        let run = try decodeJSON(WorkflowRunResult.self, from: result.stdout)
        sessionIds.insert(run.session.sessionId)
      }
      XCTAssertEqual(sessionIds.count, results.count, "round \(round): each concurrent run must own a distinct session id")
      let persisted = try CLIWorkflowSessionStore(rootDirectory: root.path).loadAll()
      XCTAssertEqual(Set(persisted.map(\.session.sessionId)), sessionIds, "round \(round)")
    }
  }
}
