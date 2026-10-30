import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class DurableQueueTests: XCTestCase {
  private func config(_ action: String, _ values: JSONObject = [:]) -> JSONObject {
    ["action": .string(action), "storage": .object([:])].merging(values) { _, value in value }
  }

  func testFixedScopeRearmFairnessAndPartialDoesNotComplete() throws {
    var state: JSONObject = ["version": .integer(1), "requests": .object([:])]
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    @discardableResult func run(_ action: String, _ values: JSONObject = [:], offset: Double = 0) throws -> JSONObject {
      let pair = try DurableQueue.apply(config(action, values), state: state, date: date.addingTimeInterval(offset))
      state = pair.0; return pair.1
    }
    let scope: JSONValue = .object(["start": .string("fixed"), "end": .string("frozen")])
    for key in ["b", "a"] { try run("admit", ["identity": .string(key), "request": scope]) }
    XCTAssertEqual(try run("pending")["identity"], .string("a"))
    try run("attempted", ["identity": .string("a")], offset: 1)
    XCTAssertEqual(try run("pending")["identity"], .string("b"))
    try run("finish", ["identity": .string("a"), "complete": .bool(false), "status": .string("partial")])
    try run("finish", ["identity": .string("b"), "complete": .bool(true), "status": .string("partial")])
    XCTAssertEqual(try run("pending")["identity"], .string("a"))
    try run("finish", ["identity": .string("a"), "complete": .bool(true), "status": .string("ok")])
    XCTAssertEqual(try run("pending")["found"], .bool(false))
    try run("admit", ["identity": .string("a"), "request": scope])
    XCTAssertEqual(try run("pending")["request"], scope)
    XCTAssertThrowsError(try run("admit", ["identity": .string("a"), "request": .object(["start": .string("changed")])]))
  }

  func testLegacyJournalKeepsMetadataAndOrdersInstantsNotTimestampSpellings() throws {
    let legacy: JSONObject = ["version": .integer(1), "requests": .object([
      "a": .object(["request": .object([:]), "status": .string("acquired"), "attempts": .integer(2),
        "registered_at": .string("2026-10-21T07:00:00.123456+00:00"), "acquisition_complete": .bool(true)]),
      "b": .object(["request": .object([:]), "status": .string("pending"), "attempts": .integer(0),
        "registered_at": .string("2026-10-21T10:00:00+09:00")]),
      "c": .object(["request": .object([:]), "status": .string("pending"), "attempts": .integer(0),
        "registered_at": .string("2026-10-21T02:00:00Z")])])]
    let pair = try DurableQueue.apply(config("pending"), state: legacy, date: Date())
    XCTAssertEqual(pair.1["identity"], .string("b")); XCTAssertEqual(pair.0, legacy)
    XCTAssertThrowsError(try DurableQueue.apply(config("attempted", ["identity": .string("unknown")]), state: legacy, date: Date()))
    XCTAssertThrowsError(try DurableQueue.validateOperation(config("pending", ["private": .string("refuse")])) )
    let reopened = try DurableQueue.apply(config("admit", ["identity": .string("a"), "request": .object([:])]), state: legacy, date: Date()).0
    let finished = try DurableQueue.apply(config("finish", ["identity": .string("a"), "complete": .bool(false),
      "status": .string("partial"), "completionField": .string("acquisition_complete")]), state: reopened, date: Date()).0
    guard case let .object(rows)? = finished["requests"], case let .object(row)? = rows["a"] else { return XCTFail("row") }
    XCTAssertEqual(row["acquisition_complete"], .bool(false)); XCTAssertEqual(row["status"], .string("pending"))
    XCTAssertThrowsError(try DurableQueue.validateOperation(config("finish", ["identity": .string("a"), "complete": .bool(false),
      "status": .string("partial"), "completionField": .string("request")])))
  }

  func testJournalPersistsAcrossInstancesAndRejectsUnsafeFilesWithoutChangingThem() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/queue-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func run(_ action: String, _ values: JSONObject = [:]) throws -> JSONObject {
      try DurableQueueJournal.transaction(directory: root, name: "queue", readOnly: action == "pending", context: .init()) {
        try DurableQueue.apply(config(action, values), state: $0, date: Date())
      }
    }
    XCTAssertEqual(try run("pending")["found"], .bool(false))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    _ = try run("admit", ["identity": .string("one"), "request": .object(["scope": .string("fixed")])])
    XCTAssertEqual(try run("pending")["identity"], .string("one"))
    let file = root.appendingPathComponent("queue.json")
    let bytes = try Data(contentsOf: file)
    let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let target = root.appendingPathComponent("original")
    try FileManager.default.moveItem(at: file, to: target)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
    XCTAssertThrowsError(try run("attempted", ["identity": .string("one")]))
    XCTAssertEqual(try Data(contentsOf: target), bytes)
    try FileManager.default.removeItem(at: file)
    try FileManager.default.linkItem(at: target, to: file)
    XCTAssertThrowsError(try run("pending"))
    XCTAssertEqual(try Data(contentsOf: target), bytes)
  }

  func testCanonicalTemporaryDirectoryDoesNotCollapseIntoSymlinkAlias() throws {
    var temporary = FileManager.default.temporaryDirectory.path
    #if os(macOS)
    if temporary.hasPrefix("/var/") { temporary = "/private" + temporary }
    #endif
    let root = URL(fileURLWithPath: temporary).appendingPathComponent("queue-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try DurableQueueJournal.transaction(directory: root, name: "queue", readOnly: false, context: .init()) {
      try DurableQueue.apply(config("admit", ["identity": .string("a"), "request": .object([:])]), state: $0, date: Date())
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("queue.json").path))
  }

  func testRealResolverUsesLiteralJSONAndRejectsInvalidOperationBeforeIO() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/queue-resolver-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root)
    var value = config("admit", ["identity": .string("a"), "request": .object(["literal": .string("fixed")])])
    value["storage"] = .object(["directory": .string(root.path), "name": .string("queue")])
    let request: JSONValue = .object(["literal": .string("{{notInterpolation}}")])
    value["request"] = .string("{{requestValue}}")
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "queue", nodeId: "queue", addon: .init(name: "riela/durable-queue", version: "1", config: value), variables: ["requestValue": request])
    let result = try await resolver.execute(input, context: .init())
    XCTAssertEqual(result.payload["identity"], .string("a"))
    let file = root.appendingPathComponent("queue.json")
    let original = try Data(contentsOf: file)
    let state = try JSONDecoder().decode(JSONObject.self, from: original)
    guard case let .object(rows)? = state["requests"], case let .object(row)? = rows["a"] else { return XCTFail("journal") }
    XCTAssertEqual(row["request"], request)
    var invalid = value; invalid["status"] = .string("unexpected")
    let bad = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "queue", nodeId: "queue", addon: .init(name: "riela/durable-queue", version: "1", config: invalid), variables: ["requestValue": request])
    do { _ = try await resolver.execute(bad, context: .init()); XCTFail("extra input accepted") } catch {}
    XCTAssertEqual(try Data(contentsOf: file), original)
    do {
      _ = try await resolver.execute(input, context: .init(deadline: Date().addingTimeInterval(-1)))
      XCTFail("expired request accepted")
    } catch {}
    XCTAssertEqual(try Data(contentsOf: file), original)
  }
  func testPendingOptionsOrderingAndExhaustion() throws {
    func row(_ attempts: Int64, _ attempted: String? = nil, status: String = "pending") -> JSONValue {
      var value: JSONObject = ["request": .object([:]), "status": .string(status), "attempts": .integer(attempts),
        "registered_at": .string("2026-01-01T00:00:00Z")]
      if let attempted { value["last_attempt_at"] = .string(attempted) }
      return .object(value)
    }
    let state: JSONObject = ["version": .integer(1), "requests": .object([
      "z": row(2, "2026-01-02T00:00:00Z"), "a": row(5, "2026-01-03T00:00:00Z"),
      "b": row(0), "done": row(5, status: "completed")])]
    func pending(_ options: JSONObject = [:]) throws -> JSONObject {
      let pair = try DurableQueue.apply(config("pending", options), state: state, date: Date())
      XCTAssertEqual(pair.0, state)
      return pair.1
    }
    let plain = try pending()
    XCTAssertEqual(Set(plain.keys), Set(["found", "identity", "request"]))
    XCTAssertEqual(plain["identity"], .string("b"))
    let limited = try pending(["limit": .integer(2)])
    XCTAssertEqual(limited["items"], .array([
      .object(["identity": .string("b"), "request": .object([:]), "attempts": .integer(0)]),
      .object(["identity": .string("z"), "request": .object([:]), "attempts": .integer(2)])]))
    XCTAssertEqual(limited["itemsTruncated"], .bool(false))
    guard case let .array(all)? = try pending(["limit": .integer(10)])["items"] else { return XCTFail("items") }
    XCTAssertEqual(all.count, 3)
    let capped = try pending(["maxAttempts": .integer(2), "limit": .integer(10)])
    XCTAssertEqual(capped["identity"], .string("b"))
    XCTAssertEqual(capped["items"], .array([.object(["identity": .string("b"), "request": .object([:]), "attempts": .integer(0)])]))
    XCTAssertEqual(capped["exhausted"], .array([.object(["identity": .string("a"), "attempts": .integer(5)]),
      .object(["identity": .string("z"), "attempts": .integer(2)])]))
    XCTAssertEqual(capped["exhaustedCount"], .integer(2))
    let exhaustedState: JSONObject = ["version": .integer(1), "requests": .object(["a": row(2)])]
    let empty = try DurableQueue.apply(config("pending", ["maxAttempts": .integer(2)]), state: exhaustedState, date: Date()).1
    XCTAssertEqual(empty["found"], .bool(false)); XCTAssertEqual(empty["identity"], .null); XCTAssertEqual(empty["request"], .null)
    XCTAssertEqual(empty["exhaustedCount"], .integer(1))
  }

  func testPendingOptionValidationAndSizeBound() throws {
    for options: JSONObject in [["limit": .integer(0)], ["limit": .integer(101)], ["limit": .string("2")],
      ["limit": .number(2.0)], ["maxAttempts": .integer(0)], ["maxAttempts": .integer(1_000_000_001)],
      ["maxAttempts": .string("2")]] {
      XCTAssertThrowsError(try DurableQueue.validateOperation(config("pending", options)))
    }
    for action in ["admit", "attempted", "finish"] {
      var values: JSONObject = ["identity": .string("a"), "limit": .integer(1), "maxAttempts": .integer(1)]
      if action == "admit" { values["request"] = .object([:]) }
      if action == "finish" { values["complete"] = .bool(true); values["status"] = .string("ok") }
      XCTAssertThrowsError(try DurableQueue.validateOperation(config(action, values)))
      values.removeValue(forKey: "limit")
      XCTAssertThrowsError(try DurableQueue.validateOperation(config(action, values)))
    }
    var rows: JSONObject = [:]
    for index in 0..<40 {
      rows[String(format: "%02d", index)] = .object(["request": .object(["data": .string(String(repeating: "x", count: 260_000))]),
        "status": .string("pending"), "attempts": .integer(0), "registered_at": .string("2026-01-01T00:00:00Z")])
    }
    let result = try DurableQueue.apply(config("pending", ["limit": .integer(40)]),
      state: ["version": .integer(1), "requests": .object(rows)], date: Date()).1
    guard case let .array(items)? = result["items"] else { return XCTFail("items") }
    XCTAssertGreaterThan(items.count, 0); XCTAssertLessThan(items.count, 40)
    XCTAssertEqual(result["itemsTruncated"], .bool(true))
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(result).count, DurableQueueJournal.maximumBytes)
  }

  func testPendingOptionsOnAbsentDirectoryThroughResolver() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tmp/queue-absent-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:], workingDirectory: root)
    let value: JSONObject = ["storage": .object(["directory": .string(root.path), "name": .string("queue")]),
      "action": .string("pending"), "limit": .integer(2)]
    let input = WorkflowAddonExecutionInput(workflowId: "fixture", stepId: "queue", nodeId: "queue",
      addon: .init(name: "riela/durable-queue", version: "1", config: value), variables: [:])
    let result = try await resolver.execute(input, context: .init())
    XCTAssertEqual(result.payload["found"], .bool(false)); XCTAssertEqual(result.payload["items"], .array([]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

}
