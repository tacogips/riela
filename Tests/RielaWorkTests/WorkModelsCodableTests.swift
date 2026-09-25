import Foundation
import RielaCore
import XCTest
@testable import RielaWork

/// P0-2: every domain type round-trips, and every closed enum rejects an
/// unknown value instead of tolerating it (design decision 12).
final class WorkModelsCodableTests: XCTestCase {
  // MARK: - Fixtures

  func testIntentFixtureRoundTrips() throws {
    let intent = try decodeFixture(Intent.self, named: "intent")
    XCTAssertEqual(intent.id, IntentID("intent-6a2d3c11-8b1f-4f2a-9c3d-1b7e5f0a4d22"))
    XCTAssertEqual(intent.origin, .cli)
    XCTAssertEqual(intent.state, .open)
    XCTAssertEqual(intent.acceptance.first?.gateIds, ["implementation-review"])
    XCTAssertEqual(intent.constraints.capabilities, ["repository.write"])
    try assertReencodesToFixture(intent, named: "intent")
  }

  func testWorkTaskFixtureRoundTripsAndKeepsTheDesignsGuardKey() throws {
    let task = try decodeFixture(WorkTask.self, named: "work-task")
    XCTAssertEqual(task.id, TaskID("task-0f0d0d48-2b3e-4c1d-9f0a-5a9a3b1e7c22"))
    XCTAssertEqual(task.state, .running)
    XCTAssertEqual(task.version, 3)
    XCTAssertEqual(task.plan?.workflowName, "loop-engineer-quality-loop")
    XCTAssertEqual(task.guardPolicy.onViolation, .askDirector)
    XCTAssertEqual(task.guardPolicy.budget?.maxAttempts, 4)
    XCTAssertEqual(task.trigger, .schedule(cron: "0 0 * * * *", timezone: "Asia/Tokyo"))
    XCTAssertEqual(task.completion.gates.first?.acceptWhen.maxHighFindings, 0)
    XCTAssertEqual(task.dependsOn, [TaskID("task-1a1d3c11-8b1f-4f2a-9c3d-1b7e5f0a4d99")])
    guard case let .repository(repository)? = task.context else {
      return XCTFail("the fixture declares a repository context")
    }
    XCTAssertEqual(repository.isolation, .worktree)
    XCTAssertEqual(repository.writeScopes, ["Sources/"])

    // Delta D4: the Swift property is `guardPolicy`, the JSON key is `guard`.
    let object = try encodedObject(task)
    XCTAssertNotNil(object["guard"])
    XCTAssertNil(object["guardPolicy"])
    try assertReencodesToFixture(task, named: "work-task")
  }

  func testAttemptFixtureRoundTrips() throws {
    let attempt = try decodeFixture(Attempt.self, named: "attempt")
    XCTAssertEqual(attempt.entry, .recoverFromGate("implementation-review"))
    XCTAssertEqual(attempt.state, .terminal)
    XCTAssertEqual(attempt.generation, 2)
    XCTAssertEqual(attempt.isolation?.branch, "work/attempt-4e9c2a77")
    try assertReencodesToFixture(attempt, named: "attempt")
  }

  func testDecisionFixtureRoundTrips() throws {
    let decision = try decodeFixture(Decision.self, named: "decision")
    XCTAssertEqual(decision.kind, .recover(fromGateId: "implementation-review"))
    XCTAssertEqual(decision.kind.kindName, "recover")
    XCTAssertEqual(decision.producer, .policy(rule: "gate-rejected-with-open-findings"))
    XCTAssertEqual(decision.producer.kindName, "policy")
    XCTAssertEqual(decision.causedBy, [EvidenceID("evidence-9c1f0b2e-5a44-4c6f-9a0e-2d3b8c7e1f50")])
    try assertReencodesToFixture(decision, named: "decision")
  }

  func testEvidenceFixtureRoundTrips() throws {
    let evidence = try decodeFixture(Evidence.self, named: "evidence")
    XCTAssertEqual(evidence.kind, .gate)
    XCTAssertEqual(evidence.producedBy, .stepExecution("exec-implementation-review-1"))
    XCTAssertEqual(evidence.producedBy.stepExecutionId, "exec-implementation-review-1")
    XCTAssertEqual(evidence.payloadRef.inlinePayload?["gateId"], .string("implementation-review"))
    try assertReencodesToFixture(evidence, named: "evidence")
  }

  func testFindingFixtureRoundTrips() throws {
    let finding = try decodeFixture(Finding.self, named: "finding")
    XCTAssertEqual(finding.severity, .high)
    XCTAssertEqual(finding.status, .open)
    XCTAssertEqual(finding.fingerprint, LoopFindingFingerprint(key: "id:review-1"))
    XCTAssertTrue(finding.blocksCompletion)
    try assertReencodesToFixture(finding, named: "finding")
  }

  // MARK: - Strict decoding

  func testUnknownRawValueEnumsAreDecodeErrors() throws {
    assertDecodeFails(TaskState.self, json: "\"archived\"")
    assertDecodeFails(AttemptState.self, json: "\"paused\"")
    assertDecodeFails(EvidenceKind.self, json: "\"telemetry\"")
    assertDecodeFails(IntentState.self, json: "\"parked\"")
    assertDecodeFails(WorkOrigin.self, json: "\"webhook\"")
    assertDecodeFails(ViolationAction.self, json: "\"ignore\"")
    assertDecodeFails(RepositoryIsolation.self, json: "\"container\"")
    assertDecodeFails(FindingSeverity.self, json: "\"medium\"")
    assertDecodeFails(FindingStatus.self, json: "\"resolved\"")
  }

  func testUnknownDiscriminatorsOnPayloadEnumsAreDecodeErrors() throws {
    assertDecodeFails(DecisionKind.self, json: #"{"kind":"escalate"}"#)
    assertDecodeFails(WaitReason.self, json: #"{"kind":"quota"}"#)
    assertDecodeFails(DecisionProducer.self, json: #"{"kind":"daemon","rule":"x"}"#)
    assertDecodeFails(EvidenceProducer.self, json: #"{"kind":"plugin","addon":"x"}"#)
    assertDecodeFails(PayloadReference.self, json: #"{"kind":"blob","path":"x"}"#)
    assertDecodeFails(TaskPlan.self, json: #"{"kind":"script"}"#)
    assertDecodeFails(TaskTrigger.self, json: #"{"kind":"webhook"}"#)
    assertDecodeFails(AttemptEntry.self, json: #"{"kind":"replay"}"#)
    assertDecodeFails(ContextBinding.self, json: #"{"kind":"mailbox"}"#)
  }

  func testPayloadEnumsRejectAKnownKindWithAMissingPayload() throws {
    assertDecodeFails(DecisionKind.self, json: #"{"kind":"recover"}"#)
    assertDecodeFails(TaskTrigger.self, json: #"{"kind":"schedule"}"#)
    assertDecodeFails(AttemptEntry.self, json: #"{"kind":"recoverFromGate"}"#)
    assertDecodeFails(WaitReason.self, json: #"{"kind":"clarification"}"#)
  }

  func testMissingRequiredTaskFieldIsADecodeError() throws {
    var object = try encodedObject(try decodeFixture(WorkTask.self, named: "work-task"))
    object.removeValue(forKey: "version")
    let data = try JSONEncoder().encode(JSONValue.object(object))
    XCTAssertThrowsError(try decoder().decode(WorkTask.self, from: data))
  }

  // MARK: - Every payload case survives a round trip

  func testEveryDecisionKindAndWaitReasonRoundTrips() throws {
    let violation = GuardViolationRef(
      evidenceId: EvidenceID("evidence-1"),
      summary: "gate visits exceeded"
    )
    let kinds: [DecisionKind] = [
      .start,
      .resume,
      .rerun(fromStepId: nil),
      .rerun(fromStepId: "implementation"),
      .recover(fromGateId: "implementation-review"),
      .replan(instruction: "split the importer change"),
      .wait(.capacity),
      .wait(.dependency),
      .wait(.human),
      .wait(.clarification(question: "which vendor feed?")),
      .wait(.until(Date(timeIntervalSince1970: 1_790_000_000))),
      .proposeWorkflowChange(ProposalRef(id: "proposal-1", summary: "add a verification gate")),
      .accept,
      .reject(reason: "out of scope"),
      .cancel,
      .stop(violation)
    ]
    for kind in kinds {
      XCTAssertEqual(try roundTrip(kind), kind, "\(kind.kindName) must round-trip")
      XCTAssertFalse(kind.kindName.isEmpty)
    }
  }

  func testEveryAttemptEntryTriggerAndProducerRoundTrips() throws {
    for entry: AttemptEntry in [.start, .resume, .rerunFromStep(nil), .rerunFromStep("plan"),
                                .recoverFromGate("gate"), .director] {
      XCTAssertEqual(try roundTrip(entry), entry)
    }
    for trigger: TaskTrigger in [.manual, .schedule(cron: "* * * * * *", timezone: nil),
                                 .event(bindingId: "binding-1"), .dependency] {
      XCTAssertEqual(try roundTrip(trigger), trigger)
    }
    for producer: DecisionProducer in [.policy(rule: "r"), .agent(sessionId: "s"), .human(principal: "p")] {
      XCTAssertEqual(try roundTrip(producer), producer)
    }
    for producer: EvidenceProducer in [.stepExecution("e"), .addon("riela/git-commit"), .runtime,
                                       .director(sessionId: "s"), .human(principal: "p"),
                                       .contextAdapter("repository")] {
      XCTAssertEqual(try roundTrip(producer), producer)
    }
    for reference: PayloadReference in [.inline(["a": .integer(1)]), .artifact(path: "artifacts/x.json")] {
      XCTAssertEqual(try roundTrip(reference), reference)
    }
    for plan: TaskPlan in [
      .workflow(WorkflowReference(name: "w")),
      .temporaryWorkflow(TemporaryWorkflowPlan(name: "temp", definition: ["steps": .array([])]))
    ] {
      XCTAssertEqual(try roundTrip(plan), plan)
    }
  }

  func testTaskStateTerminalityCoversEveryCase() {
    XCTAssertEqual(
      TaskState.allCases.filter(\.isTerminal),
      [.succeeded, .failed, .cancelled, .superseded]
    )
  }

  // MARK: - Helpers

  private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private func fixtureData(named name: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
      "missing fixture Tests/RielaWorkTests/Fixtures/\(name).json"
    )
    return try Data(contentsOf: url)
  }

  private func decodeFixture<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
    try decoder().decode(type, from: try fixtureData(named: name))
  }

  /// The fixtures are checked in for P1 to reuse, so re-encoding a decoded
  /// fixture must reproduce exactly the fixture's JSON tree: same keys, same
  /// values, no key the model silently drops and none it silently adds.
  /// The comparison is on the parsed tree rather than on bytes so it pins the
  /// shape without pinning `JSONEncoder`'s whitespace and slash escaping.
  private func assertReencodesToFixture<T: Codable>(
    _ value: T,
    named name: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let expected = try decoder().decode(JSONValue.self, from: try fixtureData(named: name))
    let actual = try decoder().decode(JSONValue.self, from: try encoder().encode(value))
    XCTAssertEqual(actual, expected, "fixture \(name).json drifted from the model", file: file, line: line)
  }

  private func encodedObject<T: Encodable>(_ value: T) throws -> JSONObject {
    let data = try encoder().encode(value)
    guard case let .object(object) = try decoder().decode(JSONValue.self, from: data) else {
      throw WorkModelsCodableTestError.notAnObject
    }
    return object
  }

  private func roundTrip<T: Codable>(_ value: T) throws -> T {
    try decoder().decode(T.self, from: try encoder().encode(value))
  }

  private func assertDecodeFails<T: Decodable>(
    _ type: T.Type,
    json: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try decoder().decode(type, from: Data(json.utf8)),
      "\(type) must reject \(json)",
      file: file,
      line: line
    )
  }
}

private enum WorkModelsCodableTestError: Error {
  case notAnObject
}
