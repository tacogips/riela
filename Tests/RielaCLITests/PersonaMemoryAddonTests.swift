import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class PersonaMemoryAddonTests: XCTestCase {
  func testPersonaMemoryWriteBlocksSelfHandoffAndRemovesDanglingMention() async throws {
    let memoryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-persona-memory-addon-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
    }

    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-agent-trio-chat",
        stepId: "write-yui-memory",
        nodeId: "write-yui-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-persona-memory-write",
          version: "1",
          config: [
            "personaId": .string("yui"),
            "personaName": .string("Yui Codex"),
            "memoryRoot": .string(memoryRoot.path)
          ]
        ),
        resolvedInputPayload: [
          "replyAs": .string("yui"),
          "replyText": .string("続きは@Yuiが見るね。"),
          "handoff_yui": .bool(true),
          "memoryEntries": .array([
            .object([
              "kind": .string("note"),
              "importance": .string("normal"),
              "content": .string("The user asked for a Yui self handoff guard.")
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("では、肩の力を抜いて続けましょう。"))
    let guardPayload = try XCTUnwrap(jsonObject(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("current-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))

    let memory = try XCTUnwrap(jsonObject(output.payload["memory"]))
    XCTAssertEqual(memory["entriesWritten"], .number(1))
    XCTAssertEqual(memory["memoryRoot"], .string(memoryRoot.path))
  }

  private func jsonObject(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else {
      return nil
    }
    return object
  }
}
