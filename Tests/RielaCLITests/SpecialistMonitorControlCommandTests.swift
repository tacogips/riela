import Darwin
import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SpecialistMonitorControlCommandTests: XCTestCase {
  private struct Fixture {
    let root: URL
    let store: SpecialistSupervisorStore
    let principal: SpecialistPrincipal
  }

  func testPersistedForeignPIDIsNeverSignalledByCancelOrRecovery() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let unrelated = Process()
    unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
    unrelated.arguments = ["30"]
    try unrelated.run()
    defer {
      if unrelated.isRunning { unrelated.terminate() }
      try? WorkflowSubprocessTestSupport.waitForExit(unrelated)
    }
    _ = try fixture.store.recordChildMonitor(
      dispatchId: "dispatch", processId: unrelated.processIdentifier, receiptPath: fixture.root.appendingPathComponent("receipt").path
    )
    let cancelled = await SpecialistCommandRunner().run(SpecialistCommand(kind: .cancel, options: .init(
      scope: "specialist", command: "cancel", target: "task", arguments: ["--state-root", fixture.root.path], output: .json
    )))
    XCTAssertEqual(cancelled.exitCode, .success, cancelled.stderr)
    let recovered = await SpecialistCommandRunner().run(SpecialistCommand(kind: .serve, options: .init(
      scope: "specialist", command: "serve", target: nil, arguments: ["--state-root", fixture.root.path, "--once"], output: .json
    )))
    XCTAssertEqual(recovered.exitCode, .success, recovered.stderr)
    XCTAssertTrue(unrelated.isRunning, "A reused/foreign persisted PID must never authorize a signal")
    XCTAssertEqual(try fixture.store.dispatch(dispatchId: "dispatch")?.state, .recoveryRequired)
    XCTAssertEqual(try fixture.store.task(taskId: "task", principal: fixture.principal)?.state, .cancelRequested)
  }

  func testBoundCancellationBeforeLaunchPersistsCanonicalReceiptWithoutExecuting() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let control = SpecialistMonitorControl(stateRoot: fixture.root.path, dispatchId: "dispatch", childSessionId: "child")
    try control.preparePrivateStore()
    try control.verifyPrivateStore()
    _ = try fixture.store.recordChildMonitor(dispatchId: "dispatch", processId: getpid(), receiptPath: "/receipt", controlToken: control.nonce)
    let running = try XCTUnwrap(try fixture.store.task(taskId: "task", principal: fixture.principal))
    _ = try fixture.store.transition(taskId: "task", to: .cancelRequested, expectedVersion: running.version)
    let result = await control.run(options: .init(target: "dispatch", sessionStore: fixture.root.path, resumeSessionId: "child")) {
      XCTFail("Cancellation before the nonce handshake must not enter workflow execution")
      return CLICommandResult(exitCode: .success)
    }
    XCTAssertEqual(result.exitCode, .failure)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.root.path)
    ).load(sessionId: "child")
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertTrue(snapshot.session.executions.isEmpty)
    XCTAssertEqual(try fixture.store.task(taskId: "task", principal: fixture.principal)?.state, .cancelRequested)
  }

  func testPrivateControlRejectsSymlinksAndNonPrivatePermissions() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let control = SpecialistMonitorControl(stateRoot: fixture.root.path, dispatchId: "dispatch", childSessionId: "child")
    try control.preparePrivateStore()
    let runtime = fixture.root.appendingPathComponent("runtime-records")
    XCTAssertEqual(chmod(runtime.path, 0o755), 0)
    XCTAssertThrowsError(try control.verifyPrivateStore())
    try control.preparePrivateStore()
    let moved = fixture.root.appendingPathComponent("moved-runtime")
    try FileManager.default.moveItem(at: runtime, to: moved)
    try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: moved)
    XCTAssertThrowsError(try control.preparePrivateStore())
  }

  func testStateRootRejectsGroupAndOtherWriteWithoutRepairingItsMode() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let control = SpecialistMonitorControl(stateRoot: fixture.root.path, dispatchId: "dispatch", childSessionId: "child")
    for permissions: mode_t in [0o770, 0o777] {
      XCTAssertEqual(chmod(fixture.root.path, permissions), 0)
      XCTAssertThrowsError(try control.preparePrivateStore())
      var metadata = stat()
      XCTAssertEqual(lstat(fixture.root.path, &metadata), 0)
      XCTAssertEqual(metadata.st_mode & 0o777, permissions, "Unsafe parent permissions must be rejected, not silently repaired")
    }
    XCTAssertEqual(chmod(fixture.root.path, 0o755), 0)
    try control.preparePrivateStore()
  }

  func testForeignOwnedRootAndWritableAncestorAreRejected() throws {
    guard geteuid() != 0 else { throw XCTSkip("The ownership adversary requires a non-root test user") }
    XCTAssertThrowsError(try SpecialistMonitorStorePin(stateRoot: "/usr", repairPermissions: false)) { error in
      XCTAssertTrue(String(describing: error).contains("ownership"))
    }
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let nested = fixture.root.appendingPathComponent("nested-state")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
    let store = SpecialistSupervisorStore(rootDirectory: nested.path)
    _ = try store.createTaskIfWorkRequest(SpecialistRequest(
      requestId: "nested", sourceEventId: "nested", principal: fixture.principal, route: .work, body: "work"
    ), taskId: "nested-task")
    XCTAssertEqual(chmod(fixture.root.path, 0o777), 0)
    let control = SpecialistMonitorControl(stateRoot: nested.path, dispatchId: "dispatch", childSessionId: "child")
    XCTAssertThrowsError(try control.preparePrivateStore())
    XCTAssertEqual(chmod(fixture.root.path, 0o755), 0)
    try control.preparePrivateStore()
  }

  func testPinnedControlRejectsStateRootRenameReplacementBeforeDatabaseAccess() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let control = SpecialistMonitorControl(stateRoot: fixture.root.path, dispatchId: "dispatch", childSessionId: "child")
    try control.preparePrivateStore()
    let pin = try SpecialistMonitorStorePin(stateRoot: fixture.root.path, repairPermissions: false)
    let renamed = fixture.root.appendingPathExtension("renamed")
    defer { try? FileManager.default.removeItem(at: renamed) }
    try FileManager.default.moveItem(at: fixture.root, to: renamed)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
    XCTAssertThrowsError(try pin.withVerifiedIdentity { XCTFail("A replaced root must fail before any SQLite access") })
  }

  func testPinnedControlRejectsRuntimeSymlinkReplacementAndAncestorPermissionChange() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let control = SpecialistMonitorControl(stateRoot: fixture.root.path, dispatchId: "dispatch", childSessionId: "child")
    try control.preparePrivateStore()
    let pin = try SpecialistMonitorStorePin(stateRoot: fixture.root.path, repairPermissions: false)
    XCTAssertEqual(chmod(fixture.root.path, 0o777), 0)
    XCTAssertThrowsError(try pin.requireIdentity())
    XCTAssertEqual(chmod(fixture.root.path, 0o755), 0)
    try pin.requireIdentity()
    let runtime = fixture.root.appendingPathComponent("runtime-records")
    let moved = fixture.root.appendingPathComponent("moved-runtime")
    try FileManager.default.moveItem(at: runtime, to: moved)
    try FileManager.default.createSymbolicLink(at: runtime, withDestinationURL: moved)
    XCTAssertThrowsError(try pin.withVerifiedIdentity { XCTFail("A runtime symlink swap must fail before any SQLite access") })
  }

  private func makeFixture() throws -> Fixture {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/control-command/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = SpecialistSupervisorStore(rootDirectory: root.path)
    let principal = SpecialistPrincipal(accountId: "local", actorId: "operator", roomId: "local")
    let request = SpecialistRequest(requestId: "request", sourceEventId: "event", principal: principal, route: .work, body: "work")
    let task = try XCTUnwrap(try store.createTaskIfWorkRequest(request, taskId: "task"))
    let claimed = try store.claim(taskId: task.taskId, ownerId: "owner", capacity: 1, expectedVersion: task.version)
    _ = try store.reserveDispatch(taskId: task.taskId, dispatchId: "dispatch", childSessionId: "child", expectedVersion: claimed.version,
                                  workflowId: "workflow", entryStepId: "entry")
    _ = try store.beginDispatch(dispatchId: "dispatch")
    return Fixture(root: root, store: store, principal: principal)
  }
}
