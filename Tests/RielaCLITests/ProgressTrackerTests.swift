import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class ProgressTrackerTests: XCTestCase {
  func testDistinctSweepExhaustsBeforeOnlyNewProgressRevisits() throws {
    var state = try ProgressTracker.run(["mode": .string("identity-sweep")])
    func observe(_ event: JSONObject) throws {
      state = try ProgressTracker.run(["mode": .string("identity-sweep"), "state": state["state"]!, "event": .object(event)])
    }
    try observe(["identity": .string("a"), "token": .string("t1"), "advanced": .bool(true), "accepted": .bool(true)])
    try observe(["identity": .string("b"), "token": .string("t2"), "advanced": .bool(true), "accepted": .bool(false)])
    XCTAssertEqual(state["excludedIds"], .array([.string("a"), .string("b")]))
    try observe(["idle": .bool(true), "accepted": .bool(true)])
    XCTAssertEqual(state["excludedIds"], .array([.string("b")]))
    try observe(["identity": .string("a"), "token": .string("t1"), "advanced": .bool(true), "accepted": .bool(true)])
    try observe(["idle": .bool(true), "accepted": .bool(true)])
    XCTAssertEqual(state["canContinue"], .bool(false))
  }

  func testPublicationProofCanReopenAnotherProducerAndReplayStops() throws {
    let proof: JSONValue = .object(["identity": .string("other"), "token": .string("opaque")])
    let event: JSONObject = ["published": .bool(true), "accepted": .bool(true), "proofs": .array([proof])]
    let first = try ProgressTracker.run(["mode": .string("identity-sweep"), "event": .object(event)])
    XCTAssertEqual(first["canContinue"], .bool(true))
    let replay = try ProgressTracker.run(["mode": .string("identity-sweep"), "state": first["state"]!, "event": .object(event)])
    XCTAssertEqual(replay["canContinue"], .bool(false))
    let boundary = try ProgressTracker.run(["mode": .string("identity-sweep"), "event": .object(["boundary": .bool(true), "proofs": .array([proof])])])
    XCTAssertEqual(boundary["canContinue"], .bool(false))
    guard case let .object(state)? = boundary["state"] else { return XCTFail("state") }
    XCTAssertEqual(state["known"], .array([]))
  }

  func testCounterMinimumsPreventOscillationAndOnlyInitialUncomparedVerificationAdmits() throws {
    var state = try ProgressTracker.run(["mode": .string("decreasing-counters"), "baseline": .object(["pending": .integer(35)])])
    func observe(_ count: Int, verified: Bool = true) throws {
      state = try ProgressTracker.run(["mode": .string("decreasing-counters"), "state": state["state"]!,
        "event": .object(["counts": .object(["pending": .integer(Int64(count))]), "accepted": .bool(true), "verified": .bool(verified)])])
    }
    try observe(25); XCTAssertEqual(state["canContinue"], .bool(true))
    try observe(35); XCTAssertEqual(state["canContinue"], .bool(false))
    try observe(25); XCTAssertEqual(state["canContinue"], .bool(false))
    let initial = try ProgressTracker.run(["mode": .string("decreasing-counters"),
      "event": .object(["pending": .bool(true), "accepted": .bool(true), "verified": .bool(true)])])
    XCTAssertEqual(initial["canContinue"], .bool(true))
    let repeated = try ProgressTracker.run(["mode": .string("decreasing-counters"), "state": initial["state"]!,
      "event": .object(["pending": .bool(true), "accepted": .bool(true), "verified": .bool(true)])])
    XCTAssertEqual(repeated["canContinue"], .bool(false))
  }

  func testHardTurnLimitCountsIdlePublicationAndDistinctUTF8Identities() throws {
    var state: JSONValue = .null
    for index in 0..<64 {
      let result = try ProgressTracker.run(["mode": .string("identity-sweep"), "state": state,
        "event": .object(["published": .bool(true), "accepted": .bool(true)])])
      state = result["state"]!
      XCTAssertEqual(result["count"], .integer(Int64(index + 1)))
      XCTAssertEqual(result["canContinue"], .bool(index < 63))
    }
    let first = try ProgressTracker.run(["mode": .string("identity-sweep"), "event": .object(["identity": .string("é")])])
    let second = try ProgressTracker.run(["mode": .string("identity-sweep"), "state": first["state"]!, "event": .object(["identity": .string("e\u{301}")])])
    guard case let .array(ids)? = second["excludedIds"] else { return XCTFail("ids") }
    XCTAssertEqual(ids.count, 2)
  }

  func testMalformedAndOversizedMetadataFailClosed() throws {
    let events: [JSONObject] = [["privateBody": .string("never accepted")], ["advanced": .string("true")],
      ["proofs": .array([.object(["identity": .string("a"), "token": .string("t"), "private": .string("body")])])]]
    for event in events {
      XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("identity-sweep"), "event": .object(event)]))
    }
    XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("decreasing-counters"), "baseline": .object(["n": .bool(true)])]))
    XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("identity-sweep"), "maximumTurns": .integer(65)]))
  }

  func testDeclaredWorkflowThreadsProgressStateWithoutScriptsOrModels() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let definitions = root.appendingPathComponent("definitions/progress-fixture")
    try FileManager.default.createDirectory(at: definitions, withIntermediateDirectories: true)
    let ids = ["first", "idle", "replay", "finish"]
    let nodes: [JSONValue] = ids.enumerated().map { index, id in
      var config: JSONObject = ["mode": .string("identity-sweep"), "event": .object(index % 2 == 0 ?
        ["identity": .string("source"), "token": .string("same-version"), "advanced": .bool(true), "accepted": .bool(true)] :
        ["idle": .bool(true), "accepted": .bool(true)])]
      if index > 0 { config["state"] = .string("{{input.state}}") }
      return .object(["id": .string(id), "addon": .object(["name": .string("riela/progress-tracker"), "version": .string("1"), "config": .object(config)])])
    }
    let steps: [JSONValue] = ids.enumerated().map { index, id in
      var step: JSONObject = ["id": .string(id), "nodeId": .string(id), "role": .string("worker")]
      if index < ids.count - 1 { step["transitions"] = .array([.object(["toStepId": .string(ids[index + 1])])]) }
      return .object(step)
    }
    let graph: JSONObject = ["workflowId": .string("progress-fixture"), "entryStepId": .string("first"),
      "defaults": .object(["maxLoopIterations": .integer(1), "nodeTimeoutMs": .integer(30000)]), "nodes": .array(nodes), "steps": .array(steps)]
    try JSONEncoder().encode(graph).write(to: definitions.appendingPathComponent("workflow.json"))
    let result = await RielaCLIApplication().run(["workflow", "run", "progress-fixture", "--workflow-definition-dir", root.appendingPathComponent("definitions").path,
      "--working-dir", root.path, "--output", "json"], environment: ["HOME": root.path, "PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(JSONObject.self, from: Data(result.stdout.utf8))
    guard case let .object(value)? = output["rootOutput"] else { return XCTFail("missing output") }
    XCTAssertEqual(value["canContinue"], .bool(false)); XCTAssertEqual(value["count"], .integer(4))
  }

  func testActualCLITrackerPreservesOpaqueTokenAndCommonPostprocess() async throws {
    let result = await RielaCLIApplication().run(["node", "run", "riela/progress-tracker", "--config",
      #"{"mode":"identity-sweep","event":"{{observation}}","postprocess":[{"pick":"/canContinue"}]}"#,
      "--variables", #"{"observation":{"identity":"{{literal}}","token":"{{token}}","advanced":true,"accepted":true}}"#,
      "--output", "json"], environment: ["PATH": ""])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["excludedIds"], .array([.string("{{literal}}")]))
    XCTAssertEqual(output.payload["processed"], .bool(true))
  }
}
