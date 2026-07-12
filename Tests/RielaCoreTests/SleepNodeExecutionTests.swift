import Foundation
import XCTest

@testable import RielaCore

final class SleepNodeExecutionTests: XCTestCase {
  func testAgentNodePayloadDecodesSleepConfiguration() throws {
    let json = """
    {
      "id": "hold",
      "nodeType": "sleep",
      "modelFreeze": false,
      "variables": {},
      "sleep": {"durationMs": 1500}
    }
    """
    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(json.utf8))
    XCTAssertEqual(payload.nodeType, .sleep)
    XCTAssertEqual(payload.sleep, WorkflowSleepExecution(durationMs: 1500))

    let reencoded = try JSONDecoder().decode(
      AgentNodePayload.self,
      from: JSONEncoder().encode(payload)
    )
    XCTAssertEqual(reencoded.sleep, payload.sleep)
  }

  func testNonSleepNodeReturnsNil() async throws {
    let input = AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", model: "gpt-5.5"),
      promptText: "prompt"
    )
    let output = try await SleepNodeExecution.outputIfSleepNode(input)
    XCTAssertNil(output)
  }

  func testSleepNodePausesAndCompletesDeterministically() async throws {
    let node = AgentNodePayload(
      id: "hold",
      nodeType: .sleep,
      model: "",
      sleep: WorkflowSleepExecution(durationMs: 40)
    )
    let input = AdapterExecutionInput(node: node, promptText: "")
    let started = Date()
    let maybeOutput = try await SleepNodeExecution.outputIfSleepNode(input)
    let output = try XCTUnwrap(maybeOutput)
    let elapsedMs = Date().timeIntervalSince(started) * 1_000
    XCTAssertGreaterThanOrEqual(elapsedMs, 40)
    XCTAssertEqual(output.provider, "sleep")
    XCTAssertTrue(output.completionPassed)
    XCTAssertEqual(output.payload["status"], .string("completed"))
    XCTAssertEqual(output.payload["durationMs"], .integer(40))
    XCTAssertEqual(output.payload["nodeId"], .string("hold"))
  }

  func testMissingSleepConfigurationDegradesToNoOpPause() async throws {
    let node = AgentNodePayload(id: "hold", nodeType: .sleep, model: "")
    let input = AdapterExecutionInput(node: node, promptText: "")
    let maybeOutput = try await SleepNodeExecution.outputIfSleepNode(input)
    let output = try XCTUnwrap(maybeOutput)
    XCTAssertEqual(output.payload["durationMs"], .integer(0))
  }

  func testDeterministicLocalAdapterHonorsSleepNodes() async throws {
    let node = AgentNodePayload(
      id: "hold",
      nodeType: .sleep,
      model: "",
      sleep: WorkflowSleepExecution(durationMs: 10)
    )
    let output = try await DeterministicLocalNodeAdapter().execute(
      AdapterExecutionInput(node: node, promptText: ""),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(output.provider, "sleep")
    XCTAssertEqual(output.payload["durationMs"], .integer(10))
  }
}
