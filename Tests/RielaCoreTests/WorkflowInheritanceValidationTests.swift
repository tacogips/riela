import XCTest
@testable import RielaCore

final class WorkflowInheritanceValidationTests: XCTestCase {
  func testSparseDeclarationRejectsMalformedInheritanceFields() throws {
    let cases: [(String, String)] = [
      (#"{"workflowId":"derived","extends":null}"#, "workflow.extends"),
      (#"{"workflowId":"derived","extends":{"workflowId":"base","unknown":true}}"#, "workflow.extends.unknown"),
      (#"{"workflowId":"derived","extends":{"workflowId":"base","stringReplacements":{"":"value"}}}"#,
       "workflow.extends.stringReplacements"),
      (#"{"workflowId":"derived","extends":{"workflowId":"base","nodePatch":{"worker":[]}}}"#,
       "workflow.extends.nodePatch.worker")
    ]

    for (json, expectedPath) in cases {
      XCTAssertThrowsError(try WorkflowInheritanceDeclaration.parse(data: Data(json.utf8))) { error in
        guard case let WorkflowInheritanceError.invalidDeclaration(diagnostics) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(diagnostics.contains(where: { $0.path == expectedPath }), "missing \(expectedPath)")
      }
    }
  }

  func testSparseDeclarationRejectsUnsupportedOverlayAtInheritancePath() throws {
    let data = Data(#"{"workflowId":"derived","nodes":[],"extends":{"workflowId":"base"}}"#.utf8)
    XCTAssertThrowsError(try WorkflowInheritanceDeclaration.parse(data: data)) { error in
      guard case let WorkflowInheritanceError.invalidDeclaration(diagnostics) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(diagnostics.first?.path, "workflow.nodes")
    }
  }

  func testReplacementOrderingAndExplicitPatchPrecedence() throws {
    let workflow = WorkflowDefinition(
      workflowId: "codex-family",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: "codex-agent",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "codex-agent", nodeFile: "nodes/codex-agent.json")],
      steps: [WorkflowStepRef(id: "codex-agent", nodeId: "codex-agent")],
      nodes: [WorkflowNodeRef(id: "codex-agent", nodeFile: "nodes/codex-agent.json")]
    )
    let payload = AgentNodePayload(
      id: "codex-agent",
      nodeType: .agent,
      executionBackend: .codexAgent,
      model: "gpt-5",
      agentSandbox: .readOnly, promptTemplate: "codexAgentReferences codex-agent codex",
      promptTemplateFile: "prompts/codex.md"
    )
    let declaration = WorkflowInheritanceDeclaration(
      derivedWorkflowId: "claude-family",
      description: "Claude variant",
      baseWorkflowId: "codex-family",
      stringReplacements: [
        "codexAgentReferences": "claudeAgentReferences",
        "codex-agent": "claude-code-agent",
        "codex": "claude"
      ],
      agentNodePatch: WorkflowInstanceNodePatch(executionBackend: .claudeCodeAgent, model: "sonnet"),
      nodePatches: ["claude-code-agent": WorkflowInstanceNodePatch(model: "opus")]
    )

    let result = try WorkflowInheritanceTransformation().apply(
      declaration, to: workflow, nodePayloads: ["codex-agent": payload]
    )

    XCTAssertEqual(result.workflow.workflowId, "claude-family")
    XCTAssertEqual(result.workflow.entryStepId, "claude-code-agent")
    XCTAssertEqual(result.nodePayloads["claude-code-agent"]?.executionBackend, .claudeCodeAgent)
    XCTAssertEqual(result.nodePayloads["claude-code-agent"]?.model, "opus")
    XCTAssertEqual(result.nodePayloads["claude-code-agent"]?.promptTemplate, "claudeAgentReferences claude-code-agent claude")
    XCTAssertEqual(result.nodePayloads["claude-code-agent"]?.promptTemplateFile, "prompts/codex.md")
  }

  func testModelFreezeAndReplacementCollisionFailClosed() throws {
    var declaration = WorkflowInheritanceDeclaration(
      derivedWorkflowId: "derived", description: nil, baseWorkflowId: "base",
      stringReplacements: ["one": "same", "two": "same"],
      agentNodePatch: nil, nodePatches: [:]
    )
    let workflow = makeWorkflow(nodeIds: ["one", "two"])
    let payloads = ["one": AgentNodePayload(id: "one", model: "a"), "two": AgentNodePayload(id: "two", model: "b")]
    XCTAssertThrowsError(try WorkflowInheritanceTransformation().apply(declaration, to: workflow, nodePayloads: payloads))

    declaration.stringReplacements = [:]
    declaration.nodePatches = ["one": WorkflowInstanceNodePatch(model: "changed")]
    let frozen = ["one": AgentNodePayload(id: "one", model: "fixed", modelFreeze: true), "two": payloads["two"]!]
    XCTAssertThrowsError(try WorkflowInheritanceTransformation().apply(declaration, to: workflow, nodePayloads: frozen))
  }

  func testTransformationRejectsInvalidProviderBackendCombination() throws {
    let declaration = WorkflowInheritanceDeclaration(
      derivedWorkflowId: "derived", description: nil, baseWorkflowId: "base",
      stringReplacements: [:],
      agentNodePatch: WorkflowInstanceNodePatch(executionBackend: .claudeCodeAgent), nodePatches: [:]
    )
    let workflow = makeWorkflow(nodeIds: ["worker"])
    let provider = try AgentProviderConfiguration(name: "local", baseUrl: "https://provider.example/v1")
    let payload = AgentNodePayload(
      id: "worker",
      executionBackend: .codexAgent,
      model: "model",
      agentSandbox: .readOnly, provider: provider,
      providerProxy: .codex
    )

    XCTAssertThrowsError(
      try WorkflowInheritanceTransformation().apply(declaration, to: workflow, nodePayloads: ["worker": payload])
    ) { error in
      guard case let WorkflowInheritanceError.transformation(diagnostics) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(diagnostics.contains {
        $0.severity == .error && $0.path == "nodes.worker.providerProxy"
      })
    }
  }

  private func makeWorkflow(nodeIds: [String]) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "base",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: nodeIds[0],
      nodeRegistry: nodeIds.map { WorkflowNodeRegistryRef(id: $0, nodeFile: "nodes/\($0).json") },
      steps: nodeIds.map { WorkflowStepRef(id: $0, nodeId: $0) },
      nodes: nodeIds.map { WorkflowNodeRef(id: $0, nodeFile: "nodes/\($0).json") }
    )
  }
}
