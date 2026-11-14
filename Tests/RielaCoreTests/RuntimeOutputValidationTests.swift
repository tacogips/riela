import XCTest
@testable import RielaCore

final class RuntimeOutputValidationTests: XCTestCase {
  func testGuaranteedWhenIsCheckedIndependentlyOfRequiredPayload() throws {
    let validator = DefaultWorkflowOutputValidator()
    let contract = WorkflowOutputContract(
      schema: ["required": .array([.string("answer")])],
      guaranteedWhen: ["unused"]
    )
    func validate(_ payload: JSONObject, _ when: [String: Bool]) throws -> WorkflowOutputValidationResult {
      try validator.validate(
        RuntimeOutputCandidate(source: .inlineCandidate, payload: payload, when: when), contract: contract
      )
    }
    XCTAssertEqual(try validate(["answer": .string("ok")], [:]).reason, "route.missingDeclaredWhen unused")
    XCTAssertEqual(try validate([:], ["unused": false]).reason, "output contract $.answer required property is missing")
    XCTAssertEqual(try validate(["answer": .string("ok"), "unused": .string("false")], ["unused": false]).reason,
                   "route.wrongType unused")
    XCTAssertEqual(try validate(["answer": .string("ok"), "unused": .bool(true)], ["unused": false]).reason,
                   "route.conflictingValues unused")
    XCTAssertEqual(try validate(["answer": .string("ok")], ["unused": false]).status, .accepted)
  }

  func testValidatorRejectsCompletionFailureAndSchemaFailures() throws {
    let validator = DefaultWorkflowOutputValidator()
    let contract = WorkflowOutputContract(
      schema: [
        "type": .string("object"),
        "required": .array([.string("answer")]),
        "properties": .object(["answer": .object(["type": .string("string")])])
      ],
      requiredObject: true
    )

    let completionFailure = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["answer": .string("ok")], completionPassed: false),
      contract: contract
    )
    let missingRequired = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["other": .string("ok")]),
      contract: contract
    )
    let wrongType = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["answer": .number(1)]),
      contract: contract
    )
    let accepted = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: ["answer": .string("ok")]),
      contract: contract
    )

    XCTAssertEqual(completionFailure.status, .rejected)
    XCTAssertEqual(missingRequired.reason, "output contract $.answer required property is missing")
    XCTAssertEqual(wrongType.reason, "output contract $.answer must be of type string")
    XCTAssertEqual(accepted.status, .accepted)
    XCTAssertEqual(accepted.payload, ["answer": .string("ok")])
  }

  func testValidatorRejectsAdditionalPropertiesEnumNestedItemsBoundsAndIntegerFailures() throws {
    let validator = DefaultWorkflowOutputValidator()
    let contract = WorkflowOutputContract(
      schema: [
        "type": .string("object"),
        "required": .array([.string("status"), .string("count"), .string("items"), .string("meta")]),
        "additionalProperties": .bool(false),
        "properties": .object([
          "status": .object(["enum": .array([.string("accepted"), .string("rejected")])]),
          "count": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(3)]),
          "code": .object(["type": .string("string"), "pattern": .string("^[A-Z]+$")]),
          "items": .object([
            "type": .string("array"),
            "minItems": .number(1),
            "maxItems": .number(2),
            "uniqueItems": .bool(true),
            "items": .object([
              "type": .string("object"),
              "required": .array([.string("id")]),
              "properties": .object(["id": .object(["type": .string("string"), "minLength": .number(2)])]),
              "additionalProperties": .bool(false)
            ])
          ]),
          "meta": .object([
            "type": .string("object"),
            "properties": .object(["kind": .object(["const": .string("runtime")])]),
            "required": .array([.string("kind")])
          ])
        ])
      ],
      requiredObject: true
    )

    let acceptedPayload: JSONObject = [
      "status": .string("accepted"),
      "count": .number(2),
      "code": .string("OK"),
      "items": .array([.object(["id": .string("ab")])]),
      "meta": .object(["kind": .string("runtime")])
    ]
    let accepted = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: acceptedPayload),
      contract: contract
    )
    XCTAssertEqual(accepted.status, .accepted)

    let extra = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: payload(acceptedPayload, setting: "extra", to: .bool(true))),
      contract: contract
    )
    let enumFailure = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: payload(acceptedPayload, setting: "status", to: .string("pending"))),
      contract: contract
    )
    let integerFailure = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: payload(acceptedPayload, setting: "count", to: .number(1.5))),
      contract: contract
    )
    let nestedFailure = try validator.validate(
      RuntimeOutputCandidate(
        source: .inlineCandidate,
        payload: payload(acceptedPayload, setting: "items", to: .array([.object(["id": .string("a")])]))
      ),
      contract: contract
    )
    let duplicateFailure = try validator.validate(
      RuntimeOutputCandidate(
        source: .inlineCandidate,
        payload: payload(
          acceptedPayload,
          setting: "items",
          to: .array([.object(["id": .string("ab")]), .object(["id": .string("ab")])])
        )
      ),
      contract: contract
    )
    let constFailure = try validator.validate(
      RuntimeOutputCandidate(
        source: .inlineCandidate,
        payload: payload(acceptedPayload, setting: "meta", to: .object(["kind": .string("adapter")]))
      ),
      contract: contract
    )
    let patternFailure = try validator.validate(
      RuntimeOutputCandidate(source: .inlineCandidate, payload: payload(acceptedPayload, setting: "code", to: .string("bad"))),
      contract: contract
    )

    XCTAssertEqual(extra.reason, "output contract $.extra additional property is not allowed")
    XCTAssertEqual(enumFailure.reason, "output contract $.status must equal one of the declared enum values")
    XCTAssertEqual(integerFailure.reason, "output contract $.count must be of type integer")
    XCTAssertEqual(nestedFailure.reason, "output contract $.items[0].id must have length >= 2")
    XCTAssertEqual(duplicateFailure.reason, "output contract $.items must contain unique items")
    XCTAssertEqual(constFailure.reason, "output contract $.meta.kind must equal the declared const value")
    XCTAssertEqual(patternFailure.reason, "output contract $.code must match the declared pattern")
  }

  func testValidatorSupportsAnyOfOneOfAllOfAndTopLevelObjectGuard() throws {
    let validator = DefaultWorkflowOutputValidator()

    let anyOfContract = WorkflowOutputContract(
      schema: [
        "anyOf": .array([
          .object(["required": .array([.string("ok")])]),
          .object(["required": .array([.string("fallback")])])
        ])
      ],
      requiredObject: true
    )
    let oneOfContract = WorkflowOutputContract(
      schema: [
        "oneOf": .array([
          .object(["required": .array([.string("a")])]),
          .object(["required": .array([.string("b")])])
        ])
      ],
      requiredObject: true
    )
    let allOfContract = WorkflowOutputContract(
      schema: [
        "allOf": .array([
          .object(["required": .array([.string("a")])]),
          .object(["required": .array([.string("b")])])
        ])
      ],
      requiredObject: true
    )
    let nonObjectContract = WorkflowOutputContract(schema: ["type": .string("array")], requiredObject: true)

    XCTAssertEqual(
      try validator.validate(
        RuntimeOutputCandidate(source: .inlineCandidate, payload: ["fallback": .bool(true)]),
        contract: anyOfContract
      ).status,
      .accepted
    )
    XCTAssertEqual(
      try validator.validate(
        RuntimeOutputCandidate(source: .inlineCandidate, payload: ["a": .bool(true), "b": .bool(true)]),
        contract: oneOfContract
      ).reason,
      "output contract $ must satisfy exactly one oneOf branch"
    )
    XCTAssertEqual(
      try validator.validate(
        RuntimeOutputCandidate(source: .inlineCandidate, payload: ["a": .bool(true)]),
        contract: allOfContract
      ).reason,
      "output contract $.b required property is missing"
    )
    XCTAssertEqual(
      try validator.validate(RuntimeOutputCandidate(source: .inlineCandidate, payload: [:]), contract: nonObjectContract).reason,
      "output contract $schema must allow object because node output payloads are always top-level JSON objects"
    )
  }

  func testValidatorRejectsMalformedSchemaDefinitionsBeforePayloadValidation() throws {
    let validator = DefaultWorkflowOutputValidator()

    let malformedContracts: [(WorkflowOutputContract, String)] = [
      (
        WorkflowOutputContract(schema: ["not": .object([:])], requiredObject: true),
        "output contract $schema.not uses an unsupported JSON Schema keyword"
      ),
      (
        WorkflowOutputContract(schema: ["properties": .array([])], requiredObject: true),
        "output contract $schema.properties must be an object when provided"
      ),
      (
        WorkflowOutputContract(schema: ["additionalProperties": .string("yes")], requiredObject: true),
        "output contract $schema.additionalProperties must be an object"
      ),
      (
        WorkflowOutputContract(schema: ["anyOf": .array([])], requiredObject: true),
        "output contract $schema.anyOf must be a non-empty array when provided"
      ),
      (
        WorkflowOutputContract(schema: ["minLength": .number(4), "maxLength": .number(2)], requiredObject: true),
        "output contract $schema.maxLength must be >= minLength"
      ),
      (
        WorkflowOutputContract(schema: ["pattern": .string("[")], requiredObject: true),
        "output contract $schema.pattern must be a valid regular expression"
      ),
      (
        WorkflowOutputContract(schema: ["type": .array([.string("object"), .string("tuple")])], requiredObject: true),
        "output contract $schema.type[1] must be a supported JSON Schema type"
      ),
      (
        WorkflowOutputContract(schema: ["required": .array([.string("")])], requiredObject: true),
        "output contract $schema.required[0] must be a non-empty string"
      ),
      (
        WorkflowOutputContract(schema: ["uniqueItems": .string("yes")], requiredObject: true),
        "output contract $schema.uniqueItems must be a boolean when provided"
      )
    ]

    for (contract, reason) in malformedContracts {
      let result = try validator.validate(RuntimeOutputCandidate(source: .inlineCandidate, payload: ["answer": .string("ok")]), contract: contract)
      XCTAssertEqual(result.status, .rejected)
      XCTAssertEqual(result.reason, reason)
    }
  }

  func testMissingRouteControlExhaustsTwoTotalValidationAttempts() async throws {
    let adapter = MissingRouteControlAdapter()
    let workflow = WorkflowDefinition(
      workflowId: "route-correction-bound",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
      steps: [WorkflowStepRef(id: "review", nodeId: "node", transitions: [
        WorkflowStepTransition(toStepId: "review", label: "flag")
      ])],
      nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
    )
    let node = AgentNodePayload(
      id: "node", model: "model", output: NodeOutputContract(jsonSchema: ["type": .string("object")])
    )

    do {
      _ = try await DeterministicWorkflowRunner(adapter: adapter).run(DeterministicWorkflowRunRequest(
        workflow: workflow, nodePayloads: ["node": node], maxSteps: 3
      ))
      XCTFail("expected route control rejection")
    } catch WorkflowPublicationError.validationRejected(let reason) {
      XCTAssertTrue(reason.contains("route.missingControl"))
    }
    let attempts = await adapter.attempts
    XCTAssertEqual(attempts, [1, 2])
  }

  private func payload(_ base: JSONObject, setting key: String, to value: JSONValue) -> JSONObject {
    var copy = base
    copy[key] = value
    return copy
  }
}

private actor MissingRouteControlAdapter: NodeAdapter {
  var attempts: [Int] = []

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if let attempt = input.output?.attempt { attempts.append(attempt) }
    return AdapterExecutionOutput(
      provider: "test", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: [:]
    )
  }
}
