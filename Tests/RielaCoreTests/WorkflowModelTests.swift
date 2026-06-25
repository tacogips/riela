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

  func testWorkflowValidationRejectsRawDailySummaryMemoryIdCollision() throws {
    let data = Data("""
      {
        "workflowId": "raw-daily-memory",
        "description": "Sample workflow",
        "defaults": { "nodeTimeoutMs": 120000, "maxLoopIterations": 3 },
        "memories": [{ "id": "chat-log", "scope": "workflow", "defaultLimit": 30 }],
        "entryStepId": "record-chat",
        "nodes": [{
          "id": "record-chat",
          "memories": [{ "id": "chat-log", "purpose": "record chat memory" }],
          "addon": {
            "name": "riela/chat-memory-raw-daily-summary",
            "version": "1",
            "config": {
              "rawMemoryId": "chat-log",
              "summaryMemoryId": "chat-log"
            }
          }
        }],
        "steps": [{ "id": "record-chat", "nodeId": "record-chat", "role": "worker" }]
      }
      """.utf8)

    let result = validateAuthoredWorkflowData(data)

    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.nodes[0].addon.config.summaryMemoryId"
        && $0.message == "rawMemoryId and summaryMemoryId must be distinct memory ids"
    })
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

    let gitPushNode = try XCTUnwrap(workflow.nodes.first { $0.id == "step11-git-push" })
    XCTAssertNil(gitPushNode.nodeFile)
    XCTAssertEqual(gitPushNode.addon?.name, "riela/git-push")
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

  func testAgentEnvironmentRejectsInvalidBindingShapes() {
    let data = Data("""
      {
        "id": "planner",
        "model": "gpt-5",
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
}
