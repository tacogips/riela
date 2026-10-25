import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class WriteIntentStoreAddonTests: XCTestCase {
  func testLiteralSourceTextAndExactReferenceSurviveFreshResolver() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage: JSONValue = .object(["rootDirectory": .string(root.path), "storeId": .string("intents"), "scope": .string("a")])
    let literal = #"{"n":1.0,"source":"{{notAnInstruction}}"}"#
    let staged = try await run(["action": .string("stage"), "storage": storage, "key": .string("target"),
      "serializedJSON": .string("{{request.payload}}"), "selectedReference": .null],
      payload: ["request": .object(["payload": .string(literal)])])
    let ref = try XCTUnwrap(staged.payload["reference"])
    let loaded = try await run(["action": .string("load"), "storage": storage, "reference": ref])
    XCTAssertEqual(loaded.payload["found"], .bool(true))
    XCTAssertEqual(loaded.payload["serializedJSON"], .string(literal))
    do {
      _ = try await run(["action": .string("clear"), "storage": storage, "released": .bool(false)])
      XCTFail("unreleased pointer must be rejected")
    } catch { }
    let preserved = try await run(["action": .string("load"), "storage": storage, "reference": ref])
    XCTAssertEqual(preserved.payload["found"], .bool(true))
    _ = try await run(["action": .string("clear"), "storage": storage, "released": .bool(true)])
    let cleared = try await run(["action": .string("load"), "storage": storage, "reference": ref])
    XCTAssertEqual(cleared.payload["found"], .bool(false))
  }

  func testUnknownFieldsAndForeignOwnerAreRejectedWithoutChangingTarget() async throws {
    let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let storage: JSONValue = .object(["rootDirectory": .string(root.path), "storeId": .string("intents"), "scope": .string("a")])
    let stage: JSONObject = ["action": .string("stage"), "storage": storage, "key": .string("target"),
      "serializedJSON": .string("{}"), "selectedReference": .null]
    let result = try await run(stage); let ref = try XCTUnwrap(result.payload["reference"])
    var bad = stage; bad["unexpected"] = .bool(true)
    do { _ = try await run(bad); XCTFail("unknown field accepted") } catch { }
    let foreign: JSONValue = .object(["rootDirectory": .string(root.path), "storeId": .string("intents"), "scope": .string("b")])
    do { _ = try await run(["action": .string("load"), "storage": foreign, "reference": ref]); XCTFail("foreign owner accepted") } catch { }
    let loaded = try await run(["action": .string("load"), "storage": storage, "reference": ref])
    XCTAssertEqual(loaded.payload["serializedJSON"], .string("{}"))
  }

  private func run(_ config: JSONObject, payload: JSONObject = [:]) async throws -> AdapterExecutionOutput {
    try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      .init(workflowId: "test-intents", stepId: "intent", nodeId: "intent",
        addon: .init(name: "riela/write-intent-store", version: "1", config: config), resolvedInputPayload: payload),
      context: .init())
  }
}
