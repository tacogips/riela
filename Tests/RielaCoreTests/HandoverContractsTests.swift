import Foundation
import XCTest
@testable import RielaCore

final class HandoverContractsTests: XCTestCase {
  func testCoreContractsRoundTrip() throws {
    let question = HandoverQuestion(id: "q1", text: "Proceed?", options: [HandoverOption(id: "yes", label: "Yes", description: "continue")],
                                    answerSchema: ["type": .string("object")], defaultAnswer: ["ok": .bool(false)], impact: "deploy")
    let presence = PresenceRequirement(traits: [.interactive, .userReachable, .interactive], instructions: "Unlock the host.")
    XCTAssertEqual(presence.traits, [.userReachable, .interactive].sorted())
    let suspend = SuspendRecord(reasonKind: .userInputRequired, stepId: "build", stepExecutionId: "exec",
                                question: question, progressNote: "done", suspendedAt: Date(timeIntervalSince1970: 5),
                                producer: .stepExecution("exec"))
    for trait in HostTrait.allCases { try assertRoundTrip(trait) }
    try assertRoundTrip(question.options[0])
    try assertRoundTrip(question)
    try assertRoundTrip(presence)
    for reason in [SuspendReasonKind.userInputRequired, .userPresenceRequired, .operatorMove] { try assertRoundTrip(reason) }
    for kind in [HandoverSinkKind.store, .kaiba, .gitRef, .file, .command] { try assertRoundTrip(kind) }
    try assertRoundTrip(SuspendProducer.stepExecution("exec"))
    try assertRoundTrip(SuspendProducer.runtime)
    try assertRoundTrip(SuspendProducer.human(principal: "operator"))
    try assertRoundTrip(suspend)
    try assertRoundTrip(HandoverEnvelope(reason: .userInputRequired, question: question, progressNote: "x", resumeStepId: "next"))
    try assertRoundTrip(HandoverSinkKind.kaiba)
    try assertRoundTrip(HandoverSinkConfig(kind: .file, path: "packet.json"))
    try assertRoundTrip(HandoverSinkRef(kind: .file, locator: "a:#b", digest: String(repeating: "a", count: 64), writtenAt: Date(timeIntervalSince1970: 1)))
    try assertRoundTrip(ParsedHandoverSinkRef(kind: .file, locator: "a:#b", digest: String(repeating: "a", count: 64)))
    try assertRoundTrip(HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false))
    try assertRoundTrip(WorkflowHandoverDeclaration(sinks: []))
    try assertRoundTrip(WorkflowDeliverableProjection(store: "kaiba", instanceField: "instance", idFields: ["id"]))
    try assertRoundTrip(NodeOutputContract(deliverables: WorkflowDeliverableProjection(store: "kaiba", idFields: ["noteId"])))
    let workflow = WorkflowDefinition(workflowId: "w", defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 2),
      entryStepId: "s", nodeRegistry: [WorkflowNodeRegistryRef(id: "n")],
      steps: [WorkflowStepRef(id: "s", nodeId: "n")], nodes: [WorkflowNodeRef(id: "n")],
      handover: WorkflowHandoverDeclaration(sinks: []))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowDefinition.self, from: JSONEncoder().encode(workflow)), workflow)
    let host = HostCapabilitySnapshot(hostId: "h", backends: [], refreshedAt: Date(timeIntervalSince1970: 1),
                                      traits: [.gui, .userReachable, .gui])
    XCTAssertEqual(host.traits, [.userReachable, .gui].sorted())
    XCTAssertEqual(try JSONDecoder().decode(HostCapabilitySnapshot.self, from: JSONEncoder().encode(host)), host)
    let worker = DistributedWorkerRegistration(workerId: "w", incarnation: "i", groups: [], capacity: 1,
                                               traits: [.interactive, .interactive])
    XCTAssertEqual(worker.traits, [.interactive])
    XCTAssertEqual(try JSONDecoder().decode(DistributedWorkerRegistration.self, from: JSONEncoder().encode(worker)), worker)
    XCTAssertThrowsError(try JSONDecoder().decode(DistributedWorkerRegistration.self,
      from: Data(#"{"workerId":"w","incarnation":"i","groups":[],"capacity":1,"traits":["unknown"]}"#.utf8)))
    let event = WorkflowRunEvent(type: .handover, workflowId: "w", sessionId: "s",
      handoverReasonKind: .userInputRequired, handoverResumeStepId: "next", handoverQuestionId: "q", handoverQuestionText: "Proceed?")
    XCTAssertEqual(try JSONDecoder().decode(WorkflowRunEvent.self, from: JSONEncoder().encode(event)), event)
    let suspended = WorkflowSession(workflowId: "w", sessionId: "s", status: .suspended, entryStepId: "s",
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2))
    XCTAssertNil(LoopOutcomeClassifier.outcome(session: suspended, manifest: nil, requiredGateIds: []))
    XCTAssertEqual(try JSONDecoder().decode(PresenceRequirement.self, from: JSONEncoder().encode(presence)).traits, presence.traits)
  }

  func testEnvelopeValidationAndSinkRefParsing() throws {
    let question: JSONValue = .object(["id": .string("q"), "text": .string("Continue?"), "options": .array([])])
    let parsed = try HandoverEnvelope.parse(.object(["reason": .string("userInputRequired"), "question": question]), source: "node")
    XCTAssertEqual(parsed.question?.id, "q")
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("operatorMove")]), source: "node"))
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("userInputRequired")]), source: "node"))
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("userPresenceRequired"),
      "presence": .object(["traits": .array([]), "instructions": .string("go")])]), source: "node"))
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("userPresenceRequired"),
      "presence": .object(["traits": .array([.string("userReachable")]), "instructions": .string("go")]),
      "unexpected": .bool(true)]), source: "node"))
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("userInputRequired"), "question": question,
      "progressNote": .string(String(repeating: "é", count: 4_097))]), source: "node"))
    let ref = HandoverSinkRef(kind: .file, locator: "path:with#mark", digest: String(repeating: "b", count: 64), writtenAt: Date(timeIntervalSince1970: 1))
    let parsedRef = try HandoverSinkRef.parse(ref.serialized)
    XCTAssertEqual(parsedRef.locator, ref.locator)
    XCTAssertEqual(parsedRef.digest, ref.digest)
    XCTAssertThrowsError(try HandoverSinkRef.parse("file:path#sha256:BAD"))
    XCTAssertThrowsError(try HandoverSinkRef.parse("file:path"))
    XCTAssertThrowsError(try HandoverEnvelope.parse(.object(["reason": .string("userInputRequired"), "question": .string("wrong")]), source: "node")) {
      guard let error = $0 as? AdapterExecutionError else { return XCTFail("expected invalid-output adapter error") }
      XCTAssertEqual(error.code, .invalidOutput)
      XCTAssertTrue(error.message.hasPrefix("node.handover"))
    }
    let presence = try HandoverEnvelope.parse(.object([
      "reason": .string("userPresenceRequired"),
      "presence": .object(["traits": .array([.string("gui")]), "instructions": .string("approve")])
    ]), source: "node")
    XCTAssertEqual(presence.presence?.traits, [.gui])
  }

  func testSessionSuspendAndClosedStatusRoundTrip() throws {
    let record = SuspendRecord(reasonKind: .userPresenceRequired, stepId: "setup", presence: PresenceRequirement(traits: [.gui], instructions: "approve"),
                               suspendedAt: Date(timeIntervalSince1970: 10), producer: .runtime)
    let session = WorkflowSession(workflowId: "w", sessionId: "s", status: .suspended, entryStepId: "setup",
                                  createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2), suspend: record)
    let decoded = try JSONDecoder().decode(WorkflowSession.self, from: JSONEncoder().encode(session))
    XCTAssertEqual(decoded, session)
    XCTAssertEqual(try JSONDecoder().decode(WorkflowSessionStatus.self, from: Data("\"suspended\"".utf8)), .suspended)
    XCTAssertThrowsError(try JSONDecoder().decode(WorkflowSessionStatus.self, from: Data("\"paused\"".utf8)))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowStepExecutionStatus.self, from: Data("\"suspended\"".utf8)), .suspended)
    XCTAssertEqual(WorkflowSessionFailureKind.stalled.rawValue, "stalled")
    XCTAssertEqual(WorkflowSessionFailureKind.leaseLost.rawValue, "leaseLost")
  }

  func testWorkflowValidationRejectsReservedSchemaKeyAndWarnsForLocalState() {
    let agentRegistry = [WorkflowNodeRegistryRef(id: "agent", nodeFile: "nodes/agent.json")]
    let agentWorkflow = validationWorkflow(registry: agentRegistry)
    let payload = AgentNodePayload(id: "agent", model: "model", output: NodeOutputContract(jsonSchema: [
      "type": .string("object"),
      "properties": .object(["handover": .object(["type": .string("object")])])
    ]))
    let reserved = DefaultWorkflowValidator().validate(agentWorkflow, nodePayloads: ["agent": payload])
    XCTAssertTrue(reserved.contains {
      $0.severity == .error && $0.message == "output.jsonSchema must not declare the reserved 'handover' key"
    })

    let localWorkflow = validationWorkflow(registry: [
      WorkflowNodeRegistryRef(id: "memory", addon: WorkflowNodeAddonRef(name: "riela/kv-set"))
    ])
    let diagnostics = DefaultWorkflowValidator().validate(localWorkflow)
    XCTAssertTrue(diagnostics.contains {
      $0.severity == .warning
        && $0.message == "riela memory/KV state is cwd-local and becomes a localOnly deliverable on handover; add a kaiba mirror step"
    })
    XCTAssertFalse(diagnostics.contains { $0.severity == .error })
  }

  private func validationWorkflow(registry: [WorkflowNodeRegistryRef]) -> WorkflowDefinition {
    let steps = [WorkflowStepRef(id: "only", nodeId: registry[0].id)]
    return WorkflowDefinition(workflowId: "handover-validation",
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 2), entryStepId: "only",
      nodeRegistry: registry, steps: steps,
      nodes: registry.map { WorkflowNodeRef(id: $0.id, nodeFile: $0.nodeFile, addon: $0.addon) })
  }

  private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value)), value, file: file, line: line)
  }
}
