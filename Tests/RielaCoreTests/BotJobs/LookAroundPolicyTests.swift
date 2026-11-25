import XCTest
@testable import RielaCore

final class LookAroundPolicyTests: XCTestCase {
  func testSingleAgentWithResolvedRegistryPayloadIsAllowed() {
    let workflow = workflow(steps: [WorkflowStepRef(id: "inspect", nodeId: "agent")])
    let payload = AgentNodePayload(id: "agent", model: "default")
    XCTAssertEqual(LookAroundPolicy.violations(workflow: workflow, nodePayloads: ["agent": payload]), [])
  }

  func testCommandPayloadIsRejectedEvenWhenDeclaredAsAgent() {
    let workflow = workflow(steps: [WorkflowStepRef(id: "inspect", nodeId: "agent")])
    let payload = AgentNodePayload(
      id: "agent", nodeType: .agent, model: "default", command: WorkflowCommandExecution(executable: "true")
    )
    let issues = LookAroundPolicy.violations(workflow: workflow, nodePayloads: ["agent": payload])
    XCTAssertEqual(issues.count, 1)
    XCTAssertTrue(issues.first?.contains("Node 'agent' has a command payload") == true)
  }

  func testAddonContainerAndMultipleStepsReportEachViolation() {
    var workflow = workflow(steps: [
      WorkflowStepRef(id: "inspect", nodeId: "agent"), WorkflowStepRef(id: "use-addon", nodeId: "addon")
    ])
    workflow.nodeRegistry[1].addon = WorkflowNodeAddonRef(name: "test/addon")
    workflow.nodes[1].addon = workflow.nodeRegistry[1].addon
    let payload = AgentNodePayload(id: "agent", model: "default", container: WorkflowContainerExecution(image: "fixture"))
    let issues = LookAroundPolicy.violations(workflow: workflow, nodePayloads: ["agent": payload])
    XCTAssertEqual(issues, [
      "Look-around requires exactly one step (found 2)",
      "Node 'addon' uses an add-on",
      "Node 'agent' has a container payload"
    ])
  }

  func testNestedWorkflowCallIsRejected() {
    let workflow = workflow(steps: [
      WorkflowStepRef(id: "inspect", nodeId: "agent", transitions: [
        WorkflowStepTransition(toStepId: "entry", toWorkflowId: "other")
      ])
    ])
    let payload = AgentNodePayload(id: "agent", model: "default")
    XCTAssertEqual(
      LookAroundPolicy.violations(workflow: workflow, nodePayloads: ["agent": payload]),
      ["Node 'agent' can call another workflow"]
    )
  }

  func testMissingAndNonAgentPayloadsAreRejected() {
    let workflow = workflow(steps: [WorkflowStepRef(id: "inspect", nodeId: "agent")])
    XCTAssertEqual(
      LookAroundPolicy.violations(workflow: workflow, nodePayloads: [:]),
      ["Node 'agent' has no agent payload"]
    )
    let payload = AgentNodePayload(id: "agent", nodeType: .userAction, model: "default")
    XCTAssertEqual(
      LookAroundPolicy.violations(workflow: workflow, nodePayloads: ["agent": payload]),
      ["Node 'agent' is not an agent node"]
    )
  }

  private func workflow(steps: [WorkflowStepRef]) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "look-around", defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: steps.first?.id ?? "entry", nodeRegistry: steps.map { WorkflowNodeRegistryRef(id: $0.nodeId) },
      steps: steps, nodes: steps.map { WorkflowNodeRef(id: $0.id) }
    )
  }
}
