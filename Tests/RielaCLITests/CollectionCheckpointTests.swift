import Foundation
import RielaCore
import RielaAddons
import XCTest
@testable import RielaCLI

final class CollectionCheckpointTests: XCTestCase {
  func testRestartKeepsPendingVersionsWhileNextPageAdvances() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try await Self.run(root, "record", revision: 0, items: [Self.item("a", "1")], cursor: .string("page2"))
    XCTAssertEqual(first["pendingCount"], .integer(1))
    // A separate resolver instance reads the durable checkpoint. No pending
    // publication is required before acquiring the second page.
    let loaded = try await Self.run(root, "load")
    XCTAssertEqual(loaded["cursor"], .string("page2"))
    let second = try await Self.run(root, "record", revision: 1, items: [Self.item("b", "1")], cursor: .null, complete: true)
    XCTAssertEqual(second["acquisitionComplete"], .bool(true))
    XCTAssertEqual(second["processingComplete"], .bool(false))
    XCTAssertEqual(second["pendingCount"], .integer(2))
    let ack = try await Self.run(root, "acknowledge", revision: 2, items: [Self.item("a", "1")])
    XCTAssertEqual(ack["pending"], .array([Self.item("b", "1")]))
    // Exact version acknowledgement cannot remove a newer version of the ID.
    _ = try await Self.run(root, "record", revision: 3, items: [Self.item("a", "1"), Self.item("a", "2")], cursor: .null, complete: true)
    let repeated = try await Self.run(root, "acknowledge", revision: 4, items: [Self.item("a", "1")])
    XCTAssertEqual(repeated["pending"], .array([Self.item("b", "1"), Self.item("a", "2")]))
  }

  func testStaleAndUnknownAcknowledgementsLeaveCursorUntouched() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Self.run(root, "record", revision: 0, items: [Self.item("a", "1")], cursor: .string("next"))
    struct Attempt {
      var action: String
      var revision: Int64
      var items: [JSONValue]
      var cursor: JSONValue?
    }
    for attempt in [
      Attempt(action: "record", revision: 0, items: [Self.item("b", "1")], cursor: .string("stale")),
      Attempt(action: "acknowledge", revision: 1, items: [Self.item("a", "2")], cursor: nil)
    ] {
      do {
        _ = try await Self.run(root, attempt.action, revision: attempt.revision, items: attempt.items, cursor: attempt.cursor)
        XCTFail("invalid mutation accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
    let saved = try await Self.run(root, "load")
    XCTAssertEqual(saved["revision"], .integer(1))
    XCTAssertEqual(saved["cursor"], .string("next"))
    XCTAssertEqual(saved["pending"], .array([Self.item("a", "1")]))
  }

  func testSourcesAndWorkflowScopesAreIndependentAndStringsStayLiteral() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try await Self.run(root, "record", revision: 0, items: [Self.item("{{secret}}", "v")], cursor: .string("{{next}}"))
    for (key, workflow) in [("other-account", "collection-test"), ("account", "other-workflow")] {
      let other = try await Self.run(root, "load", key: key, workflow: workflow)
      XCTAssertEqual(other["revision"], .integer(0))
      XCTAssertEqual(other["pendingCount"], .integer(0))
    }
    let loaded = try await Self.run(root, "load")
    XCTAssertEqual(loaded["cursor"], .string("{{next}}"))
    XCTAssertEqual(loaded["pending"], .array([Self.item("{{secret}}", "v")]))
    XCTAssertTrue(RielaBuiltinAddonCatalog.supports(name: "riela/collection-checkpoint", version: "1"))
  }

  func testConcurrentPagesHaveExactlyOneCommit() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    // Both writers claim the same revision. Even if both read before writing,
    // the storage transaction admits exactly one complete cursor+pending pair.
    let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
      for index in 0..<8 {
        group.addTask {
          do {
            _ = try await Self.run(root, "record", revision: 0,
              items: [Self.item(String(index), "1")], cursor: .string(String(index)))
            return true
          } catch { return false }
        }
      }
      var count = 0
      for await success in group where success { count += 1 }
      return count
    }
    XCTAssertEqual(successes, 1)
    let saved = try await Self.run(root, "load")
    XCTAssertEqual(saved["revision"], .integer(1))
    guard case let .string(cursor)? = saved["cursor"] else { return XCTFail("missing cursor") }
    XCTAssertEqual(saved["pending"], .array([Self.item(cursor, "1")]))
  }

  func testRejectedMetadataAndDuplicatePairsDoNotAdvance() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    for items in [[Self.item("a", "1"), Self.item("a", "1")],
                  [.object(["id": .string("a"), "version": .string("1"), "body": .string("private")])],
                  [Self.item("", "1")]] {
      do {
        _ = try await Self.run(root, "record", revision: 0, items: items, cursor: .string("next"))
        XCTFail("invalid metadata accepted")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput) }
    }
    let saved = try await Self.run(root, "load")
    XCTAssertEqual(saved["revision"], .integer(0))
    XCTAssertEqual(saved["pending"], .array([]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }

  func testLongAcknowledgedIdentitiesCannotBlockLaterPages() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suffix = String(repeating: "x", count: 1000)
    let first = (0..<2000).map { Self.item("first-\($0)-" + suffix, suffix) }
    let second = (0..<2000).map { Self.item("second-\($0)-" + suffix, suffix) }
    _ = try await Self.run(root, "record", revision: 0, items: first, cursor: .string("page2"))
    _ = try await Self.run(root, "acknowledge", revision: 1, items: first)
    let recorded = try await Self.run(root, "record", revision: 2, items: second, cursor: .string("page3"))
    XCTAssertEqual(recorded["pending"], .array(second))
    let finished = try await Self.run(root, "acknowledge", revision: 3, items: second)
    XCTAssertEqual(finished["pendingCount"], .integer(0))
    let next = try await Self.run(root, "record", revision: 4, items: [Self.item("next", "1")], cursor: .null, complete: true)
    XCTAssertEqual(next["pending"], .array([Self.item("next", "1")]))
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(next).count, 8_001_000)
  }

  private static func item(_ id: String, _ version: String) -> JSONValue {
    .object(["id": .string(id), "version": .string(version)])
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("collection-checkpoint-" + UUID().uuidString)
  }

  private static func run(_ root: URL, _ action: String, revision: Int64? = nil, items: [JSONValue]? = nil,
                          cursor: JSONValue? = nil, complete: Bool = false, key: String = "account",
                          workflow: String = "collection-test") async throws -> JSONObject {
    var config: JSONObject = ["action": .string(action), "key": .string(key), "kvRoot": .string(root.path)]
    var values: JSONObject = [:]
    if let revision {
      config["expectedRevision"] = .string("{{input.revision}}")
      values["revision"] = .integer(revision)
    }
    if let items {
      config["items"] = .string("{{input.records}}")
      values["records"] = .array(items)
    }
    if let cursor {
      config["cursor"] = .string("{{input.cursor}}")
      values["cursor"] = cursor
      config["acquisitionComplete"] = .bool(complete)
    }
    let result = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(workflowId: workflow, stepId: "checkpoint", nodeId: "checkpoint",
        addon: .init(name: "riela/collection-checkpoint", version: "1", config: config), resolvedInputPayload: values),
      context: .init(deadline: Date().addingTimeInterval(30)))
    return result.payload
  }
}
