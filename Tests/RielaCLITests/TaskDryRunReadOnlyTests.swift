import Foundation
import RielaAppSupport
import RielaCore
import RielaSQLite
import RielaWork
import XCTest
@testable import RielaCLI

final class TaskDryRunReadOnlyTests: XCTestCase {
  private let tables = [
    "work_intents", "work_tasks", "work_attempts", "work_leases", "work_pending_reservations",
    "work_cancellations", "work_decisions", "work_decision_applications", "work_evidence",
    "work_findings", "work_hosts"
  ]

  func testReadyAndWaitPreviewsPreserveEveryRowAndFile() async throws {
    for mode in ["ready", "dependency", "capacity"] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      let prerequisite = try harness.seed("prerequisite")
      let task = try harness.seed(
        "task-repair-loop", dependsOn: mode == "dependency" ? [prerequisite.id] : []
      )
      let before = try snapshot(harness)
      let result = try await harness.dispatch(
        "task-repair-loop", capacity: mode == "capacity" ? 0 : 1, dryRun: true
      )
      XCTAssertEqual(result.exitCode, .success, result.stderr)
      let response = try harness.decode(result)
      XCTAssertEqual(response.status, mode == "ready" ? "ready" : "waiting")
      XCTAssertEqual(response.waitReason, mode == "dependency" ? .dependency : mode == "capacity" ? .capacity : nil)
      XCTAssertNil(response.attemptId)
      XCTAssertNil(response.sessionId)
      let after = try snapshot(harness)
      let fileNames = Set(before.files.keys).union(after.files.keys)
      let changedFiles = fileNames.filter { before.files[$0] != after.files[$0] }.sorted()
      let changedTables = tables.filter { before.rows[$0] != after.rows[$0] }
      XCTAssertTrue(changedFiles.isEmpty, "\(mode): changed files \(changedFiles)")
      XCTAssertTrue(changedTables.isEmpty, "\(mode): changed rows \(changedTables)")
      XCTAssertEqual(try harness.store.loadTask(id: task.id), task)
    }
  }

  func testAbsentAndCorruptStoresKeepInventoryAndBytes() async throws {
    for mode in ["absent", "incompatible", "corrupt"] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      if mode == "corrupt" {
        let url = URL(fileURLWithPath: harness.store.databasePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: url)
      } else if mode == "incompatible" {
        let database = try SQLiteDatabase.open(path: harness.store.databasePath)
        try database.execute("CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
      }
      let before = try harness.fileBytes()
      let result = try await harness.dispatch("task-repair-loop", dryRun: true)
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertFalse(result.stderr.isEmpty && result.stdout.isEmpty)
      XCTAssertEqual(try harness.fileBytes(), before, mode)
    }
  }

  func testActiveWALFailsBeforeReadWithoutChangingSidecars() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    _ = try harness.seed("task-repair-loop")
    let writer = try SQLiteDatabase.open(path: harness.store.databasePath)
    try writer.execute("CREATE TABLE preview_wal_marker (value INTEGER NOT NULL)")
    try writer.execute("INSERT INTO preview_wal_marker (value) VALUES (42)")
    let walPath = harness.store.databasePath + "-wal"
    XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: walPath)).count, 0)
    let before = try harness.fileBytes()
    let result = try await harness.dispatch("task-repair-loop", dryRun: true)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("active SQLite WAL"), result.stdout)
    XCTAssertEqual(try harness.fileBytes(), before)
    withExtendedLifetime(writer) {}
  }

  func testCorruptActiveProfileSelectionFailsWithoutRepair() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let profileStore = RielaAppProfileStore(appRootURL: harness.sessionStore)
    try Data("bad active profile".utf8).write(to: profileStore.activeProfileURL)
    let resolver = HostCapabilityResolver(activeProfileStore: profileStore)
    let before = try snapshot(harness)
    let result = try await harness.dispatch("task-repair-loop", dryRun: true, hostResolver: resolver)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("active profile selection"), result.stdout)
    let after = try snapshot(harness)
    XCTAssertEqual(after.files, before.files)
    XCTAssertEqual(after.rows, before.rows)
    XCTAssertEqual(try harness.store.loadTask(id: task.id), task)
  }

  func testConcurrentWriterCannotProduceStaleReadyPreview() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let resolver = PreviewWritingHostResolver(store: harness.store, task: task)
    let result = try await harness.dispatch("task-repair-loop", dryRun: true, hostResolver: resolver)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("source changed concurrently"), result.stdout)
    XCTAssertFalse(result.stdout.contains("\"status\":\"ready\""), result.stdout)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.title, "concurrent writer")
  }

  func testFirstMatchingStoreIgnoresLaterActiveWAL() throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let laterRoot = harness.sessionStore.appendingPathComponent("later-root", isDirectory: true)
    let later = WorkStore(rootDirectory: laterRoot.path)
    let writer = try SQLiteDatabase.open(path: later.databasePath)
    try writer.execute("CREATE TABLE later_marker (value INTEGER NOT NULL)")
    try writer.execute("INSERT INTO later_marker (value) VALUES (1)")
    let wal = try Data(contentsOf: URL(fileURLWithPath: later.databasePath + "-wal"))
    XCTAssertFalse(wal.isEmpty)
    let preview = try PreviewStoreSnapshot(
      roots: [harness.store.rootDirectory, laterRoot.path], taskId: task.id
    )
    defer { preview.remove() }
    XCTAssertEqual(preview.locateTask()?.task.id, task.id)
    withExtendedLifetime(writer) {}
  }

  private func snapshot(_ harness: TaskExampleHarness) throws -> Snapshot {
    let filesBeforeRead = try harness.fileBytes()
    let inspectionRoot = harness.repository.appendingPathComponent(
      "tmp/p1-6b-row-snapshot-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: inspectionRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: inspectionRoot) }
    let copiedDatabase = inspectionRoot.appendingPathComponent("work.sqlite")
    for suffix in ["", "-wal", "-shm"] {
      let source = URL(fileURLWithPath: harness.store.databasePath + suffix)
      if FileManager.default.fileExists(atPath: source.path) {
        try FileManager.default.copyItem(
          at: source, to: URL(fileURLWithPath: copiedDatabase.path + suffix)
        )
      }
    }
    let database = try SQLiteDatabase.open(
      path: copiedDatabase.path, mode: .strictReadOnlyWithImmutableFallback,
      options: .readOnlyDefault
    )
    var rows: [String: [String]] = [:]
    for table in tables {
      let columns = try database.query("PRAGMA table_info(\(table))").compactMap { $0["name"] }
      let fields = columns.map { "'\($0)', quote(\"\($0)\")" }.joined(separator: ", ")
      rows[table] = try database.query(
        "SELECT json_object(\(fields)) AS value FROM \(table) ORDER BY rowid"
      ).map { $0["value"] ?? "" }
    }
    XCTAssertEqual(try harness.fileBytes(), filesBeforeRead, "snapshot read mutated fixture files")
    return Snapshot(files: filesBeforeRead, rows: rows)
  }

  private struct Snapshot: Equatable {
    var files: [String: Data]
    var rows: [String: [String]]
  }
}

private struct PreviewWritingHostResolver: HostCapabilityResolving {
  let store: WorkStore
  let task: WorkTask

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    var updated = task
    updated.title = "concurrent writer"
    try store.saveTask(updated)
    let now = Date()
    return [HostCapabilitySnapshot(
      hostId: "local", capacity: 1,
      backends: [BackendCapability(
        backend: .codexAgent, source: .observed, observedAt: now,
        availability: .available, authentication: .available, models: ["gpt-5.4-mini"]
      )], refreshedAt: now
    )]
  }
}
