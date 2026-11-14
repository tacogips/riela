import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class SnapshotWorkAddonTests: XCTestCase {
  func testScanProjectsOnlyScopedPendingMetadataAndSortsAttempts() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    for (id, pending, research, attempt) in [("jobs-c", true, true, "2"), ("jobs-a", false, true, ""), ("jobs-b", false, false, "1")] {
      _ = try store.save(memoryId: id, workflowId: "work", nodeId: "queue", tags: ["checkpoint"], payload: .object([
        "records": .array([.string("PRIVATE BODY")]), "state": .object(["pending": .bool(pending), "research": .bool(research), "attempt": .string(attempt)])]))
    }
    _ = try store.save(memoryId: "jobs-z", workflowId: "different", nodeId: "queue", tags: ["checkpoint"], payload: .string("different scope"))
    var config = scan(root)
    config["valueFrom"] = .string("/state")
    config["whereAny"] = .array([.object(["path": .string("/pending"), "equals": .bool(true)]), .object(["path": .string("/research"), "equals": .bool(false)])])
    config["sortBy"] = .array([.object(["path": .string("/attempt"), "default": .string("")])])
    let output = try await Self.run("riela/snapshot-scan", config)
    XCTAssertEqual(output["scannedCount"], .integer(4))
    guard case let .array(items)? = output["items"] else { return XCTFail("missing items") }
    XCTAssertEqual(items.compactMap { item -> JSONValue? in guard case let .object(row) = item else { return nil }; return row["memoryId"] }, [.string("jobs-b"), .string("jobs-c")])
    XCTAssertNil(try JSONEncoder().encode(output).range(of: Data("PRIVATE BODY".utf8)))
  }

  func testScanRejectsEveryUnsafePathBeforeLoadingLegacyBaseline() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    _ = try store.save(memoryId: "jobs-a", workflowId: "work", nodeId: "queue", tags: ["checkpoint"], payload: .object([:]))
    let path = root.appendingPathComponent("jobs-a.sqlite"), before = try Data(contentsOf: path)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("jobs-z.sqlite").path, withDestinationPath: "missing")
    await rejects("riela/snapshot-scan", scan(root))
    XCTAssertEqual(try Data(contentsOf: path), before)
  }

  func testStoredIntegerPredicateMatchesNumericMemoryWithoutRoundingLargeIDs() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    for (id, version) in [("jobs-a", 1.0), ("jobs-b", 2.0)] {
      _ = try store.save(memoryId: id, workflowId: "work", nodeId: "queue", tags: ["checkpoint"],
        payload: .object(["version": .number(version)]))
    }
    var config = scan(root)
    config["whereAny"] = .array([.object(["path": .string("/version"), "equals": .integer(1)])])
    let output = try await Self.run("riela/snapshot-scan", config)
    guard case let .array(items)? = output["items"] else { return XCTFail("missing items") }
    XCTAssertEqual(items.count, 1)
    guard case let .object(row) = items[0] else { return XCTFail("missing row") }
    XCTAssertEqual(row["memoryId"], .string("jobs-a"))
    config["whereAny"] = .array([.object(["path": .string("/version"), "equals": .integer(9_007_199_254_740_993)])])
    await rejects("riela/snapshot-scan", config)
  }

  func testScanRefusesBoundsMalformedFlagsAndProjectionWithoutReturningPartial() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    for id in ["jobs-a", "jobs-b"] {
      _ = try store.save(memoryId: id, workflowId: "work", nodeId: "queue", tags: ["checkpoint"], payload: .object(["pending": .string("true")]))
    }
    var config = scan(root); config["maxDatabases"] = .integer(1)
    await rejects("riela/snapshot-scan", config)
    config = scan(root); config["whereAny"] = .array([.object(["path": .string("/pending"), "equals": .bool(true)])])
    await rejects("riela/snapshot-scan", config)
    config = scan(root); config["valueFrom"] = .string("/absent")
    await rejects("riela/snapshot-scan", config)
  }

  func testEmptyScanCreatesNothingAndInvalidPointersOrDeadlineFailBeforeIO() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = try await Self.run("riela/snapshot-scan", scan(root))
    XCTAssertEqual(empty["items"], .array([]))
    var invalid = scan(root); invalid["valueFrom"] = .string("/bad~2")
    await rejects("riela/snapshot-scan", invalid)
    await rejects("riela/snapshot-scan", scan(root), context: .init(deadline: Date.distantPast))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testRotationContinuesLegacyCursorSkipsRemovedItemsAndNeverAcknowledges() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    _ = try store.save(memoryId: "turn", workflowId: "work", nodeId: "queue", tags: ["checkpoint"], payload: .object([
      "version": .number(1), "state": .object(["after_id": .string("b"), "unchanged": .string("opaque")]), "records": .array([])]))
    var config = rotate(root, ids: ["a", "c", "d"], maximum: 2)
    let first = try await Self.run("riela/snapshot-rotate", config)
    XCTAssertEqual(first["items"], .array([.string("c"), .string("d")]))
    config["maximum"] = .integer(1)
    let second = try await Self.run("riela/snapshot-rotate", config)
    XCTAssertEqual(second["items"], .array([.string("a")]))
    let saved = try XCTUnwrap(store.loadSnapshot(memoryId: "turn", workflowId: "work", nodeId: "queue", tag: "checkpoint"))
    XCTAssertEqual(saved.record.payload, .object(["version": .number(1), "state": .object(["after_id": .string("a"), "unchanged": .string("opaque")]), "records": .array([])]))
  }

  func testConcurrentReservationsPersistDistinctPrefixes() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let config = rotate(root, ids: ["a", "b", "c", "d"], maximum: 1)
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<4 {
        group.addTask {
          let output = try await Self.run("riela/snapshot-rotate", config)
          guard case let .string(value)? = output["after"] else { throw NSError(domain: "test", code: 1) }
          return value
        }
      }
      var result: [String] = []; for try await id in group { result.append(id) }; return result
    }
    XCTAssertEqual(Set(ids), Set(["a", "b", "c", "d"]))
  }

  func testRotationUsesExactUTF8IDsAndBoundsBeforeAnyMutation() async throws {
    let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
    let config = rotate(root, ids: ["é", "e\u{301}", "a"], maximum: 3)
    let output = try await Self.run("riela/snapshot-rotate", config)
    XCTAssertEqual(output["items"], .array([.string("a"), .string("e\u{301}"), .string("é")]))
    let path = root.appendingPathComponent("turn.sqlite"), before = try Data(contentsOf: path)
    var invalid = config; invalid["items"] = .array([.string("a"), .string("a")])
    await rejects("riela/snapshot-rotate", invalid)
    invalid = config; invalid["context"] = .string(String(repeating: "x", count: 8_000_000))
    await rejects("riela/snapshot-rotate", invalid)
    await rejects("riela/snapshot-rotate", config, context: .init(deadline: .distantPast))
    XCTAssertEqual(try Data(contentsOf: path), before)
  }

  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); return root
  }
  private func storage(_ root: URL) -> JSONObject {
    ["memoryId": .string("turn"), "workflowId": .string("work"), "nodeId": .string("queue"), "memoryRoot": .string(root.path)]
  }
  private func scan(_ root: URL) -> JSONObject {
    var value = storage(root); value.removeValue(forKey: "memoryId"); value["memoryPrefix"] = .string("jobs-")
    return ["storage": .object(value)]
  }
  private func rotate(_ root: URL, ids: [String], maximum: Int64) -> JSONObject {
    ["storage": .object(storage(root)), "items": .array(ids.map(JSONValue.string)), "maximum": .integer(maximum),
      "cursorPointer": .string("/state/after_id"), "initialValue": .object(["version": .integer(1), "state": .object([:]), "records": .array([])])]
  }
  private static func run(_ name: String, _ config: JSONObject, context: AdapterExecutionContext = .init()) async throws -> JSONObject {
    let input = WorkflowAddonExecutionInput(workflowId: "caller", stepId: "select", nodeId: "select",
      addon: .init(name: name, version: "1", config: config), variables: [:])
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: context).payload
  }
  private func rejects(_ name: String, _ config: JSONObject, context: AdapterExecutionContext = .init()) async {
    do { _ = try await Self.run(name, config, context: context); XCTFail("invalid work metadata accepted") } catch {}
  }
}
