import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class MemoryEvolutionHistoryTests: XCTestCase {
  func testUpdatesReconstructRecordsAndRetainAttachments() throws {
    let root = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let attachment = root.appendingPathComponent("input.bin")
    try Data([0, 255, 128]).write(to: attachment)
    let store = RielaMemoryStore(rootDirectory: root.appendingPathComponent("store").path)
    let first = try store.save(memoryId: "m", workflowId: "w", tags: ["before"],
      files: [MemoryFileReference(path: attachment.path)], payload: .string("記憶"))
    let second = try store.update(memoryId: "m", recordId: first.recordId, tags: ["after"],
      files: [], payload: .string("進化"), historyRetention: 2)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 1), first)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 2), second)
    let oldFile = try XCTUnwrap(first.files.first)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: oldFile.path)), Data([0, 255, 128]))
    let history = try store.evolutionHistory(memoryId: "m", recordId: first.recordId)
    XCTAssertEqual(history.map(\.version), [2, 1])
    XCTAssertEqual(history.first?.storage?.encoding, "external")
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId, beforeVersion: 2).map(\.version), [1])
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 3))
    _ = try store.update(memoryId: "m", recordId: first.recordId, tags: ["after"], files: [], payload: .string("進化"))
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).count, 2)
    try Data([9, 9, 9]).write(to: URL(fileURLWithPath: oldFile.path))
    XCTAssertThrowsError(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 1))
    XCTAssertThrowsError(try store.restoreRecordVersion(memoryId: "m", recordId: first.recordId,
      version: 1, expectedHeadVersion: 2))
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).count, 2)
  }

  func testFailedUpdateDoesNotChangeHeadOrHistory() throws {
    let root = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", payload: .string("first"))
    XCTAssertThrowsError(try store.update(memoryId: "m", recordId: first.recordId,
      files: [MemoryFileReference(path: root.appendingPathComponent("missing").path)], payload: .string("lost")))
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 1), first)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).count, 1)
    XCTAssertThrowsError(try store.update(memoryId: "m", recordId: first.recordId, workflowId: "wrong", payload: .null))
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).count, 1)
  }

  func testRestoreCreatesRevisionAndRejectsStaleHead() throws {
    let root = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", payload: .string("first"))
    let second = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("second"), historyRetention: 10)
    XCTAssertThrowsError(try store.restoreRecordVersion(memoryId: "m", recordId: first.recordId,
      version: 1, expectedHeadVersion: 1))
    let restored = try store.restoreRecordVersion(memoryId: "m", recordId: first.recordId,
      version: 1, expectedHeadVersion: 2, historyRetention: 10)
    XCTAssertEqual(restored, first)
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 2), second)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).map(\.version), [3, 2, 1])
    _ = try store.restoreRecordVersion(memoryId: "m", recordId: first.recordId, version: 1, expectedHeadVersion: 3, historyRetention: 10)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).map(\.version), [4, 3, 2, 1])
  }

  func testVersionThreeDatabaseBaselinesBeforeFirstUpdate() throws {
    let root = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", payload: .string("legacy"))
    let db = try store.openDatabase(memoryId: "m")
    try execute(db, "DROP TABLE memory_evolution")
    try execute(db, "PRAGMA user_version = 3")
    sqlite3_close(db)
    _ = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("new"))
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 1), first)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).map(\.version), [2, 1])
  }

  func testConcurrentWritersProduceOneUnbrokenChain() async throws {
    let root = try scratchRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.save(memoryId: "m", workflowId: "w", payload: .string("baseline"))
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          _ = try store.update(memoryId: "m", recordId: first.recordId, payload: .string("writer-\(index)"), historyRetention: 20)
        }
      }
      try await group.waitForAll()
    }
    XCTAssertEqual(try store.evolutionHistory(memoryId: "m", recordId: first.recordId).map(\.version), Array((1...9).reversed()))
    XCTAssertEqual(try store.recordVersion(memoryId: "m", recordId: first.recordId, version: 1), first)
    var payloads: Set<String> = []
    for version in 2...9 {
      let restored = try store.recordVersion(memoryId: "m", recordId: first.recordId, version: Int64(version))
      payloads.insert(try encodedJSONString(restored.payload))
    }
    XCTAssertEqual(payloads.count, 8)
  }

  private func scratchRoot() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/evolution-history/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
