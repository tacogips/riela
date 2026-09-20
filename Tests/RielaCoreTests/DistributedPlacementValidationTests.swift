import XCTest
@testable import RielaCore

final class DistributedPlacementValidationTests: XCTestCase {
  func testProgrammaticPlacementAndOutputProjectionAreValidatedBeforeExecution() {
    var workflow = WorkflowDefinition(workflowId: "typed", defaults: .init(nodeTimeoutMs: 1000, maxLoopIterations: 1),
      entryStepId: "step", nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [.init(id: "step", nodeId: "node", placement: .init(target: .init(group: ""), workspace: "project"))],
      nodes: [.init(id: "node", nodeFile: "node.json")])
    XCTAssertTrue(DefaultWorkflowValidator().validate(workflow).contains { $0.path.hasSuffix(".placement") && $0.severity == .error })
    workflow.steps[0].placement = .init(target: .init(), workspace: "project")
    XCTAssertFalse(DefaultWorkflowValidator().validate(workflow).contains { $0.path.hasSuffix(".placement") })
    let projection = AgentNodePayload(id: "node", model: "local", output: .init(projection: .init(kind: .latestInputPayload)))
    XCTAssertTrue(DefaultWorkflowValidator().validate(workflow, nodePayloads: ["node": projection]).contains {
      $0.path.hasSuffix(".placement") && $0.message.contains("output projection")
    })
  }

  func testPlacementRequiresWorkspaceAndRejectsUnknownOrInvalidTargets() {
    let invalid: [Any] = [
      NSNull(), ["workspace": "project"], ["target": [:]],
      ["workspace": " ", "target": [:]],
      ["workspace": "project", "target": ["workerId": ""]],
      ["workspace": "project", "target": ["group": 42]],
      ["workspace": "project", "target": ["typo": "linux"]],
      ["workspace": "project", "target": [:], "fallback": "local"]
    ]
    for value in invalid {
      var diagnostics: [WorkflowValidationDiagnostic] = []
      validateDistributedPlacement(value, path: "placement", diagnostics: &diagnostics)
      XCTAssertEqual(diagnostics.count, 1)
    }
    for target: [String: String] in [[:], ["workerId": "mac"], ["group": "linux"], ["workerId": "linux-1", "group": "linux"]] {
      var diagnostics: [WorkflowValidationDiagnostic] = []
      validateDistributedPlacement(["workspace": "project", "target": target], path: "placement", diagnostics: &diagnostics)
      XCTAssertTrue(diagnostics.isEmpty)
    }
  }
}
