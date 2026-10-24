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
}
