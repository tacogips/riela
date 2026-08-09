import XCTest
@testable import RielaCore

final class WorkflowModelTests: XCTestCase {
  func testNormalizesKnownBackends() {
    XCTAssertEqual(normalizeCliAgentBackend("codex-agent"), .codexAgent)
    XCTAssertEqual(normalizeCliAgentBackend("claude-code-agent"), .claudeCodeAgent)
    XCTAssertEqual(normalizeCliAgentBackend("cursor-cli-agent"), .cursorCliAgent)
    XCTAssertNil(normalizeCliAgentBackend("official/openai-sdk"))
    XCTAssertEqual(normalizeNodeExecutionBackend("official/anthropic-sdk"), .officialAnthropicSDK)
    XCTAssertEqual(normalizeNodeExecutionBackend("official/gemini-sdk"), .officialGeminiSDK)
  }

  func testWorkflowDecodesStepAddressedShape() throws {
    let data = Data("""
      {
        "workflowId": "sample",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "main",
        "nodes": [{ "id": "main", "nodeFile": "nodes/main.json" }],
        "steps": [{ "id": "main", "nodeId": "main", "role": "worker" }]
      }
      """.utf8)

    let workflow = try JSONDecoder().decode(AuthoredWorkflowJSON.self, from: data)

    XCTAssertEqual(workflow.workflowId, "sample")
    XCTAssertEqual(workflow.defaults.nodeTimeoutMs, 120000)
    XCTAssertEqual(workflow.nodes.first?.nodeFile, "nodes/main.json")
    XCTAssertEqual(workflow.steps?.first?.role, .worker)
  }

  func testWorkflowDecodesNodeInputFilters() throws {
    let data = Data("""
      {
        "workflowId": "telegram-filtered",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "reply",
        "nodes": [{
          "id": "reply",
          "nodeFile": "nodes/reply.json",
          "inputFilters": [{
            "kind": "telegram",
            "language": "javascript",
            "expression": "telegram.message.text.includes('@yui')"
          }]
        }],
        "steps": [{ "id": "reply", "nodeId": "reply", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    let workflow = try XCTUnwrap(result.workflow)
    XCTAssertEqual(workflow.nodeRegistry.first?.inputFilters?.first?.kind, .telegram)
    XCTAssertEqual(workflow.nodeRegistry.first?.inputFilters?.first?.expression, "telegram.message.text.includes('@yui')")
    XCTAssertEqual(workflow.nodes.first?.inputFilters?.first?.kind, .telegram)
  }

  func testDefaultWorkflowValidatorRejectsDuplicateProgrammaticStepAndNodeIds() {
    let workflow = WorkflowDefinition(
      workflowId: "duplicate-programmatic",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "step",
      nodeRegistry: [
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/one.json"),
        WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/two.json")
      ],
      steps: [
        WorkflowStepRef(id: "step", nodeId: "node"),
        WorkflowStepRef(id: "step", nodeId: "node")
      ],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/one.json")]
    )

    let diagnostics = DefaultWorkflowValidator().validate(workflow)

    XCTAssertTrue(diagnostics.contains(error("workflow.nodes[0].id", "must be unique across workflow.nodes[]")))
    XCTAssertTrue(diagnostics.contains(error("workflow.nodes[1].id", "must be unique across workflow.nodes[]")))
    XCTAssertTrue(diagnostics.contains(error("workflow.steps[0].id", "must be unique across workflow.steps[]")))
    XCTAssertTrue(diagnostics.contains(error("workflow.steps[1].id", "must be unique across workflow.steps[]")))
  }

  func testWorkflowValidationRejectsUnsupportedNodeInputFilterKind() throws {
    let data = Data("""
      {
        "workflowId": "telegram-filtered",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "reply",
        "nodes": [{
          "id": "reply",
          "nodeFile": "nodes/reply.json",
          "inputFilters": [{
            "kind": "matrix",
            "language": "javascript",
            "expression": "true"
          }]
        }],
        "steps": [{ "id": "reply", "nodeId": "reply", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.nodes[0].inputFilters[0].kind" && $0.message == "must be 'telegram'"
    })
  }

  func testWorkflowValidationAcceptsBuiltinInputFilter() throws {
    let data = Data("""
      {
        "workflowId": "telegram-filtered",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "reply",
        "nodes": [{
          "id": "reply",
          "nodeFile": "nodes/reply.json",
          "inputFilters": [{
            "kind": "telegram",
            "builtin": "mention-responder",
            "config": {
              "aliases": ["yui", "@yuicodexf0529bot"],
              "selfUsernames": ["yuicodexf0529bot"]
            }
          }]
        }],
        "steps": [{ "id": "reply", "nodeId": "reply", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    let workflow = try XCTUnwrap(result.workflow)
    XCTAssertEqual(workflow.nodeRegistry.first?.inputFilters?.first?.builtin, .mentionResponder)
  }

  func testWorkflowValidationAcceptsNodeReferenceSource() throws {
    let data = Data("""
      {
        "workflowId": "telegram-persona",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "reply",
        "nodes": [{
          "id": "reply",
          "nodeRef": { "workflowId": "shared-personas", "nodeId": "mika" }
        }],
        "steps": [{ "id": "reply", "nodeId": "reply", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    let registryNode = try XCTUnwrap(result.workflow?.nodeRegistry.first)
    XCTAssertEqual(registryNode.nodeRef, WorkflowSharedNodeRef(workflowId: "shared-personas", nodeId: "mika"))
    XCTAssertNil(registryNode.nodeFile)
    XCTAssertNil(registryNode.addon)
    XCTAssertEqual(result.workflow?.nodes.first?.nodeRef?.workflowId, "shared-personas")
  }

  func testWorkflowValidationRejectsMultipleNodeSources() throws {
    let data = Data("""
      {
        "workflowId": "bad-persona",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "reply",
        "nodes": [{
          "id": "reply",
          "nodeFile": "nodes/reply.json",
          "nodeRef": { "workflowId": "shared-personas", "nodeId": "mika" }
        }],
        "steps": [{ "id": "reply", "nodeId": "reply", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.nodes[0]" && $0.message == "must define only one of nodeFile, nodeRef, or addon"
    })
  }

  func testWorkflowValidationRequiresDeclaredMemoryForBuiltinMemoryAddons() throws {
    let data = Data("""
      {
        "workflowId": "memory-declarations",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "save-memory",
        "nodes": [{
          "id": "save-memory",
          "addon": {
            "name": "riela/memory-save",
            "version": "1",
            "config": {
              "memoryId": "chat-memory",
              "payloadSource": "event"
            }
          }
        }],
        "steps": [{ "id": "save-memory", "nodeId": "save-memory", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.nodes[0].addon.config.memoryId"
        && $0.message == "memory addon uses 'chat-memory' but workflow.memories does not declare it"
    })
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.nodes[0].memories"
        && $0.message == "memory addon uses 'chat-memory' but node memories do not declare it"
    })
  }

  func testWorkflowValidationAcceptsDeclaredMemoryForBuiltinMemoryAddons() throws {
    let data = Data("""
      {
        "workflowId": "memory-declarations",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "memories": [{ "id": "chat-memory", "scope": "workflow", "defaultLimit": 30 }],
        "entryStepId": "save-memory",
        "nodes": [{
          "id": "save-memory",
          "memories": [{ "id": "chat-memory", "purpose": "save incoming chat events" }],
          "addon": {
            "name": "riela/memory-save",
            "version": "1",
            "config": {
              "memoryId": "chat-memory",
              "payloadSource": "event"
            }
          }
        }],
        "steps": [{ "id": "save-memory", "nodeId": "save-memory", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.memories?.first?.id, "chat-memory")
    XCTAssertEqual(result.workflow?.nodeRegistry.first?.memories?.first?.id, "chat-memory")
  }

  func testWorkflowValidationUsesPersonaMemoryDefaultForPersonaAddons() throws {
    let data = Data("""
      {
        "workflowId": "persona-memory-declarations",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "memories": [{ "id": "persona-chat-memory", "scope": "cross-workflow", "defaultLimit": 30 }],
        "entryStepId": "read-memory",
        "nodes": [{
          "id": "read-memory",
          "memories": [{ "id": "persona-chat-memory", "purpose": "read persona chat memory" }],
          "addon": {
            "name": "riela/chat-persona-memory-read",
            "version": "1",
            "config": {
              "personaId": "yui"
            }
          }
        }],
        "steps": [{ "id": "read-memory", "nodeId": "read-memory", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertEqual(result.diagnostics.filter { $0.severity == .error }, [])
    XCTAssertEqual(result.workflow?.memories?.first?.id, "persona-chat-memory")
    XCTAssertEqual(result.workflow?.nodeRegistry.first?.memories?.first?.id, "persona-chat-memory")
  }

  func testWorkflowValidationLoadsProjectDesignLoopFixture() throws {
    let rootURL = try repositoryRoot()
    let fixtureURL = rootURL.appendingPathComponent(".riela/workflows/codex-design-and-implement-review-loop/workflow.json")
    let data = try Data(contentsOf: fixtureURL)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertTrue(result.diagnostics.filter { $0.severity == .error }.isEmpty)
    let workflow = try XCTUnwrap(result.workflow)
    XCTAssertEqual(workflow.workflowId, "codex-design-and-implement-review-loop")
    XCTAssertEqual(workflow.entryStepId, "riela-manager")
    XCTAssertEqual(workflow.managerStepId, "riela-manager")
    XCTAssertEqual(workflow.defaults.fanoutConcurrency, 20)
    XCTAssertTrue(workflow.steps.contains { $0.id == "step6-implement" })
    XCTAssertEqual(workflow.steps.first?.transitions?.first?.toStepId, "step1-issue-intake")

    let gitCommitNode = try XCTUnwrap(workflow.nodes.first { $0.id == "step10-git-commit" })
    XCTAssertNil(gitCommitNode.nodeFile)
    XCTAssertEqual(gitCommitNode.addon?.name, "riela/git-commit")
    XCTAssertEqual(gitCommitNode.addon?.version, "1")
    XCTAssertEqual(gitCommitNode.addon?.config?["allowCommit"], .bool(true))

    let gitPushNode = try XCTUnwrap(workflow.nodes.first { $0.id == "step11-git-push" })
    XCTAssertNil(gitPushNode.nodeFile)
    XCTAssertEqual(gitPushNode.addon?.name, "riela/git-push")
    XCTAssertEqual(gitPushNode.addon?.version, "1")
    XCTAssertEqual(gitPushNode.addon?.config?["allowPush"], .bool(true))
    XCTAssertEqual(
      gitPushNode.addon?.config?["expectedCommitHashTemplate"],
      .string("{{inbox.latest.output.payload.git.commitHash}}")
    )

    let outputStep = try XCTUnwrap(workflow.steps.first { $0.id == "workflow-output" })
    XCTAssertEqual(
      DeterministicWorkflowRunner.gitFinalizationEvidencePolicy(
        workflow: workflow,
        terminalStep: outputStep
      ),
      WorkflowGitFinalizationEvidencePolicy(
        commitStepId: "step10-git-commit",
        pushStepId: "step11-git-push",
        planningModeStepIds: ["step5-impl-plan-review", "step5-feature-plan-join"]
      )
    )
    var unrelatedWorkflow = workflow
    unrelatedWorkflow.workflowId = "design-and-implement-review-loop"
    XCTAssertNil(DeterministicWorkflowRunner.gitFinalizationEvidencePolicy(
      workflow: unrelatedWorkflow,
      terminalStep: outputStep
    ))
  }

  func testProtectedGitFinalizationPolicyFailsClosedOnTopologyDrift() throws {
    let fixtureURL = try repositoryRoot().appendingPathComponent(
      ".riela/workflows/codex-design-and-implement-review-loop/workflow.json"
    )
    let workflow = try XCTUnwrap(validateAuthoredWorkflowData(Data(contentsOf: fixtureURL)).workflow)
    let outputStep = try XCTUnwrap(workflow.steps.first { $0.id == "workflow-output" })
    XCTAssertNoThrow(try DeterministicWorkflowRunner.requiredGitFinalizationEvidencePolicy(
      workflow: workflow,
      terminalStep: outputStep
    ))

    var intermediateStepWorkflow = workflow
    let pushIndex = try XCTUnwrap(intermediateStepWorkflow.steps.firstIndex { $0.id == "step11-git-push" })
    intermediateStepWorkflow.steps[pushIndex].transitions = [WorkflowStepTransition(toStepId: "post-push-audit")]
    intermediateStepWorkflow.steps.append(WorkflowStepRef(
      id: "post-push-audit",
      nodeId: "workflow-output",
      transitions: [WorkflowStepTransition(toStepId: "workflow-output")]
    ))
    try assertProtectedGitFinalizationPolicyRejected(intermediateStepWorkflow)

    var renamedPlanningRouteWorkflow = workflow
    for index in renamedPlanningRouteWorkflow.steps.indices {
      renamedPlanningRouteWorkflow.steps[index].transitions = renamedPlanningRouteWorkflow.steps[index].transitions?.map {
        var transition = $0
        if transition.label?.contains("planning_only") == true {
          transition.label = "renamed-planning-route"
        }
        return transition
      }
    }
    try assertProtectedGitFinalizationPolicyRejected(renamedPlanningRouteWorkflow)

    var missingPushNodeWorkflow = workflow
    missingPushNodeWorkflow.nodes.removeAll { $0.id == "step11-git-push" }
    try assertProtectedGitFinalizationPolicyRejected(missingPushNodeWorkflow)

    var ambiguousPushWorkflow = workflow
    ambiguousPushWorkflow.steps.append(WorkflowStepRef(
      id: "duplicate-git-push",
      nodeId: "step11-git-push",
      transitions: [WorkflowStepTransition(toStepId: "workflow-output")]
    ))
    try assertProtectedGitFinalizationPolicyRejected(ambiguousPushWorkflow)

    var detachedPushWorkflow = workflow
    let duplicatePushAddon = try XCTUnwrap(
      detachedPushWorkflow.nodes.first { $0.id == "step11-git-push" }?.addon
    )
    detachedPushWorkflow.nodes.append(WorkflowNodeRef(
      id: "detached-git-push",
      addon: duplicatePushAddon
    ))
    detachedPushWorkflow.steps.append(WorkflowStepRef(
      id: "detached-git-push",
      nodeId: "detached-git-push"
    ))
    try assertProtectedGitFinalizationPolicyRejected(detachedPushWorkflow)

    var outOfChainCommitWorkflow = workflow
    let duplicateCommitAddon = try XCTUnwrap(
      outOfChainCommitWorkflow.nodes.first { $0.id == "step10-git-commit" }?.addon
    )
    outOfChainCommitWorkflow.nodes.append(WorkflowNodeRef(
      id: "out-of-chain-git-commit",
      addon: duplicateCommitAddon
    ))
    outOfChainCommitWorkflow.steps.append(WorkflowStepRef(
      id: "out-of-chain-git-commit",
      nodeId: "out-of-chain-git-commit",
      transitions: [WorkflowStepTransition(toStepId: "step1-issue-intake")]
    ))
    try assertProtectedGitFinalizationPolicyRejected(outOfChainCommitWorkflow)
  }

  func testWorkflowOutputPromptRejectsMissingStaleOrMismatchedGitEvidence() throws {
    let promptURL = try repositoryRoot().appendingPathComponent(
      ".riela/workflows/codex-design-and-implement-review-loop/prompts/workflow-output.md"
    )
    let prompt = try String(contentsOf: promptURL, encoding: .utf8)
    let normalizedPrompt = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")

    XCTAssertTrue(normalizedPrompt.contains("Treat only `step10-git-commit`'s accepted `payload.git` object as commit evidence"))
    XCTAssertTrue(normalizedPrompt.contains("only `step11-git-push`'s accepted `payload.git` object as push evidence"))
    XCTAssertTrue(normalizedPrompt.contains("require Step 11's `commitHash` to match it"))
    XCTAssertTrue(normalizedPrompt.contains("If any required field is missing or mismatched"))
    XCTAssertTrue(normalizedPrompt.contains("do not fabricate finalization evidence"))
    for requiredField in ["commitMessage", "commitHash", "committedFiles", "pushedRemote", "pushedBranch"] {
      XCTAssertTrue(prompt.contains("`\(requiredField)`"), requiredField)
    }

    let nodeURL = try repositoryRoot().appendingPathComponent(
      ".riela/workflows/codex-design-and-implement-review-loop/nodes/node-workflow-output.json"
    )
    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: Data(contentsOf: nodeURL))
    let schema = try XCTUnwrap(payload.output?.jsonSchema)
    XCTAssertEqual(schema["type"], .string("object"))
    guard case let .object(properties)? = schema["properties"],
          case let .object(statusSchema)? = properties["status"] else {
      return XCTFail("missing status output schema")
    }
    XCTAssertEqual(statusSchema["const"], .string("accepted"))
    guard case let .array(requiredValues)? = schema["required"] else {
      return XCTFail("missing required output fields")
    }
    let required = Set(requiredValues.compactMap { value -> String? in
      guard case let .string(text) = value else { return nil }
      return text
    })
    XCTAssertEqual(required, ["status", "workflowMode"])
    guard case let .array(modeSchemas)? = schema["oneOf"], modeSchemas.count == 2,
          case let .object(planningSchema) = modeSchemas[0],
          case let .array(planningRequiredValues)? = planningSchema["required"],
          case let .object(issueSchema) = modeSchemas[1],
          case let .array(issueRequiredValues)? = issueSchema["required"] else {
      return XCTFail("missing mode-conditional evidence schema")
    }
    let planningRequired = Set(planningRequiredValues.compactMap { value -> String? in
      guard case let .string(text) = value else { return nil }
      return text
    })
    let issueRequired = Set(issueRequiredValues.compactMap { value -> String? in
      guard case let .string(text) = value else { return nil }
      return text
    })
    let finalizationEvidenceFields: Set<String> = [
      "commitMessage", "commitHash", "committedFiles", "pushedRemote", "pushedBranch"
    ]
    XCTAssertEqual(planningRequired, finalizationEvidenceFields)
    XCTAssertEqual(issueRequired, finalizationEvidenceFields)

    let validator = DefaultWorkflowOutputValidator()
    let contract = WorkflowOutputContract(schema: schema, requiredObject: true)
    let commitHash = String(repeating: "a", count: 40)
    let planningResult = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: [
        "status": .string("accepted"),
        "workflowMode": .string("design-plan-only"),
        "commitMessage": .string("docs: record accepted plan"),
        "commitHash": .string(commitHash),
        "committedFiles": .array([.string("impl-plans/completed/accepted-plan.md")]),
        "pushedRemote": .string("origin"),
        "pushedBranch": .string("main")
      ]),
      contract: contract
    )
    XCTAssertEqual(planningResult.status, .accepted)
    let missingPlanningEvidence = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: [
        "status": .string("accepted"),
        "workflowMode": .string("design-plan-only")
      ]),
      contract: contract
    )
    XCTAssertEqual(missingPlanningEvidence.status, .rejected)
    let missingIssueEvidence = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: [
        "status": .string("accepted"),
        "workflowMode": .string("issue-resolution")
      ]),
      contract: contract
    )
    XCTAssertEqual(missingIssueEvidence.status, .rejected)
  }

  func testCommandExecutionDecodesRielaScriptPathShape() throws {
    let data = Data("""
      {
        "scriptPath": "scripts/mock-command.sh",
        "argvTemplate": ["--lane", "command"],
        "envTemplate": { "SHOWCASE_LANE": "command" },
        "workingDirectory": "scripts"
      }
      """.utf8)

    let command = try JSONDecoder().decode(WorkflowCommandExecution.self, from: data)

    XCTAssertEqual(command.executable, "./mock-command.sh")
    XCTAssertEqual(command.arguments, ["--lane", "command"])
    XCTAssertEqual(command.environment, ["SHOWCASE_LANE": "command"])
    XCTAssertEqual(command.workingDirectory, "scripts")
  }

  func testContainerExecutionDecodesRielaBuildShape() throws {
    let data = Data("""
      {
        "build": {
          "contextPath": "containers/mock-worker",
          "containerfilePath": "containers/mock-worker/Containerfile"
        },
        "entrypoint": ["/bin/sh", "-lc"],
        "argsTemplate": ["printf ok"],
        "envTemplate": { "SHOWCASE_LANE": "container" },
        "workingDirectory": "/workspace"
      }
      """.utf8)

    let container = try JSONDecoder().decode(WorkflowContainerExecution.self, from: data)

    XCTAssertEqual(container.image, "containers/mock-worker")
    XCTAssertEqual(container.command, ["/bin/sh", "-lc", "printf ok"])
    XCTAssertEqual(container.environment, ["SHOWCASE_LANE": "container"])
    XCTAssertEqual(container.workingDirectory, "/workspace")
  }

  func testAgentNodePayloadDecodesAndEncodesAgentEnvironmentBindings() throws {
    let data = Data("""
      {
        "id": "planner",
        "executionBackend": "codex-agent",
        "model": "gpt-5",
        "modelFreeze": false,
        "agentEnvironment": {
          "OPENAI_BASE_URL": { "value": "https://{{router.host}}/v1" },
          "OPENAI_API_KEY": { "fromEnv": "RIELA_OPENAI_API_KEY", "required": true }
        }
      }
      """.utf8)

    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: data)

    XCTAssertEqual(payload.agentEnvironment["OPENAI_BASE_URL"]?.value, "https://{{router.host}}/v1")
    XCTAssertEqual(payload.agentEnvironment["OPENAI_API_KEY"]?.fromEnv, "RIELA_OPENAI_API_KEY")
    XCTAssertEqual(payload.agentEnvironment["OPENAI_API_KEY"]?.required, true)

    let encoded = try JSONEncoder().encode(payload)
    let roundTrip = try JSONDecoder().decode(AgentNodePayload.self, from: encoded)
    XCTAssertEqual(roundTrip.agentEnvironment, payload.agentEnvironment)
  }

  func testAgentNodePayloadDecodesSandboxAndToolPolicy() throws {
    let data = Data("""
      {
        "id": "output",
        "executionBackend": "codex-agent",
        "model": "gpt-5",
        "agentSandbox": "read-only",
        "agentToolPolicy": {
          "mode": "backend-arguments",
          "additionalArguments": ["--disable", "shell"],
          "codexArguments": ["--config", "tools.web_search=false"]
        },
        "output": {
          "projection": { "kind": "latest-input-payload" }
        }
      }
      """.utf8)

    let payload = try JSONDecoder().decode(AgentNodePayload.self, from: data)

    XCTAssertEqual(payload.agentSandbox, .readOnly)
    XCTAssertEqual(payload.agentToolPolicy?.mode, .backendArguments)
    XCTAssertEqual(payload.agentToolPolicy?.additionalArguments, ["--disable", "shell"])
    XCTAssertEqual(payload.agentToolPolicy?.codexArguments, ["--config", "tools.web_search=false"])
    XCTAssertEqual(payload.output?.projection?.kind, .latestInputPayload)
  }

  func testAgentNodePayloadDefaultsMissingModelFreezeToFalse() throws {
    let frozen = Data("""
      {
        "id": "planner",
        "executionBackend": "codex-agent",
        "model": "gpt-5",
        "modelFreeze": true
      }
      """.utf8)
    let missingModelFreeze = Data("""
      {
        "id": "planner",
        "executionBackend": "codex-agent",
        "model": "gpt-5"
      }
      """.utf8)

    XCTAssertTrue(try JSONDecoder().decode(AgentNodePayload.self, from: frozen).modelFreeze)
    XCTAssertFalse(try JSONDecoder().decode(AgentNodePayload.self, from: missingModelFreeze).modelFreeze)
  }

  func testAgentEnvironmentRejectsInvalidBindingShapes() {
    let data = Data("""
      {
        "id": "planner",
        "model": "gpt-5",
        "modelFreeze": false,
        "agentEnvironment": {
          "OPENAI_API_KEY": { "value": "literal", "fromEnv": "SOURCE_ENV" }
        }
      }
      """.utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(AgentNodePayload.self, from: data))
  }

  func testAgentEnvironmentRejectsInvalidAndReservedTargetNames() {
    let invalidName = Data("""
      {
        "id": "planner",
        "model": "gpt-5",
        "modelFreeze": false,
        "agentEnvironment": {
          "INVALID-NAME": { "value": "literal" }
        }
      }
      """.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(AgentNodePayload.self, from: invalidName))

    let reservedName = Data("""
      {
        "id": "planner",
        "model": "gpt-5",
        "modelFreeze": false,
        "agentEnvironment": {
          "RIELA_AGENT_BACKEND": { "value": "spoof" }
        }
      }
      """.utf8)
    XCTAssertThrowsError(try JSONDecoder().decode(AgentNodePayload.self, from: reservedName))
  }

  func testAgentEnvironmentResolutionTemplatesValuesAndRequiresSources() throws {
    let bindings: [String: AgentEnvironmentBinding] = [
      "OPENAI_BASE_URL": AgentEnvironmentBinding(value: "https://{{routerHost}}/v1"),
      "OPENAI_API_KEY": AgentEnvironmentBinding(fromEnv: "RIELA_OPENAI_API_KEY", required: true),
      "OPTIONAL_TOKEN": AgentEnvironmentBinding(fromEnv: "MISSING_OPTIONAL")
    ]

    let resolved = try resolveAgentEnvironment(
      bindings,
      variables: ["routerHost": .string("router.example.test")],
      runtimeEnvironment: ["RIELA_OPENAI_API_KEY": "secret-value"]
    )

    XCTAssertEqual(resolved["OPENAI_BASE_URL"], "https://router.example.test/v1")
    XCTAssertEqual(resolved["OPENAI_API_KEY"], "secret-value")
    XCTAssertNil(resolved["OPTIONAL_TOKEN"])

    XCTAssertThrowsError(try resolveAgentEnvironment(
      ["OPENAI_API_KEY": AgentEnvironmentBinding(fromEnv: "MISSING", required: true)],
      variables: [:],
      runtimeEnvironment: [:]
    )) { error in
      XCTAssertEqual(
        error as? AgentEnvironmentResolutionError,
        .missingRequiredSource(targetName: "OPENAI_API_KEY", sourceName: "MISSING")
      )
    }
  }

  func testAgentEnvironmentResolutionRejectsReservedTargets() {
    XCTAssertThrowsError(try resolveAgentEnvironment(
      ["RIELA_AGENT_BACKEND": AgentEnvironmentBinding(value: "spoof")],
      variables: [:],
      runtimeEnvironment: [:]
    )) { error in
      XCTAssertEqual(error as? AgentEnvironmentResolutionError, .reservedTargetName("RIELA_AGENT_BACKEND"))
    }
  }

  func testWorkflowValidationRejectsRemovedTopLevelEdgesAndBrokenStepReference() throws {
    let data = Data("""
      {
        "workflowId": "broken",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "missing-entry",
        "nodes": [{ "id": "main", "nodeFile": "nodes/main.json" }],
        "steps": [{ "id": "main-step", "nodeId": "missing-node", "role": "worker" }],
        "edges": [{ "from": "main-step", "to": "other-step" }]
      }
      """.utf8)

    let diagnostics = validateAuthoredWorkflowData(data).diagnostics

    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.edges" && $0.message.contains("workflow.steps[].transitions")
      }
    )
    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.entryStepId" && $0.message == "must reference workflow.steps[] entry 'missing-entry'"
      }
    )
    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.steps.main-step.nodeId" && $0.message == "must reference workflow.nodes[] entry 'missing-node'"
      }
    )
  }

  func testWorkflowValidationRejectsUnsafeWorkflowRelativeFilePaths() throws {
    let data = Data("""
      {
        "workflowId": "unsafe-paths",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "entryStepId": "safe-step",
        "nodes": [
          { "id": "unsafe-node", "nodeFile": "../x.json" },
          { "id": "absolute-node", "nodeFile": "/tmp/x.json" },
          { "id": "windows-node", "nodeFile": "C:\\\\tmp\\\\x.json" },
          { "id": "safe-node", "nodeFile": "nodes/node-safe-node.json" }
        ],
        "steps": [
          { "id": "unsafe-step", "nodeId": "unsafe-node" },
          { "id": "absolute-step", "nodeId": "absolute-node" },
          { "id": "windows-step", "nodeId": "windows-node" },
          { "id": "safe-step", "nodeId": "safe-node", "stepFile": "steps/safe-step.json" },
          { "id": "bad-step-file", "nodeId": "safe-node", "stepFile": "../manager-step.json" }
        ]
      }
      """.utf8)

    let diagnostics = validateAuthoredWorkflowData(data).diagnostics

    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.nodes[0].nodeFile" && $0.message == "nodeFile '../x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.nodes[1].nodeFile" && $0.message == "nodeFile '/tmp/x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.nodes[2].nodeFile" && $0.message == "nodeFile 'C:\\tmp\\x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      diagnostics.contains {
        $0.path == "workflow.steps[4].stepFile" && $0.message == "stepFile '../manager-step.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertFalse(diagnostics.contains { $0.path == "workflow.nodes[3].nodeFile" })
    XCTAssertFalse(diagnostics.contains { $0.path == "workflow.steps[3].stepFile" })
  }

  func testTypedWorkflowValidationRejectsUnsafeWorkflowRelativeFilePaths() throws {
    let workflow = AuthoredWorkflowJSON(
      workflowId: "unsafe-typed",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120000, maxLoopIterations: 3),
      entryStepId: "safe-step",
      nodes: [
        WorkflowNodeRegistryRef(id: "unsafe-node", nodeFile: "../x.json"),
        WorkflowNodeRegistryRef(id: "absolute-node", nodeFile: "/tmp/x.json"),
        WorkflowNodeRegistryRef(id: "windows-node", nodeFile: "C:\\tmp\\x.json"),
        WorkflowNodeRegistryRef(id: "safe-node", nodeFile: "nodes/node-safe-node.json")
      ],
      steps: [
        WorkflowStepRef(id: "unsafe-step", nodeId: "unsafe-node"),
        WorkflowStepRef(id: "absolute-step", nodeId: "absolute-node"),
        WorkflowStepRef(id: "windows-step", nodeId: "windows-node"),
        WorkflowStepRef(id: "safe-step", stepFile: "steps/safe-step.json", nodeId: "safe-node"),
        WorkflowStepRef(id: "bad-step-file", stepFile: "../manager-step.json", nodeId: "safe-node")
      ]
    )

    let result = validateAuthoredWorkflowJSON(workflow)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.nodes[0].nodeFile" && $0.message == "nodeFile '../x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.nodes[1].nodeFile" && $0.message == "nodeFile '/tmp/x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.nodes[2].nodeFile" && $0.message == "nodeFile 'C:\\tmp\\x.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.steps[4].stepFile" && $0.message == "stepFile '../manager-step.json' must be a workflow-relative path without '.' or '..' segments"
      }
    )
    XCTAssertFalse(result.diagnostics.contains { $0.path == "workflow.nodes[3].nodeFile" })
    XCTAssertFalse(result.diagnostics.contains { $0.path == "workflow.steps[3].stepFile" })
  }

  func testTypedWorkflowValidationRejectsUnsafeNodeIdBeforeSynthesizingNodeFile() throws {
    let workflow = AuthoredWorkflowJSON(
      workflowId: "unsafe-typed-node",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120000, maxLoopIterations: 3),
      entryStepId: "escape-step",
      nodes: [
        WorkflowNodeRegistryRef(id: "../escape")
      ],
      steps: [
        WorkflowStepRef(id: "escape-step", nodeId: "../escape")
      ]
    )

    let result = validateAuthoredWorkflowJSON(workflow)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.nodes[0].id" && $0.message == "must match ^[a-z0-9][a-z0-9-]{1,63}$"
      }
    )
    XCTAssertTrue(
      result.diagnostics.contains {
        $0.path == "workflow.nodes[0]" && $0.message == "must define exactly one of nodeFile, nodeRef, or addon"
      }
    )
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    for _ in 0..<8 {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(domain: "WorkflowModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"])
  }

  private func assertProtectedGitFinalizationPolicyRejected(
    _ workflow: WorkflowDefinition,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let outputStep = try XCTUnwrap(
      workflow.steps.first { $0.id == "workflow-output" },
      file: file,
      line: line
    )
    XCTAssertThrowsError(
      try DeterministicWorkflowRunner.requiredGitFinalizationEvidencePolicy(
        workflow: workflow,
        terminalStep: outputStep
      ),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput, file: file, line: line)
    }
  }
}
