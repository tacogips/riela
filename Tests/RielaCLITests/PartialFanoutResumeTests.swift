import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class PartialFanoutResumeTests: XCTestCase {
  func testResumeRecoversBudgetLimitedChildAndFailedSiblingWithoutRepeatingCommands() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/partial-fanout-resume/" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions")
    let sessions = root.appendingPathComponent("sessions")
    let attempts = root.appendingPathComponent("attempts.txt")
    func write(_ name: String, _ value: [String: Any]) throws {
      let path = definitions.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: value).write(to: path)
    }
    let command = #"cat >/dev/null; printf '%s\n' "$1" >> "$2"; if [ "$1" = 0 ]; then exit 1; fi; printf '%s\n' '{"safe_ids":["healthy"]}'"#
    try write("child/nodes/inspect.json", ["id": "inspect", "nodeType": "command", "variables": [:],
      "command": ["executable": "/bin/sh", "arguments": ["-c", command, "probe", "{{fanoutIndex}}", attempts.path]]])
    try write("child/workflow.json", ["workflowId": "child", "entryStepId": "inspect",
      "defaults": ["nodeTimeoutMs": 30000, "maxLoopIterations": 1],
      "nodes": [["id": "inspect", "nodeFile": "nodes/inspect.json"],
        ["id": "finish", "addon": ["name": "riela/json-compose", "version": "1", "config": ["payload": "{{input}}"]]]],
      "steps": [["id": "inspect", "nodeId": "inspect", "transitions": [["toStepId": "finish"]]],
        ["id": "finish", "nodeId": "finish"]]])
    try write("parent/workflow.json", ["workflowId": "parent", "entryStepId": "batch",
      "defaults": ["nodeTimeoutMs": 30000, "maxLoopIterations": 1],
      "nodes": [
        ["id": "batch", "addon": ["name": "riela/array-batch", "version": "1", "config": [
          "items": [["id": "failed"], ["id": "healthy"]], "size": 1, "uniqueBy": "id", "bindItems": true]]],
        ["id": "gather", "addon": ["name": "riela/array-gather", "version": "1", "config": [
          "join": "{{input.fanoutJoin}}", "groupId": "partial", "selectedIdsFrom": "/safe_ids", "allowPartial": true]]]],
      "steps": [["id": "batch", "nodeId": "batch", "transitions": [[
        "toWorkflowId": "child", "toStepId": "inspect", "resumeStepId": "gather", "fanout": [
          "groupId": "partial", "itemsFrom": "/items", "contextFrom": "/receipt", "itemVariable": "items",
          "concurrency": 2, "joinStepId": "gather", "failurePolicy": "collect-partial", "resultOrder": "input",
          "writeOwnership": ["mode": "shared-workspace"]]]]], ["id": "gather", "nodeId": "gather"]]])
    let options = ["--workflow-definition-dir", definitions.path, "--working-dir", root.path,
      "--session-store", sessions.path, "--output", "json"]
    let first = await RielaCLIApplication().run(["workflow", "run", "parent"] + options + ["--max-steps", "1"])
    XCTAssertEqual(first.exitCode, .failure, first.stdout + first.stderr)
    let failure = try JSONDecoder().decode(WorkflowRunFailureResult.self, from: Data(first.stdout.utf8))
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    let identity = try XCTUnwrap(failure.sessionId)
    let before = try String(contentsOf: attempts, encoding: .utf8)
    XCTAssertEqual(before.split(separator: "\n").count, 2)
    let resumed = await RielaCLIApplication().run(["session", "resume", identity] + options + ["--max-steps", "4"])
    XCTAssertEqual(resumed.exitCode, .success, resumed.stdout + resumed.stderr)
    let saved = try CLIWorkflowSessionStore(rootDirectory: sessions.path).load(sessionId: identity)
    XCTAssertEqual(saved.session.status, .completed)
    let output = try XCTUnwrap(saved.session.executions.last?.acceptedOutput?.payload)
    XCTAssertEqual(output["items"], .array([.object(["id": .string("healthy")])]))
    XCTAssertEqual(output["failedItemIds"], .array([.string("failed")]))
    XCTAssertEqual(output["failedBatchCount"], .integer(1))
    XCTAssertEqual(try String(contentsOf: attempts, encoding: .utf8), before)
  }
}
