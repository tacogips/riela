import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class ScenarioNodeAdapterUsageTests: XCTestCase {
  func testAdapterEmitsUsageBackendEventWhenScenarioSpecifiesUsage() async throws {
    let scenario = WorkflowMockScenario(responses: [
      "impl": [MockNodeResponse(
        payload: ["status": .string("done")],
        usage: ["input_tokens": .integer(100), "output_tokens": .integer(40), "total_tokens": .integer(140)]
      )]
    ])
    let adapter = ScenarioNodeAdapter(scenario: scenario)
    let capture = UsageCapture()
    let context = AdapterExecutionContext(backendEventHandler: { event in await capture.record(event) })
    let input = AdapterExecutionInput(node: AgentNodePayload(id: "impl", model: "gpt-5.5"), promptText: "do it")

    _ = try await adapter.execute(input, context: context)

    let events = await capture.events
    XCTAssertEqual(events.count, 1)
    XCTAssertEqual(events.first?.channel, .usage)
    XCTAssertEqual(events.first?.eventType, "usage")
    XCTAssertEqual(events.first?.usage?["total_tokens"]?.asInt64, 140)
    XCTAssertEqual(events.first?.usage?["input_tokens"]?.asInt64, 100)
  }

  func testAdapterEmitsNoUsageEventWhenUnset() async throws {
    let scenario = WorkflowMockScenario(responses: ["impl": [MockNodeResponse(payload: [:])]])
    let adapter = ScenarioNodeAdapter(scenario: scenario)
    let capture = UsageCapture()
    let context = AdapterExecutionContext(backendEventHandler: { event in await capture.record(event) })
    let input = AdapterExecutionInput(node: AgentNodePayload(id: "impl", model: "gpt-5.5"), promptText: "x")

    _ = try await adapter.execute(input, context: context)

    let events = await capture.events
    XCTAssertTrue(events.isEmpty)
  }
}

private actor UsageCapture {
  var events: [AdapterBackendEvent] = []
  func record(_ event: AdapterBackendEvent) { events.append(event) }
}
