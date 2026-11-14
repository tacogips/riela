import XCTest
@testable import RielaCore

final class LoopPolicyEvaluatorTests: XCTestCase {
  func testPreflightRecordsDefaultCommitPushDenyAndAllowsConfiguredWorker() {
    let evaluator = DefaultLoopPolicyEvaluator()
    let workflow = workflow(
      loop: WorkflowLoopMetadata(
        required: true,
        policies: LoopPolicyDeclaration(
          mutation: LoopMutationPolicyDeclaration(allowedWriteRoots: ["Sources"], scratchRoot: "tmp"),
          process: LoopProcessPolicyDeclaration(
            nestedRiela: "deny",
            nestedCodex: "deny",
            allowedBackends: ["codex-agent"],
            requiredWorkerModel: "gpt-5.5"
          )
        )
      )
    )

    let evidence = evaluator.preflight(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")]
    )

    XCTAssertEqual(evidence.effective?.mutation?.commit, "deny")
    XCTAssertEqual(evidence.effective?.mutation?.push, "deny")
    XCTAssertTrue(evidence.denials.isEmpty)
    XCTAssertTrue(evidence.decisions.contains { $0.policy == "mutation.commit" && $0.decision == "deny" })
    XCTAssertTrue(evidence.decisions.contains { $0.policy == "mutation.push" && $0.decision == "deny" })
    XCTAssertTrue(evidence.decisions.contains { $0.policy == "process.allowedBackends" && $0.decision == "allow" })
    XCTAssertTrue(evidence.decisions.contains { $0.policy == "process.requiredWorkerModel" && $0.decision == "allow" })
  }

  func testPreflightDeniesUnsupportedWorkerBackendAndModel() {
    let evaluator = DefaultLoopPolicyEvaluator()
    let workflow = workflow(
      loop: WorkflowLoopMetadata(
        required: true,
        policies: LoopPolicyDeclaration(
          process: LoopProcessPolicyDeclaration(
            allowedBackends: ["codex-agent"],
            requiredWorkerModel: "gpt-5.5"
          )
        )
      )
    )

    let evidence = evaluator.preflight(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(id: "node", executionBackend: .claudeCodeAgent, model: "claude-sonnet")]
    )

    XCTAssertTrue(evidence.denials.contains { $0.policy == "process.allowedBackends" })
    XCTAssertTrue(evidence.denials.contains { $0.policy == "process.requiredWorkerModel" })
  }

  func testPreflightDeniesCommandAndNestedCodexWhenPolicyForbidsThem() {
    let evaluator = DefaultLoopPolicyEvaluator()
    let workflow = workflow(
      loop: WorkflowLoopMetadata(
        required: true,
        policies: LoopPolicyDeclaration(
          process: LoopProcessPolicyDeclaration(
            nestedCodex: "deny",
            allowedBackends: ["codex-agent"]
          )
        )
      )
    )
    let commandNode = AgentNodePayload(
      id: "node",
      nodeType: .command,
      model: "",
      command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", "codex exec --json"])
    )

    let evidence = evaluator.preflight(workflow: workflow, nodePayloads: ["node": commandNode])

    XCTAssertTrue(evidence.denials.contains { $0.policy == "process.allowedBackends" })
    XCTAssertTrue(evidence.denials.contains { $0.policy == "process.nestedCodex" })
  }

  func testNormalizesPolicyRelativePaths() {
    XCTAssertEqual(DefaultLoopPolicyEvaluator.normalizedPolicyRelativePath("tmp/evidence"), "tmp/evidence")
    XCTAssertNil(DefaultLoopPolicyEvaluator.normalizedPolicyRelativePath("../tmp"))
    XCTAssertNil(DefaultLoopPolicyEvaluator.normalizedPolicyRelativePath("/tmp"))
  }

  private func workflow(loop: WorkflowLoopMetadata) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "loop-policy",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")],
      loop: loop
    )
  }
}
