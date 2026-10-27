import Foundation
import SQLite3
import XCTest
@testable import RielaMemory

final class MemorySnapshotTests: XCTestCase {
  func testLegacyHeadLoadsAtomicallyAndStaleWriterCannotOverwriteIt() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let legacy = try store.save(memoryId: "source", workflowId: "poll", nodeId: "collect", tags: ["checkpoint"],
      payload: .object(["cursor": .string("literal"), "pending": .array([.string("untouched")])]))
    let read = try XCTUnwrap(store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint"))
    XCTAssertEqual(read.record, legacy)
    XCTAssertEqual(read.head, .init(recordId: legacy.recordId, version: 1, scope: read.head.scope))
    let newer = try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: read.head, payload: .object(["cursor": .string("next"), "pending": .array([.string("untouched")])]))
    XCTAssertEqual(newer.head.version, 2)
    XCTAssertThrowsError(try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: read.head, payload: .string("stale"))) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertThrowsError(try store.recordVersion(memoryId: "source", recordId: legacy.recordId, version: 1))
    XCTAssertEqual(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.head, newer.head)
  }

  func testNamespaceAndNewLegacyHeadAreBothFenced() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: nil, payload: .string("one"))
    XCTAssertNil(try store.loadSnapshot(memoryId: "source", workflowId: "other", nodeId: "collect", tag: "checkpoint"))
    XCTAssertNil(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "other", tag: "checkpoint"))
    XCTAssertNil(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "other"))
    let newer = try store.save(memoryId: "source", workflowId: "poll", nodeId: "collect", registeredAt: "2999-01-01T00:00:00Z",
      tags: ["checkpoint"], payload: .string("legacy-new-head"))
    XCTAssertThrowsError(try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: first.head, payload: .string("overwrite"))) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertEqual(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.record.recordId, newer.recordId)
  }

  func testConcurrentCreatorsHaveExactlyOneWinner() async throws {
    for _ in 0..<12 { try await concurrentCreatorsHaveExactlyOneWinner() }
  }

  private func concurrentCreatorsHaveExactlyOneWinner() async throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
      for index in 0..<12 {
        group.addTask {
          do {
            try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
              expectedHead: nil, payload: .number(Double(index)))
            return true
          } catch MemorySnapshotError.conflict { return false }
        }
      }
      var successes = 0
      for try await win in group where win { successes += 1 }
      return successes
    }
    XCTAssertEqual(wins, 1)
  }

  func testUnicodeByteLimitAndFailedCommitLeaveHeadUntouched() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let first = try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: nil, payload: .string("small"))
    XCTAssertThrowsError(try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: first.head, payload: .string(String(repeating: "字", count: 100)), maxPayloadBytes: 200))
    XCTAssertEqual(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.head, first.head)
    _ = try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: first.head, payload: .string(String(repeating: "字", count: 100)))
    XCTAssertThrowsError(try store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint", maxPayloadBytes: 200))
  }

  func testHeadCannotBeReusedAcrossDatabasesWithIdenticalRowAndRevisionNumbers() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let a = try store.commitSnapshot(memoryId: "account-a", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: nil, payload: .string("a"))
    let b = try store.commitSnapshot(memoryId: "account-b", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: nil, payload: .string("b"))
    XCTAssertEqual(a.head.recordId, b.head.recordId)
    XCTAssertEqual(a.head.version, b.head.version)
    XCTAssertNotEqual(a.head.scope, b.head.scope)
    XCTAssertThrowsError(try store.commitSnapshot(memoryId: "account-b", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: a.head, payload: .string("wrong account"))) { XCTAssertEqual($0 as? MemorySnapshotError, .conflict) }
    XCTAssertEqual(try store.loadSnapshot(memoryId: "account-b", workflowId: "poll", nodeId: "collect", tag: "checkpoint")?.record.payload, .string("b"))
  }

  func testSchemaThreePayloadWithoutEvolutionGetsAtomicBaselineWithoutDataChanges() throws {
    let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    let legacy = try store.save(memoryId: "source", workflowId: "poll", nodeId: "collect", tags: ["checkpoint"],
      payload: .object(["cursor": .string("literal-frozen"), "pending": .array([.string("unacknowledged")])]))
    let db = try store.openDatabase(memoryId: "source")
    try execute(db, "DROP TABLE memory_evolution")
    try execute(db, "DROP TABLE memory_evolution_attachments")
    try execute(db, "DROP TABLE memory_retirement")
    try execute(db, "PRAGMA user_version = 3")
    sqlite3_close(db)
    let read = try XCTUnwrap(store.loadSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint"))
    XCTAssertEqual(read.record, legacy)
    XCTAssertEqual(read.head.version, 1)
    XCTAssertEqual(try store.evolutionHistory(memoryId: "source", recordId: legacy.recordId).map(\.version), [1])
    let updated = try store.commitSnapshot(memoryId: "source", workflowId: "poll", nodeId: "collect", tag: "checkpoint",
      expectedHead: read.head, payload: .string("new state"))
    XCTAssertEqual(updated.head.version, 2)
    XCTAssertThrowsError(try store.recordVersion(memoryId: "source", recordId: legacy.recordId, version: 1))
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
