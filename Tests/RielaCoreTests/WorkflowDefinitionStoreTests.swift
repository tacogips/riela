import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

private actor SeedRaceStartBarrier {
  private var arrivals = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    arrivals += 1
    guard arrivals < 2 else {
      waiters.forEach { $0.resume() }
      waiters.removeAll()
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }
}

final class WorkflowDefinitionStoreTests: XCTestCase {
  func testFreshStoreCreatesDefinitionSchemaAtGenerationEleven() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    XCTAssertNil(try store.head(workflowName: "example"))
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .strictReadOnly,
      options: .readOnlyDefault
    )
    for table in ["definition_versions", "definition_heads", "definition_change_audit", "definition_history_heads", "definition_history_versions", "definition_version_pins", "definition_version_identities"] {
      XCTAssertTrue(try database.tableExists(table), "missing \(table)")
    }
    XCTAssertFalse(try database.tableExists("definition_blobs"))
    XCTAssertEqual(try database.query("PRAGMA user_version").first?["user_version"], "11")
  }

  func testGenerationNineMigratesInPlaceAndKeepsSession() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "keep", sessionId: "keep-session", status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
    try persistence.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path)
    for table in ["definition_change_audit", "definition_heads", "definition_versions", "definition_blobs",
                  "definition_history_heads", "definition_history_versions", "definition_version_pins",
                  "definition_retention_guard", "definition_store_state"] {
      try database.execute("DROP TABLE IF EXISTS \(table)")
    }
    try database.execute("PRAGMA user_version = 9")

    XCTAssertNil(try WorkflowDefinitionStore(rootDirectory: root.path).head(workflowName: "keep"))
    XCTAssertEqual(try persistence.load(sessionId: session.sessionId).session, session)
    let reopened = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertEqual(try reopened.query("PRAGMA user_version").first?["user_version"], "11")
    XCTAssertTrue(try reopened.tableExists("definition_history_versions"))
  }

  func testSeedRaceAndRepeatedSeedDoNotCreateExtraRows() async throws {
    for _ in 0..<200 {
      let root = try makeRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let first = WorkflowDefinitionStore(rootDirectory: root.path)
      let second = WorkflowDefinitionStore(rootDirectory: root.path)
      let write = makeWrite(operation: .seed, reason: "register")
      let barrier = SeedRaceStartBarrier()
      async let left: WorkflowDefinitionCommitOutcome = {
        await barrier.wait()
        return try first.commit(write)
      }()
      async let right: WorkflowDefinitionCommitOutcome = {
        await barrier.wait()
        return try second.commit(write)
      }()
      let outcomes = try await [left, right]
      XCTAssertEqual(outcomes.filter { if case .created = $0 { return true }; return false }.count, 1)
      XCTAssertEqual(outcomes.filter { if case .alreadyRegistered = $0 { return true }; return false }.count, 1)
      let database = try rawDatabase(root)
      XCTAssertEqual(try count("definition_heads", database: database), 1)
      XCTAssertEqual(try count("definition_versions", database: database), 1)
      XCTAssertEqual(try count("definition_change_audit", database: database), 1)
    }
  }

  func testStaleHeadAndMissingReasonRejectWithoutWritingRows() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let created = try store.commit(makeWrite(operation: .seed, reason: "seed"))
    guard case let .created(version, _) = created else { return XCTFail("expected seed") }
    let before = try rawCounts(root)
    XCTAssertThrowsError(try store.commit(makeWrite(
      operation: .update, reason: "edit", expected: "old-version"
    ))) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .staleHead)
    }
    XCTAssertThrowsError(try store.commit(makeWrite(operation: .update, reason: " \n", expected: version.versionId))) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .missingReason)
    }
    XCTAssertEqual(try rawCounts(root), before)
  }

  func testCommitIsAtomicAndAppendOnlyRowsRejectMutation() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    XCTAssertNil(try store.head(workflowName: "workflow"))
    let database = try rawDatabase(root)
    try database.execute("""
    CREATE TRIGGER reject_definition_audit BEFORE INSERT ON definition_change_audit
    BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END
    """)
    XCTAssertThrowsError(try store.commit(makeWrite(operation: .seed, reason: "seed")))
    XCTAssertEqual(try rawCounts(root), [0, 0, 0, 0])
    try database.execute("DROP TRIGGER reject_definition_audit")
    guard case let .created(version, audit) = try store.commit(makeWrite(
      operation: .seed, reason: "seed", targetNode: "node"
    )) else { return XCTFail("expected seed") }
    XCTAssertEqual(try store.history(workflowName: "workflow").first, audit)
    XCTAssertThrowsError(try database.execute("UPDATE definition_change_audit SET reason = 'changed'"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_versions WHERE version_id = '\(version.versionId)'"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_change_audit WHERE audit_id = '\(audit.auditId)'"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_history_versions WHERE key='workflow' AND version=1"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_heads WHERE workflow_name='workflow'"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_history_heads WHERE key='workflow'"))
    XCTAssertThrowsError(try database.execute("INSERT OR REPLACE INTO definition_versions SELECT * FROM definition_versions WHERE version_id='\(version.versionId)'"))
    XCTAssertThrowsError(try database.execute("INSERT OR REPLACE INTO definition_change_audit SELECT * FROM definition_change_audit WHERE audit_id='\(audit.auditId)'"))
    XCTAssertThrowsError(try database.execute("INSERT OR REPLACE INTO definition_history_versions SELECT * FROM definition_history_versions WHERE key='workflow' AND version=1"))
    XCTAssertThrowsError(try database.execute("INSERT OR REPLACE INTO definition_version_identities SELECT * FROM definition_version_identities WHERE version_id='\(version.versionId)'"))
    try database.execute("INSERT INTO definition_retention_guard(id) VALUES(1)")
    XCTAssertThrowsError(try database.execute("INSERT INTO definition_retention_guard(id) VALUES(1)"))
    try database.execute("DELETE FROM definition_retention_guard WHERE id=1")
  }

  func testIdenticalDocumentsShareBlobAndHistoryFiltersNewestFirst() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(first, firstAudit) = try store.commit(makeWrite(
      operation: .seed, reason: "seed", targetNode: "one"
    )) else { return XCTFail("expected seed") }
    guard case .created = try store.commit(makeWrite(
      operation: .updatePrompt, reason: "prompt", expected: first.versionId, targetNode: "two",
      documentData: makeDocument()
    )) else { return XCTFail("expected update") }
    let database = try rawDatabase(root)
    XCTAssertFalse(try database.tableExists("definition_blobs"))
    XCTAssertEqual(try count("definition_versions", database: database), 2)
    XCTAssertEqual(try count("definition_history_versions", database: database), 2)
    let history = try store.history(workflowName: "workflow")
    XCTAssertEqual(history.map(\.reason), ["prompt", "seed"])
    XCTAssertEqual(try store.history(workflowName: "workflow", nodeId: "one").map(\.auditId), [firstAudit.auditId])
    XCTAssertEqual(try store.history(workflowName: "workflow", limit: 1).count, 1)
    XCTAssertEqual(try store.current(workflowName: "workflow")?.document, makeDocument())
  }

  func testFileVersionPinMovesOnlyForFileOperations() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(seed, _) = try store.commit(makeWrite(operation: .seed, reason: "seed")) else {
      return XCTFail("expected seed")
    }
    guard case let .created(update, _) = try store.commit(makeWrite(
      operation: .update, reason: "change", expected: seed.versionId,
      documentData: Data(#"{"runtime":{"workflow":"change"}}"#.utf8)
    )) else { return XCTFail("expected update") }
    XCTAssertEqual(try store.head(workflowName: "workflow")?.lastFileVersionId, seed.versionId)
    guard case .created = try store.commit(makeWrite(
      operation: .forceUpdate, reason: "force", expected: update.versionId,
      documentData: Data(#"{"runtime":{"workflow":"change"}}"#.utf8)
    )) else { return XCTFail("expected force update") }
    XCTAssertEqual(try store.head(workflowName: "workflow")?.lastFileVersionId, try store.head(workflowName: "workflow")?.currentVersionId)
  }

  func testStoreWithDefinitionHeadIsNeverDiscarded() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path)
    try WorkflowDefinitionStoreSchema.create(in: database)
    try database.execute("""
    INSERT INTO definition_heads(
      workflow_name, current_version_id, last_file_version_id, revision,
      source_directory, source_scope, created_at, updated_at
    ) VALUES ('kept', 'v', 'v', 1, '/', 'project', '2026-10-25T00:00:00.000Z', '2026-10-25T00:00:00.000Z')
    """)
    try database.execute("PRAGMA user_version = 8")
    XCTAssertFalse(SQLiteWorkflowRuntimePersistenceStore.discardIncompatibleStoreIfNeeded(databasePath: path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    XCTAssertThrowsError(try WorkflowDefinitionStore(rootDirectory: root.path).head(workflowName: "kept"))
  }

  func testDiffUsesEscapedPointersAndStableArrayTailEntries() {
    let before: JSONValue = .object(["a/b": .object(["child": .integer(1)]), "items": .array([.string("x"), .string("y")])])
    let after: JSONValue = .object(["a/b": .object(["child": .integer(2)]), "items": .array([.string("x"), .string("z"), .string("tail")])])
    XCTAssertEqual(WorkflowDefinitionDiff.compute(before: before, after: after), [
      WorkflowDefinitionDiffEntry(path: "/a~1b/child", op: .replace, before: .integer(1), after: .integer(2)),
      WorkflowDefinitionDiffEntry(path: "/items/1", op: .replace, before: .string("y"), after: .string("z")),
      WorkflowDefinitionDiffEntry(path: "/items/2", op: .add, after: .string("tail"))
    ])
    XCTAssertEqual(WorkflowDefinitionDiff.compute(before: before, after: before), [])
  }

  func testActorAndEvidenceParsingAreConstrained() throws {
    XCTAssertNil(WorkflowDefinitionActorKind(rawValue: "addon"))
    XCTAssertEqual(WorkflowDefinitionActorKind(rawValue: "improvementNode"), .improvementNode)
    XCTAssertEqual(try WorkflowDefinitionEvidenceRef.parse("session:abc"), WorkflowDefinitionEvidenceRef(kind: .session, id: "abc"))
    XCTAssertThrowsError(try WorkflowDefinitionEvidenceRef.parse("bogus:1"))
    XCTAssertThrowsError(try WorkflowDefinitionEvidenceRef.parse("session:"))
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("workflow-definition-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeDocument() -> Data { Data(#"{"runtime":{"workflow":"example"}}"#.utf8) }

  private func makeWrite(
    operation: WorkflowDefinitionOperation,
    reason: String,
    expected: String? = nil,
    targetNode: String? = nil,
    documentData: Data? = nil
  ) -> WorkflowDefinitionWrite {
    let document = documentData ?? makeDocument()
    return WorkflowDefinitionWrite(
      workflowName: "workflow", operation: operation, documentData: document,
      documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/workflow", sourceScope: "project",
      provenance: "test", actor: WorkflowDefinitionActor(kind: .user, id: "tester"), reason: reason,
      targetNodeId: targetNode, targetField: targetNode == nil ? nil : "promptTemplate", expectedCurrentVersionId: expected
    )
  }

  private func rawDatabase(_ root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
  }

  private func count(_ table: String, database: SQLiteDatabase) throws -> Int {
    try Int(database.query("SELECT COUNT(*) AS count FROM \(table)").first?.string("count") ?? "0") ?? 0
  }

  private func rawCounts(_ root: URL) throws -> [Int] {
    let database = try rawDatabase(root)
    return [
      try count("definition_history_versions", database: database), try count("definition_versions", database: database),
      try count("definition_heads", database: database), try count("definition_change_audit", database: database)
    ]
  }
}
