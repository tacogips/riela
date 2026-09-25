import XCTest
@testable import RielaCore

final class AgentNodeOutputContractValidationTests: XCTestCase {
  func testSandboxDeclarationMatchesBackendCapability() {
    for backend in [NodeExecutionBackend.codexAgent, .claudeCodeAgent, .cursorCliAgent] {
      let diagnostics = validate(singleAgent: AgentNodePayload(
        id: "agent", executionBackend: backend, model: "model"
      ))
      XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix("agentSandbox") && $0.message.contains("must declare") })
    }

    for backend in [
      NodeExecutionBackend.officialOpenAISDK, .officialAnthropicSDK,
      .officialGeminiSDK, .officialCursorSDK
    ] {
      let diagnostics = validate(singleAgent: AgentNodePayload(
        id: "agent", executionBackend: backend, model: "model", agentSandbox: .readOnly
      ))
      XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix("agentSandbox") && $0.message.contains("not supported") })
    }
  }

  func testTemplateClassifierKeepsContextLenientAndSplitsAddonSurfaces() {
    let configSurface = TemplateSurface.addonConfig(addonInputKeys: ["results"])
    XCTAssertEqual(classifyTemplateReference("event.input.text", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("workflowInput.name", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("input._rielaInput.latest.fromStepId", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("input.upstream.value", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("input.runtime.value", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("results", surface: configSurface), .context)
    XCTAssertEqual(classifyTemplateReference("results", surface: .addonInputs), .payload)
    XCTAssertEqual(classifyTemplateReference("teamName", surface: configSurface), .payload)
    XCTAssertEqual(classifyTemplateReference("commitMessage", surface: configSurface), .payload)
    XCTAssertEqual(classifyTemplateReference("input.commitMessage", surface: configSurface), .payload)
    XCTAssertEqual(classifyTemplateReference("inbox.latest.output.payload.commitMessage", surface: configSurface), .payload)
  }

  func testPayloadReferencesRequireProducerSchemaAndDeclaredFieldAcrossAddonRelay() {
    for reference in [
      "{{commitMessage}}",
      "{{input.commitMessage}}",
      "{{inbox.latest.output.payload.commitMessage}}"
    ] {
      let workflow = relayedWorkflow(reference: reference)
      let missingSchema = DefaultWorkflowValidator().validate(
        workflow,
        nodePayloads: ["agent": compliantAgent(output: nil)]
      )
      XCTAssertTrue(missingSchema.contains {
        $0.path == "workflow.nodes.agent.output.jsonSchema" && $0.message.contains("commitMessage")
      })
      XCTAssertFalse(missingSchema.contains { $0.path.contains("workflow.nodes.relay") })

      let missingProperty = DefaultWorkflowValidator().validate(
        workflow,
        nodePayloads: ["agent": compliantAgent(output: NodeOutputContract(jsonSchema: ["type": .string("object")]))]
      )
      XCTAssertTrue(missingProperty.contains { $0.path.hasSuffix("properties.commitMessage") })
    }
  }

  func testAddonInputCannotResolveFromAnotherDeclaredInput() {
    let workflow = baseWorkflow(
      registry: [
        WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json"),
        WorkflowNodeRegistryRef(id: "consumer", addon: WorkflowNodeAddonRef(
          name: "riela/example",
          inputs: ["first": .string("{{input.source}}"), "second": .string("{{first}}")]
        ))
      ],
      steps: [
        WorkflowStepRef(id: "produce", nodeId: "agent", transitions: [WorkflowStepTransition(toStepId: "consume")]),
        WorkflowStepRef(id: "consume", nodeId: "consumer")
      ]
    )
    let schema = NodeOutputContract(jsonSchema: [
      "type": .string("object"),
      "properties": .object(["source": .object(["type": .string("string")])])
    ])

    let diagnostics = DefaultWorkflowValidator().validate(
      workflow,
      nodePayloads: ["agent": compliantAgent(output: schema)]
    )

    XCTAssertTrue(diagnostics.contains {
      $0.path.hasSuffix("properties.first") && $0.message.contains("first")
    })
  }

  func testAgentVariablesDoNotExcludeBareAddonPayloadReferences() {
    let workflow = relayedWorkflow(reference: "{{teamName}}")
    let producer = AgentNodePayload(
      id: "agent", executionBackend: .codexAgent, model: "model",
      agentSandbox: .readOnly, variables: ["teamName": .string("declared-only-on-agent")]
    )

    let diagnostics = DefaultWorkflowValidator().validate(
      workflow,
      nodePayloads: ["agent": producer]
    )

    XCTAssertTrue(diagnostics.contains {
      $0.path == "workflow.nodes.agent.output.jsonSchema" && $0.message.contains("teamName")
    })
  }

  func testConditionalLabelsRequireSchemaAndProducerWalkTerminatesWithoutAgent() {
    var workflow = baseWorkflow(
      registry: [WorkflowNodeRegistryRef(id: "addon", addon: WorkflowNodeAddonRef(name: "riela/kv-set"))],
      steps: [WorkflowStepRef(id: "only", nodeId: "addon", transitions: [WorkflowStepTransition(toStepId: "only")])]
    )
    XCTAssertTrue(DefaultWorkflowValidator().validate(workflow, nodePayloads: [:]).isEmpty)

    workflow = baseWorkflow(
      registry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")],
      steps: [WorkflowStepRef(
        id: "only", nodeId: "agent",
        transitions: [WorkflowStepTransition(toStepId: "only", label: "accepted")]
      )]
    )
    let diagnostics = DefaultWorkflowValidator().validate(
      workflow,
      nodePayloads: ["agent": compliantAgent(output: NodeOutputContract(description: "envelope"))]
    )
    XCTAssertTrue(diagnostics.contains { $0.message.contains("conditional transition labels") })
    XCTAssertTrue(diagnostics.contains {
      $0.severity == .warning && $0.path == "workflow.nodes.agent.output.jsonSchema" &&
        $0.message.contains("analysis_incomplete: route control 'accepted'")
    })
  }

  func testConditionalRouteGuaranteeDiagnosticsInspectAllIdentifiers() {
    let registry = [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")]
    let malformed = baseWorkflow(registry: registry, steps: [WorkflowStepRef(
      id: "only", nodeId: "agent", transitions: [WorkflowStepTransition(toStepId: "only", label: "true || !")]
    )])
    let schema: JSONObject = [
      "type": .string("object"),
      "properties": .object(["flag": .object(["type": .string("boolean")])])
    ]
    let agent = compliantAgent(output: NodeOutputContract(jsonSchema: schema))
    let malformedDiagnostics = DefaultWorkflowValidator().validate(malformed, nodePayloads: ["agent": agent])
    XCTAssertTrue(malformedDiagnostics.contains {
      $0.severity == .error && $0.path == "workflow.steps.only.transitions[0].label" &&
        $0.message.contains("route.invalidCondition")
    })

    let shortCircuited = baseWorkflow(registry: registry, steps: [WorkflowStepRef(
      id: "only", nodeId: "agent", transitions: [WorkflowStepTransition(toStepId: "only", label: "true || flag")]
    )])
    let incomplete = DefaultWorkflowValidator().validate(shortCircuited, nodePayloads: ["agent": agent])
    XCTAssertTrue(incomplete.contains {
      $0.severity == .warning && $0.path.hasSuffix("/properties/flag") &&
        $0.message.contains("analysis_incomplete")
    })

    var required = schema
    required["required"] = .array([.string("flag")])
    let proven = DefaultWorkflowValidator().validate(
      shortCircuited, nodePayloads: ["agent": compliantAgent(output: NodeOutputContract(jsonSchema: required))]
    )
    XCTAssertFalse(proven.contains { $0.message.contains("analysis_incomplete") })
  }

  private func validate(singleAgent payload: AgentNodePayload) -> [WorkflowValidationDiagnostic] {
    DefaultWorkflowValidator().validate(
      baseWorkflow(
        registry: [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")],
        steps: [WorkflowStepRef(id: "only", nodeId: "agent")]
      ),
      nodePayloads: ["agent": payload]
    )
  }

  private func compliantAgent(output: NodeOutputContract?) -> AgentNodePayload {
    AgentNodePayload(
      id: "agent", executionBackend: .codexAgent, model: "model",
      agentSandbox: .readOnly, output: output
    )
  }

  private func relayedWorkflow(reference: String) -> WorkflowDefinition {
    baseWorkflow(
      registry: [
        WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json"),
        WorkflowNodeRegistryRef(id: "relay", addon: WorkflowNodeAddonRef(name: "riela/kv-set")),
        WorkflowNodeRegistryRef(id: "consumer", addon: WorkflowNodeAddonRef(
          name: "riela/git-commit", config: ["commitMessageTemplate": .string(reference)]
        ))
      ],
      steps: [
        WorkflowStepRef(id: "produce", nodeId: "agent", transitions: [WorkflowStepTransition(toStepId: "relay")]),
        WorkflowStepRef(id: "relay", nodeId: "relay", transitions: [WorkflowStepTransition(toStepId: "consume")]),
        WorkflowStepRef(id: "consume", nodeId: "consumer")
      ]
    )
  }

  private func baseWorkflow(
    registry: [WorkflowNodeRegistryRef],
    steps: [WorkflowStepRef]
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "agent-output-contract", defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: steps[0].id, nodeRegistry: registry, steps: steps,
      nodes: registry.map { WorkflowNodeRef(id: $0.id, nodeFile: $0.nodeFile, addon: $0.addon) }
    )
  }
}
