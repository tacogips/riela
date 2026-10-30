import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class EventLiveServeMaintenanceTests: XCTestCase {
  func testScheduledAndHostHookConvertLegacySessions() throws {
    for useHook in [false, true] {
      let root = try makeRielaCLITestTemporaryDirectory("scheduled-maintenance")
      let home = root.appendingPathComponent("home")
      let project = root.appendingPathComponent("project")
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
      var environment = ["HOME": home.path]
      for key in ["PATH", "TMPDIR"] {
        if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
      }
      let isolation = RielaCLIIsolatedEnvironment(root: root, home: home, project: project, environment: environment)
      defer { isolation.remove() }
      let store = isolation.project.appendingPathComponent(".riela/sessions")
      let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))
      let session = WorkflowSession(workflowId: "flow", sessionId: "legacy", status: .completed,
        entryStepId: "start", createdAt: Date(), updatedAt: Date())
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
      let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path))
      try db.execute("CREATE TABLE maintenance_freelist(value BLOB)")
      try db.execute("INSERT INTO maintenance_freelist VALUES(zeroblob(4194304))")
      try db.execute("DELETE FROM maintenance_freelist")
      let freeBefore = try XCTUnwrap(Int(db.query("PRAGMA freelist_count").first?["freelist_count"] ?? ""))
      XCTAssertGreaterThan(freeBefore, 128)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
      try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
        bindings: [.text(json), .text(session.sessionId)])
      XCTAssertEqual(try runtime.legacyInlineSessionIds(limit: 10), [session.sessionId])
      let request = AutomaticRetentionHook.request(arguments: [], environment: isolation.environment,
        currentDirectory: isolation.project.path)
      let warnings = isolation.run {
        useHook ? AutomaticRetentionHook.runAutomaticPass(request) : RielaAutomaticStoragePass.runScheduled(request)
      }
      XCTAssertTrue(warnings.isEmpty, "\(warnings)")
      let targets = RetentionTargetResolver.resolve(scope: request.scope, homeDirectory: request.homeDirectory,
        projectDirectory: request.projectDirectory, explicitSessionStore: nil, environment: request.environment)
      XCTAssertTrue(try runtime.legacyInlineSessionIds(limit: 10).isEmpty, "targets: \(targets)")
      let freeAfter = try XCTUnwrap(Int(db.query("PRAGMA freelist_count").first?["freelist_count"] ?? ""))
      XCTAssertLessThan(freeAfter, freeBefore)
    }
  }

  func testSchedulerConvertsLegacySessionAndStops() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("scheduled-maintenance-loop")
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    var environment = ["HOME": home.path]
    for key in ["PATH", "TMPDIR"] {
      if let value = ProcessInfo.processInfo.environment[key] { environment[key] = value }
    }
    let isolation = RielaCLIIsolatedEnvironment(root: root, home: home, project: project, environment: environment)
    defer { isolation.remove() }
    let store = project.appendingPathComponent(".riela/sessions")
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path))
    let session = WorkflowSession(workflowId: "flow", sessionId: "scheduled", status: .completed,
      entryStepId: "start", createdAt: Date(), updatedAt: Date())
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try XCTUnwrap(String(data: encoder.encode(session), encoding: .utf8))
    try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(session.sessionId)])
    XCTAssertEqual(try runtime.legacyInlineSessionIds(limit: 10), [session.sessionId])
    let request = AutomaticRetentionHook.request(arguments: [], environment: isolation.environment,
      currentDirectory: project.path)
    let passed = expectation(description: "scheduled maintenance pass")
    let sleeping = expectation(description: "second scheduler sleep")
    let cancelled = expectation(description: "scheduler sleep cancelled")
    let sleepCount = SchedulerSleepCount()
    let scheduler = RielaRetentionScheduler(interval: 0.01, runImmediately: false, sleep: { _ in
      if sleepCount.next() == 1 {
        try await Task.sleep(for: .milliseconds(10))
      } else {
        sleeping.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          cancelled.fulfill()
          throw error
        }
      }
    }, pass: {
      _ = isolation.run { RielaAutomaticStoragePass.runScheduled(request) }
      passed.fulfill()
    })
    scheduler.start()
    await fulfillment(of: [passed, sleeping], timeout: 5)
    scheduler.stop()
    await fulfillment(of: [cancelled], timeout: 5)
    XCTAssertTrue(try runtime.legacyInlineSessionIds(limit: 10).isEmpty)
  }

}

private final class SchedulerSleepCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  func next() -> Int {
    lock.lock()
    defer { lock.unlock() }
    value += 1
    return value
  }
}
