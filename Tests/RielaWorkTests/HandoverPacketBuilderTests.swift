import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class HandoverPacketBuilderTests: XCTestCase {
  func testRedactionIsRecursiveAndMatchesBoundValues() throws {
    let value: JSONValue = .object(["token": .string("secret"), "nested": .array([.string("secret"), .object(["ok": .bool(true)])])])
    let result = HandoverRedactionRules.apply(value, rules: HandoverRedactionRules(secretKeyNames: ["token"], boundValues: ["secret": "API_KEY"]))
    XCTAssertEqual(result, .object(["token": .string("<redacted:token>"), "nested": .array([.string("<redacted:API_KEY>"), .object(["ok": .bool(true)])])]))
  }

  func testBriefMatchesGoldenFixture() throws {
    let packet = HandoverPacket(id: HandoverID("handover-1"), taskId: TaskID("task-1"), intentId: IntentID("intent-1"),
      fromAttemptId: AttemptID("attempt-1"), fromSessionId: "session-1", generation: 1,
      reason: .userInputRequired(HandoverQuestion(id: "q", text: "Proceed?")),
      workflow: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "next"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["next"], latestGateResults: [], openFindings: [], evidenceSummary: [:],
        remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "next", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()),
      brief: "", producedBy: .runtime, producedOn: "host", createdAt: Date(timeIntervalSince1970: 10))
    let actual = HandoverBriefRenderer().render(packet)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/handover-brief-golden.md")
    XCTAssertEqual(actual, try String(contentsOf: fixture, encoding: .utf8))
  }

  func testBuildIsDeterministicAndPreservesOnlyAcceptedHistory() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let execution = WorkflowStepExecution(executionId: "exec-1", stepId: "done", nodeId: "agent", attempt: 1,
      backend: .codexAgent, backendSessionId: "private-session", backendWorkingDirectory: "/private", status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["apiKey": .string("bound-secret")], when: [:], acceptedAt: now),
      streamedResponseText: "response", usage: AdapterUsage(inputTokens: 4, outputTokens: 5, totalTokens: 9), createdAt: now, updatedAt: now)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .suspended, entryStepId: "start",
                                  createdAt: now, updatedAt: now, executions: [execution])
    let message = WorkflowMessageRecord(communicationId: "message-1", workflowExecutionId: "session-1", fromStepId: "done", toStepId: "left",
      sourceStepExecutionId: "exec-1", payload: ["credential": .string("bound-secret")], createdOrder: 1, createdAt: now)
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: [message])
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 3),
      entryStepId: "start", nodeRegistry: [], steps: [
        WorkflowStepRef(id: "start", nodeId: "a", transitions: [WorkflowStepTransition(toStepId: "left"), WorkflowStepTransition(toStepId: "right")]),
        WorkflowStepRef(id: "left", nodeId: "b", transitions: [WorkflowStepTransition(toStepId: "done")]),
        WorkflowStepRef(id: "right", nodeId: "c", transitions: [WorkflowStepTransition(toStepId: "done")]),
        WorkflowStepRef(id: "done", nodeId: "d")
      ], nodes: [])
    let input = HandoverPacketBuilderInput(handoverId: HandoverID("handover-1"), task: task,
      attempt: Attempt(id: AttemptID("attempt-1"), taskId: task.id, generation: 1, sessionId: "session-1"),
      reason: .operatorMove(reason: "capacity"), resumeStepId: "left", snapshot: snapshot, workflow: workflow,
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "left"),
      variables: ["apiKey": .string("bound-secret"), "handover": .string("old")], hostId: "host",
      producer: .runtime, redaction: HandoverRedactionRules(boundValues: ["bound-secret": "API_KEY"]), now: now)
    let builder = HandoverPacketBuilder(store: store)
    let first = try builder.build(input)
    let second = try builder.build(input)
    XCTAssertEqual(try JSONCanonical.encode(first), try JSONCanonical.encode(second))
    XCTAssertEqual(first.digest, second.digest)
    XCTAssertEqual(first.progress.remainingSteps, ["left", "done"])
    XCTAssertEqual(first.variables, ["apiKey": .string("<redacted:API_KEY>")])
    XCTAssertNil(first.history.executions[0].backendSessionId)
    XCTAssertNil(first.history.executions[0].backendWorkingDirectory)
    XCTAssertNil(first.history.executions[0].usage)
    XCTAssertEqual(first.progress.acceptedSteps[0].acceptedOutput?["apiKey"], .string("<redacted:API_KEY>"))
    XCTAssertEqual(first.history.messages[0].payload["credential"], .string("<redacted:API_KEY>"))
  }

  func testHistoryExcludesUnacceptedExecutionsAndBranchingRemainingStepsAreBreadthFirst() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let accepted = WorkflowAcceptedOutputMetadata(payload: ["ok": .bool(true)], when: [:], acceptedAt: now)
    func execution(_ id: String, status: WorkflowStepExecutionStatus, output: WorkflowAcceptedOutputMetadata?) -> WorkflowStepExecution {
      WorkflowStepExecution(executionId: id, stepId: "start", nodeId: "a", attempt: 1, status: status,
        acceptedOutput: output, createdAt: now, updatedAt: now)
    }
    let executions = [
      execution("exec-1", status: .completed, output: accepted),
      execution("exec-2", status: .failed, output: accepted),
      execution("exec-3", status: .completed, output: nil),
      execution("exec-4", status: .completed, output: accepted)
    ]
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .suspended, entryStepId: "start",
                                  createdAt: now, updatedAt: now, executions: executions)
    let messages = executions.enumerated().map { index, execution in
      WorkflowMessageRecord(communicationId: "message-\(index + 1)", workflowExecutionId: "session-1", fromStepId: "start", toStepId: "left",
        sourceStepExecutionId: execution.executionId, payload: ["from": .string(execution.executionId)], createdOrder: index + 1, createdAt: now)
    }
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1000, maxLoopIterations: 3),
      entryStepId: "start", nodeRegistry: [], steps: [
        WorkflowStepRef(id: "start", nodeId: "a", transitions: [WorkflowStepTransition(toStepId: "left"), WorkflowStepTransition(toStepId: "right")]),
        WorkflowStepRef(id: "left", nodeId: "b", transitions: [WorkflowStepTransition(toStepId: "done")]),
        WorkflowStepRef(id: "right", nodeId: "c", transitions: [WorkflowStepTransition(toStepId: "done")]),
        WorkflowStepRef(id: "done", nodeId: "d")
      ], nodes: [])
    let input = HandoverPacketBuilderInput(handoverId: HandoverID("handover-1"), task: task,
      attempt: Attempt(id: AttemptID("attempt-1"), taskId: task.id, generation: 1, sessionId: "session-1"),
      reason: .operatorMove(reason: "capacity"), resumeStepId: "start",
      snapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages), workflow: workflow,
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"),
      hostId: "host", producer: .runtime, now: now)
    let packet = try HandoverPacketBuilder(store: store).build(input)
    XCTAssertEqual(packet.progress.acceptedSteps.map(\.stepExecutionId), ["exec-1", "exec-4"])
    XCTAssertEqual(packet.history.executions.map(\.executionId), ["exec-1", "exec-4"])
    XCTAssertEqual(packet.history.messages.map(\.sourceStepExecutionId), ["exec-1", "exec-4"])
    XCTAssertEqual(packet.progress.remainingSteps, ["start", "left", "right", "done"])
    XCTAssertFalse(packet.history.truncated)
  }

  func testGateEvidenceKeepsLatestPerGateInStableOrder() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let early = Date(timeIntervalSince1970: 10)
    let latest = Date(timeIntervalSince1970: 20)
    let records = [
      LoopGateResult(gateId: "gate-b", stepId: "judge", stepExecutionId: "e1", decision: .rejected),
      LoopGateResult(gateId: "gate-a", stepId: "judge", stepExecutionId: "e2", decision: .accepted),
      LoopGateResult(gateId: "gate-b", stepId: "judge", stepExecutionId: "e3", decision: .accepted)
    ]
    for (index, result) in records.enumerated() {
      let payload = try JSONCanonical.decoder().decode(JSONObject.self, from: JSONCanonical.encode(result))
      try store.saveEvidence(Evidence(id: EvidenceID("gate-evidence-\(index)"), taskId: task.id, kind: .gate,
        producedBy: .runtime, payloadRef: .inline(payload), createdAt: index == 2 ? latest : early))
    }
    let session = WorkflowSession(workflowId: "flow", sessionId: "session", status: .suspended, entryStepId: "start",
      createdAt: early, updatedAt: latest)
    let packet = try HandoverPacketBuilder(store: store).build(builderInput(task: task, session: session, messages: [], hostId: "host", now: latest))
    XCTAssertEqual(packet.progress.latestGateResults.map(\.gateId), ["gate-a", "gate-b"])
    XCTAssertEqual(packet.progress.latestGateResults.last?.decision, .accepted)
  }

  func testLargeAcceptedOutputIsBounded() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let execution = WorkflowStepExecution(executionId: "exec", stepId: "done", nodeId: "a", attempt: 1, status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["text": .string(String(repeating: "x", count: 40_000))], when: [:], acceptedAt: now),
      createdAt: now, updatedAt: now)
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(workflowId: "flow", sessionId: "s", status: .suspended,
      entryStepId: "done", createdAt: now, updatedAt: now, executions: [execution]))
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 1), entryStepId: "done", nodeRegistry: [], steps: [], nodes: [])
    let input = HandoverPacketBuilderInput(handoverId: HandoverID("h"), task: task, attempt: Attempt(id: AttemptID("a"), taskId: task.id, sessionId: "s"),
      reason: .operatorMove(reason: "move"), resumeStepId: "done", snapshot: snapshot, workflow: workflow,
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "done", resumeStepId: "done"), hostId: "host", producer: .runtime, now: now)
    let output = try HandoverPacketBuilder(store: store).build(input).progress.acceptedSteps[0].acceptedOutput
    XCTAssertEqual(output?["truncated"], .bool(true))
    let expectedPayload: JSONObject = ["text": .string(String(repeating: "x", count: 40_000))]
    XCTAssertEqual(output?["bytes"], .integer(Int64(try JSONCanonical.encode(expectedPayload).count)))
  }

  func testOversizedHistoryIsTruncatedAndMessageSecretsAreRedacted() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let execution = WorkflowStepExecution(executionId: "exec", stepId: "done", nodeId: "a", attempt: 1, status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["ok": .bool(true)], when: [:], acceptedAt: now),
      createdAt: now, updatedAt: now)
    let session = WorkflowSession(workflowId: "flow", sessionId: "s", status: .suspended, entryStepId: "done",
      createdAt: now, updatedAt: now, executions: [execution])
    let message = WorkflowMessageRecord(communicationId: "m", workflowExecutionId: "s", fromStepId: "done", toStepId: "done",
      sourceStepExecutionId: "exec", payload: ["token": .string("secret"), "large": .string(String(repeating: "x", count: 3_000_000))],
      createdOrder: 1, createdAt: now)
    let input = builderInput(task: task, session: session, messages: [message], hostId: "host", now: now,
      redaction: HandoverRedactionRules(secretKeyNames: ["token"]))
    let packet = try HandoverPacketBuilder(store: store).build(input)
    XCTAssertTrue(packet.history.truncated)
    XCTAssertTrue(packet.history.executions.isEmpty)
    XCTAssertTrue(packet.history.messages.isEmpty)
  }

  func testPacketAboveFourMiBIsRejected() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let deliverables = (0..<16_000).map { index in
      let path = "\(index)-" + String(repeating: "x", count: 280)
      return DeliverableRef.localOnly(LocalOnlyDeliverable(kind: "memory", path: path))
    }
    let input = builderInput(task: task, session: WorkflowSession(workflowId: "flow", sessionId: "s", status: .suspended,
      entryStepId: "start", createdAt: now, updatedAt: now), messages: [], hostId: "host", now: now, deliverables: deliverables)
    XCTAssertThrowsError(try HandoverPacketBuilder(store: store).build(input)) { error in
      XCTAssertTrue(String(describing: error).contains("exceeds 4 MiB"))
    }
  }

  func testHistoryExecutionsRedactInputSnapshotAndDropTranscripts() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let now = Date(timeIntervalSince1970: 10)
    let execution = WorkflowStepExecution(executionId: "exec-1", stepId: "done", nodeId: "agent", attempt: 1,
      inputSnapshot: ["variables": .object(["apiKey": .string("bound-secret")]),
                      "_rielaHistoryContract": .object(["workflowDigest": .string("digest-1")])], status: .completed,
      acceptedOutput: WorkflowAcceptedOutputMetadata(payload: ["ok": .bool(true)], when: [:], acceptedAt: now),
      streamedResponseText: "full transcript", createdAt: now, updatedAt: now)
    let session = WorkflowSession(workflowId: "flow", sessionId: "session-1", status: .suspended, entryStepId: "start",
                                  createdAt: now, updatedAt: now, executions: [execution])
    let input = builderInput(task: task, session: session, messages: [], hostId: "host", now: now,
      redaction: HandoverRedactionRules(boundValues: ["bound-secret": "API_KEY"]))
    let packet = try HandoverPacketBuilder(store: store).build(input)
    XCTAssertEqual(packet.history.executions.count, 1)
    XCTAssertEqual(packet.history.executions[0].inputSnapshot?["variables"],
                   JSONValue.object(["apiKey": .string("<redacted:API_KEY>")]))
    XCTAssertNil(packet.history.executions[0].streamedResponseText)
    XCTAssertNil(packet.history.executions[0].adapterOutput)
    XCTAssertEqual(packet.history.compatibilityDigests["done"], "digest-1")
    let bytes = try JSONCanonical.encode(packet)
    XCTAssertFalse((String(data: bytes, encoding: .utf8) ?? "").contains("bound-secret"))
  }

  private func builderInput(task: WorkTask, session: WorkflowSession, messages: [WorkflowMessageRecord], hostId: String,
                            now: Date, deliverables: [DeliverableRef] = [], redaction: HandoverRedactionRules = HandoverRedactionRules()) -> HandoverPacketBuilderInput {
    let workflow = WorkflowDefinition(workflowId: "flow", defaults: WorkflowDefaults(nodeTimeoutMs: 1, maxLoopIterations: 1),
      entryStepId: "start", nodeRegistry: [], steps: [], nodes: [])
    return HandoverPacketBuilderInput(handoverId: HandoverID("handover-large"), task: task,
      attempt: Attempt(id: AttemptID("attempt-1"), taskId: task.id, sessionId: session.sessionId),
      reason: .operatorMove(reason: "move"), resumeStepId: "start",
      snapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages), workflow: workflow,
      workflowRef: HandoverWorkflowRef(workflowId: "flow", entryStepId: "start", resumeStepId: "start"),
      deliverables: deliverables, hostId: hostId, producer: .runtime, redaction: redaction, now: now)
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func sampleTask() -> WorkTask {
    WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "Repair task", instruction: "Fix it",
             plan: .workflow(WorkflowReference(name: "flow")), state: .running)
  }
}
