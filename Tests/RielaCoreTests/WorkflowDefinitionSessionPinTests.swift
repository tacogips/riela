import Foundation
import XCTest
@testable import RielaCore

final class WorkflowDefinitionSessionPinTests: XCTestCase {
  func testOldSessionSnapshotDecodesWithoutDefinitionSource() throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", entryStepId: "entry", createdAt: date, updatedAt: date
    )
    let encoded = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(WorkflowSession.self, from: encoded)
    XCTAssertNil(decoded.definitionSource)
    XCTAssertEqual(decoded, session)
  }

  func testDefinitionSourceRoundTripsAndSessionCreateInputCarriesIt() async throws {
    let source = WorkflowDefinitionSource(
      kind: .store, workflowName: "workflow", versionId: "defv-123", storeRoot: "/sessions/user",
      digest: String(repeating: "a", count: 64), sourceScope: "user"
    )
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: "session", entryStepId: "entry", createdAt: date, updatedAt: date,
      definitionSource: source
    )
    XCTAssertEqual(try JSONDecoder().decode(WorkflowSession.self, from: JSONEncoder().encode(session)), session)

    let store = InMemoryWorkflowRuntimeStore()
    let created = try await store.createSession(WorkflowSessionCreateInput(
      workflowId: "workflow", entryStepId: "entry", definitionSource: source
    ))
    XCTAssertEqual(created.definitionSource, source)
  }

  func testRunnerRequestPinsDefinitionSourceOnRootSession() async throws {
    let source = WorkflowDefinitionSource(
      kind: .file, workflowName: "workflow", digest: String(repeating: "b", count: 64),
      sourcePath: "/workflows/workflow.json", sourceScope: "project"
    )
    let workflow = WorkflowDefinition(
      workflowId: "workflow",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 2),
      entryStepId: "entry",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "entry", nodeId: "node")],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: AdapterExecutionOutput(
      provider: "test", model: "test", promptText: "prompt", completionPassed: true,
      payload: ["status": .string("ok")]
    )))
    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", model: "test", promptTemplate: "prompt")],
      definitionSource: source
    ))
    XCTAssertEqual(result.session.definitionSource, source)
  }
}
