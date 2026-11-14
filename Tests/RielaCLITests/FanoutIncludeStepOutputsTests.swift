import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class FanoutIncludeStepOutputsTests: XCTestCase {
  func testCalleeReferencesWithAndWithoutResume() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/fixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func write(_ name: String, _ value: [String: Any]) throws {
      let path = root.appendingPathComponent(name + "/workflow.json")
      try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: value).write(to: path)
    }
    func node(_ id: String) -> [String: Any] {
      ["id": id, "addon": ["name": "riela/json-compose", "version": "1", "config": ["payload": [:]]]]
    }
    let defaults = ["nodeTimeoutMs": 30000, "maxLoopIterations": 1]
    try write("callee", ["workflowId": "callee", "entryStepId": "a", "defaults": defaults,
      "nodes": [node("node-a"), node("node-b")], "steps": [["id": "a", "nodeId": "node-a"], ["id": "b", "nodeId": "node-b"]]])
    for resume in [true, false] {
      for included in ["missing", "a"] {
        var transition: [String: Any] = ["toWorkflowId": "callee", "toStepId": "a", "fanout": [
          "groupId": "items", "itemsFrom": "/items", "itemVariable": "item", "joinStepId": "join",
          "failurePolicy": "fail-fast", "writeOwnership": ["mode": "read-only"], "includeStepOutputs": [included]]]
        if resume { transition["resumeStepId"] = "join" }
        try write("caller", ["workflowId": "caller", "entryStepId": "source", "defaults": defaults,
          "nodes": [node("source"), node("join")], "steps": [
            ["id": "source", "nodeId": "source", "transitions": [transition]], ["id": "join", "nodeId": "join"]]])
        let result = await RielaCLIApplication().run(["workflow", "validate", "caller",
          "--workflow-definition-dir", root.path, "--working-dir", root.path, "--output", "json"])
        let decoded = try JSONDecoder().decode(WorkflowValidationCommandResult.self, from: Data(result.stdout.utf8))
        let matches = decoded.diagnostics.filter { $0.path.contains("includeStepOutputs") }
        if included == "missing" {
          XCTAssertEqual(result.exitCode, .failure, result.stdout + result.stderr)
          XCTAssertEqual(matches.count, 1)
          XCTAssertEqual(matches.first?.path, "workflow.steps.source.transitions[0].fanout.includeStepOutputs[0]")
          XCTAssertTrue(matches.first?.message.contains("missing") == true)
          XCTAssertTrue(matches.first?.message.contains("callee") == true)
        } else {
          XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
          XCTAssertTrue(matches.isEmpty)
        }
      }
    }
  }

  func testExampleValidatesAndRuns() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let sessions = root.appendingPathComponent("tmp/youtube-processing-builtins/ypb-07-fanout-cli-validation-example/test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: sessions) }
    let common = ["--workflow-definition-dir", root.appendingPathComponent("examples").path, "--output", "json"]
    let validate = await RielaCLIApplication().run(["workflow", "validate", "fanout-include-step-outputs"] + common)
    XCTAssertEqual(validate.exitCode, .success, validate.stdout + validate.stderr)
    let run = await RielaCLIApplication().run(["workflow", "run", "fanout-include-step-outputs"] + common + [
      "--mock-scenario", root.appendingPathComponent("examples/fanout-include-step-outputs/mock-scenario.json").path,
      "--session-store", sessions.path, "--max-steps", "50"])
    XCTAssertEqual(run.exitCode, .success, run.stdout + run.stderr)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
    let output = try XCTUnwrap(object["rootOutput"] as? [String: Any])
    let join = try XCTUnwrap(output["joined"] as? [String: Any])
    let branches = try XCTUnwrap(join["branches"] as? [[String: Any]])
    XCTAssertEqual(branches.count, 2)
    for (index, branch) in branches.enumerated() {
      let outputs = try XCTUnwrap(branch["stepOutputs"] as? [String: Any])
      let transcript = try XCTUnwrap(outputs["transcribe"] as? [String: Any])
      XCTAssertEqual(transcript["transcript"] as? String, "transcript s\(index + 1)")
    }
  }
}
