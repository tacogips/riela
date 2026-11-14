import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowDefinitionSessionPinTests: XCTestCase {
  func testOldSessionSnapshotDecodesWithoutDefinitionSource() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let encoded = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(WorkflowSession.self, from: encoded)
    XCTAssertNil(decoded.definitionSource)
    XCTAssertEqual(decoded, session)
  }

  func testDefinitionSourceRoundTripsAndSessionCreateInputCarriesIt() async throws {
    let source = WorkflowDefinitionSource(
      kind: .store, workflowName: "workflow", versionId: "defv-123", storeRoot: "/sessions/user",
      digest: String(repeating: "a", count: 64), sourceScope: "user"
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", entryStepId: "entry", createdAt: date, updatedAt: date,
      definitionSource: source
    )
    XCTAssertEqual(try JSONDecoder().decode(WorkflowSession.self, from: JSONEncoder().encode(session)), session)

    let store = InMemoryWorkflowRuntimeStore()
    let created = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: "workflow", entryStepId: "entry", definitionSource: source
    ))
    XCTAssertEqual(created.definitionSource, source)
  }

  func testRunnerRequestPinsDefinitionSourceOnRootSession() async throws {
    let source = WorkflowDefinitionSource(
      kind: .file, workflowName: "workflow", digest: String(repeating: "b", count: 64),
      sourcePath: "/workflows/workflow.json", sourceScope: "project"
    )
    let workflow = WorkflowDefinition(
      workflowId: "workflow",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 2),
      entryStepId: "entry",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "entry", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: AdapterExecutionOutput(
      provider: "test", model: "test", promptText: "prompt", completionPassed: true,
      payload: ["status": .string("ok")]
    )))
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", model: "test", promptTemplate: "prompt")],
      definitionSource: source
    ))
    XCTAssertEqual(result.session.definitionSource, source)
  }

  func testForeignPinFailureLeavesLocalStoreUnwrittenAndRetries() throws {
    let localRoot = try makeRoot("pin-local")
    let definitionRoot = try makeRoot("pin-definition")
    defer { try? FileManager.default.removeItem(at: localRoot); try? FileManager.default.removeItem(at: definitionRoot) }
    let version = try seedDefinition(at: definitionRoot)
    let definitionDB = try database(definitionRoot)
    try definitionDB.execute("""
      CREATE TRIGGER reject_definition_pin BEFORE INSERT ON definition_version_pins
      BEGIN SELECT RAISE(ABORT, 'injected foreign pin failure'); END
      """)
    let snapshot = makeSnapshot(sessionId: "foreign-session", root: definitionRoot.path, versionId: version)
    let local = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: localRoot.path)
    XCTAssertThrowsError(try local.save(snapshot))
    XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: localRoot.path)))

    try definitionDB.execute("DROP TRIGGER reject_definition_pin")
    try local.save(snapshot)
    XCTAssertEqual(try local.load(sessionId: "foreign-session").session, snapshot.session)
    XCTAssertEqual(try definitionDB.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='foreign-session'").first?.string("count"), "1")
  }

  func testHeldForeignWriterLockDoesNotStartLocalSessionTransaction() async throws {
    let localRoot = try makeRoot("held-local")
    let definitionRoot = try makeRoot("held-definition")
    defer { try? FileManager.default.removeItem(at: localRoot); try? FileManager.default.removeItem(at: definitionRoot) }
    let version = try seedDefinition(at: definitionRoot)
    let database = try database(definitionRoot)
    try database.execute("BEGIN IMMEDIATE")
    let local = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: localRoot.path)
    let snapshot = makeSnapshot(sessionId: "held-lock-session", root: definitionRoot.path, versionId: version)
    let saveTask = Task.detached { try local.save(snapshot) }
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: localRoot.path)))
    try database.execute("COMMIT")
    try await saveTask.value
    XCTAssertEqual(try local.load(sessionId: "held-lock-session").session, snapshot.session)
    XCTAssertEqual(try database.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='held-lock-session'").first?.string("count"), "1")
  }

  func testForeignSessionDeletionReleasesPinOnNextDefinitionCommit() throws {
    let localRoot = try makeRoot("release-local")
    let definitionRoot = try makeRoot("release-definition")
    defer { try? FileManager.default.removeItem(at: localRoot); try? FileManager.default.removeItem(at: definitionRoot) }
    let version = try seedDefinition(at: definitionRoot)
    let local = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: localRoot.path)
    try local.save(makeSnapshot(sessionId: "released-session", root: definitionRoot.path, versionId: version))
    let definitionDB = try database(definitionRoot)
    XCTAssertEqual(try definitionDB.query("SELECT COUNT(*) AS count FROM definition_version_pins").first?.string("count"), "1")
    let localDB = try database(localRoot)
    try localDB.execute("DELETE FROM workflow_runtime_snapshots WHERE workflow_execution_id='released-session'")
    let clock = PinTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    clock.advance(by: 25 * 60 * 60)

    let nextData = Data(#"{"version":2}"#.utf8)
    _ = try WorkflowDefinitionStore(rootDirectory: definitionRoot.path, now: { clock.now }).commit(WorkflowDefinitionWrite(
      workflowName: "pin-flow", operation: .update, documentData: nextData,
      documentDigest: JSONCanonical.sha256Hex(nextData), sourceDirectory: "/pin-flow", sourceScope: "project",
      provenance: "test", actor: .init(kind: .user), reason: "release stale pin", expectedCurrentVersionId: version
    ))
    XCTAssertEqual(try definitionDB.query("SELECT COUNT(*) AS count FROM definition_version_pins").first?.string("count"), "0")
  }

  func testForeignTargetSameStoreHookNeverOpensTarget() throws {
    let localRoot = try makeRoot("same-hook-local")
    let missingRoot = localRoot.appendingPathComponent("missing-definition", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: localRoot) }
    _ = try seedDefinition(at: localRoot)
    let snapshot = makeSnapshot(sessionId: "missing-target", root: missingRoot.path, versionId: "defv-unknown")
    let database = try database(localRoot)
    try database.transaction { transaction in
      try WorkflowDefinitionPins.recordPinIfNeeded(transaction, snapshot: snapshot, sessionStoreRoot: localRoot.path)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: missingRoot.path)))
  }

  func testSameStorePinRollsBackWithSnapshotTransactionAndUnknownVersionHandling() throws {
    let root = try makeRoot("same-store")
    defer { try? FileManager.default.removeItem(at: root) }
    let version = try seedDefinition(at: root)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let snapshot = makeSnapshot(sessionId: "rollback-pin", root: root.path, versionId: version)
    let database = try database(root)
    XCTAssertThrowsError(try database.transaction { transaction in
      try persistence.save(snapshot, in: transaction)
      throw PinTestError.rollback
    })
    XCTAssertEqual(try pinCount(database), 0)
    XCTAssertThrowsError(try persistence.save(makeSnapshot(sessionId: "unknown-active", root: root.path, versionId: "defv-missing"))) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .versionNotRetained)
    }
    let cancelled = makeSnapshot(sessionId: "unknown-cancelled", root: root.path,
      versionId: "defv-missing", status: .cancelled)
    try persistence.save(cancelled)
    XCTAssertEqual(try database.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='unknown-cancelled'").first?.string("count"), "0")
  }

  func testTrailingSlashAndSymlinkRootsResolveAsSameStore() throws {
    let root = try makeRoot("normalized-store")
    let link = root.deletingLastPathComponent().appendingPathComponent("definition-link-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: link) }
    let version = try seedDefinition(at: root)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(makeSnapshot(sessionId: "trailing-root", root: root.path + "/", versionId: version))
    try persistence.save(makeSnapshot(sessionId: "symlink-root", root: link.path, versionId: version))
    let db = try database(root)
    XCTAssertEqual(try pinCount(db), 2)
    XCTAssertEqual(try db.query("SELECT COUNT(DISTINCT session_store_root) AS count FROM definition_version_pins").first?.string("count"), "1")
  }

  private func seedDefinition(at root: URL) throws -> String {
    let data = Data(#"{"version":1}"#.utf8)
    let write = WorkflowDefinitionWrite(workflowName: "pin-flow", operation: .`import`, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/pin-flow", sourceScope: "project",
      provenance: "test", actor: .init(kind: .user), reason: "seed")
    guard case let .created(version, _) = try WorkflowDefinitionStore(rootDirectory: root.path).commit(write) else {
      throw PinTestError.seedDidNotCreate
    }
    return version.versionId
  }

  private func makeSnapshot(sessionId: String, root: String, versionId: String, status: WorkflowSessionStatus = .running) -> WorkflowRuntimePersistenceSnapshot {
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let source = WorkflowDefinitionSource(kind: .store, workflowName: "pin-flow", versionId: versionId,
      storeRoot: root, digest: JSONCanonical.sha256Hex(Data(#"{"version":1}"#.utf8)))
    let session = WorkflowSession(workflowId: "pin-flow", sessionId: sessionId, status: status,
      entryStepId: "entry", createdAt: date, updatedAt: date, definitionSource: source)
    return WorkflowRuntimePersistenceSnapshot(session: session)
  }

  private func makeRoot(_ name: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func database(_ root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
  }

  private func pinCount(_ database: SQLiteDatabase) throws -> Int {
    Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM definition_version_pins").first?["count"])) ?? -1
  }

  private enum PinTestError: Error { case rollback, seedDidNotCreate }
}

private final class PinTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance(by interval: TimeInterval) { lock.lock(); value = value.addingTimeInterval(interval); lock.unlock() }
}
