import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class ChatAddonPayloadBoundsTests: XCTestCase {
  func testRepeatedReplyHopsForwardApplicationDataWithoutReplicatingRuntimeHistory() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    var previous: JSONObject = ["replyText": .string("hello"), "custom": .object(["retain": .bool(true)])]
    var outputs: [JSONValue] = []
    for hop in 0 ..< 40 {
      var input = previous
      input["_rielaInput"] = .object([
        "latest": .object(["payload": .object(previous)]),
        "messages": .array([.object(["payload": .object(previous)])])
      ])
      input["upstream"] = .array(outputs)
      input["runtime"] = .object(["executedStepIds": .array((0 ..< hop).map { .string("step-\($0)") })])
      let output = try await resolver.execute(WorkflowAddonExecutionInput(
        workflowId: "bounded-reply", stepId: "reply-\(hop)", nodeId: "reply",
        addon: WorkflowNodeAddonRef(name: "riela/chat-reply-worker", version: "1", config: ["textTemplate": .string("{{replyText}}")]),
        resolvedInputPayload: input
      ), context: AdapterExecutionContext())
      XCTAssertNil(output.payload["_rielaInput"])
      XCTAssertNil(output.payload["upstream"])
      XCTAssertNil(output.payload["runtime"])
      XCTAssertEqual(output.payload["custom"], .object(["retain": .bool(true)]))
      let encoded = try JSONEncoder().encode(output.payload)
      guard encoded.count < 1024 else { return XCTFail("Reply output must be bounded independently of history length") }
      previous = output.payload
      outputs.append(.object(output.payload))
    }
    XCTAssertLessThan(try JSONEncoder().encode(outputs).count, 40 * 1024)
  }

  func testMemoryWriteUsesInputIdentityButNeverPersistsInputHistoryAsOutput() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/specialist-supervisor/bounded-memory/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(WorkflowAddonExecutionInput(
      workflowId: "bounded-memory", stepId: "write", nodeId: "write",
      addon: WorkflowNodeAddonRef(name: "riela/chat-persona-memory-write", version: "1", config: [
        "personaId": .string("yui"), "memoryRoot": .string(root.path)
      ]), resolvedInputPayload: [
        "replyText": .string("hello"), "custom": .bool(true),
        "_rielaInput": .object(["workflowExecutionId": .string("session"), "sourceStepExecutionId": .string("source")]),
        "upstream": .array([.object(["payload": .string(String(repeating: "x", count: 64_000))])]),
        "runtime": .object(["executedStepIds": .array([])])
      ]
    ), context: AdapterExecutionContext())
    XCTAssertEqual(output.payload["custom"], .bool(true))
    XCTAssertNil(output.payload["_rielaInput"])
    XCTAssertNil(output.payload["upstream"])
    XCTAssertNil(output.payload["runtime"])
    XCTAssertLessThan(try JSONEncoder().encode(output.payload).count, 4096)
  }
}
