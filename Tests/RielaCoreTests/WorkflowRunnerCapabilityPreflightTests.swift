import XCTest
import RielaMemory
@testable import RielaCore

final class WorkflowRunnerCapabilityPreflightTests: XCTestCase {
  func testUnsupportedTransitionsFailPreflightBeforeSessionCreation() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let unsupportedTransitions: [(WorkflowStepTransition, String)] = [
      (
        WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow"),
        "step 'step' uses cross-workflow transitions, which this runner does not support yet"
      ),
      (
        WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow", resumeStepId: "resume"),
        "step 'step' uses cross-workflow dispatch, but this run has no callee workflow resolver wired"
      ),
      (
        WorkflowStepTransition(toStepId: "step", resumeStepId: "resume"),
        "step 'step' uses resume-step transitions, which this runner does not support yet"
      )
    ]
    for (transition, message) in unsupportedTransitions {
      let workflow = workflow(transitions: [transition])
      let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

      do {
        _ = try await runner.run(request(workflow: workflow))
        XCTFail("expected preflight failure")
      } catch DeterministicWorkflowRunnerError.invalidWorkflow(let actualMessage) {
        XCTAssertTrue(actualMessage.contains(message), actualMessage)
      }
    }
    let latestSession = await store.latestSession(workflowId: "runner")
    XCTAssertNil(latestSession)
  }

  func testLabeledUnsupportedTransitionsReportWarningsWithoutHardPreflightFailure() {
    let workflow = workflow(transitions: [
      WorkflowStepTransition(
        toStepId: "child",
        toWorkflowId: "child-workflow",
        label: "conditional-child"
      )
    ])

    let diagnostics = DeterministicWorkflowRunner.unsupportedFeatures(in: workflow).map(\.diagnostic)

    XCTAssertEqual(diagnostics.first?.severity, .warning)
    XCTAssertEqual(diagnostics.first?.path, "workflow.steps.step.transitions.toWorkflowId")
    XCTAssertEqual(
      diagnostics.first?.message,
      "step 'step' uses cross-workflow transitions, which this runner does not support yet"
    )
  }

  func testCrossWorkflowDispatchGapReportsWarningForValidation() {
    let workflow = workflow(transitions: [
      WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow", resumeStepId: "resume")
    ])

    let diagnostics = DeterministicWorkflowRunner.unsupportedFeatures(in: workflow).map(\.diagnostic)

    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics.first?.severity, .warning)
    XCTAssertEqual(diagnostics.first?.path, "workflow.steps.step.transitions.toWorkflowId")
  }

  func testSupportedFanoutDoesNotReportCapabilityGap() {
    let workflow = workflow(transitions: [
      WorkflowStepTransition(
        toStepId: "branch",
        fanout: WorkflowStepFanout(
          groupId: "group",
          itemsFrom: "/items",
          joinStepId: "join",
          writeOwnership: WorkflowFanoutWriteOwnership(mode: .readOnly)
        )
      )
    ], extraSteps: [
      WorkflowStepRef(id: "branch", nodeId: "node", transitions: [WorkflowStepTransition(toStepId: "join")]),
      WorkflowStepRef(id: "join", nodeId: "node")
    ])

    let diagnostics = DeterministicWorkflowRunner.unsupportedFeatures(in: workflow, maxConcurrency: 2).map(\.diagnostic)

    XCTAssertEqual(diagnostics, [])
  }

  func testIsolatedWorkspaceFanoutReportsSpecificCapabilityGap() {
    let workflow = workflow(transitions: [
      WorkflowStepTransition(
        toStepId: "branch",
        fanout: WorkflowStepFanout(
          groupId: "group",
          itemsFrom: "/items",
          joinStepId: "join",
          writeOwnership: WorkflowFanoutWriteOwnership(mode: .isolatedWorkspace)
        )
      )
    ], extraSteps: [
      WorkflowStepRef(id: "branch", nodeId: "node", transitions: [WorkflowStepTransition(toStepId: "join")]),
      WorkflowStepRef(id: "join", nodeId: "node")
    ])

    let diagnostics = DeterministicWorkflowRunner.unsupportedFeatures(in: workflow).map(\.diagnostic)

    XCTAssertEqual(diagnostics.count, 1)
    XCTAssertEqual(diagnostics.first?.path, "workflow.steps.step.transitions.fanout.writeOwnership")
    XCTAssertEqual(
      diagnostics.first?.message,
      "step 'step' uses fanout writeOwnership isolated-workspace, which this runner does not support yet"
    )
  }

  func testCrossWorkflowDispatchSimulationRunnerPassesPreflightAndResumesLocally() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json"),
        WorkflowNodeRegistryRef(id: "resume-node", nodeFile: "nodes/resume-node.json")
      ],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(toStepId: "child", toWorkflowId: "child-workflow", resumeStepId: "resume")
          ]
        ),
        WorkflowStepRef(id: "resume", nodeId: "resume-node")
      ],
      nodes: [
        WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json"),
        WorkflowNodeRef(id: "resume", nodeFile: "nodes/resume-node.json")
      ]
    )
    let runner = DeterministicWorkflowRunner(
      store: store,
      adapter: StaticAdapter(output: output()),
      simulatesCrossWorkflowDispatch: true
    )

    let result = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: [
        "node": payload(),
        "resume-node": AgentNodePayload(id: "resume-node", executionBackend: .codexAgent, model: "gpt-5.5")
      ]
    ))

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["step", "resume"])
  }

  func testRuntimeCapabilityGapDecodesLegacyPayloadAsErrorSeverity() throws {
    let legacyData = Data("""
      {
        "path": "workflow.steps.step.transitions.fanout",
        "message": "unsupported"
      }
      """.utf8)
    let modernData = Data("""
      {
        "severity": "warning",
        "path": "workflow.steps.step.transitions.fanout",
        "message": "unsupported"
      }
      """.utf8)

    let legacy = try JSONDecoder().decode(WorkflowRuntimeCapabilityGap.self, from: legacyData)
    let modern = try JSONDecoder().decode(WorkflowRuntimeCapabilityGap.self, from: modernData)

    XCTAssertEqual(legacy.severity, .error)
    XCTAssertEqual(legacy.path, "workflow.steps.step.transitions.fanout")
    XCTAssertEqual(modern.severity, .warning)
  }

  func testDuplicateProgrammaticStepIdsFailValidationWithoutPreflightTrap() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let workflow = WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [
        WorkflowStepRef(
          id: "step",
          nodeId: "node",
          transitions: [
            WorkflowStepTransition(
              toStepId: "child",
              toWorkflowId: "child-workflow"
            )
          ]
        ),
        WorkflowStepRef(id: "step", nodeId: "node")
      ],
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    do {
      _ = try await runner.run(request(workflow: workflow))
      XCTFail("expected duplicate step validation failure")
    } catch DeterministicWorkflowRunnerError.invalidWorkflow(let message) {
      XCTAssertEqual(message, "workflow.steps[0].id: must be unique across workflow.steps[]")
    }
    XCTAssertFalse(DeterministicWorkflowRunner.unsupportedFeatures(in: workflow).isEmpty)
  }

  func testMaxConcurrencyIsAcceptedWithoutPreflightFailure() async throws {
    let store = InMemoryWorkflowRuntimeStore()
    let runner = DeterministicWorkflowRunner(store: store, adapter: StaticAdapter(output: output()))

    _ = try await runner.run(DeterministicWorkflowRunRequest(
      workflow: workflow(),
      nodePayloads: ["node": payload()],
      maxConcurrency: 2
    ))

    let latestSession = await store.latestSession(workflowId: "runner")
    XCTAssertEqual(latestSession?.status, .completed)
  }

  private func request(workflow: WorkflowDefinition) -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: workflow,
      nodePayloads: ["node": payload()]
    )
  }

  private func workflow(
    transitions: [WorkflowStepTransition]? = nil,
    extraSteps: [WorkflowStepRef] = []
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "runner",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "step", nodeId: "node", transitions: transitions)] + extraSteps,
      nodes: [WorkflowNodeRef(id: "step", nodeFile: "nodes/node.json")]
    )
  }

  private func payload() -> AgentNodePayload {
    AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5")
  }

  private func output() -> AdapterExecutionOutput {
    AdapterExecutionOutput(
      provider: "test",
      model: "gpt-5.5",
      promptText: "prompt",
      completionPassed: true,
      payload: ["status": .string("ok")]
    )
  }
}
