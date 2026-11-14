import XCTest
@testable import RielaCore

final class WorkflowBackendPolicyTests: XCTestCase {
  func testPolicyRejectsAmbiguousAndInvalidAuthoredValues() {
    let policy = WorkflowBackendPolicy(
      allowed: [.codexAgent, .codexAgent],
      preferred: [.claudeCodeAgent, .claudeCodeAgent],
      modelByBackend: [.officialOpenAISDK: " "]
    )
    let diagnostics = WorkflowBackendPolicyValidation.diagnostics(
      pin: .codexAgent, policy: policy, fallbackModel: "shared", path: "node.agent"
    )
    XCTAssertEqual(diagnostics.count, 8)
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix("backendPolicy") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("duplicate") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("included") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("empty") })
    XCTAssertTrue(diagnostics.contains { $0.message.contains("shared model") })
  }

  func testPolicyPrefersAuthoredBackendThenPreservesAllowedOrder() {
    let policy = WorkflowBackendPolicy(
      allowed: [.claudeCodeAgent, .codexAgent, .officialOpenAISDK],
      preferred: [.codexAgent, .officialOpenAISDK]
    )
    XCTAssertEqual(policy.orderedCandidates(), [.codexAgent, .officialOpenAISDK, .claudeCodeAgent])
  }

  func testPolicyRoundTripsPerBackendModelsAndRejectsEmptyAllowedWithoutTrapping() throws {
    let policy = WorkflowBackendPolicy(
      allowed: [.codexAgent, .claudeCodeAgent],
      preferred: [.claudeCodeAgent],
      modelByBackend: [.codexAgent: "gpt", .claudeCodeAgent: "claude"]
    )
    XCTAssertEqual(try JSONDecoder().decode(WorkflowBackendPolicy.self, from: JSONEncoder().encode(policy)), policy)

    let empty = WorkflowBackendPolicy(allowed: [], modelByBackend: [.codexAgent: "gpt"])
    let emptyDiagnostics = WorkflowBackendPolicyValidation.diagnostics(pin: nil, policy: empty)
    XCTAssertTrue(emptyDiagnostics.contains { $0.message.contains("at least one") })
    XCTAssertTrue(emptyDiagnostics.contains { $0.message.contains("requires an allowed") })
  }

  func testKnownModelValidationAndStrictFreshnessBoundary() {
    let policy = WorkflowBackendPolicy(allowed: [.codexAgent], modelByBackend: [.codexAgent: "unknown"])
    let diagnostics = WorkflowBackendPolicyValidation.diagnostics(
      pin: nil, policy: policy, knownModels: [.codexAgent: ["known"]]
    )
    XCTAssertTrue(diagnostics.contains { $0.message.contains("not known") })

    let date = Date(timeIntervalSinceReferenceDate: 1_000)
    let capability = BackendCapability(backend: .codexAgent, source: .observed, observedAt: date)
    XCTAssertFalse(capability.isFresh(at: date.addingTimeInterval(30), maximumAge: 30))
    XCTAssertTrue(capability.isFresh(at: date.addingTimeInterval(29), maximumAge: 30))
  }

  func testAgentValidationUsesPolicyRulesWithoutBreakingLegacyPayloads() throws {
    let legacy = try JSONDecoder().decode(AgentNodePayload.self, from: Data(#"{"id":"agent","model":"model"}"#.utf8))
    XCTAssertNil(legacy.backendPolicy)

    let payload = AgentNodePayload(
      id: "agent", executionBackend: .codexAgent,
      backendPolicy: WorkflowBackendPolicy(allowed: [.codexAgent]), model: "model"
    )
    XCTAssertTrue(validateAgentNodePayload(payload).contains { $0.message.contains("cannot be combined") })

    let provider = try AgentProviderConfiguration(name: "provider", baseUrl: "https://example.com")
    let policyOnly = AgentNodePayload(
      id: "agent",
      backendPolicy: WorkflowBackendPolicy(allowed: [.codexAgent]),
      model: "model",
      provider: provider
    )
    XCTAssertFalse(validateAgentNodePayload(policyOnly).contains {
      $0.message.contains("requires an agent-gateway-backed executionBackend")
    })
  }

  func testReachableRequirementsFollowCallsAndCyclesButSkipUnreachableAndReusedPrefixes() throws {
    let defaults = WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 2)
    let root = WorkflowDefinition(
      workflowId: "root",
      defaults: defaults,
      entryStepId: "start",
      nodeRegistry: [],
      steps: [
        WorkflowStepRef(id: "start", nodeId: "start-node", transitions: [
          WorkflowStepTransition(toStepId: "child-start", toWorkflowId: "child", resumeStepId: "done")
        ]),
        WorkflowStepRef(id: "done", nodeId: "done-node"),
        WorkflowStepRef(id: "unreachable", nodeId: "unreachable-node")
      ],
      nodes: []
    )
    let child = WorkflowDefinition(
      workflowId: "child",
      defaults: defaults,
      entryStepId: "child-start",
      nodeRegistry: [],
      steps: [
        WorkflowStepRef(
          id: "child-start",
          nodeId: "child-node",
          transitions: [WorkflowStepTransition(toStepId: "child-start")]
        )
      ],
      nodes: []
    )
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: "root",
      workflows: ["root": root, "child": child],
      nodePayloads: [
        "root": [
          "start-node": AgentNodePayload(id: "start-node", executionBackend: .codexAgent, model: "gpt"),
          "done-node": AgentNodePayload(id: "done-node", executionBackend: .officialOpenAISDK, model: "gpt"),
          "unreachable-node": AgentNodePayload(id: "unreachable-node", executionBackend: .claudeCodeAgent, model: "claude")
        ],
        "child": [
          "child-node": AgentNodePayload(id: "child-node", executionBackend: .officialAnthropicSDK, model: "claude")
        ]
      ],
      reusedPrefixStepIds: ["root:start"]
    )
    XCTAssertEqual(requirements.compactMap(\.pin), [.officialAnthropicSDK, .officialOpenAISDK])
    XCTAssertFalse(requirements.flatMap(\.provenance).contains { $0.stepId == "unreachable" })

    let context = WorkflowPlanningCapabilityContext(
      host: HostCapabilitySnapshot(
        hostId: "local",
        backends: [],
        refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
      ),
      requirements: requirements
    )
    XCTAssertNotNil(try context.workflowVariables()["hostCapabilityContext"])
  }

  func testRequirementProjectionIncludesCustomAPIKeyEnvironment() throws {
    let workflow = WorkflowDefinition(
      workflowId: "custom-provider",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [],
      steps: [WorkflowStepRef(id: "run", nodeId: "agent")],
      nodes: []
    )
    let payload = AgentNodePayload(
      id: "agent",
      executionBackend: .codexAgent,
      model: "custom",
      baseURL: "https://example.com",
      apiKeyEnvironment: "CUSTOM_API_KEY"
    )
    let requirement = try XCTUnwrap(WorkflowRequirementResolver().resolve(
      workflowId: workflow.workflowId,
      workflows: [workflow.workflowId: workflow],
      nodePayloads: [workflow.workflowId: ["agent": payload]]
    ).first)
    XCTAssertEqual(requirement.requiredEnvironment, ["CUSTOM_API_KEY"])
  }

  func testExplicitCommandPlacementProjectsProvenanceWithoutBackendPolicy() throws {
    let workflow = WorkflowDefinition(
      workflowId: "command-placement",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [.init(id: "command", nodeFile: "node.json")],
      steps: [.init(id: "run", nodeId: "command", placement: .init(
        target: .init(workerId: "worker"), workspace: "project"
      ))],
      nodes: [.init(id: "command", nodeFile: "node.json")]
    )
    let payload = AgentNodePayload(id: "command", nodeType: .command, model: "", command: .init(executable: "/usr/bin/true"))
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: workflow.workflowId,
      workflows: [workflow.workflowId: workflow],
      nodePayloads: [workflow.workflowId: ["command": payload]]
    )
    XCTAssertEqual(requirements.count, 1)
    XCTAssertEqual(requirements.first?.provenance, [.init(workflowId: "command-placement", stepId: "run", nodeId: "command")])
    XCTAssertNil(requirements.first?.pin)
    XCTAssertNil(requirements.first?.policy)
  }

  func testRequirementProjectionKeepsPackageEnvironmentWithoutBackendPin() throws {
    let workflow = WorkflowDefinition(
      workflowId: "package-env",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [],
      steps: [WorkflowStepRef(id: "run", nodeId: "agent")],
      nodes: []
    )
    let payload = AgentNodePayload(id: "agent", model: "test-model")
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: workflow.workflowId,
      workflows: [workflow.workflowId: workflow],
      nodePayloads: [workflow.workflowId: ["agent": payload]],
      nodeHostRequirements: [workflow.workflowId: [
        "agent": WorkflowNodeHostRequirement(requiredEnvironment: ["PACKAGE_TOKEN"])
      ]]
    )
    XCTAssertEqual(requirements.count, 1)
    XCTAssertEqual(requirements.first?.requiredEnvironment, ["PACKAGE_TOKEN"])
    XCTAssertNil(requirements.first?.pin)
  }

  func testProviderPolicyRejectsUnsupportedBackend() throws {
    let payload = AgentNodePayload(
      id: "agent",
      backendPolicy: WorkflowBackendPolicy(allowed: [.cursorCliAgent]),
      model: "model",
      provider: try AgentProviderConfiguration(name: "provider", baseUrl: "https://example.com")
    )
    XCTAssertTrue(validateAgentNodePayload(payload).contains {
      $0.path == "node.backendPolicy.allowed" && $0.message.contains("cursor-cli-agent")
    })
  }

  func testAddonOnlyNodeProjectsResolvedExecutableWithoutAddonDependency() throws {
    let workflow = WorkflowDefinition(
      workflowId: "addon-only",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool",
        addon: WorkflowNodeAddonRef(name: "example/tool", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )
    let requirements = try WorkflowRequirementResolver().resolve(
      workflowId: workflow.workflowId,
      workflows: [workflow.workflowId: workflow],
      nodePayloads: [workflow.workflowId: [:]],
      nodeHostRequirements: [workflow.workflowId: [
        "tool": WorkflowNodeHostRequirement(addonExecutable: "tool-cli")
      ]]
    )
    XCTAssertEqual(requirements.count, 1)
    XCTAssertEqual(requirements.first?.addonExecutable, "tool-cli")
    XCTAssertNil(requirements.first?.pin)
  }

  func testAddonOnlyNodeWithoutResolvedExecutableFailsRequirementResolution() {
    let workflow = WorkflowDefinition(
      workflowId: "unresolved-addon",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(
        id: "tool",
        addon: WorkflowNodeAddonRef(name: "example/tool", version: "1")
      )],
      steps: [WorkflowStepRef(id: "run", nodeId: "tool")],
      nodes: []
    )

    XCTAssertThrowsError(try WorkflowRequirementResolver().resolve(
      workflowId: workflow.workflowId,
      workflows: [workflow.workflowId: workflow],
      nodePayloads: [workflow.workflowId: [:]]
    )) { error in
      XCTAssertEqual(
        error as? WorkflowRequirementResolutionError,
        .unresolvedAddonExecutable(workflowId: workflow.workflowId, nodeId: "tool")
      )
    }
  }
}
