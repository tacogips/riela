import CryptoKit
import Foundation
import XCTest
import RielaSQLite
@testable import RielaCLI
@testable import RielaMemory

final class StorageDoctorCommandTests: XCTestCase {
  func testDoctorStorageReadsDatabaseWithoutChangingBytesOrModificationDate() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: root.path)
    let database = try SQLiteDatabase.open(path: databasePath)
    try database.execute("CREATE TABLE example(value TEXT)")
    try database.execute("INSERT INTO example VALUES ('payload')")
    let beforeBytes = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let beforeDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)
    let result = await RielaCLIApplication().run(["doctor", "storage", "--session-store", root.path, "--output", "json"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let files = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    XCTAssertEqual(files.count, 1)
    XCTAssertEqual(files[0]["kind"] as? String, "session")
    XCTAssertTrue(["none", "full", "incremental", "unknown"].contains(files[0]["autoVacuum"] as? String ?? ""))
    XCTAssertFalse((files[0]["tables"] as? [[String: Any]] ?? []).isEmpty)
    let afterBytes = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let afterDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date)
    XCTAssertEqual(SHA256.hash(data: beforeBytes), SHA256.hash(data: afterBytes))
    XCTAssertEqual(beforeDate, afterDate)
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
  }

  func testStorageParserHelpListsContractFlags() throws {
    let help = ParsedStorageCommandArguments.helpMessage()
    for flag in ["--scope", "--working-dir", "--session-store", "--memory-root", "--cache-root", "--kv-root",
      "--top", "--output", "--apply", "--max-batch", "--abandoned-after-hours", "--results-max-age-days",
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
}
