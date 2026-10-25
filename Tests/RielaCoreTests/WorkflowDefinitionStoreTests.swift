import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowDefinitionStoreTests: XCTestCase {
  func testFreshStoreCreatesDefinitionSchemaAtGenerationTen() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    XCTAssertNil(try store.head(workflowName: "example"))
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path),
      mode: .strictReadOnly,
      options: .readOnlyDefault
    )
    for table in ["definition_blobs", "definition_versions", "definition_heads", "definition_change_audit"] {
      XCTAssertTrue(try database.tableExists(table), "missing \(table)")
    }
    XCTAssertEqual(try database.query("PRAGMA user_version").first?["user_version"], "10")
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
    for table in ["definition_change_audit", "definition_heads", "definition_versions", "definition_blobs"] {
      try database.execute("DROP TABLE IF EXISTS \(table)")
    }
    try database.execute("PRAGMA user_version = 9")

    XCTAssertNil(try WorkflowDefinitionStore(rootDirectory: root.path).head(workflowName: "keep"))
    XCTAssertEqual(try persistence.load(sessionId: session.sessionId).session, session)
    let reopened = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    XCTAssertEqual(try reopened.query("PRAGMA user_version").first?["user_version"], "10")
  }

  func testSeedRaceAndRepeatedSeedDoNotCreateExtraRows() async throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = WorkflowDefinitionStore(rootDirectory: root.path)
    let second = WorkflowDefinitionStore(rootDirectory: root.path)
    let write = makeWrite(operation: .seed, reason: "register")
    async let left = first.commit(write)
    async let right = second.commit(write)
    let outcomes = try await [left, right]
    XCTAssertEqual(outcomes.filter { if case .created = $0 { return true }; return false }.count, 1)
    XCTAssertEqual(outcomes.filter { if case .alreadyRegistered = $0 { return true }; return false }.count, 1)
    let database = try rawDatabase(root)
    XCTAssertEqual(try count("definition_heads", database: database), 1)
    XCTAssertEqual(try count("definition_versions", database: database), 1)
    XCTAssertEqual(try count("definition_change_audit", database: database), 1)
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
    XCTAssertThrowsError(try database.execute("UPDATE definition_blobs SET size = 0"))
  }

  func testIdenticalDocumentsShareBlobAndHistoryFiltersNewestFirst() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(first, firstAudit) = try store.commit(makeWrite(
      operation: .seed, reason: "seed", targetNode: "one"
    )) else { return XCTFail("expected seed") }
    guard case .created = try store.commit(makeWrite(
      operation: .updatePrompt, reason: "prompt", expected: first.versionId, targetNode: "two"
    )) else { return XCTFail("expected update") }
    let database = try rawDatabase(root)
    XCTAssertEqual(try count("definition_blobs", database: database), 1)
    XCTAssertEqual(try count("definition_versions", database: database), 2)
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
      operation: .update, reason: "change", expected: seed.versionId
    )) else { return XCTFail("expected update") }
    XCTAssertEqual(try store.head(workflowName: "workflow")?.lastFileVersionId, seed.versionId)
    guard case .created = try store.commit(makeWrite(
      operation: .forceUpdate, reason: "force", expected: update.versionId
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
    targetNode: String? = nil
  ) -> WorkflowDefinitionWrite {
    let document = makeDocument()
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
      try count("definition_blobs", database: database), try count("definition_versions", database: database),
      try count("definition_heads", database: database), try count("definition_change_audit", database: database)
    ]
  }
}
