import Foundation
import XCTest
@testable import RielaAppSupport
#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class RielaAppOwnerStartupTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: "/tmp/rac-\(UUID().uuidString.prefix(8))", isDirectory: true)
  }

  func testDirectoryAndLockValidation() throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    var info = stat()
    XCTAssertEqual(lstat(run.directoryURL.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700)
    try run.validate()
    try run.validateSocketFile()
    XCTAssertTrue(FileManager.default.createFile(atPath: run.socketURL.path, contents: Data()))
    XCTAssertThrowsError(try run.validateSocketFile()) { XCTAssertEqual($0 as? RielaAppOwnerLockError, .insecure) }
    let first = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(run))
    XCTAssertNil(try RielaAppOwnerLock.tryAcquire(run))
    first.release()
    first.release()
    XCTAssertNotNil(try RielaAppOwnerLock.tryAcquire(run))
    XCTAssertEqual(chmod(run.directoryURL.path, 0o755), 0)
    XCTAssertThrowsError(try run.validate()) { XCTAssertEqual($0 as? RielaAppOwnerLockError, .insecure) }
    try FileManager.default.removeItem(at: run.directoryURL)
    let target = base.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: run.directoryURL, withDestinationURL: target)
    XCTAssertThrowsError(try run.validate()) { XCTAssertEqual($0 as? RielaAppOwnerLockError, .insecure) }
  }

  func testSocketPathLength() {
    let suffix = "/run/control.sock".utf8.count
    let base = "/tmp/" + String(repeating: "a", count: 103 - suffix - 5)
    XCTAssertTrue(RielaAppRunDirectory(appRoot: URL(fileURLWithPath: base)).socketPathFits)
    XCTAssertFalse(RielaAppRunDirectory(appRoot: URL(fileURLWithPath: base + "a")).socketPathFits)
  }

  @MainActor
  func testStartupWaitsForReloadAndPreservesRelink() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let store = RielaAppDaemonWorkflowStore(stateURL: base.appendingPathComponent("profiles/default/daemon-workflows.json"))
    var state = RielaAppDaemonWorkflowState(preferences: ["one": .init(identity: "one", sourceIdentity: "selected-workflow:A")])
    try store.save(state)
    let held = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(run))
    XCTAssertTrue(FileManager.default.createFile(atPath: run.socketURL.path, contents: Data("owner".utf8)))
    var before = stat()
    XCTAssertEqual(lstat(run.socketURL.path, &before), 0)
    let waiting = expectation(description: "waiting")
    let completed = expectation(description: "phase B")
    let premature = expectation(description: "no bind before release")
    premature.isInverted = true
    let events = StartupEvents()
    let startup = RielaAppOwnerStartup(run: run, waitObserver: { waiting.fulfill() })
    startup.start(bindChannel: { url in
      events.bind(url)
      if events.isBlocked { premature.fulfill() }
    }, phaseB: { lock in
      events.finish(lock: lock, state: store.load())
      completed.fulfill()
    }, failed: { error in XCTFail("unexpected failure: \(error)") })
    await fulfillment(of: [waiting], timeout: 2)
    await fulfillment(of: [premature], timeout: 0.2)
    XCTAssertNil(events.state)
    var during = stat()
    XCTAssertEqual(lstat(run.socketURL.path, &during), 0)
    XCTAssertEqual(before.st_ino, during.st_ino)
    state.preferences["one"]?.sourceIdentity = "selected-workflow:B"
    try store.save(state)
    events.unblock()
    held.release()
    await fulfillment(of: [completed], timeout: 2)
    XCTAssertEqual(events.boundURL, run.socketURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: run.socketURL.path))
    var loaded = try XCTUnwrap(events.state)
    XCTAssertEqual(loaded.preferences["one"]?.sourceIdentity, "selected-workflow:B")
    loaded.preferences["one"]?.active.toggle()
    try store.save(loaded)
    XCTAssertEqual(store.load().preferences["one"]?.sourceIdentity, "selected-workflow:B")
  }

  @MainActor
  func testInsecureDirectoryFailsBeforeLockOrBind() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    XCTAssertEqual(chmod(run.directoryURL.path, 0o755), 0)
    let failed = expectation(description: "insecure")
    let startup = RielaAppOwnerStartup(run: run)
    startup.start(bindChannel: { _ in XCTFail("bound") }, phaseB: { _ in XCTFail("phase B") }, failed: { error in
      XCTAssertEqual(error, .insecure)
      failed.fulfill()
    })
    await fulfillment(of: [failed], timeout: 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: run.lockURL.path))
  }
}

private final class StartupEvents: @unchecked Sendable {
  private let mutex = NSLock()
  private var blocked = true
  private var url: URL?
  private var loaded: RielaAppDaemonWorkflowState?
  private var owner: RielaAppOwnerLock?
  var isBlocked: Bool { mutex.lock(); defer { mutex.unlock() }; return blocked }
  var boundURL: URL? { mutex.lock(); defer { mutex.unlock() }; return url }
  var state: RielaAppDaemonWorkflowState? { mutex.lock(); defer { mutex.unlock() }; return loaded }
  func unblock() { mutex.lock(); defer { mutex.unlock() }; blocked = false }
  func bind(_ value: URL) { mutex.lock(); defer { mutex.unlock() }; url = value }
  func finish(lock: RielaAppOwnerLock, state: RielaAppDaemonWorkflowState) {
    mutex.lock(); defer { mutex.unlock() }; owner = lock; loaded = state
  }
}
