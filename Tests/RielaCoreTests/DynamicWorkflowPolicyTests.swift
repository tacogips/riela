import XCTest
@testable import RielaCore

final class DynamicWorkflowPolicyTests: XCTestCase {
  private let parentWorkflowId = "parent-workflow"

  func testAcceptsCleanTwoNodeAgentWorkflowWithinDefaults() {
    XCTAssertEqual(check(cleanEnvelope()), [])
  }

  func testRejectsForbiddenDefinitionAndPayloadKeysWithPaths() {
    let cases: [(String, (inout JSONObject) -> Void)] = [
      ("workflow.handover", { envelope in
        self.editWorkflow(&envelope) {
          $0["handover"] = .object(["sinks": .array([.object(["command": .string("run")])])])
        }
      }),
      ("workflow.memories", { envelope in
        self.editWorkflow(&envelope) { $0["memories"] = .array([.object(["scope": .string("cross-workflow")])]) }
      }),
      ("workflow.nodes[0].memories", { envelope in self.editNode(&envelope) { $0["memories"] = .array([]) } }),
      ("workflow.nodes[0].inputFilters", { envelope in
        self.editNode(&envelope) { $0["inputFilters"] = .array([.object(["language": .string("javascript")])]) }
      }),
      ("workflow.nodes[0].nodeRef", { envelope in
        self.editNode(&envelope) { $0["nodeRef"] = .object(["workflowId": .string("elsewhere")]) }
      }),
      ("workflow.requiredEnvironment", { envelope in
        self.editWorkflow(&envelope) { $0["requiredEnvironment"] = .array([.string("TOKEN")]) }
      }),
      ("workflow.nodes[0].requiredEnvironment", { envelope in
        self.editNode(&envelope) { $0["requiredEnvironment"] = .array([.string("TOKEN")]) }
      }),
      ("workflow.loop", { envelope in self.editWorkflow(&envelope) { $0["loop"] = .object([:]) } }),
      ("workflow.triggerDefaults", { envelope in self.editWorkflow(&envelope) { $0["triggerDefaults"] = .object([:]) } }),
      ("workflow.steps[0].placement", { envelope in self.editStep(&envelope) { $0["placement"] = .object([:]) } }),
      ("workflow.steps[0].stepFile", { envelope in self.editStep(&envelope) { $0["stepFile"] = .string("step.json") } }),
      ("workflow.steps[0].transitions[0].fanout.writeOwnership", { envelope in
        self.editStep(&envelope) {
          $0["transitions"] = .array([.object([
            "fanout": .object(["groupId": .string("g"), "writeOwnership": .object([:])])
          ])])
        }
      }),
      ("nodePayloads.node-1.workingDirectory", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["workingDirectory"] = .string("/tmp") }
      }),
      ("nodePayloads.node-1.command", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["command"] = .object([:]) }
      }),
      ("nodePayloads.node-1.agentSandbox", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["agentSandbox"] = .string("danger-full-access") }
      }),
      ("nodePayloads.node-1.agentToolPolicy", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["agentToolPolicy"] = .object([:]) }
      }),
      ("nodePayloads.node-1.agentEnvironment", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["agentEnvironment"] = .object([:]) }
      }),
      ("nodePayloads.node-1.promptTemplateFile", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["promptTemplateFile"] = .string("prompt.md") }
      }),
      ("nodePayloads.node-1.promptVariants.x.promptTemplateFile", { envelope in
        self.editPayload(&envelope, key: "node-1") {
          $0["promptVariants"] = .object(["x": .object(["promptTemplateFile": .string("prompt.md")])])
        }
      }),
      ("nodePayloads.node-1.output.deliverables", { envelope in
        self.editPayload(&envelope, key: "node-1") { $0["output"] = .object(["deliverables": .array([])]) }
      }),
      ("workflow.futureField", { envelope in self.editWorkflow(&envelope) { $0["futureField"] = .bool(true) } })
    ]

    for (path, mutate) in cases {
      var envelope = cleanEnvelope()
      mutate(&envelope)
      let diagnostics = check(envelope)
      XCTAssertTrue(diagnostics.contains { $0.path == path }, "Expected \(path), got \(diagnostics)")
      XCTAssertTrue(diagnostics.allSatisfy { $0.message.hasPrefix("dynamic workflow policy:") })
    }
  }

  func testRejectsWorkflowCallsAndParentWorkflowIdReuse() {
    for key in ["toWorkflowId", "dynamicWorkflow"] {
      var envelope = cleanEnvelope()
      self.editStep(&envelope) { $0["transitions"] = .array([.object([key: .string("other")])]) }
      XCTAssertTrue(check(envelope).contains { $0.message.contains("cannot call other workflows") })
    }

    var sameId = cleanEnvelope()
    self.editWorkflow(&sameId) { $0["workflowId"] = .string(parentWorkflowId) }
    XCTAssertTrue(check(sameId).contains { $0.path == "workflow.workflowId" })
  }

  func testRequiresNodePayloadAndEnforcesNodeAddonBackendAndModelAllowLists() {
    var missing = cleanEnvelope()
    missing["nodePayloads"] = .object(["node-2": payloadObject("node-2")])
    XCTAssertTrue(check(missing).contains { $0.message.contains("has no payload in nodePayloads") })

    var commandType = cleanEnvelope()
    self.editPayload(&commandType, key: "node-1") { $0["nodeType"] = .string("command") }
    XCTAssertTrue(check(commandType).contains { $0.path == "nodePayloads.node-1.nodeType" })

    var deniedBackend = cleanEnvelope()
    self.editPayload(&deniedBackend, key: "node-1") { $0["executionBackend"] = .string("official/openai-sdk") }
    XCTAssertTrue(check(deniedBackend).contains { $0.path == "nodePayloads.node-1.executionBackend" })

    var deniedModel = cleanEnvelope()
    self.editPayload(&deniedModel, key: "node-1") { $0["model"] = .string("unapproved-model") }
    XCTAssertTrue(check(deniedModel).contains { $0.path == "nodePayloads.node-1.model" })

    var missingBackend = cleanEnvelope()
    self.editPayload(&missingBackend, key: "node-1") { $0.removeValue(forKey: "executionBackend") }
    XCTAssertTrue(check(missingBackend).contains { $0.message.contains("executionBackend is required") })

    var deniedAddon = cleanEnvelope()
    self.editNode(&deniedAddon) { $0["addon"] = .object(["name": .string("vendor/tool")]) }
    XCTAssertTrue(check(deniedAddon).contains { $0.path == "workflow.nodes[0].addon.name" })
  }

  func testEnforcesDefinitionSizeNodeAndStepBounds() {
    var oversized = cleanEnvelope()
    self.editWorkflow(&oversized) { $0["description"] = .string(String(repeating: "x", count: 200)) }
    XCTAssertTrue(check(oversized, bounds: bounds(maxDefinitionBytes: 64)).contains {
      $0.path == "workflow" && $0.message.contains("definition is")
    })

    var tooManyNodes = cleanEnvelope()
    self.editWorkflow(&tooManyNodes) { $0["nodes"] = .array((0..<9).map { .object(["id": .string("n\($0)")]) }) }
    XCTAssertTrue(check(tooManyNodes).contains { $0.path == "workflow.nodes" })

    var tooManySteps = cleanEnvelope()
    self.editWorkflow(&tooManySteps) { $0["steps"] = .array((0..<17).map { .object(["id": .string("s\($0)")]) }) }
    XCTAssertTrue(check(tooManySteps).contains { $0.path == "workflow.steps" })
  }

  func testRejectsWrongEnvelopeShapesAndFinishDecision() {
    var finish = cleanEnvelope()
    finish["decision"] = .string("finish")
    XCTAssertTrue(check(finish).contains { $0.path == "decision" })

    var wrongWorkflow = cleanEnvelope()
    wrongWorkflow["workflow"] = .string("not an object")
    XCTAssertTrue(check(wrongWorkflow).contains { $0.path == "workflow" })

    var wrongPayloads = cleanEnvelope()
    wrongPayloads["nodePayloads"] = .array([])
    XCTAssertTrue(check(wrongPayloads).contains { $0.path == "nodePayloads" })

    var wrongInput = cleanEnvelope()
    wrongInput["input"] = .string("not an object")
    XCTAssertTrue(check(wrongInput).contains { $0.path == "input" })

    var longRationale = cleanEnvelope()
    longRationale["rationale"] = .string(String(repeating: "r", count: 2_001))
    XCTAssertTrue(check(longRationale).contains { $0.path == "rationale" })
  }

  func testAuthoredDiagnosticsValidateBoundsAndAllowValues() {
    let zeroIterations = WorkflowDynamicWorkflowTransition(maxIterations: 0)
    XCTAssertTrue(DynamicWorkflowPolicy.authoredDiagnostics(zeroIterations, path: "dynamicWorkflow").contains {
      $0.path == "dynamicWorkflow.maxIterations"
    })

    let invalid = WorkflowDynamicWorkflowTransition(
      maxIterations: 17,
      limits: WorkflowDynamicWorkflowLimits(maxDefinitionBytes: 300_000),
      allow: WorkflowDynamicWorkflowAllow(
        nodeTypes: ["future-node"],
        backends: ["future-backend"],
        addons: ["Not/Namespaced"]
      )
    )
    let diagnostics = DynamicWorkflowPolicy.authoredDiagnostics(
      invalid,
      path: "workflow.steps[0].transitions[0].dynamicWorkflow"
    )
    XCTAssertEqual(diagnostics.count, 5)
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix(".maxIterations") })
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix(".maxDefinitionBytes") })
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix(".allow.nodeTypes[0]") })
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix(".allow.backends[0]") })
    XCTAssertTrue(diagnostics.contains { $0.path.hasSuffix(".allow.addons[0]") })
    XCTAssertTrue(diagnostics.allSatisfy { $0.message.hasPrefix("dynamic workflow policy:") })

    let valid = WorkflowDynamicWorkflowTransition(
      maxIterations: 16,
      limits: WorkflowDynamicWorkflowLimits(maxDefinitionBytes: 262_144, maxNodes: 32, maxSteps: 64, childMaxSteps: 256),
      allow: WorkflowDynamicWorkflowAllow(
        nodeTypes: ["agent", "command"],
        backends: ["claude-code-agent"],
        addons: ["vendor/tool"]
      )
    )
    XCTAssertEqual(DynamicWorkflowPolicy.authoredDiagnostics(valid, path: "dynamicWorkflow"), [])
  }

  func testResolveUsesDefaultsAndParentAuthority() {
    let parent = AgentNodePayload(id: "brain", executionBackend: .claudeCodeAgent, model: "claude-opus-5-5")
    let resolved = DynamicWorkflowPolicy.resolve(WorkflowDynamicWorkflowTransition(), parentNodePayloads: ["brain": parent])
    XCTAssertEqual(resolved.maxIterations, 4)
    XCTAssertEqual(resolved.onFailure, .return)
    XCTAssertEqual(resolved.maxDefinitionBytes, 65_536)
    XCTAssertEqual(resolved.maxNodes, 8)
    XCTAssertEqual(resolved.maxSteps, 16)
    XCTAssertEqual(resolved.childMaxSteps, 32)
    XCTAssertEqual(resolved.nodeTypes, ["agent"])
    XCTAssertEqual(resolved.backends, ["claude-code-agent"])
    XCTAssertEqual(resolved.models, ["claude-opus-5-5"])
    XCTAssertEqual(resolved.addons, [])
  }

  func testDiagnosticsAreDeterministicAndUseSortedKeyPaths() {
    var envelope = cleanEnvelope()
    self.editWorkflow(&envelope) {
      $0["zUnknown"] = .bool(true)
      $0["aUnknown"] = .bool(true)
    }
    let first = check(envelope)
    XCTAssertEqual(check(envelope), first)
    XCTAssertEqual(first.map(\.path).filter { $0.contains("Unknown") }, ["workflow.aUnknown", "workflow.zUnknown"])
  }

  private func check(_ envelope: JSONObject) -> [WorkflowValidationDiagnostic] {
    check(envelope, bounds: Self.defaultBounds())
  }

  private func check(
    _ envelope: JSONObject,
    bounds: ResolvedDynamicWorkflowBounds
  ) -> [WorkflowValidationDiagnostic] {
    DynamicWorkflowPolicy.check(envelope: envelope, parentWorkflowId: parentWorkflowId, bounds: bounds)
  }

  private func cleanEnvelope() -> JSONObject {
    let nodes: [JSONValue] = ["node-1", "node-2"].map { .object(["id": .string($0)]) }
    let steps: [JSONValue] = [
      .object(["id": .string("step-1"), "nodeId": .string("node-1")]),
      .object(["id": .string("step-2"), "nodeId": .string("node-2")])
    ]
    return [
      "decision": .string("execute_workflow"),
      "rationale": .string("two independent work units"),
      "workflow": .object([
        "workflowId": .string("generated-workflow"),
        "defaults": .object(["nodeTimeoutMs": .integer(30_000), "maxLoopIterations": .integer(2)]),
        "entryStepId": .string("step-1"),
        "nodes": .array(nodes),
        "steps": .array(steps)
      ]),
      "nodePayloads": .object(["node-1": payloadObject("node-1"), "node-2": payloadObject("node-2")]),
      "input": .object(["topic": .string("test")])
    ]
  }

  private func payloadObject(_ id: String) -> JSONValue {
    .object([
      "id": .string(id),
      "nodeType": .string("agent"),
      "executionBackend": .string("claude-code-agent"),
      "model": .string("claude-opus-5-5"),
      "modelFreeze": .bool(false)
    ])
  }

  private static func defaultBounds() -> ResolvedDynamicWorkflowBounds {
    bounds(maxDefinitionBytes: 65_536)
  }

  private func bounds(maxDefinitionBytes: Int = 65_536) -> ResolvedDynamicWorkflowBounds {
    Self.bounds(maxDefinitionBytes: maxDefinitionBytes)
  }

  private static func bounds(maxDefinitionBytes: Int) -> ResolvedDynamicWorkflowBounds {
    ResolvedDynamicWorkflowBounds(
      maxIterations: 4,
      onFailure: .return,
      maxDefinitionBytes: maxDefinitionBytes,
      maxNodes: 8,
      maxSteps: 16,
      childMaxSteps: 32,
      nodeTypes: ["agent"],
      backends: ["claude-code-agent"],
      models: ["claude-opus-5-5"],
      addons: []
    )
  }

  private func editWorkflow(_ envelope: inout JSONObject, _ edit: (inout JSONObject) -> Void) {
    guard case var .object(workflow) = envelope["workflow"] else { fatalError("fixture workflow must be an object") }
    edit(&workflow)
    envelope["workflow"] = .object(workflow)
  }

  private func editNode(_ envelope: inout JSONObject, _ edit: (inout JSONObject) -> Void) {
    self.editWorkflow(&envelope) { workflow in
      guard case var .array(nodes) = workflow["nodes"], case var .object(node) = nodes[0] else {
        fatalError("fixture first node must be an object")
      }
      edit(&node)
      nodes[0] = .object(node)
      workflow["nodes"] = .array(nodes)
    }
  }

  private func editStep(_ envelope: inout JSONObject, _ edit: (inout JSONObject) -> Void) {
    self.editWorkflow(&envelope) { workflow in
      guard case var .array(steps) = workflow["steps"], case var .object(step) = steps[0] else {
        fatalError("fixture first step must be an object")
      }
      edit(&step)
      steps[0] = .object(step)
      workflow["steps"] = .array(steps)
    }
  }

  private func editPayload(_ envelope: inout JSONObject, key: String, _ edit: (inout JSONObject) -> Void) {
    guard case var .object(payloads) = envelope["nodePayloads"], case var .object(payload) = payloads[key] else {
      fatalError("fixture payload must be an object")
    }
    edit(&payload)
    payloads[key] = .object(payload)
    envelope["nodePayloads"] = .object(payloads)
  }
}
