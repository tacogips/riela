import Foundation
import RielaCore
import RielaMemory
import XCTest
@testable import RielaCLI

final class WorkerMetadataSelectionTests: XCTestCase {
  func testScopeExclusionsCurrentDayAndAttemptOrderSelectOneFairTurn() throws {
    func row(_ id: String, _ day: String, _ source: String, _ attempt: String = "") -> JSONValue {
      .object(["id": .string(id), "day": .string(day), "source": .string(source), "attempt": .string(attempt)])
    }
    let config: JSONObject = ["items": .array([
      row("history", "24", "mail"), row("excluded", "25", "mail"), row("mail", "25", "mail", "later"),
      row("x", "25", "x"), row("feed", "25", "feed")]),
      "whereAll": .array([.object(["path": .string("/id"), "notIn": .array([.string("excluded")])])]),
      "sortBy": .array([.object(["path": .string("/day"), "rank": .array([.string("25")])]),
        .object(["path": .string("/attempt")]), .object(["path": .string("/source"), "rank": .array([.string("mail"), .string("x")])])]), "limit": .integer(1)]
    let result = try ArrayMetadataSelection.select(config)
    XCTAssertEqual(result["items"], .array([row("x", "25", "x")]))
    XCTAssertEqual(result["matchedCount"], .integer(4))
  }

  func testExactUTF8MembershipStableTiesAndMissingSortDefault() throws {
    let first: JSONValue = .object(["id": .string("e\u{301}"), "source": .string("other")])
    let second: JSONValue = .object(["id": .string("é"), "source": .string("other")])
    var config: JSONObject = ["items": .array([first, second]), "sortBy": .array([
      .object(["path": .string("/attempt"), "default": .string("")]),
      .object(["path": .string("/source"), "rank": .array([.string("mail")])])])]
    XCTAssertEqual(try ArrayMetadataSelection.select(config)["items"], .array([first, second]))
    config["whereAll"] = .array([.object(["path": .string("/id"), "in": .array([.string("é")])])])
    XCTAssertEqual(try ArrayMetadataSelection.select(config)["items"], .array([second]))
  }

  func testInvalidRulesAndRequiredFieldsNeverBecomeSuccessfulEmptySelection() throws {
    let invalid: [JSONObject] = [
      ["items": .array([]), "whereAll": .array([.object(["path": .string("/bad~2"), "equals": .string("x")])])],
      ["items": .array([]), "sortBy": .array([.object(["path": .string("/id"), "rank": .array([.string("x"), .string("x")])])])],
      ["items": .array([.object([:])]), "whereAll": .array([.object(["path": .string("/id"), "notIn": .array([])])])],
      ["items": .array([]), "limit": .integer(-1)]
    ]
    for config in invalid { XCTAssertThrowsError(try ArrayMetadataSelection.select(config)) }
    XCTAssertThrowsError(try ArrayMetadataSelection.select(["items": .array([])], context: .init(deadline: .distantPast)))
  }

  func testCLISelectionResolvesLiteralMetadataOnlyOnce() async throws {
    let items: JSONValue = .array([.object(["id": .string("{{literal}}")])])
    let rules: JSONValue = .array([.object(["path": .string("/id"), "equals": .string("{{literal}}")])])
    let config: JSONObject = ["items": .string("{{jobs}}"), "whereAll": .string("{{rules}}"), "limit": .integer(1)]
    let result = await RielaCLIApplication().run(["node", "run", "riela/array-select", "--config",
      try JSONValue.object(config).compactJSONString(), "--variables", try JSONValue.object(["jobs": items, "rules": rules]).compactJSONString(), "--output", "json"],
      environment: ["PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["items"], items)
  }

  func testExplicitSnapshotSetReturnsPresenceWithoutLargePublicationBodyOrUnrelatedFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaMemoryStore(rootDirectory: root.path)
    for (id, pending) in [("day-a", MemoryJSONValue.object(["body": .string(String(repeating: "PRIVATE BODY", count: 800_000))])), ("day-b", .null)] {
      _ = try store.save(memoryId: id, workflowId: "publish", nodeId: "write", tags: ["checkpoint"], payload: .object(["state": .object(["pending": pending])]))
    }
    try Data("not a database".utf8).write(to: root.appendingPathComponent("unrelated.sqlite"))
    let result = try await scan(root, ids: ["day-b", "missing", "day-a"])
    guard case let .array(items)? = result["items"] else { return XCTFail("missing items") }
    XCTAssertEqual(items.count, 2); XCTAssertEqual(result["scannedCount"], .integer(3))
    let flags = try items.map { item -> JSONValue in
      guard case let .object(row) = item, let value = row["value"] else { throw NSError(domain: "test", code: 1) }; return value
    }
    XCTAssertEqual(flags, [.object(["pending": .bool(true)]), .object(["pending": .bool(false)])])
    XCTAssertLessThan(try JSONEncoder().encode(result).count, 1000)
  }

  func testWholeExplicitSetPreflightAndMissingDirectoryNeverMutateEarlierSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let absent = try await scan(root, ids: ["missing"])
    XCTAssertEqual(absent["items"], .array([])); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    let store = RielaMemoryStore(rootDirectory: root.path)
    _ = try store.save(memoryId: "day-a", workflowId: "publish", nodeId: "write", tags: ["checkpoint"], payload: .object([:]))
    let file = root.appendingPathComponent("day-a.sqlite"), before = try Data(contentsOf: file)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("day-z.sqlite").path, withDestinationPath: "missing")
    for ids in [["day-a", "day-z"], ["day-a", "../escape"], ["day-a", "day-a"]] {
      do { _ = try await scan(root, ids: ids); XCTFail("unsafe explicit set accepted") } catch {}
    }
    XCTAssertEqual(try Data(contentsOf: file), before)
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("DAY-A.sqlite").path) {
      do { _ = try await scan(root, ids: ["day-a", "DAY-A"]); XCTFail("case alias counted as independent memory") } catch {}
    } else {
      let distinct = try await scan(root, ids: ["day-a", "DAY-A"])
      guard case let .array(items)? = distinct["items"] else { return XCTFail("missing result") }; XCTAssertEqual(items.count, 1)
    }
    do { _ = try await scan(file, ids: ["missing"]); XCTFail("regular-file directory accepted") } catch {}
  }

  func testPublicationEnvelopeValidationRefusesMalformedHeadsBeforePresenceCanClearBarrier() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let schema: JSONObject = ["type": .string("object"), "required": .array([.string("version"), .string("state"), .string("records")]),
      "properties": .object(["version": .object(["type": .string("integer"), "const": .integer(1)]),
        "state": .object(["type": .string("object")]), "records": .object(["type": .string("array")])])]
    let store = RielaMemoryStore(rootDirectory: root.path)
    let values: [MemoryJSONValue] = [.object(["version": .number(1), "state": .object([:]), "records": .array([])]),
      .object(["version": .number(2), "state": .object([:]), "records": .array([])]),
      .object(["version": .number(1), "state": .null, "records": .array([])]), .object(["state": .object([:])])]
    for (index, value) in values.enumerated() {
      let id = "head-\(index)"
      _ = try store.save(memoryId: id, workflowId: "publish", nodeId: "write", tags: ["checkpoint"], payload: value)
      if index == 0 {
        let result = try await scan(root, ids: [id], schema: schema)
        guard case let .array(items)? = result["items"] else { return XCTFail("missing result") }; XCTAssertEqual(items.count, 1)
      } else {
        do { _ = try await scan(root, ids: [id], schema: schema); XCTFail("malformed publication barrier accepted") } catch {}
      }
    }
  }

  private func scan(_ root: URL, ids: [String], schema: JSONObject? = nil) async throws -> JSONObject {
    var config: JSONObject = ["storage": .object(["memoryIds": .array(ids.map(JSONValue.string)), "workflowId": .string("publish"),
      "nodeId": .string("write"), "memoryRoot": .string(root.path)]), "presence": .object(["pending": .string("/state/pending")]), "maxPayloadBytes": .integer(16_000_000)]
    if let schema { config["valueSchema"] = .object(schema) }
    let input = WorkflowAddonExecutionInput(workflowId: "caller", stepId: "scan", nodeId: "scan",
      addon: .init(name: "riela/snapshot-scan", version: "1", config: config), variables: [:])
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(input, context: .init()).payload
  }
}
