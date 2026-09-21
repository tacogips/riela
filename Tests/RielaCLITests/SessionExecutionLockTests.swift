import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SessionExecutionLockTests: XCTestCase {
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

  func testRegistryRejectsUnsafeSessionIdentity() {
    let registry = SessionExecutionLockRegistry(sessionStoreRoot: FileManager.default.temporaryDirectory.path)

    XCTAssertThrowsError(try registry.acquire(sessionId: "../session")) { error in
      XCTAssertEqual(error as? SessionExecutionLockError, .invalidSessionId("../session"))
    }
  }

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
}
