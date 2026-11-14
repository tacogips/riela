import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NoteMemoryAddonHandoffTests: XCTestCase {
  func testBlocksHandoffBackToVisitedPersonaAndSanitizesReply() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論。ここで止める。@Yui はどう見る？"),
        "handoff_yui": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])]),
          .object(["payload": .object(["replyAs": .string("mika"), "replyText": .string("Mika reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.when["handoff_rina"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論。ここで止める。"))
    XCTAssertEqual(output.payload["autonomousTurns"], .number(3))
    let guardPayload = try XCTUnwrap(objectValue(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(true))
    XCTAssertEqual(guardPayload["reason"], .string("target-persona-already-replied"))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("yui"))
  }

  func testUsesRuntimeReplyStepsForHandoffTrail() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論。@Yui に戻す必要はない。"),
        "handoff_yui": .bool(true),
        "runtime": .object([
          "executedStepIds": .array([
            .string("route-message"),
            .string("send-yui-reply"),
            .string("send-mika-reply")
          ])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論。"))
    XCTAssertEqual(output.payload["handoffTrail"], .array([.string("yui"), .string("mika"), .string("rina")]))
    let guardPayload = try XCTUnwrap(objectValue(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["visitedPersonas"], .array([.string("yui"), .string("mika")]))
  }

  func testAllowsNextUnvisitedPersona() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "mika",
      personaName: "Mika Trend",
      resolvedInputPayload: [
        "replyText": .string("いいじゃん。@Rina はどう？"),
        "handoff_rina": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_rina"], true)
    let guardPayload = try XCTUnwrap(objectValue(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["blocked"], .bool(false))
    XCTAssertEqual(guardPayload["selectedTarget"], .string("rina"))
  }

  func testMultipleHandoffsUsePersonaPriority() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "yui",
      personaName: "Yui Codex",
      resolvedInputPayload: [
        "replyText": .string("Mikaに聞きます。"),
        "handoff_mika": .bool(true),
        "handoff_rina": .bool(true)
      ]
    )

    XCTAssertEqual(output.when["handoff_mika"], true)
    XCTAssertEqual(output.when["handoff_rina"], false)
  }

  func testBlocksSelfHandoffAndUsesPersonaFallback() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "yui",
      personaName: "Yui Codex",
      resolvedInputPayload: [
        "replyText": .string("続きは@Yuiが見るね。"),
        "handoff_yui": .bool(true)
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("では、肩の力を抜いて続けましょう。"))
    let guardPayload = try XCTUnwrap(objectValue(output.payload["handoffGuard"]))
    XCTAssertEqual(guardPayload["reason"], .string("current-persona-already-replied"))
  }

  func testMaximumTurnReplyRemovesContinuationWithoutHandoffFlag() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("結論: 妥当。要点は3点。次はミカの要点を受け取り、私の短評を返す。"),
        "handoff_mika": .bool(false),
        "handoff_yui": .bool(false),
        "runtime": .object([
          "executedStepIds": .array([.string("send-yui-reply"), .string("send-mika-reply")])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_mika"], false)
    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("結論: 妥当。要点は3点。"))
  }

  func testBlockedNonContinuationMentionRemainsVisible() async throws {
    let output = try await executePersonaMemoryWrite(
      personaId: "rina",
      personaName: "Rina Cursor",
      resolvedInputPayload: [
        "replyText": .string("Yuiの前提は正しい。ここで止める。"),
        "handoff_yui": .bool(true),
        "latestOutputs": .array([
          .object(["payload": .object(["replyAs": .string("yui"), "replyText": .string("Yui reply")])])
        ])
      ]
    )

    XCTAssertEqual(output.when["handoff_yui"], false)
    XCTAssertEqual(output.payload["replyText"], .string("Yuiの前提は正しい。ここで止める。"))
  }

  private func executePersonaMemoryWrite(
    personaId: String,
    personaName: String,
    resolvedInputPayload: JSONObject
  ) async throws -> AdapterExecutionOutput {
    let noteRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-note-memory-handoff-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: noteRoot) }
    let stepId = "write-\(personaId)-memory"
    return try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-agent-trio-chat",
        stepId: stepId,
        nodeId: stepId,
        addon: WorkflowNodeAddonRef(
          name: "riela/note-persona-memory-write",
          version: "1",
          config: [
            "personaId": .string(personaId),
            "personaName": .string(personaName),
            "memoryNamespace": .string("persona-chat-memory"),
            "noteRoot": .string(noteRoot.path)
          ]
        ),
        resolvedInputPayload: resolvedInputPayload
      ),
      context: AdapterExecutionContext()
    )
  }
}
