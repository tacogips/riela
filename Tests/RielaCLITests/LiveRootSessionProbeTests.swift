import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LiveRootSessionProbeTests: XCTestCase {
  func testMissingStoreDoesNotCreateAnything() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/probe-missing-\(UUID().uuidString)")
    XCTAssertEqual(try LiveRootSessionProbe.liveRootSessions(workflowId: "flow", sessionStoreRoot: root.path), [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testEmptyDatabaseDoesNotCreateSchemaLock() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/probe-empty-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    try FileManager.default.createDirectory(atPath: runtimeRoot, withIntermediateDirectories: true)
    let database = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtimeRoot)
    XCTAssertTrue(FileManager.default.createFile(atPath: database, contents: Data()))
    let before = try FileManager.default.contentsOfDirectory(atPath: runtimeRoot).sorted()
    XCTAssertEqual(try LiveRootSessionProbe.liveRootSessions(workflowId: "flow", sessionStoreRoot: root.path), [])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runtimeRoot).sorted(), before)
  }

  func testFiltersClassificationOrderingAndSameProcessLiveness() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/probe-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    func save(_ id: String, workflow: String = "flow", status: WorkflowSessionStatus = .running,
              kind: WorkflowInstanceKind = .default, base: String? = nil, parent: String? = nil,
              offset: TimeInterval = 0, lock: Bool = true) throws {
      let session = WorkflowSession(workflowId: workflow, sessionId: id, status: status, entryStepId: "start",
        createdAt: date.addingTimeInterval(offset), updatedAt: date.addingTimeInterval(offset),
        instanceKind: kind.rawValue, instanceBaseIdentity: base, parentSessionId: parent)
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
      if lock { try owner.acquire(sessionId: id) }
    }
    try save("named", kind: .named, base: "art", offset: 2)
    try save("ephemeral", status: .created, kind: .ephemeral, base: "art", offset: 1)
    try save("default-base", kind: .ephemeral, base: WorkflowInstanceIdentity.defaultIdentity)
    try save("default-kind")
    try save("completed", status: .completed)
    try save("child", parent: "parent")
    try save("other", workflow: "other")
    try save("missing-lock", lock: false)
    try save("released")
    owner.release(sessionId: "released")
    let lockRoot = URL(fileURLWithPath: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .appendingPathComponent("execution-locks")
    let before = try FileManager.default.contentsOfDirectory(atPath: lockRoot.path).sorted()
    let result = try LiveRootSessionProbe.liveRootSessions(workflowId: "flow", sessionStoreRoot: root.path)
    XCTAssertEqual(result.map(\.sessionId), ["default-base", "default-kind", "ephemeral", "named"])
    XCTAssertEqual(result.map(\.isManual), [false, false, true, true])
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lockRoot.path).sorted(), before)
    XCTAssertTrue(owner.holds(sessionId: "named"))
    XCTAssertEqual(try LiveRootSessionProbe.liveRootSessions(workflowId: "flow", sessionStoreRoot: root.path), result)
  }
}
