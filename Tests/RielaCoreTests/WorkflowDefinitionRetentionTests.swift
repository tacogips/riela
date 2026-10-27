import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowDefinitionRetentionTests: XCTestCase {
  func testPruneDoesNotPersistRetentionAndNextWriteKeepsDefaultWindow() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var previous: String?
    for version in 1...12 {
      previous = try commit(store, version: version, previous: previous,
        operation: version == 1 ? .import : .update).versionId
      clock.advance()
    }
    let db = try database(root)
    let unchanged = try store.prune(workflowName: "retention-flow", keepVersions: 20, reason: "no-op", actor: .init(kind: .user))
    XCTAssertTrue(unchanged.removedVersionIds.isEmpty)
    XCTAssertNil(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'")
      .first?["retained_generations"])
    let prune = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "temporary prune",
      actor: .init(kind: .user))
    XCTAssertGreaterThan(prune.removedVersionIds.count, 0)
    XCTAssertNil(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'")
      .first?["retained_generations"])
    previous = try commit(store, version: 13, previous: previous).versionId
    for version in 14...20 {
      previous = try commit(store, version: version, previous: previous).versionId
      clock.advance()
    }
    XCTAssertEqual(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'")
      .first?["retained_generations"], nil)
    XCTAssertGreaterThanOrEqual(try count("definition_history_versions", db: db), 10)
  }

  func testNoOpPruneLeavesDefaultRetentionForNextWrite() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var previous: String?
    for version in 1...12 {
      previous = try commit(store, version: version, previous: previous,
        operation: version == 1 ? .import : .update).versionId
    }
    let result = try store.prune(workflowName: "retention-flow", keepVersions: 2,
      reason: "no versions outside the grace window", actor: .init(kind: .user))
    XCTAssertTrue(result.removedVersionIds.isEmpty)
    let db = try database(root)
    XCTAssertNil(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'")
      .first?["retained_generations"])
    _ = try commit(store, version: 13, previous: previous)
    XCTAssertEqual(try count("definition_history_versions", db: db), 13)
    XCTAssertNil(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'")
      .first?["retained_generations"])
  }

  func testPruneRejectsInvalidInputAndGuardedDeletesRemainBlocked() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let first = try commit(store, version: 1, previous: nil, operation: .import)
    let db = try database(root)
    XCTAssertThrowsError(try store.prune(workflowName: "retention-flow", keepVersions: 0, reason: "x", actor: .init(kind: .user))) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .invalidRetention)
    }
    XCTAssertThrowsError(try store.prune(workflowName: "retention-flow", keepVersions: 1, reason: " ", actor: .init(kind: .user))) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .missingReason)
    }
    XCTAssertThrowsError(try store.purgeHistory(workflowName: "missing", reason: "x", actor: .init(kind: .user))) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .headMissing)
    }
    let versionCount = try count("definition_versions", db: db)
    let auditCount = try count("definition_change_audit", db: db)
    XCTAssertThrowsError(try db.execute("DELETE FROM definition_versions WHERE version_id = ?", bindings: [.text(first.versionId)]))
    XCTAssertThrowsError(try db.execute("DELETE FROM definition_history_versions WHERE key = 'retention-flow'"))
    XCTAssertEqual(try count("definition_versions", db: db), versionCount)
    XCTAssertEqual(try count("definition_change_audit", db: db), auditCount)
  }

  func testPurgeKeepsOnlyProtectedVersionsAndOneAuditWithoutMovingHead() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var ids: [String] = []
    for version in 1...4 {
      ids.append(try commit(store, version: version, previous: ids.last,
        operation: version == 1 ? .import : .update).versionId)
      clock.advance()
    }
    _ = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "earlier prune", actor: .init(kind: .user))
    let revision = try XCTUnwrap(store.head(workflowName: "retention-flow")?.revision)
    let purged = try store.purgeHistory(workflowName: "retention-flow", reason: "start over", actor: .init(kind: .user))
    XCTAssertEqual(Set(purged.keptVersionIds), Set([ids[0], ids[3]]))
    XCTAssertEqual(try store.history(workflowName: "retention-flow").map(\.operation), [.purgeHistory])
    XCTAssertEqual(try store.history(workflowName: "retention-flow").first?.reason, "start over")
    XCTAssertEqual(try store.head(workflowName: "retention-flow")?.revision, revision)
    XCTAssertThrowsError(try database(root).execute("DELETE FROM definition_change_audit"))
  }

  func testOverwrittenChangeLookupIgnoresRetentionRecords() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var ids: [String] = []
    for version in 1...3 {
      ids.append(try commit(store, version: version, previous: ids.last,
        operation: version == 1 ? .import : .update).versionId)
      clock.advance()
    }
    ids.append(try commit(store, version: 4, previous: ids.last, operation: .forceUpdate).versionId)
    _ = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "trim", actor: .init(kind: .user))
    clock.advance()
    ids.append(try commit(store, version: 5, previous: ids.last).versionId)
    clock.advance()
    ids.append(try commit(store, version: 6, previous: ids.last).versionId)
    XCTAssertEqual(try store.auditRecords(workflowName: "retention-flow", afterVersionId: ids[3]).map(\.versionId),
      [ids[4], ids[5]])
  }

  func testEarlierPruneAuditSurvivesLaterAutomaticRetention() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var previous: String?
    for version in 1...12 {
      previous = try commit(store, version: version, previous: previous,
        operation: version == 1 ? .import : .update).versionId
      clock.advance()
    }
    let prune = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "keep audit", actor: .init(kind: .user))
    XCTAssertNotNil(prune.audit)
    for version in 13...24 {
      previous = try commit(store, version: version, previous: previous).versionId
      clock.advance()
    }
    XCTAssertTrue(try store.history(workflowName: "retention-flow").contains { $0.operation == .prune })
  }

  func testConfiguredDefaultChangesAndPendingBackfillPreservesExplicitRetention() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    var previous: String?
    var expired: String?
    let initial = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    for version in 1...12 {
      previous = try commit(initial, version: version, previous: previous, operation: version == 1 ? .`import` : .update).versionId
      if version == 2 { expired = previous }
      clock.advance()
    }
    let changedDefault = WorkflowDefinitionStore(rootDirectory: root.path, defaultHistoryRetention: 3, now: { clock.now })
    let newest = try commit(changedDefault, version: 13, previous: previous, defaultRetention: 3)
    let db = try database(root)
    let retained = try db.query("SELECT version FROM definition_history_versions WHERE key='retention-flow' ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }
    XCTAssertEqual(retained, [1, 11, 12, 13])
    XCTAssertNil(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'").first?["retained_generations"])
    XCTAssertThrowsError(try changedDefault.document(versionId: try XCTUnwrap(expired))) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.retainedGenerations, 3)
    }

    var explicitPrevious = newest.versionId
    for version in 14...17 {
      explicitPrevious = try commit(changedDefault, version: version, previous: explicitPrevious, retention: 50, defaultRetention: 3).versionId
      clock.advance()
    }
    let versionsBeforePendingBackfill = try db.query("SELECT COUNT(*) AS count FROM definition_history_versions WHERE key='retention-flow'")
      .first?.string("count")
    try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES('retention', 'pendingBackfill')")
    _ = try commit(changedDefault, version: 18, previous: explicitPrevious, defaultRetention: 3)
    let versionsAfterPendingCommit = try db.query("SELECT COUNT(*) AS count FROM definition_history_versions WHERE key='retention-flow'")
      .first?.string("count")
    XCTAssertEqual(versionsAfterPendingCommit, "9")
    _ = try changedDefault.backfillPinsAndApplyRetention(foreignSessionStoreRoots: [], defaultHistoryRetention: 10)
    XCTAssertEqual(try db.query("SELECT retained_generations FROM definition_history_heads WHERE key='retention-flow'").first?["retained_generations"], "50")
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_history_versions WHERE key='retention-flow'").first?.string("count"), versionsAfterPendingCommit)
    XCTAssertEqual(versionsBeforePendingBackfill, "8")
  }

  func testPendingBackfillCommitPinsEveryExistingVersionBeforeWriting() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, defaultHistoryRetention: 10, now: { clock.now })
    var previous: String?
    for version in 1...6 {
      previous = try commit(store, version: version, previous: previous,
        operation: version == 1 ? .`import` : .update, defaultRetention: 10).versionId
      clock.advance()
    }
    let db = try database(root)
    XCTAssertEqual(try db.query("SELECT version FROM definition_history_versions WHERE key='retention-flow' ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }, Array(1...6))
    try db.execute("INSERT OR REPLACE INTO definition_store_state(key, value) VALUES('retention', 'pendingBackfill')")
    let reducedDefault = WorkflowDefinitionStore(rootDirectory: root.path, defaultHistoryRetention: 3, now: { clock.now })
    _ = try commit(reducedDefault, version: 7, previous: previous, defaultRetention: 3)
    let retained = try db.query("SELECT version FROM definition_history_versions WHERE key='retention-flow' ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }
    XCTAssertEqual(retained, Array(1...7))
  }

  func testWriteAfterUndoDropsRedoBranchAfterFormerHeadWindow() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    let first = try commit(store, version: 1, previous: nil, operation: .`import`)
    let second = try commit(store, version: 2, previous: first.versionId)
    let third = try commit(store, version: 3, previous: second.versionId)
    _ = try store.moveHead(workflowName: "retention-flow", direction: .undo, reason: "branch", expectedRevision: 3,
      expectedVersionId: third.versionId, evidence: [], actorKind: "user", actorId: nil)
    _ = try commit(store, version: 4, previous: second.versionId)
    XCTAssertThrowsError(try store.moveHead(workflowName: "retention-flow", direction: .redo, reason: "redo discarded branch",
      expectedRevision: 5, expectedVersionId: try XCTUnwrap(store.head(workflowName: "retention-flow")?.currentVersionId),
      evidence: [], actorKind: "user", actorId: nil))
    XCTAssertNotNil(try store.document(versionId: third.versionId))
    clock.advance()
    _ = try commit(store, version: 5, previous: try XCTUnwrap(store.head(workflowName: "retention-flow")?.currentVersionId))
    XCTAssertThrowsError(try store.document(versionId: third.versionId))
  }

  func testMissingForeignSessionPinGetsTwentyFourHourGrace() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    let first = try commit(store, version: 1, previous: nil, operation: .`import`)
    let db = try database(root)
    try db.execute("INSERT INTO definition_version_pins(workflow_name,history_version,session_store_root,session_id,created_at) VALUES('retention-flow',1,?,?,?)",
      bindings: [.text(root.appendingPathComponent("missing-session-store").path), .text("missing-session"), .text("2027-01-15T08:00:00.000Z")])
    _ = try commit(store, version: 2, previous: first.versionId)
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='missing-session'").first?.string("count"), "1")
    clock.advance()
    _ = try commit(store, version: 3, previous: try XCTUnwrap(store.head(workflowName: "retention-flow")?.currentVersionId))
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='missing-session'").first?.string("count"), "0")
  }

  func testWindowKeepsLastFileLivePinAndRecentHeadsAndCleansOrphanAudit() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var ids: [Int: String] = [:]
    for number in 1...3 {
      ids[number] = try commit(store, version: number, previous: ids[number - 1], operation: number == 1 ? .`import` : .update).versionId
      if number == 3 { try savePin(sessionId: "live-pin", versionId: ids[3]!, root: root) }
      clock.advance()
    }
    for number in 4...25 {
      ids[number] = try commit(store, version: number, previous: ids[number - 1]!).versionId
      clock.advance()
    }

    let database = try database(root)
    let retained = try database.query("SELECT version FROM definition_history_versions WHERE key='retention-flow' ORDER BY version")
      .compactMap { $0["version"].flatMap(Int.init) }
    XCTAssertEqual(Set(retained), Set([1, 3] + Array(16...25)))
    XCTAssertEqual(try count("definition_history_versions", db: database), retained.count)
    XCTAssertEqual(try store.head(workflowName: "retention-flow")?.currentVersionId, ids[25])
    XCTAssertEqual(try store.head(workflowName: "retention-flow")?.lastFileVersionId, ids[1])
    XCTAssertNotNil(try store.document(versionId: ids[3]!))
    XCTAssertEqual(try count("definition_retention_guard", db: database), 0)
    XCTAssertThrowsError(try store.document(versionId: ids[2]!)) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .versionNotRetained)
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.retainedGenerations, 10)
    }
    XCTAssertThrowsError(try store.document(versionId: ids[8]!)) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .versionNotRetained)
    }
    XCTAssertTrue(try database.query("SELECT 1 FROM definition_change_audit WHERE version_id=?", bindings: [.text(ids[5]!)]).isEmpty)
    XCTAssertFalse(try database.query("SELECT 1 FROM definition_change_audit WHERE version_id=?", bindings: [.text(ids[4]!)]).isEmpty)
  }

  func testRealClockKeepsAllHeadsWrittenWithinTwentyFourHours() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    var previous: String?
    for number in 1...25 {
      previous = try commit(store, version: number, previous: previous, operation: number == 1 ? .`import` : .update).versionId
    }
    XCTAssertEqual(try count("definition_versions", db: database(root)), 25)
  }

  func testUndoRedoAndOldestBoundaryPreserveFileVersionAndAudit() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let first = try commit(store, version: 1, previous: nil, operation: .`import`)
    let second = try commit(store, version: 2, previous: first.versionId)
    let third = try commit(store, version: 3, previous: second.versionId)
    let fileId = try XCTUnwrap(store.head(workflowName: "retention-flow")?.lastFileVersionId)

    guard case let .created(undone, undoAudit) = try store.moveHead(workflowName: "retention-flow", direction: .undo,
      reason: "undo edit", expectedRevision: 3, expectedVersionId: third.versionId, evidence: [], actorKind: "user", actorId: nil) else {
      return XCTFail("undo should move the head")
    }
    XCTAssertEqual(undone.versionId, second.versionId)
    XCTAssertEqual(undoAudit.operation, .undo)
    XCTAssertEqual(try store.head(workflowName: "retention-flow")?.lastFileVersionId, fileId)
    guard case let .created(redone, redoAudit) = try store.moveHead(workflowName: "retention-flow", direction: .redo,
      reason: "redo edit", expectedRevision: 4, expectedVersionId: second.versionId, evidence: [], actorKind: "user", actorId: nil) else {
      return XCTFail("redo should move the head")
    }
    XCTAssertEqual(redone.versionId, third.versionId)
    XCTAssertEqual(redoAudit.operation, .redo)
    _ = try store.moveHead(workflowName: "retention-flow", direction: .undo, reason: "undo again",
      expectedRevision: 5, expectedVersionId: third.versionId, evidence: [], actorKind: "user", actorId: nil)
    _ = try store.moveHead(workflowName: "retention-flow", direction: .undo, reason: "undo to oldest",
      expectedRevision: 6, expectedVersionId: second.versionId, evidence: [], actorKind: "user", actorId: nil)
    XCTAssertThrowsError(try store.moveHead(workflowName: "retention-flow", direction: .undo, reason: "at oldest",
      expectedRevision: 7, expectedVersionId: first.versionId, evidence: [], actorKind: "user", actorId: nil)) { error in
      XCTAssertEqual((error as? WorkflowDefinitionStoreError)?.code, .nothingToUndo)
    }
    XCTAssertTrue(try store.history(workflowName: "retention-flow").contains { $0.operation == .undo })
  }

  func testPendingBackfillDoesNotDeleteUntilExplicitBackfill() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "migration-flow",
      sessionId: "migration-session", status: .completed, entryStepId: "entry", createdAt: date, updatedAt: date)))
    let database = try database(root)
    for table in ["definition_change_audit", "definition_heads", "definition_versions", "definition_blobs", "definition_version_identities",
                  "definition_version_pins", "definition_retention_guard", "definition_store_state",
                  "definition_history_versions", "definition_history_heads"] {
      try database.execute("DROP TABLE IF EXISTS \(table)")
    }
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: database)
    try insertGeneration10Fixture(database, versions: 15)
    let sessionBytes = Data(#"{"workflowId":"migration-flow","sessionId":"migration-session","status":"completed","definitionSource":{"kind":"store","workflowName":"migration-flow","versionId":"defv-2"}}"#.utf8)
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id='migration-session'",
      bindings: [.blob(sessionBytes)])
    try database.execute("PRAGMA user_version = 10")
    try database.transaction { transaction in
      try WorkflowDefinitionHistorySchema.migrateToGeneration11(in: transaction, pinBackfillByteLimit: 0)
    }
    try database.execute("PRAGMA user_version = 11")
    XCTAssertEqual(try WorkflowDefinitionStore(rootDirectory: root.path).retentionState(), "pendingBackfill")
    XCTAssertEqual(try count("definition_versions", db: database), 15)
    let report = try WorkflowDefinitionStore(rootDirectory: root.path)
      .backfillPinsAndApplyRetention(foreignSessionStoreRoots: [], defaultHistoryRetention: 10)
    XCTAssertEqual(report.state, "active")
    XCTAssertEqual(report.pinsInserted, 1)
    XCTAssertEqual(report.versionsDropped, 3)
    XCTAssertEqual(try count("definition_versions", db: database), 12)
    XCTAssertTrue(try database.query("SELECT 1 FROM definition_version_pins WHERE history_version=2").count == 1)
  }

  func testPendingBackfillKeepsSameStoreCLIPinUntilExplicitBackfill() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try database(root)
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: db)
    try insertGeneration10Fixture(db, versions: 15)
    try db.execute("CREATE TABLE cli_workflow_sessions(session_id TEXT PRIMARY KEY, record_json BLOB NOT NULL, created_at TEXT NOT NULL)")
    let record = Data(#"{"session":{"definitionSource":{"kind":"store","workflowName":"migration-flow","versionId":"defv-2"}}}"#.utf8)
    try db.execute("INSERT INTO cli_workflow_sessions VALUES('pending-cli-session',jsonb(?),'2026-01-01T00:00:00.000Z')",
      bindings: [.blob(record)])
    try db.execute("PRAGMA user_version = 10")
    try db.transaction { transaction in
      try WorkflowDefinitionHistorySchema.migrateToGeneration11(in: transaction, pinBackfillByteLimit: 0)
    }
    try db.execute("PRAGMA user_version = 11")
    XCTAssertEqual(try WorkflowDefinitionStore(rootDirectory: root.path).retentionState(), "pendingBackfill")
    XCTAssertTrue(try db.query("SELECT 1 FROM definition_version_pins WHERE session_id='pending-cli-session'").isEmpty)

    let report = try WorkflowDefinitionStore(rootDirectory: root.path)
      .backfillPinsAndApplyRetention(foreignSessionStoreRoots: [], defaultHistoryRetention: 10)
    XCTAssertEqual(report.pinsInserted, 1)
    XCTAssertEqual(try db.query("SELECT history_version FROM definition_version_pins WHERE session_id='pending-cli-session'").first?[
      "history_version"], "2")
    XCTAssertNotNil(try WorkflowDefinitionStore(rootDirectory: root.path).document(versionId: "defv-2"))
  }

  func testForeignPinQueryFailureKeepsPinAndAllowsCommit() throws {
    let root = try makeRoot()
    let foreignRoot = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: foreignRoot) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, defaultHistoryRetention: 3, now: { clock.now })
    let first = try commit(store, version: 1, previous: nil, operation: .`import`, defaultRetention: 3)
    let db = try database(root)
    try db.execute("INSERT INTO definition_version_pins(workflow_name,history_version,session_store_root,session_id,created_at) VALUES(?,?,?,?,?)",
      bindings: [.text("retention-flow"), .int(1), .text(WorkflowDefinitionPins.normalizedStoreRoot(rootDirectory: foreignRoot.path)),
        .text("unreadable-session"), .text("2026-01-01T00:00:00.000Z")])
    let foreignPath = WorkflowDefinitionPins.normalizedDatabasePath(rootDirectory: foreignRoot.path)
    let foreign = try SQLiteDatabase.open(path: foreignPath)
    try foreign.execute("CREATE TABLE workflow_runtime_snapshots(session_id TEXT PRIMARY KEY)")
    clock.advance()

    let second = try commit(store, version: 2, previous: first.versionId, defaultRetention: 3)
    XCTAssertEqual(second.workflowName, "retention-flow")
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE session_id='unreadable-session'")
      .first?.string("count"), "1")
    XCTAssertNotNil(try store.document(versionId: first.versionId))
  }

  func testGenerationTenMigrationPreservesIdsAndAppliesWindowWhenSnapshotsAreSmall() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "migration-flow",
      sessionId: "migration-session", status: .completed, entryStepId: "entry", createdAt: date, updatedAt: date)))
    let db = try database(root)
    try dropCurrentDefinitionTables(db)
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: db)
    try insertGeneration10Fixture(db, versions: 15)
    let sessionBytes = Data(#"{"workflowId":"migration-flow","sessionId":"migration-session","status":"completed","definitionSource":{"kind":"store","workflowName":"migration-flow","versionId":"defv-2"}}"#.utf8)
    try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id='migration-session'",
      bindings: [.blob(sessionBytes)])
    try db.execute("PRAGMA user_version = 10")

    _ = try WorkflowDefinitionStore(rootDirectory: root.path).head(workflowName: "migration-flow")
    XCTAssertEqual(try db.query("PRAGMA user_version").first?["user_version"], "11")
    XCTAssertFalse(try db.tableExists("definition_blobs"))
    let ids = try db.query("SELECT version_id FROM definition_versions ORDER BY history_version").map { $0.string("version_id") }
    XCTAssertEqual(Set(ids), Set(["defv-1", "defv-2"] + (6...15).map { "defv-\($0)" }))
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_version_pins WHERE history_version=2").first?.string("count"), "1")
    XCTAssertEqual(try db.query("SELECT COUNT(*) AS count FROM definition_history_versions").first?.string("count"), "12")
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    XCTAssertEqual(try store.document(versionId: "defv-2"), Data("{\"version\":2}".utf8))
    XCTAssertEqual(try db.query("SELECT revision FROM definition_history_heads WHERE key='migration-flow'").first?["revision"], "15")
    let nextData = Data(#"{"version":16}"#.utf8)
    guard case let .created(next, _) = try store.commit(WorkflowDefinitionWrite(workflowName: "migration-flow", operation: .update,
      documentData: nextData, documentDigest: JSONCanonical.sha256Hex(nextData), sourceDirectory: "/workflow", sourceScope: "project",
      provenance: "test", actor: .init(kind: .user), reason: "migration continuation", expectedCurrentVersionId: "defv-15")) else {
      return XCTFail("migration continuation should create a version")
    }
    XCTAssertEqual(try db.query("SELECT history_version FROM definition_versions WHERE version_id=?", bindings: [.text(next.versionId)]).first?["history_version"], "16")
  }

  func testMigrationBackfillsCLIPinWithoutSnapshot() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "migration-flow",
      sessionId: "migration-session", status: .completed, entryStepId: "entry", createdAt: date, updatedAt: date)))
    let db = try database(root)
    try db.execute("DELETE FROM workflow_runtime_snapshots")
    try dropCurrentDefinitionTables(db)
    try SQLiteWorkflowRuntimePersistenceStore.createGeneration10DefinitionSchema(in: db)
    try insertGeneration10Fixture(db, versions: 10)
    try db.execute("CREATE TABLE cli_workflow_sessions(session_id TEXT PRIMARY KEY, record_json BLOB NOT NULL, created_at TEXT NOT NULL)")
    let record = Data(#"{"session":{"definitionSource":{"kind":"store","workflowName":"migration-flow","versionId":"defv-2"}}}"#.utf8)
    try db.execute("INSERT INTO cli_workflow_sessions VALUES('cli-session',jsonb(?),'2026-01-01T00:00:00.000Z')", bindings: [.blob(record)])
    try db.execute("PRAGMA user_version = 10")
    _ = try WorkflowDefinitionStore(rootDirectory: root.path).head(workflowName: "migration-flow")
    XCTAssertEqual(try db.query("SELECT history_version FROM definition_version_pins WHERE session_id='cli-session'").first?["history_version"], "2")
    XCTAssertNotNil(try WorkflowDefinitionStore(rootDirectory: root.path).document(versionId: "defv-2"))
  }

  func testExplicitPruneAndPurgeUseSharedEngineAndProtectedVersionRules() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let store = WorkflowDefinitionStore(rootDirectory: root.path, now: { clock.now })
    var ids: [String] = []
    for number in 1...5 {
      let version = try commit(store, version: number, previous: ids.last,
        operation: number == 1 ? .import : .update)
      ids.append(version.versionId)
      clock.advance()
    }
    try savePin(sessionId: "active-version-two", versionId: ids[2], root: root)

    let preview = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "", actor: .init(kind: .user), dryRun: true)
    XCTAssertEqual(Set(preview.removedVersionIds), Set([ids[1]]))
    XCTAssertNil(preview.audit)
    let pruned = try store.prune(workflowName: "retention-flow", keepVersions: 2, reason: "trim old edits", actor: .init(kind: .user))
    XCTAssertEqual(Set(pruned.removedVersionIds), Set([ids[1]]))
    XCTAssertGreaterThan(pruned.removedBlobCount, 0)
    XCTAssertGreaterThan(pruned.removedBlobBytes, 0)
    XCTAssertEqual(Set(pruned.keptVersionIds), Set([ids[0], ids[2], ids[3], ids[4]]))
    XCTAssertEqual(Set(pruned.protectedVersions.map(\.reason)), Set(["current", "lastFileImport", "activeSession"]))
    XCTAssertEqual(pruned.audit?.operation, .prune)
    XCTAssertEqual(try count("definition_history_versions", db: database(root)), 4)
    XCTAssertNotNil(try store.document(versionId: ids[2]))

    _ = try store.moveHead(workflowName: "retention-flow", direction: .undo, reason: "open redo branch",
      expectedRevision: 5, expectedVersionId: ids[4], evidence: [], actorKind: "user", actorId: nil)
    clock.advance()
    let purged = try store.purgeHistory(workflowName: "retention-flow", reason: "reset audit", actor: .init(kind: .user))
    XCTAssertEqual(Set(purged.keptVersionIds), Set([ids[0], ids[2], ids[3]]))
    XCTAssertEqual(purged.audit?.operation, .purgeHistory)
    XCTAssertEqual(try store.history(workflowName: "retention-flow").map(\.operation), [.purgeHistory])
    XCTAssertEqual(try store.head(workflowName: "retention-flow")?.currentVersionId, ids[3])
    XCTAssertThrowsError(try store.document(versionId: ids[4]))
    XCTAssertEqual(try count("definition_history_versions", db: database(root)), 3)
    XCTAssertThrowsError(try database(root).execute("DELETE FROM definition_versions WHERE workflow_name='retention-flow'"))
    XCTAssertThrowsError(try database(root).execute("DELETE FROM definition_history_versions WHERE key='retention-flow'"))
  }

  func testPurgeAuditPreservesFormerHeadProtectionForNextWrite() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path, defaultHistoryRetention: 2)
    var ids: [String] = []
    for version in 1...4 {
      ids.append(try commit(store, version: version, previous: ids.last,
        operation: version == 1 ? .import : .update, defaultRetention: 2).versionId)
    }
    let result = try store.purgeHistory(workflowName: "retention-flow", reason: "preserve grace", actor: .init(kind: .user))
    XCTAssertEqual(Set(result.keptVersionIds), Set(ids))
    let next = try commit(store, version: 5, previous: ids.last, defaultRetention: 2)
    XCTAssertEqual(try store.document(versionId: ids[1]), Data("{\"version\":2}".utf8))
    XCTAssertNotNil(try store.document(versionId: next.versionId))
  }

  private func commit(_ store: WorkflowDefinitionStore, version: Int, previous: String?, operation: WorkflowDefinitionOperation = .update,
                      retention: Int? = nil, defaultRetention: Int = WorkflowDefinitionStore.defaultHistoryRetention) throws -> WorkflowDefinitionVersion {
    let data = Data("{\"version\":\(version)}".utf8)
    guard case let .created(created, _) = try store.commit(WorkflowDefinitionWrite(
      workflowName: "retention-flow", operation: operation, documentData: data,
      documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: "/workflows/retention-flow",
      sourceScope: "project", provenance: "test", actor: .init(kind: .user), reason: "version \(version)",
      expectedCurrentVersionId: previous, historyRetention: retention, defaultHistoryRetention: defaultRetention
    )) else { throw TestError.commitWasUnchanged }
    return created
  }

  private func savePin(sessionId: String, versionId: String, root: URL) throws {
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    let session = WorkflowSession(workflowId: "retention-flow", sessionId: sessionId, status: .running,
      entryStepId: "entry", createdAt: time, updatedAt: time,
      definitionSource: WorkflowDefinitionSource(kind: .store, workflowName: "retention-flow", versionId: versionId,
        storeRoot: root.path, digest: String(repeating: "a", count: 64)))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func insertGeneration10Fixture(_ db: SQLiteDatabase, versions: Int) throws {
    for number in 1...versions {
      let document = Data("{\"version\":\(number)}".utf8)
      let digest = "digest-\(number)"
      try db.execute("INSERT INTO definition_blobs(digest,bytes,size,created_at) VALUES(?,?,?, '2026-01-01T00:00:00.000Z')",
        bindings: [.text(digest), .blob(document), .int(Int64(document.count))])
      let versionId = "defv-\(number)"
      let prior = number > 1 ? "defv-\(number - 1)" : nil
      let fields: [SQLiteValue] = [.text(versionId), .text("migration-flow"), .optionalText(prior), .text(digest),
        .text("import"), .text("/workflow"), .text("project"), .text("test"), .text("user"), .null,
        .text("2026-01-01T00:\(String(format: "%02d", number)):00.000Z")]
      try db.execute("""
        INSERT INTO definition_versions(version_id,workflow_name,parent_version_id,document_digest,operation,
          source_directory,source_scope,provenance,actor_kind,actor_id,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)
        """, bindings: fields)
      try db.execute("""
        INSERT INTO definition_change_audit(audit_id,workflow_name,operation,version_id,previous_version_id,
          after_digest,diff_json,reason,evidence_refs_json,actor_kind,approval_state,created_at)
        VALUES(?,?,'import',?,?, 'digest-\(number)','[]','fixture','[]','user','applied',?)
        """, bindings: [.text("audit-\(number)"), .text("migration-flow"), .text(versionId), .optionalText(prior),
          .text("2026-01-01T00:\(String(format: "%02d", number)):00.000Z")])
    }
    try db.execute("""
      INSERT INTO definition_heads(workflow_name,current_version_id,last_file_version_id,revision,source_directory,source_scope,created_at,updated_at)
      VALUES('migration-flow',?,?,?, '/workflow','project','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z')
      """, bindings: [.text("defv-\(versions)"), .text("defv-1"), .int(Int64(versions))])
  }

  private func dropCurrentDefinitionTables(_ db: SQLiteDatabase) throws {
    for table in ["definition_change_audit", "definition_heads", "definition_versions", "definition_blobs",
                  "definition_version_pins", "definition_retention_guard", "definition_store_state",
                  "definition_history_versions", "definition_history_heads"] {
      try db.execute("DROP TABLE IF EXISTS \(table)")
    }
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("definition-retention-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func database(_ root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
  }

  private func count(_ table: String, db: SQLiteDatabase) throws -> Int {
    try Int(db.query("SELECT COUNT(*) AS count FROM \(table)").first?.string("count") ?? "0") ?? 0
  }

  private enum TestError: Error { case commitWasUnchanged }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var now: Date { lock.lock(); defer { lock.unlock() }; return value }
  func advance() { lock.lock(); value = value.addingTimeInterval(25 * 60 * 60); lock.unlock() }
}
