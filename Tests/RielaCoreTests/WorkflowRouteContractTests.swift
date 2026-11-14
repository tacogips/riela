import XCTest
@testable import RielaCore

final class WorkflowRouteContractTests: XCTestCase {
  func testGuaranteedWhenRoundTripsAndRejectsInvalidDeclarations() throws {
    let declared = NodeOutputContract(guaranteedWhen: ["ready", "done"])
    let decoded = try JSONDecoder().decode(NodeOutputContract.self, from: JSONEncoder().encode(declared))
    XCTAssertEqual(decoded.guaranteedWhen, ["ready", "done"])
    XCTAssertNil(NodeOutputContract().invalidGuaranteedWhenIndex)
    XCTAssertNil(NodeOutputContract(guaranteedWhen: []).invalidGuaranteedWhenIndex)
    for invalid in [[""], ["ready", "ready"], ["true"], ["never"], ["bad name"]] {
      XCTAssertNotNil(NodeOutputContract(guaranteedWhen: invalid).invalidGuaranteedWhenIndex)
    }
  }

  func testWhenOnlyDeclarationPassesValidationWithoutPayloadSchema() {
    let registry = [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")]
    let workflow = WorkflowDefinition(
      workflowId: "when-only", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: "start", nodeRegistry: registry,
      steps: [.init(id: "start", nodeId: "agent", transitions: [.init(toStepId: "start", label: "flag")])],
      nodes: [WorkflowNodeRef(id: "agent", nodeFile: "nodes/agent.json")]
    )
    func diagnostics(_ names: [String]) -> [WorkflowValidationDiagnostic] {
      DefaultWorkflowValidator().validate(workflow, nodePayloads: [
        "agent": AgentNodePayload(id: "agent", executionBackend: .codexAgent, model: "model",
                                  agentSandbox: .readOnly, output: .init(guaranteedWhen: names))
      ])
    }
    XCTAssertFalse(diagnostics(["flag"]).contains { $0.path.contains("output.jsonSchema") })
    XCTAssertFalse(diagnostics(["flag"]).contains { $0.message.contains("analysis_incomplete: route control") })
    XCTAssertTrue(diagnostics([]).contains { $0.path.contains("output.jsonSchema") })
    XCTAssertTrue(diagnostics(["flag", "flag"]).contains { $0.path.contains("output.guaranteedWhen") })
    XCTAssertTrue(diagnostics(["true"]).contains { $0.path.contains("output.guaranteedWhen") })
  }

  func testRequiredBooleanSchemaGuaranteesAndIncompleteVariants() {
    let contract = WorkflowRouteContract()
    let required: JSONObject = [
      "type": .string("object"), "required": .array([.string("flag")]),
      "properties": .object(["flag": .object(["type": .string("boolean")])])
    ]
    XCTAssertEqual(contract.provePayloadBoolean(identifier: "flag", schema: required), .proven)
    let provenProperties: [JSONObject] = [
      ["const": .bool(false)],
      ["enum": .array([.bool(false), .bool(true)])]
    ]
    for property in provenProperties {
      var schema = required
      schema["properties"] = .object(["flag": .object(property)])
      XCTAssertEqual(contract.provePayloadBoolean(identifier: "flag", schema: schema), .proven)
    }

    var optional = required
    optional.removeValue(forKey: "required")
    XCTAssertNotEqual(contract.provePayloadBoolean(identifier: "flag", schema: optional), .proven)
    let unprovenProperties: [JSONObject] = [
      ["type": .array([.string("boolean"), .string("null")])],
      ["enum": .array([.bool(true), .null])],
      [:]
    ]
    for property in unprovenProperties {
      var schema = required
      schema["properties"] = .object(["flag": .object(property)])
      XCTAssertNotEqual(contract.provePayloadBoolean(identifier: "flag", schema: schema), .proven)
    }
  }

  func testBooleanGuaranteeCombinatorsAndBudget() {
    let contract = WorkflowRouteContract()
    let guaranteed: JSONValue = .object([
      "required": .array([.string("flag")]),
      "properties": .object(["flag": .object(["type": .string("boolean")])])
    ])
    let optional: JSONValue = .object(["properties": .object(["flag": .object(["type": .string("boolean")])])])
    XCTAssertEqual(contract.provePayloadBoolean(identifier: "flag", schema: ["anyOf": .array([guaranteed, guaranteed])]), .proven)
    XCTAssertNotEqual(contract.provePayloadBoolean(identifier: "flag", schema: ["oneOf": .array([guaranteed, optional])]), .proven)
    XCTAssertEqual(contract.provePayloadBoolean(identifier: "flag", schema: ["allOf": .array([
      .object(["required": .array([.string("flag")])]),
      .object(["properties": .object(["flag": .object(["type": .string("boolean")])])])
    ])]), .proven)
    let tooMany = Array(repeating: guaranteed, count: 4_097)
    XCTAssertNotEqual(contract.provePayloadBoolean(identifier: "flag", schema: ["anyOf": .array(tooMany)]), .proven)
  }

  func testPresentFalseAndReservedConstantsAreValid() throws {
    let candidate = RuntimeOutputCandidate(
      source: .inlineCandidate, payload: ["flag": .bool(false)], when: [:]
    )
    try WorkflowRouteContract().validateCandidate(candidate, transitions: [
      .init(toStepId: "next", label: "!flag && always"),
      .init(toStepId: "other", label: "never")
    ])
  }

  func testEveryReferencedControlIsChecked() {
    let candidate = RuntimeOutputCandidate(source: .inlineCandidate, payload: [:], when: [:])
    for label in ["!flag", "true || flag"] {
      XCTAssertThrowsError(try WorkflowRouteContract().validateCandidate(candidate, transitions: [
        .init(toStepId: "next", label: label)
      ])) { error in
        guard case let WorkflowRouteControlError.missing(index, name, _) = error else {
          return XCTFail("expected missing control: \(error)")
        }
        XCTAssertEqual(index, 0)
        XCTAssertEqual(name, "flag")
      }
    }
  }

  func testWrongTypeAndConflictingValuesAreRejected() {
    let contract = WorkflowRouteContract()
    let route = [WorkflowStepTransition(toStepId: "next", label: "flag")]
    XCTAssertThrowsError(try contract.validateCandidate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["flag": .null], when: [:]),
      transitions: route
    )) { error in
      guard case WorkflowRouteControlError.wrongType = error else {
        return XCTFail("expected wrong type: \(error)")
      }
    }
    XCTAssertThrowsError(try contract.validateCandidate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["flag": .bool(false)], when: ["flag": true]),
      transitions: route
    )) { error in
      guard case WorkflowRouteControlError.conflictingValues = error else {
        return XCTFail("expected conflict: \(error)")
      }
    }
  }

  func testMalformedLabelReportsTransitionAndSpan() {
    let candidate = RuntimeOutputCandidate(source: .inlineCandidate, payload: [:], when: [:])
    XCTAssertThrowsError(try WorkflowRouteContract().validateCandidate(candidate, transitions: [
      .init(toStepId: "next", label: "true || !")
    ])) { error in
      XCTAssertEqual(error as? WorkflowRouteControlError,
                     .invalidCondition(transitionIndex: 0, span: .init(start: 9, end: 9)))
    }
  }

  func testRawValidationRejectsMalformedRouteCondition() {
    let data = Data(#"""
    {
      "workflowId":"route-raw","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":2},
      "entryStepId":"only","nodes":[{"id":"node","nodeFile":"nodes/node.json"}],
      "steps":[{"id":"only","nodeId":"node","transitions":[{"toStepId":"only","label":"true || !"}]}]
    }
    """#.utf8)
    let result = validateAuthoredWorkflowData(data)
    XCTAssertNil(result.workflow)
    XCTAssertTrue(result.diagnostics.contains {
      $0.path == "workflow.steps[0].transitions[0].label" &&
        $0.message == "route.invalidCondition characters[9..<9]"
    })
    let finding = result.defectDiagnostics.first {
      $0.code == .invalidCondition
    }
    XCTAssertEqual(finding?.sourceDigest, WorkflowHistoryCanonicalCoding.sha256(data))
    XCTAssertEqual(finding?.filePath, "workflow.json")
    XCTAssertEqual(finding?.pointer, "/steps/0/transitions/0/label")
    XCTAssertEqual(finding?.transitionIndex, 0)
    XCTAssertEqual(finding?.proofStatus, .complete)
    XCTAssertEqual(validateAuthoredWorkflowData(data).defectDiagnostics, result.defectDiagnostics)
    var changed = data
    changed.append(0x20)
    XCTAssertNotEqual(validateAuthoredWorkflowData(changed).defectDiagnostics.first?.sourceDigest, finding?.sourceDigest)
  }

  func testTypedDiagnosticProjectionKeepsUnknownProofIncompleteAndSorted() {
    let diagnostics = [
      WorkflowValidationDiagnostic(severity: .warning, path: "workflow.steps[1].transitions[2].label", message: "analysis_incomplete: unknown producer"),
      WorkflowValidationDiagnostic(severity: .error, path: "workflow.steps[0].transitions[0].label", message: "route.invalidCondition")
    ]
    let projected = WorkflowDefectDiagnostic.project(diagnostics, sourceDigest: "digest")
    XCTAssertEqual(projected.map(\.pointer), [
      "/steps/0/transitions/0/label", "/steps/1/transitions/2/label"
    ])
    XCTAssertEqual(projected.map(\.proofStatus), [.complete, .incomplete])
    XCTAssertEqual(projected.last?.remediationClass, .establishProducerGuarantee)
  }

  func testTypedStepIdentifierResolvesCapturedArrayPointer() {
    let diagnostics = [WorkflowValidationDiagnostic(
      severity: .warning,
      path: "workflow.steps.step.one/~x.transitions[1].label",
      message: "analysis_incomplete: unknown producer"
    )]
    let typed = WorkflowDefectDiagnostic.project(
      diagnostics, sourceDigest: "captured", stepIds: ["other", "step.one/~x"]
    )
    let raw = WorkflowDefectDiagnostic.project([
      WorkflowValidationDiagnostic(
        severity: .warning, path: "workflow.steps[1].transitions[1].label",
        message: "analysis_incomplete: unknown producer"
      )
    ], sourceDigest: "captured", stepIds: ["other", "step.one/~x"])
    XCTAssertEqual(typed.first?.pointer, "/steps/1/transitions/1/label")
    XCTAssertEqual(typed.first?.pointer, raw.first?.pointer)
    XCTAssertEqual(typed.first?.stepId, "step.one/~x")
    XCTAssertEqual(typed.first?.proofStatus, .incomplete)
    let schema = WorkflowDefectDiagnostic.project([
      WorkflowValidationDiagnostic(
        severity: .warning,
        path: "workflow.nodes.node-one.output.jsonSchema/properties/a~0b~1c",
        message: "analysis_incomplete: unsupported schema"
      )
    ], sourceDigest: "captured", nodeIds: ["node-one"])
    XCTAssertEqual(schema.first?.pointer, "/nodes/0/output/jsonSchema/properties/a~0b~1c")
  }

  func testCatalogForwardingRequiresExactIdentityAndEverySource() {
    let registry = [
      WorkflowNodeRegistryRef(id: "agent-a", nodeFile: "nodes/agent-a.json"),
      WorkflowNodeRegistryRef(id: "agent-b", nodeFile: "nodes/agent-b.json"),
      WorkflowNodeRegistryRef(id: "relay", addon: .init(name: "riela/chat-reply-worker", version: "1"))
    ]
    let workflow = WorkflowDefinition(
      workflowId: "route-proof", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: "produce-a", nodeRegistry: registry,
      steps: [
        .init(id: "produce-a", nodeId: "agent-a", transitions: [.init(toStepId: "relay-step")]),
        .init(id: "produce-b", nodeId: "agent-b", transitions: [.init(toStepId: "relay-step")]),
        .init(id: "relay-step", nodeId: "relay", transitions: [.init(toStepId: "done", label: "flag")]),
        .init(id: "done", nodeId: "relay")
      ],
      nodes: registry.map { WorkflowNodeRef(id: $0.id, nodeFile: $0.nodeFile, addon: $0.addon) }
    )
    let schema: JSONObject = [
      "required": .array([.string("flag")]),
      "properties": .object(["flag": .object(["type": .string("boolean")])])
    ]
    let agents = [
      "agent-a": AgentNodePayload(id: "agent-a", executionBackend: .codexAgent, model: "model",
                                  agentSandbox: .readOnly, output: .init(jsonSchema: schema)),
      "agent-b": AgentNodePayload(id: "agent-b", executionBackend: .codexAgent, model: "model",
                                  agentSandbox: .readOnly, output: .init(jsonSchema: schema))
    ]
    let validator = DefaultWorkflowValidator()
    let evidence = WorkflowAddonRouteEvidence(
      name: "riela/chat-reply-worker", version: "1", output: .init(forwardsPayload: true)
    )
    func incomplete(_ proof: WorkflowAddonRouteEvidence?, producers: [String: AgentNodePayload]) -> Bool {
      let diagnostics = validator.validate(
        workflow, nodePayloads: producers, addonEvidence: proof.map { ["relay": $0] } ?? [:]
      )
      return diagnostics.contains { $0.message.contains("analysis_incomplete: route control 'flag'") }
    }
    XCTAssertTrue(incomplete(nil, producers: agents))
    XCTAssertTrue(incomplete(.init(name: evidence.name, version: "2", output: evidence.output), producers: agents))
    XCTAssertFalse(incomplete(evidence, producers: agents))
    var missingSource = agents
    missingSource["agent-b"] = AgentNodePayload(
      id: "agent-b", executionBackend: .codexAgent, model: "model",
      agentSandbox: .readOnly, output: .init(jsonSchema: [:])
    )
    XCTAssertTrue(incomplete(evidence, producers: missingSource))
    XCTAssertTrue(incomplete(.init(name: evidence.name, version: "1", output: .init(
      forwardsPayload: true, removedPayload: ["flag"]
    )), producers: agents))
    XCTAssertTrue(incomplete(.init(name: evidence.name, version: "1", output: .init(
      forwardsPayload: true, overwrittenPayload: ["flag"]
    )), producers: agents))
    XCTAssertFalse(incomplete(.init(name: evidence.name, version: "1", output: .init(
      forwardsPayload: true, overwrittenPayload: ["flag"], booleanOverwrites: ["flag"]
    )), producers: agents))
  }

  func testCapturedRawAndTypedStepLocationsAgree() throws {
    let authored = AuthoredWorkflowJSON(
      workflowId: "location-proof", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 2),
      entryStepId: "logical-step",
      nodes: [.init(id: "available", nodeFile: "nodes/available.json")],
      steps: [.init(id: "logical-step", nodeId: "missing")]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(authored)
    let raw = validateAuthoredWorkflowData(data)
    let typed = validateAuthoredWorkflowJSON(authored)
    let rawLocation = raw.defectDiagnostics.first { $0.pointer == "/steps/0/nodeId" }
    let typedLocation = typed.defectDiagnostics.first { $0.pointer == "/steps/0/nodeId" }
    XCTAssertNotNil(rawLocation)
    XCTAssertNotNil(typedLocation)
    XCTAssertEqual(rawLocation?.sourceDigest, WorkflowHistoryCanonicalCoding.sha256(data))
    XCTAssertEqual(typedLocation?.sourceDigest, rawLocation?.sourceDigest)
    XCTAssertEqual(typedLocation?.stepId, "logical-step")
  }
}
