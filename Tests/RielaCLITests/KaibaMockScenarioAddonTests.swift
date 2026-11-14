import RielaAdapters
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class KaibaMockScenarioAddonTests: XCTestCase {
  func testMemoryConsolidationScenarioOverridesKaibaAddonBeforePreflight() async throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
    let resolver = try await makeScenarioBackedAddonResolver(
      scenarioPath: "\(root)/examples/memory-consolidation/mock-scenario.json",
      workingDirectory: root
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "memory-consolidation",
        stepId: "consolidate-long-term",
        nodeId: "consolidate-long-term",
        addon: WorkflowNodeAddonRef(name: "kaiba/memory-consolidate", version: "1"),
        variables: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "scenario-mock")
    XCTAssertEqual(output.payload["entriesWritten"], JSONValue.number(1))
    XCTAssertEqual(output.payload["notebookId"], JSONValue.string("notebook-long-term-memory-fixture"))
  }
}
