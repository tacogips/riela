import XCTest
@testable import RielaCore

final class AskToolSetTests: XCTestCase {
  func testToolNamesAndRequiredLimits() throws {
    let names = [
      "session_list", "session_status", "session_progress", "session_health", "session_logs", "ops_overview",
      "bot_list", "bot_board", "bot_activity", "routine_list", "workflow_list", "workflow_inspect", "workflow_validate",
      "definition_history", "model_catalog", "remote_list", "propose_action", "propose_workflow"
    ]
    XCTAssertEqual(AskToolSet.all.map(\.name), names)
    XCTAssertEqual(try AskToolSet.validate(name: "session_list", arguments: [:]), ["limit": .integer(20)])
    XCTAssertEqual(
      try AskToolSet.validate(name: "session_logs", arguments: ["sessionId": .string("run")]),
      ["sessionId": .string("run"), "tail": .integer(80)]
    )
    XCTAssertEqual(try AskToolSet.validate(
      name: "bot_activity", arguments: ["sessionId": .string("run"), "afterSequence": .integer(0), "limit": .integer(100)]
    )["limit"], .integer(100))
  }

  func testRejectsUnknownToolAndInvalidArguments() {
    assertCode("tool_unknown", tool: "mutation", [:])
    assertCode("tool_arguments_invalid", tool: "session_logs", ["sessionId": .string("run"), "tail": .integer(500)])
    assertCode("tool_arguments_invalid", tool: "session_status", ["sessionId": .bool(true)])
    assertCode("tool_arguments_invalid", tool: "session_status", [:])
    assertCode("tool_arguments_invalid", tool: "session_status", ["sessionId": .string("run"), "remote": .string("other")])
    assertCode("tool_arguments_invalid", tool: "bot_activity", ["limit": .integer(1)])
    assertCode("tool_arguments_invalid", tool: "bot_activity", ["sessionId": .string("run"), "botId": .string("bot"), "limit": .integer(1)])
    assertCode("tool_arguments_invalid", tool: "bot_activity", ["botId": .string("bot"), "limit": .number(1.5)])
  }

  private func assertCode(_ code: String, tool: String, _ args: JSONObject, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try AskToolSet.validate(name: tool, arguments: args), file: file, line: line) {
      XCTAssertEqual(($0 as? AskError)?.code, code, file: file, line: line)
    }
  }
}
