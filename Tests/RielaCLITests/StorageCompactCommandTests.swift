import Foundation
import XCTest
import Darwin
@testable import RielaCore
import RielaSQLite
@testable import RielaCLI
@testable import RielaMemory

final class StorageCompactCommandTests: XCTestCase {
  func testDryRunReportsLegacyMemoryWorkAndLeavesFileUnchanged() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("memory.sqlite").path
    let database = try SQLiteDatabase.open(path: path)
    try database.execute("CREATE TABLE memory_evolution(record_id INTEGER, version INTEGER, reverse_delta_json TEXT)")
    try database.execute("CREATE TABLE memory_history_heads(key TEXT PRIMARY KEY)")
    try database.execute("INSERT INTO memory_evolution VALUES (1, 1, NULL), (1, 2, '{\"payload\":\"legacy\"}')")
    let before = try Data(contentsOf: URL(fileURLWithPath: path))
    let result = await RielaCLIApplication().run(["storage", "compact", "--memory-root", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(report["dryRun"] as? Bool, true)
    let stores = try XCTUnwrap(report["stores"] as? [[String: Any]])
    XCTAssertEqual(stores.first?["kind"] as? String, "memory")
    let converted = try XCTUnwrap(stores.first?["converted"] as? [String: Any])
    XCTAssertEqual(converted["memoryRecords"] as? Int, 1)
    XCTAssertGreaterThan(stores.first?["convertedBytes"] as? Int ?? 0, 0)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), before)
  }

  func testCompactSpecificOptionsAreRejectedByDoctorAndTopByCompact() async {
    let app = RielaCLIApplication()
    let doctor = await app.run(["doctor", "storage", "--apply"])
    XCTAssertEqual(doctor.exitCode, .usage)
    let compact = await app.run(["storage", "compact", "--top", "3"])
    XCTAssertEqual(compact.exitCode, .usage)
  }

  func testLowDiskConversionWarningReportsRequiredAndAvailableBytesAndAlternative() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path)
    try database.execute("CREATE TABLE example(value BLOB)")
    try database.execute("INSERT INTO example VALUES (zeroblob(8192))")
    let reclaimer = RetentionSQLiteReclaimer(freeSpace: { _ in 123 })
    let runner = StorageCompactCommandRunner(reclaimer: reclaimer)
    let result = runner.run(["compact", "--apply", "--session-store", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let warnings = try XCTUnwrap(report["warnings"] as? [String])
    let warning = try XCTUnwrap(warnings.first)
    let reclamations = try XCTUnwrap((report["stores"] as? [[String: Any]])?.first?["reclamation"] as? [[String: Any]])
    let fileBytes = try XCTUnwrap(reclamations.first?["fileBytesBefore"] as? Int64)
    let required = fileBytes * 2 + (256 << 20)
    XCTAssertTrue(warning.contains("requires"))
    XCTAssertTrue(warning.contains("\(required) free bytes"))
    XCTAssertTrue(warning.contains("123 available"))
    XCTAssertTrue(warning.contains("VACUUM INTO"))
    XCTAssertTrue(warning.contains("stop writers"))
    XCTAssertTrue(warning.contains("cross-volume rename"))
    let textResult = runner.run(["compact", "--apply", "--session-store", root.path])
    XCTAssertTrue(textResult.stdout.contains("work remaining: true"))
    XCTAssertTrue(textResult.stdout.contains("warnings:"))
    XCTAssertTrue(textResult.stdout.contains("VACUUM INTO"))
  }

  func testHeldSessionLockIsSkippedAndLeavesWorkRemaining() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    let session = WorkflowSession(workflowId: "workflow", sessionId: "locked-session", entryStepId: "start",
      createdAt: now, updatedAt: now)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtime.rootDirectory)
    let database = try SQLiteDatabase.open(path: databasePath)
    let legacySessionJSON = "'{\"workflowId\":\"workflow\",\"status\":\"created\",\"updatedAt\":\"2026-01-01T00:00:00Z\",\"executions\":[]}'"
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(\(legacySessionJSON)) WHERE workflow_execution_id='locked-session'")
    let owner = SessionExecutionLockRegistry(sessionStoreRoot: root.path)
    try owner.acquire(sessionId: "locked-session")
    defer { owner.release(sessionId: "locked-session") }

    let result = StorageCompactCommandRunner().run(["compact", "--apply",
      "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .failure, result.stderr)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(report["workRemaining"] as? Bool, true)
    let store = try XCTUnwrap((report["stores"] as? [[String: Any]])?.first)
    XCTAssertEqual((store["converted"] as? [String: Int])?["sessions"], 0)
    XCTAssertEqual(try database.query("SELECT json_type(session_json,'$.executions') AS kind FROM workflow_runtime_snapshots WHERE workflow_execution_id='locked-session'").first?["kind"], "array")
  }

  func testMessageRetiredLegacyRowDoesNotAbortOtherConversionsOrReruns() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    for id in ["retired", "convert-me"] {
      let session = WorkflowSession(workflowId: "workflow", sessionId: id, entryStepId: "start",
        createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
      let db = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtime.rootDirectory))
      let sessionEncoder = JSONEncoder()
      sessionEncoder.dateEncodingStrategy = .iso8601
      var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: sessionEncoder.encode(session)) as? [String: Any])
      legacy["executions"] = []
      let legacyData = try JSONSerialization.data(withJSONObject: legacy)
      let legacyJSON = try XCTUnwrap(String(data: legacyData, encoding: .utf8))
      try db.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
        bindings: [.text(legacyJSON), .text(id)])
    }
    let db = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try db.execute("CREATE TABLE session_message_retention_tombstones(session_id TEXT PRIMARY KEY,workflow_id TEXT NOT NULL,pruned_at TEXT NOT NULL,message_bytes INTEGER NOT NULL)")
    try db.execute("INSERT INTO session_message_retention_tombstones(session_id,workflow_id,pruned_at,message_bytes) VALUES('retired','workflow','2020-01-01T00:00:00Z',0)")
    let arguments = ["compact", "--apply", "--session-store", root.path, "--output", "json"]
    let first = StorageCompactCommandRunner().run(arguments)
    XCTAssertEqual(first.exitCode, .success, first.stderr + first.stdout)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any])
    let store = try XCTUnwrap((report["stores"] as? [[String: Any]])?.first)
    XCTAssertEqual((store["converted"] as? [String: Int])?["sessions"], 2)
    let second = StorageCompactCommandRunner().run(arguments)
    XCTAssertEqual(second.exitCode, .success, second.stderr)
    let rerun = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(second.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(rerun["workRemaining"] as? Bool, false)
  }

  func testDefinitionPinBackfillSelectsOnlyFieldsAndDoesNotHoldLongWriterLock() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = Data(#"{"version":1}"#.utf8)
    let digest = JSONCanonical.sha256Hex(document)
    let definitions = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case let .created(version, _) = try definitions.commit(WorkflowDefinitionWrite(workflowName: "workflow",
      operation: .`import`, documentData: document, documentDigest: digest, sourceDirectory: root.path,
      sourceScope: "project", provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "seed")) else {
      XCTFail("definition seed did not create a version")
      return
    }
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    let large = String(repeating: "x", count: 2_000_000)
    for index in 0..<20 {
      let session = WorkflowSession(workflowId: "workflow", sessionId: "legacy-\(index)", entryStepId: "start",
        createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000),
        definitionSource: WorkflowDefinitionSource(kind: .store, workflowName: "workflow", versionId: version.versionId,
          storeRoot: root.path, digest: digest, sourceScope: "project"))
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session, rootOutput: ["large": .string(large)]))
    }
    let recorder = DefinitionBackfillStatementRecorder()
    var observed = definitions
    let writer = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
    try writer.execute("CREATE TABLE writer_probe(value INTEGER)")
    let peakRSSBefore = peakResidentMemoryBytes()
    observed.pinBackfillStatementObserver = { recorder.record($0, writer: writer) }
    _ = try observed.backfillPinsAndApplyRetention(foreignSessionStoreRoots: [root.path], defaultHistoryRetention: 10, batchSize: 1)

    XCTAssertTrue(recorder.statements.contains { $0.contains("json_extract(session_json") })
    XCTAssertFalse(recorder.statements.contains { $0.contains("json(session_json)") || $0.contains("json(record_json)") })
    XCTAssertLessThan(recorder.maximumWriterDuration, 1)
    XCTAssertGreaterThan(recorder.successfulWrites, 0)
    XCTAssertLessThan(peakResidentMemoryBytes() - peakRSSBefore, 128 * 1_024 * 1_024)
    XCTAssertEqual(try writer.query("SELECT count(*) AS count FROM definition_version_pins").first?["count"], "20")
  }

  private func peakResidentMemoryBytes() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    return Int64(usage.ru_maxrss)
  }

  func testMaxBatchAboveEffectiveLimitIsUsageError() {
    let result = StorageCompactCommandRunner().run(["compact", "--max-batch", "10001", "--session-store", "/tmp/no-store"])
    XCTAssertEqual(result.exitCode, .usage)
  }

  func testExactlyMaxBatchDoesNotReportRemainingWork() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtime.rootDirectory))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for index in 0..<16 {
      let session = WorkflowSession(workflowId: "workflow", sessionId: "legacy-\(index)", entryStepId: "start",
        createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
      try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
      var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
      legacy["executions"] = []
      let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: legacy), encoding: .utf8))
      try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
        bindings: [.text(json), .text(session.sessionId)])
    }

    let report = try run(StorageCompactCommandRunner(), ["compact", "--apply", "--max-batch", "16",
      "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(report["workRemaining"] as? Bool, false)
    let stores = try XCTUnwrap(report["stores"] as? [[String: Any]])
    XCTAssertEqual((stores.first?["converted"] as? [String: Int])?["sessions"], 16)
  }

  func testFailingLegacySessionDoesNotConsumeBatchSlot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let bad = WorkflowSession(workflowId: "workflow", sessionId: "a-bad", entryStepId: "start",
      createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
    let good = WorkflowSession(workflowId: "workflow", sessionId: "b-good", entryStepId: "start",
      createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: bad))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: good))
    let database = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtime.rootDirectory))
    let badEncoder = JSONEncoder()
    badEncoder.dateEncodingStrategy = .iso8601
    var invalidSession = try XCTUnwrap(JSONSerialization.jsonObject(with: badEncoder.encode(bad)) as? [String: Any])
    invalidSession.removeValue(forKey: "entryStepId")
    invalidSession["executions"] = []
    let invalidJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: invalidSession), encoding: .utf8))
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id='a-bad'",
      bindings: [.text(invalidJSON)])
    var legacyGood = try XCTUnwrap(JSONSerialization.jsonObject(with: badEncoder.encode(good)) as? [String: Any])
    legacyGood["executions"] = []
    let legacyGoodJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: legacyGood), encoding: .utf8))
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id='b-good'",
      bindings: [.text(legacyGoodJSON)])

    let result = StorageCompactCommandRunner().run(["compact", "--apply", "--max-batch", "1",
      "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .failure)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(report["workRemaining"] as? Bool, true)
    XCTAssertTrue((report["skipped"] as? [String] ?? []).contains { $0.contains("a-bad") })
    let stores = try XCTUnwrap(report["stores"] as? [[String: Any]])
    XCTAssertEqual((stores.first?["converted"] as? [String: Int])?["sessions"], 1)
    XCTAssertEqual(try runtime.load(sessionId: good.sessionId).session.sessionId, good.sessionId)
  }

  func testCheckpointPendingAddsWarningAndFailsApply() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let setup = try SQLiteDatabase.open(path: databasePath)
    _ = try setup.query("PRAGMA journal_mode=WAL")
    _ = try setup.query("PRAGMA auto_vacuum=INCREMENTAL")
    try setup.execute("VACUUM")
    try setup.execute("CREATE TABLE checkpoint_fixture(value TEXT)")
    let reader = try SQLiteDatabase.open(path: databasePath)
    let writer = try SQLiteDatabase.open(path: databasePath)
    let reclaimer = RetentionSQLiteReclaimer(statementObserver: { sql in
      guard sql == "PRAGMA wal_checkpoint(PASSIVE)" else { return }
      try? reader.execute("BEGIN")
      _ = try? reader.query("SELECT * FROM checkpoint_fixture")
      try? writer.execute("INSERT INTO checkpoint_fixture VALUES ('pending frame')")
    })
    defer { try? reader.execute("ROLLBACK") }

    let result = StorageCompactCommandRunner(reclaimer: reclaimer)
      .run(["compact", "--apply", "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .failure)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertTrue((report["warnings"] as? [String] ?? []).contains { $0.contains("WAL checkpoint is pending") })
  }

  func testLegacyCLIListingCapsAtParserMaximum() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try database.execute("CREATE TABLE cli_workflow_sessions(session_id TEXT PRIMARY KEY,record_json TEXT NOT NULL,updated_at TEXT NOT NULL)")
    try database.execute("""
      WITH RECURSIVE ids(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM ids WHERE n<10001)
      INSERT INTO cli_workflow_sessions(session_id,record_json,updated_at)
      SELECT 'legacy-'||n, '{}', '2020-01-01T00:00:00Z' FROM ids
      """)

    let ids = try CLIWorkflowSessionStore(rootDirectory: root.path).legacyFullRecordIds(limit: 20_000)

    XCTAssertEqual(ids.count, 10_000)
  }

  func testNoneAutoVacuumShrinksAfterLegacySessionConversion() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    let session = WorkflowSession(workflowId: "workflow", sessionId: "large-legacy", entryStepId: "start",
      createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtimeRoot)
    let database = try SQLiteDatabase.open(path: databasePath)
    try database.execute("PRAGMA auto_vacuum=NONE")
    try database.execute("VACUUM")
    try database.execute("CREATE TABLE bloat(value BLOB)")
    try database.execute("INSERT INTO bloat VALUES(zeroblob(4194304))")
    try database.execute("DELETE FROM bloat")
    let largeData = String(repeating: "payload", count: 500_000)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
    legacy["executions"] = []
    legacy["largePayload"] = largeData
    let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: legacy), encoding: .utf8))
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(json), .text(session.sessionId)])
    let before = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? NSNumber).int64Value

    let result = StorageCompactCommandRunner().run(["compact", "--apply", "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let reclamation = try XCTUnwrap((report["stores"] as? [[String: Any]])?.first?["reclamation"] as? [[String: Any]])
    XCTAssertEqual(reclamation.first?["action"] as? String, "converted")
    XCTAssertGreaterThan(reclamation.first?["reclaimedBytes"] as? Int64 ?? 0, 0)
    XCTAssertLessThan(reclamation.first?["fileBytesAfter"] as? Int64 ?? before,
      reclamation.first?["fileBytesBefore"] as? Int64 ?? 0)
  }

  func testApplyConvertsLegacyMemoryInResumableBatches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = RielaMemoryStore(rootDirectory: root.path)
    let first = try memory.save(memoryId: "legacy", workflowId: "flow", payload: .string("first-v1"))
    let firstHead = try memory.update(memoryId: "legacy", recordId: first.recordId, payload: .string("first-v2"))
    let second = try memory.save(memoryId: "legacy", workflowId: "flow", payload: .string("second-v1"))
    let secondHead = try memory.update(memoryId: "legacy", recordId: second.recordId, payload: .string("second-v2"))
    let path = try memory.databasePath(memoryId: "legacy")
    let database = try SQLiteDatabase.open(path: path)
    try database.execute("DELETE FROM memory_history_versions")
    try database.execute("DELETE FROM memory_history_heads")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for (record, head) in [(first, firstHead), (second, secondHead)] {
      let delta = try EvolutionReverseDelta(previous: encoder.encode(record), next: encoder.encode(head), nextVersion: 2)
      let deltaJSON = try XCTUnwrap(String(bytes: try encoder.encode(delta), encoding: .utf8))
      try database.execute("INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES (?,1,'2020-01-01T00:00:00Z',NULL),(?,2,'2020-01-02T00:00:00Z',?)",
        bindings: [.int(record.recordId), .int(record.recordId), .text(deltaJSON)])
    }
    let runner = StorageCompactCommandRunner()
    let arguments = ["compact", "--apply", "--max-batch", "1", "--memory-root", root.path, "--output", "json"]

    let firstRun = try run(runner, arguments)
    XCTAssertEqual(firstRun["workRemaining"] as? Bool, true)
    let secondRun = try run(runner, arguments)
    XCTAssertEqual(secondRun["workRemaining"] as? Bool, false)
    XCTAssertEqual(try SQLiteDatabase.open(path: path, mode: .strictReadOnly).query(
      "SELECT key FROM memory_history_heads").count, 2)
    XCTAssertEqual(try memory.evolutionHistory(memoryId: "legacy", recordId: first.recordId).count, 2)
    XCTAssertEqual(try memory.recordVersion(memoryId: "legacy", recordId: first.recordId, version: 2), firstHead)
  }

  func testApplyConvertsLegacyRuntimeAndCLISessionRows() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/storage-compact-sessions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionRoot = root.appendingPathComponent("sessions", isDirectory: true).path
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    let definitionDocument = Data(#"{"version":1}"#.utf8)
    let definitionDigest = JSONCanonical.sha256Hex(definitionDocument)
    let write = WorkflowDefinitionWrite(workflowName: "runtime-workflow", operation: .`import`,
      documentData: definitionDocument, documentDigest: definitionDigest, sourceDirectory: "/runtime-workflow",
      sourceScope: "project", provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "seed")
    guard case let .created(definitionVersion, _) = try WorkflowDefinitionStore(rootDirectory: sessionRoot).commit(write) else {
      XCTFail("definition seed did not create a version")
      return
    }
    let definitionSource = WorkflowDefinitionSource(kind: .store, workflowName: "runtime-workflow",
      versionId: definitionVersion.versionId, storeRoot: sessionRoot, digest: definitionDigest, sourceScope: "project")
    let runtimeSession = WorkflowSession(workflowId: "runtime-workflow", sessionId: "legacy-runtime",
      status: .completed, entryStepId: "start", createdAt: now, updatedAt: now,
      definitionSource: definitionSource)
    let runtimeSnapshot = WorkflowRuntimePersistenceSnapshot(session: runtimeSession)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot)
    try runtime.save(runtimeSnapshot)
    let cliSession = WorkflowSession(workflowId: "cli-workflow", sessionId: "legacy-cli",
      status: .completed, entryStepId: "start", createdAt: now, updatedAt: now)
    let cliRecord = PersistedCLIWorkflowSession(workflowName: "cli-workflow", session: cliSession,
      resolution: WorkflowResolutionOptions(workflowName: "cli-workflow", workingDirectory: root.path))
    let cli = CLIWorkflowSessionStore(rootDirectory: sessionRoot)
    try cli.save(cliRecord, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: cliSession))
    let childSession = WorkflowSession(workflowId: "child-workflow", sessionId: "nested-child",
      status: .created, entryStepId: "start", createdAt: now, updatedAt: now,
      parentSessionId: runtimeSession.sessionId, rootSessionId: runtimeSession.sessionId)
    let reservation = WorkflowNestedInvocationReservation(parentSessionId: runtimeSession.sessionId,
      parentStepId: "parent-step", resumeStepId: "resume-step", sourceStepExecutionId: "source-execution",
      branchId: "branch", childSnapshot: WorkflowRuntimePersistenceSnapshot(session: childSession))
    _ = try runtime.reserveNestedInvocation(reservation)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionRoot))
    let definitionDatabase = try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: sessionRoot))
    let runtimeJSON = try XCTUnwrap(String(bytes: encoder.encode(runtimeSession), encoding: .utf8))
    let cliJSON = try XCTUnwrap(String(bytes: encoder.encode(cliRecord), encoding: .utf8))
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(runtimeJSON), .text(runtimeSession.sessionId)])
    try database.execute("UPDATE cli_workflow_sessions SET record_json=jsonb(?) WHERE session_id=?",
      bindings: [.text(cliJSON), .text(cliSession.sessionId)])
    try definitionDatabase.execute("DELETE FROM definition_version_pins WHERE session_id=?", bindings: [.text(runtimeSession.sessionId)])
    let invocationKey = try XCTUnwrap(database.query("SELECT invocation_key FROM workflow_nested_invocations").first?["invocation_key"])
    let reservationJSON = try XCTUnwrap(String(bytes: encoder.encode(reservation), encoding: .utf8))
    try database.execute("UPDATE workflow_nested_invocations SET reservation_json=jsonb(?), updated_at=? WHERE invocation_key=?",
      bindings: [.text(reservationJSON), .text("2020-09-13T12:26:40Z"), .text(invocationKey)])
    try database.execute("DELETE FROM workflow_nested_invocation_refs WHERE invocation_key=? AND role='reservation'",
      bindings: [.text(invocationKey)])
    XCTAssertEqual(try database.query("SELECT json_extract(session_json,'$.definitionSource.kind') AS kind " +
      "FROM workflow_runtime_snapshots WHERE workflow_execution_id=?",
      bindings: [.text(runtimeSession.sessionId)]).first?["kind"], "store")
    XCTAssertEqual(try database.query("SELECT count(*) AS count FROM definition_version_pins WHERE session_id=?",
      bindings: [.text(runtimeSession.sessionId)]).first?["count"], "0")
    let arguments = ["compact", "--apply", "--max-batch", "1", "--session-store", sessionRoot, "--output", "json"]

    let first = try run(StorageCompactCommandRunner(), arguments)
    XCTAssertEqual(first["workRemaining"] as? Bool, false)
    let firstStore = try XCTUnwrap((first["stores"] as? [[String: Any]])?.first)
    let converted = try XCTUnwrap(firstStore["converted"] as? [String: Int])
    XCTAssertEqual(converted["sessions"], 1)
    XCTAssertEqual(converted["cliRecords"], 1)
    XCTAssertEqual(converted["nestedInvocations"], 1)
    XCTAssertEqual(converted["definitionPins"], 1)
    let second = try run(StorageCompactCommandRunner(), arguments)
    XCTAssertEqual(second["workRemaining"] as? Bool, false)
    XCTAssertEqual(try runtime.load(sessionId: runtimeSession.sessionId), runtimeSnapshot)
    XCTAssertEqual(try cli.load(sessionId: cliSession.sessionId), cliRecord)
    let marker = try database.query("SELECT json_extract(record_json,'$.sessionStorage') AS storage " +
      "FROM cli_workflow_sessions WHERE session_id=?", bindings: [.text(cliSession.sessionId)]).first?["storage"]
    XCTAssertEqual(marker, "canonical")
    XCTAssertEqual(try definitionDatabase.query("SELECT count(*) AS count FROM definition_version_pins WHERE session_id=?",
      bindings: [.text(runtimeSession.sessionId)]).first?["count"], "1")
    let abandoned = try database.query("SELECT abandoned_at FROM workflow_nested_invocations WHERE invocation_key=?",
      bindings: [.text(invocationKey)]).first?["abandoned_at"]
    XCTAssertNotNil(abandoned)
  }

  func testNoRetentionPolicyReportsNotConfiguredAndKeepsSessionDatabase() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    try database.execute("CREATE TABLE retained_fixture(value TEXT)")
    try database.execute("INSERT INTO retained_fixture VALUES ('keep')")

    let report = try run(StorageCompactCommandRunner(), ["compact", "--apply", "--session-store", root.path, "--output", "json"])

    let stores = try XCTUnwrap(report["stores"] as? [[String: Any]])
    XCTAssertEqual((stores.first?["prune"] as? [String: String])?["state"], "notConfigured")
    XCTAssertFalse(FileManager.default.fileExists(atPath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path)))
    XCTAssertEqual(try database.query("SELECT value FROM retained_fixture").first?["value"], "keep")
  }

  func testConfiguredResultsRetentionPrunesOldSessionFamily() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/storage-compact-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".riela"), withIntermediateDirectories: true)
    let sessionRoot = CLIWorkflowSessionStore.resolveRootDirectory(sessionStore: nil, scope: .project,
      workingDirectory: root.path)
    let old = Date(timeIntervalSince1970: 1_600_000_000)
    let session = WorkflowSession(workflowId: "retained-workflow", sessionId: "old-family",
      status: .completed, entryStepId: "start", createdAt: old, updatedAt: old)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: session,
      rootOutput: ["payload": .string(String(repeating: "retained-data", count: 200_000))]))
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionRoot)
    let sizeBefore = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? NSNumber).int64Value

    let report = try run(StorageCompactCommandRunner(), ["compact", "--apply", "--working-dir", root.path,
      "--results-max-age-days", "1", "--output", "json"])

    XCTAssertFalse(report["dryRun"] as? Bool ?? true)
    let stores = try XCTUnwrap(report["stores"] as? [[String: Any]])
    let prune = try XCTUnwrap(stores.first?["prune"] as? [String: Any])
    let results = try XCTUnwrap(prune["results"] as? [String: Any])
    XCTAssertEqual(results["removedCount"] as? Int, 1)
    let reclamation = try XCTUnwrap(stores.first?["reclamation"] as? [[String: Any]])
    XCTAssertGreaterThan(reclamation.compactMap { $0["reclaimedBytes"] as? Int64 }.reduce(0, +), 0)
    let sizeAfter = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.size] as? NSNumber).int64Value
    XCTAssertLessThan(sizeAfter, sizeBefore)
    XCTAssertThrowsError(try runtime.load(sessionId: "old-family"))
  }

  private func run(_ runner: StorageCompactCommandRunner, _ arguments: [String]) throws -> [String: Any] {
    let result = runner.run(arguments)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
  }
}

private final class DefinitionBackfillStatementRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []
  private var writerDurations: [TimeInterval] = []
  private var writeCount = 0

  var statements: [String] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }

  var maximumWriterDuration: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return writerDurations.max() ?? 0
  }

  var successfulWrites: Int {
    lock.lock()
    defer { lock.unlock() }
    return writeCount
  }

  func record(_ statement: String, writer: SQLiteDatabase) {
    lock.lock()
    values.append(statement)
    lock.unlock()
    let started = Date()
    let succeeded = (try? writer.execute("INSERT INTO writer_probe VALUES (1)")) != nil
    lock.lock()
    writerDurations.append(Date().timeIntervalSince(started))
    if succeeded { writeCount += 1 }
    lock.unlock()
  }
}
