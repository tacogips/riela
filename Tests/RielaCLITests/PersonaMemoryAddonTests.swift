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

  func testPersonaMemoryWriteIsIdempotentPerStepExecution() async throws {
    let memoryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-persona-memory-idempotent-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: memoryRoot)
    }
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    func writeInput(sourceExecutionId: String) -> WorkflowAddonExecutionInput {
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
          "_rielaInput": .object([
            "workflowExecutionId": .string("session-1"),
            "sourceStepExecutionId": .string(sourceExecutionId)
          ]),
          "replyAs": .string("yui"),
          "replyText": .string("覚えておきますね。"),
          "memoryEntries": .array([
            .object([
              "kind": .string("user-instruction"),
              "importance": .string("high"),
              "content": .string("Release codename is AOZORA")
            ])
          ])
        ]
      )
    }

    let first = try await resolver.execute(
      writeInput(sourceExecutionId: "yui-codex-attempt-1-exec-3"),
      context: AdapterExecutionContext()
    )
    let firstMemory = try XCTUnwrap(jsonObject(first.payload["memory"]))
    XCTAssertEqual(firstMemory["entriesWritten"], .number(1))
    XCTAssertEqual(firstMemory["idempotentReplay"], .bool(false))
    let firstRecordIds = try XCTUnwrap(firstMemory["recordIds"])

    // Replaying the same step execution (resume/rerun, event redelivery) must
    // not append a second record and must report the original record ids.
    let replay = try await resolver.execute(
      writeInput(sourceExecutionId: "yui-codex-attempt-1-exec-3"),
      context: AdapterExecutionContext()
    )
    let replayMemory = try XCTUnwrap(jsonObject(replay.payload["memory"]))
    XCTAssertEqual(replayMemory["entriesWritten"], .number(1))
    XCTAssertEqual(replayMemory["idempotentReplay"], .bool(true))
    XCTAssertEqual(replayMemory["recordIds"], firstRecordIds)

    // A different source execution is a new conversation turn and appends.
    let second = try await resolver.execute(
      writeInput(sourceExecutionId: "yui-codex-attempt-1-exec-7"),
      context: AdapterExecutionContext()
    )
    let secondMemory = try XCTUnwrap(jsonObject(second.payload["memory"]))
    XCTAssertEqual(secondMemory["idempotentReplay"], .bool(false))
    XCTAssertNotEqual(secondMemory["recordIds"], firstRecordIds)

    let read = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-agent-trio-chat",
        stepId: "read-yui-memory",
        nodeId: "read-yui-memory",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-persona-memory-read",
          version: "1",
          config: [
            "personaId": .string("yui"),
            "memoryRoot": .string(memoryRoot.path),
            "limit": .number(10)
          ]
        ),
        resolvedInputPayload: [:]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(read.payload["memoryRecordCount"], .number(2))
  }

  private func jsonObject(_ value: JSONValue?) -> JSONObject? {
    guard case let .object(object)? = value else {
      return nil
    }
    return object
  }
}
