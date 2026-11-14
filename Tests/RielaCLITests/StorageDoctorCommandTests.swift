import CryptoKit
import Foundation
import XCTest
@testable import RielaCore
import RielaSQLite
@testable import RielaCLI
@testable import RielaMemory

final class StorageDoctorCommandTests: XCTestCase {
  func testDoctorMemoryReadsStayConsistentWithConcurrentDeleteJournalWriter() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
    let emptySessionRoot = root.appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: emptySessionRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = memoryRoot.appendingPathComponent("state.sqlite").path
    let database = try SQLiteDatabase.open(path: path, options: .init(enableWAL: false, requireJSONB: false))
    try database.execute("CREATE TABLE memory_entries(record_id INTEGER PRIMARY KEY,payload_json TEXT,tags_json TEXT,related_record_ids_json TEXT)")
    try database.execute("INSERT INTO memory_entries VALUES(1,'{\"value\":\"seed\"}','[]','[]')")
    XCTAssertEqual(try database.query("PRAGMA journal_mode").first?["journal_mode"], "delete")

    let writer = Task.detached {
      for index in 0..<80 {
        try database.transaction { transaction in
          try transaction.execute("UPDATE memory_entries SET payload_json=? WHERE record_id=1",
            bindings: [.text("{\"value\":\"revision-\(index)\"}")])
        }
      }
    }
    for _ in 0..<50 {
      let result = await RielaCLIApplication().run([
        "doctor", "storage", "--session-store", emptySessionRoot.path, "--memory-root", memoryRoot.path, "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      let files = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
      let memoryFile = try XCTUnwrap(files.first(where: { $0["kind"] as? String == "memory" }), result.stdout)
      let memory = try XCTUnwrap(memoryFile["memory"] as? [String: Any], result.stdout)
      XCTAssertEqual(memory["records"] as? Int64 ?? Int64(memory["records"] as? Int ?? 0), 1)
    }
    _ = try await writer.value
  }

  func testDoctorStorageReadsDatabaseWithoutChangingBytesOrModificationDate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: databasePath)
    _ = try database.query("PRAGMA journal_mode=WAL")
    try database.execute("CREATE TABLE example(value TEXT)")
    try database.execute("INSERT INTO example VALUES ('payload')")
    let walPath = databasePath + "-wal"
    let beforeWAL = try Data(contentsOf: URL(fileURLWithPath: walPath))
    let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let beforeDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)
    let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
    try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
    for name in ["persona-events.sqlite", "persona-summary.sqlite"] {
      let memoryDatabase = try SQLiteDatabase.open(path: memoryRoot.appendingPathComponent(name).path)
      try memoryDatabase.execute("CREATE TABLE example(value TEXT)")
    }
    let result = await RielaCLIApplication().run([
      "doctor", "storage", "--session-store", root.path, "--memory-root", memoryRoot.path, "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    XCTAssertEqual(files.count, 3)
    XCTAssertEqual(files.compactMap { $0["kind"] as? String }.sorted(), ["memory", "memory", "session"])
    XCTAssertEqual(files[0]["kind"] as? String, "session")
    XCTAssertTrue(["none", "full", "incremental", "unknown"].contains(files[0]["autoVacuum"] as? String ?? ""))
    XCTAssertFalse((files[0]["tables"] as? [[String: Any]] ?? []).isEmpty)
    let afterBytes = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let afterDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)
    XCTAssertEqual(SHA256.hash(data: beforeBytes), SHA256.hash(data: afterBytes))
    XCTAssertEqual(SHA256.hash(data: beforeWAL), SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: walPath))))
    XCTAssertEqual(beforeDate, afterDate)
  }

  func testDoctorListsWALSessionStoreWithoutSidecarFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let session = WorkflowSession(workflowId: "wal", sessionId: "wal-session", status: .completed,
      entryStepId: "start", createdAt: Date(timeIntervalSince1970: 1_600_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
      .save(WorkflowRuntimePersistenceSnapshot(session: session))
    XCTAssertTrue(FileManager.default.fileExists(atPath: databasePath), databasePath)
    do {
      let database = try SQLiteDatabase.open(path: databasePath)
      _ = try database.query("PRAGMA journal_mode=WAL")
    }
    try? FileManager.default.removeItem(atPath: databasePath + "-wal")
    try? FileManager.default.removeItem(atPath: databasePath + "-shm")
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-shm"))

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let files = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    XCTAssertTrue(files.contains { $0["kind"] as? String == "session" && $0["path"] as? String == databasePath }, result.stderr + result.stdout)
  }

  func testDoctorReadOnlyReconciliationLeavesTreeAndLocksUntouched() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let parent = WorkflowSession(workflowId: "workflow", sessionId: "parent-zz", status: .completed,
      entryStepId: "start", createdAt: now, updatedAt: now)
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: parent))
    let child = WorkflowSession(workflowId: "child", sessionId: "child-zz", status: .created,
      entryStepId: "start", createdAt: now, updatedAt: now, parentSessionId: parent.sessionId,
      rootSessionId: parent.sessionId)
    _ = try runtime.reserveNestedInvocation(WorkflowNestedInvocationReservation(parentSessionId: parent.sessionId,
      parentStepId: "step", resumeStepId: "resume", sourceStepExecutionId: "execution", branchId: "branch",
      childSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)))
    let databasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: runtime.rootDirectory)
    try? FileManager.default.removeItem(atPath: databasePath + "-wal")
    try? FileManager.default.removeItem(atPath: databasePath + "-shm")
    let before = try treeSnapshot(root)

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(try treeSnapshot(root), before)
    let lockRoot = URL(fileURLWithPath: runtime.rootDirectory).appendingPathComponent("execution-locks")
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockRoot.appendingPathComponent("child-zz.lock").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: lockRoot.appendingPathComponent("parent-zz.lock").path))
  }

  func testDoctorCountsOnlyMemorySpecificUnreferencedFilesUsingLegacyReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sources = root.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let alphaSource = sources.appendingPathComponent("alpha.bin")
    let betaSource = sources.appendingPathComponent("beta.bin")
    try Data(repeating: 1, count: 1_000).write(to: alphaSource)
    try Data(repeating: 2, count: 2_000).write(to: betaSource)
    let alpha = try RielaMemoryStore(rootDirectory: root.path).save(memoryId: "alpha", workflowId: "flow",
      files: [MemoryFileReference(path: alphaSource.path, mediaType: "application/octet-stream", kind: "file")],
      payload: .string("alpha"))
    _ = try RielaMemoryStore(rootDirectory: root.path).save(memoryId: "beta", workflowId: "flow",
      files: [MemoryFileReference(path: betaSource.path, mediaType: "application/octet-stream", kind: "file")],
      payload: .string("beta"))
    for memoryId in ["alpha", "beta"] {
      let memoryStore = RielaMemoryStore(rootDirectory: root.path)
      let database = try SQLiteDatabase.open(path: memoryStore.databasePath(memoryId: memoryId))
      try database.execute("DELETE FROM memory_history_heads")
    }
    let orphan = root.appendingPathComponent("files/alpha/\(alpha.recordId)/orphan.bin")
    try Data(repeating: 3, count: 3_000).write(to: orphan)

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path,
      "--memory-root", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    let memories = Dictionary(uniqueKeysWithValues: files.compactMap { file -> (String, Int)? in
      guard file["kind"] as? String == "memory", let path = file["path"] as? String,
            let info = file["memory"] as? [String: Any],
            let size = info["unreferencedAttachmentBytes"] as? Int else { return nil }
      return (URL(fileURLWithPath: path).lastPathComponent, size)
    })
    XCTAssertEqual(memories["alpha.sqlite"], 3_000)
    XCTAssertEqual(memories["beta.sqlite"], 0)
  }

  private func treeSnapshot(_ root: URL) throws -> [String: String] {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
    var result: [String: String] = [:]
    while let url = enumerator?.nextObject() as? URL {
      let key = String(url.path.dropFirst(root.path.count))
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      result[key] = values.isDirectory == true ? "directory" : SHA256.hash(data: try Data(contentsOf: url)).description
    }
    return result
  }

  func testTextOutputHasOneBlockForEachDatabaseFile() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: path)
    try database.execute("CREATE TABLE example(value TEXT)")
    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(result.stdout.components(separatedBy: "session: ").count - 1, 1)
    XCTAssertTrue(result.stdout.contains("reclaimable:"))
  }

  func testStorageParserHelpListsContractFlags() throws {
    let help = ParsedStorageCommandArguments.helpMessage()
    for flag in ["--scope", "--working-dir", "--session-store", "--memory-root", "--cache-root", "--kv-root",
      "--top", "--output", "--apply", "--allow-live-vacuum", "--max-batch", "--abandoned-after-hours", "--results-max-age-days",
      "--results-max-total-bytes", "--messages-max-age-days", "--messages-max-total-bytes"] {
      XCTAssertTrue(help.contains(flag), "missing \(flag)")
    }
  }

  func testLegacyTwentyVersionMemoryHistoryReportIsReadOnly() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    var versions = [try store.save(memoryId: "memory", workflowId: "workflow", payload: .string("v1"))]
    for index in 2...20 {
      versions.append(try store.update(memoryId: "memory", recordId: versions[0].recordId,
        payload: .string("v\(index)"), historyRetention: 25))
    }
    let databasePath = try store.databasePath(memoryId: "memory")
    do {
      let database = try SQLiteDatabase.open(path: databasePath)
      try database.execute("DELETE FROM memory_history_versions")
      try database.execute("DELETE FROM memory_history_heads")
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      for index in versions.indices {
        let previousDelta: String
        if index == 0 { previousDelta = "NULL" } else {
          let delta = try EvolutionReverseDelta(previous: encoder.encode(versions[index - 1]),
            next: encoder.encode(versions[index]), nextVersion: Int64(index + 1))
          let json = try XCTUnwrap(String(bytes: encoder.encode(delta), encoding: .utf8))
          previousDelta = "'\(json)'"
        }
        try database.execute("INSERT INTO memory_evolution(record_id,version,recorded_at,reverse_delta_json) VALUES (1,\(index + 1),'2020-01-01T00:00:00Z',\(previousDelta))")
      }
    }
    let before = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let beforeDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path,
      "--memory-root", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    let memoryFile = try XCTUnwrap(files.first { $0["kind"] as? String == "memory" })
    let memory = try XCTUnwrap(memoryFile["memory"] as? [String: Any])
    XCTAssertEqual(memory["legacyRecords"] as? Int, 1)
    XCTAssertEqual(memory["maxVersionsPerRecord"] as? Int, 20)
    XCTAssertGreaterThan(memory["amplification"] as? Double ?? 0, 0)
    XCTAssertFalse((memoryFile["tables"] as? [[String: Any]] ?? []).isEmpty)
    let afterDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)
    XCTAssertEqual(SHA256.hash(data: before), SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: databasePath))))
    XCTAssertEqual(beforeDate, afterDate)
  }

  func testDoctorReportsSeparateDefinitionDatabase() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let document = Data(#"{"version":1}"#.utf8)
    let digest = JSONCanonical.sha256Hex(document)
    let definitions = WorkflowDefinitionStore(rootDirectory: root.path)
    guard case .created = try definitions.commit(WorkflowDefinitionWrite(workflowName: "workflow",
      operation: .`import`, documentData: document, documentDigest: digest, sourceDirectory: root.path,
      sourceScope: "project", provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "seed")) else {
      XCTFail("definition seed did not create a version")
      return
    }

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    let definitionFile = try XCTUnwrap(files.first { $0["kind"] as? String == "definitions" })
    XCTAssertEqual((definitionFile["definitions"] as? [String: Any])?["workflows"] as? Int, 1)
  }

  func testDoctorCountsOnlyUnreferencedMemoryFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = root.appendingPathComponent("memory.sqlite").path
    let database = try SQLiteDatabase.open(path: databasePath)
    try database.execute("CREATE TABLE memory_entries(record_id INTEGER PRIMARY KEY,payload_json TEXT,tags_json TEXT,related_record_ids_json TEXT)")
    try database.execute("CREATE TABLE memory_evolution_attachments(path TEXT PRIMARY KEY,content_sha256 TEXT NOT NULL)")
    let referenced = root.appendingPathComponent("files/memory/1/referenced.bin")
    let orphan = root.appendingPathComponent("files/memory/2/orphan.bin")
    try FileManager.default.createDirectory(at: referenced.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 12).write(to: referenced)
    try Data(repeating: 2, count: 29).write(to: orphan)
    let payload = try JSONSerialization.data(withJSONObject: ["files": [["path": referenced.path]]])
    try database.execute("INSERT INTO memory_entries VALUES(1,?, '[]','[]')",
      bindings: [.text(String(data: payload, encoding: .utf8) ?? "{}")])
    try database.execute("INSERT INTO memory_evolution_attachments(path,content_sha256) VALUES(?, 'hash')", bindings: [.text(referenced.path)])

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path,
      "--memory-root", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    let memory = try XCTUnwrap(files.first { $0["kind"] as? String == "memory" }?["memory"] as? [String: Any])
    XCTAssertEqual(memory["unreferencedAttachmentBytes"] as? Int, 29)
  }

  func testDoctorSkipsUnreadableDatabaseWhenAnotherStoreOpens() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionPath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: sessionPath)
    try database.execute("CREATE TABLE usable(value TEXT)")
    let memoryPath = root.appendingPathComponent("broken.sqlite")
    try Data("not sqlite".utf8).write(to: memoryPath)

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path,
      "--memory-root", root.path, "--output", "json"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.contains("broken.sqlite"))
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    XCTAssertTrue(files.contains { $0["path"] as? String == sessionPath })
  }

  func testDoctorReportsLegacyInlineAndEnvelopeSessionFixture() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_600_000_000)
    let legacySession = WorkflowSession(workflowId: "workflow", sessionId: "legacy-inline", status: .completed,
      entryStepId: "start", createdAt: now, updatedAt: now)
    let envelopeSession = WorkflowSession(workflowId: "workflow", sessionId: "envelope", status: .completed,
      entryStepId: "start", createdAt: now, updatedAt: now)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    try runtime.save(WorkflowRuntimePersistenceSnapshot(session: legacySession))
    let cli = CLIWorkflowSessionStore(rootDirectory: root.path)
    let record = PersistedCLIWorkflowSession(workflowName: "workflow", session: envelopeSession,
      resolution: WorkflowResolutionOptions(workflowName: "workflow", workingDirectory: root.path))
    try cli.save(record, runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: envelopeSession))
    let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(legacySession)) as? [String: Any])
    legacy["executions"] = []
    let legacyJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: legacy), encoding: .utf8))
    try database.execute("UPDATE workflow_runtime_snapshots SET session_json=jsonb(?) WHERE workflow_execution_id=?",
      bindings: [.text(legacyJSON), .text(legacySession.sessionId)])

    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    let session = try XCTUnwrap(files.first { $0["kind"] as? String == "session" }?["session"] as? [String: Any])
    XCTAssertEqual(session["sessions"] as? Int, 2)
    XCTAssertEqual(session["legacyInlineSnapshots"] as? Int, 1)
    XCTAssertEqual(session["legacyCLICopies"] as? Int, 0)
    let textResult = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path])
    XCTAssertTrue(textResult.stdout.contains("largest sessions"))
  }
}
