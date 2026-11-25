import Foundation
import XCTest
@testable import RielaCore

final class ActivityContractTests: XCTestCase {
  func testEveryAdapterUpdateRoundTrips() throws {
    let updates: [AdapterActivityUpdate] = [
      .message(messageId: "message", text: "hello", replace: true),
      .thought(text: "considering"),
      .toolCall(.init(toolCallId: "tool", status: "pending")),
      .toolCall(.init(
        toolCallId: "tool", title: "Read", toolKind: "read", status: "completed",
        locations: [.init(path: "file", line: 9)]
      )),
      .plan(planId: "plan", entries: [.init(content: "read the file", status: "pending", priority: "high")]),
      .planRemoved(planId: "plan"),
      .mode(modeId: "read-only"),
      .commands(names: ["help"]),
      .configOptions(options: [["id": .string("model")]]),
      .sessionInfo(title: "session"),
      .usage(["inputTokens": .number(3)]),
      .notice(severity: "info", title: "ready", description: "ready to start"),
      .subagent(subSessionId: "agent", title: "helper", state: "running"),
      .stop(stopReason: "rate_limit", limited: true, limitedResetAt: Date(timeIntervalSince1970: 1_700_000_000)),
      .reportedModel("provider-model"),
      .other(updateKind: "new_kind")
    ]
    for update in updates {
      let encoded = try JSONEncoder().encode(update)
      XCTAssertEqual(try JSONDecoder().decode(AdapterActivityUpdate.self, from: encoded), update)
    }
    let event = AdapterBackendEvent(provider: "acp", eventType: "update", activity: updates.first)
    XCTAssertEqual(try JSONDecoder().decode(AdapterBackendEvent.self, from: JSONEncoder().encode(event)), event)
  }

  func testLegacyBackendEventWithoutActivityDecodes() throws {
    let json = Data(#"{"provider":"fixture","eventType":"message","isDelta":false}"#.utf8)
    let decoded = try JSONDecoder().decode(AdapterBackendEvent.self, from: json)
    XCTAssertEqual(decoded, AdapterBackendEvent(provider: "fixture", eventType: "message"))
    XCTAssertNil(decoded.activity)
  }

  func testRoutineWithoutBotIdDecodes() throws {
    let json = Data(
      """
      {
        "routineId":"daily","name":"Daily","task":"check","schedule":"0 0 0 * * *","workflowName":"check",
        "status":"active","createdAt":"2023-11-14T22:13:20.000Z","updatedAt":"2023-11-14T22:13:20.000Z",
        "runCount":0,"eventRoot":"events","sourceId":"source","bindingId":"binding","deactivateWorkflowOnCompletion":false
      }
      """.utf8
    )
    let routine = try JSONDecoder().decode(RoutineRecord.self, from: json)
    XCTAssertEqual(routine.routineId, "daily")
    XCTAssertNil(routine.botId)
  }
}
