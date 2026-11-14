import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RoundRobinProgressTests: XCTestCase {
  private func next(_ ids: [String], eligible: Set<String> = [], state: JSONValue = .null,
                    maximum: Int = 64, budget: Bool = true) throws -> JSONObject {
    try ProgressTracker.run(["mode": .string("round-robin"), "maximumTurns": .integer(Int64(maximum)),
      "state": state, "budgetAvailable": .bool(budget), "items": .array(ids.map {
        .object(["id": .string($0), "eligible": .bool(eligible.contains($0))])
      })])
  }

  func testEveryFirstTurnPrecedesFairEligibleContinuations() throws {
    var state: JSONValue = .null
    let ids = ["b", "a", "c"]
    for (index, expected) in ["b", "a", "c", "b", "a", "b", "a"].enumerated() {
      let output = try next(ids, eligible: ["a", "b"], state: state)
      XCTAssertEqual(output["item"], .string(expected)); XCTAssertEqual(output["count"], .integer(Int64(index + 1)))
      XCTAssertEqual(output["firstTurn"], .bool(index < 3)); state = output["state"]!
    }
    let stopped = try next(ids, state: state)
    XCTAssertEqual(stopped["item"], .null); XCTAssertEqual(stopped["reason"], .string("no-eligible"))
    XCTAssertEqual(stopped["state"], state)
    let resumed = try next(ids, eligible: ["c"], state: state)
    XCTAssertEqual(resumed["item"], .string("c"))
  }

  func testBudgetAndLimitDoNotReserveAnotherAttempt() throws {
    let budget = try next(["a"], budget: false)
    XCTAssertEqual(budget["count"], .integer(0)); XCTAssertEqual(budget["reason"], .string("budget"))
    var state = budget["state"]!
    for _ in 0..<64 { state = try next(["a"], eligible: ["a"], state: state)["state"]! }
    let limit = try next(["a"], eligible: ["a"], state: state)
    XCTAssertEqual(limit["reason"], .string("limit")); XCTAssertEqual(limit["count"], .integer(64))
    XCTAssertEqual(limit["state"], state)
    XCTAssertEqual(try next([])["reason"], .string("empty"))
  }

  func testLiteralUTF8IdentitiesAndFrozenTaskOrder() throws {
    let ids = ["é", "e\u{301}", "{{literal}}"]
    let first = try next(ids)
    XCTAssertEqual(first["item"], .string(ids[0]))
    XCTAssertThrowsError(try next(Array(ids.reversed()), state: first["state"]!))
    XCTAssertThrowsError(try next(["a", "a"]))
    XCTAssertThrowsError(try next(["a\u{7f}"]))
    XCTAssertThrowsError(try next(["a\u{85}"]))
    XCTAssertThrowsError(try next(Array(repeating: "x", count: 17)))
    guard case var .object(state)? = first["state"] else { return XCTFail("missing state") }
    state["cursor"] = .integer(0)
    XCTAssertThrowsError(try next(ids, state: .object(state)))
    guard case var .object(empty)? = try next([])["state"] else { return XCTFail("missing empty state") }
    empty["count"] = .integer(1)
    XCTAssertThrowsError(try next([], state: .object(empty)))
  }

  func testMalformedEligibilityAndCrossModeFieldsAreRefused() throws {
    for value: JSONValue in [.null, .string("true"), .integer(1)] {
      XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("round-robin"),
        "items": .array([.object(["id": .string("a"), "eligible": value])])]))
    }
    XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("identity-sweep"), "items": .array([])]))
    XCTAssertThrowsError(try ProgressTracker.run(["mode": .string("round-robin"), "items": .array([]), "event": .object([:])]))
  }

  func testActualCLINodeAndCommonPostprocess() async throws {
    let literal = await RielaCLIApplication().run(["node", "run", "riela/progress-tracker", "--config",
      #"{"mode":"round-robin","items":"{{tasks}}","postprocess":[{"pick":"/item"}]}"#,
      "--variables", #"{"tasks":[{"id":"{{literal}}","eligible":false}]}"#, "--output", "json"], environment: ["PATH": ""])
    XCTAssertEqual(literal.exitCode, .success, literal.stdout + literal.stderr)
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(literal.stdout.utf8))
    XCTAssertEqual(output.payload["processed"], .string("{{literal}}"))
  }
}
