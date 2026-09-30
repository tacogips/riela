import Foundation
import RielaCore
import XCTest
@testable import RielaWork

final class WorkHandoverModelsTests: XCTestCase {
  func testTaggedHandoverCasesRoundTripAndRejectUnknownKinds() throws {
    let q = HandoverQuestion(id: "q", text: "Continue?")
    let attemptId = AttemptID("attempt-1")
    let handoverId = HandoverID("handover-1")
    let producer = DecisionProducer.human(principal: "operator")
    let cases: [HandoverReason] = [
      .userInputRequired(q),
      .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "be present")),
      .ownerLost(OwnerLossEvidence(attemptId: attemptId, expiredAt: Date(timeIntervalSince1970: 4), fence: 2, forcedBy: producer)),
      .inactivity(stepId: "work", idleMs: 1000),
      .operatorMove(reason: "capacity")
    ]
    for value in cases { try assertRoundTrip(value) }
    try assertRoundTrip(AttemptEntry.takeover(fromAttemptId: attemptId, handoverId: handoverId))
    try assertRoundTrip(WaitReason.handover(handoverId))
    try assertRoundTrip(DecisionKind.handover(.operatorMove(reason: "move")))
    try assertRoundTrip(DecisionKind.answer(HandoverAnswer(questionId: "q", payload: ["ok": .bool(true)], answeredBy: producer, answeredAt: Date())))
    try assertRoundTrip(DecisionKind.takeover(handoverId: handoverId, placement: TakeoverPlacement(hostId: "host", requiredTraits: [.gui])))
    for kind in [EvidenceKind.handover, .handoverAnswer, .publication, .leaseFence] {
      try assertRoundTrip(kind)
    }
    for kind in [HandoverSinkKind.store, .kaiba, .gitRef, .file, .command] { try assertRoundTrip(kind) }
    try assertRoundTrip(PublicationState.published)
    try assertRoundTrip(PublicationState.checkpointFailed(reason: "disk"))
    try assertRoundTrip(PublicationState.unpublished(lastKnown: "abc"))
    XCTAssertThrowsError(try HandoverReason.decode(#"{"kind":"missing"}"#))
  }

  func testSealedPacketDigestIgnoresSinkMirrors() throws {
    let packet = samplePacket()
    let sealed = try packet.sealed()
    var withSink = sealed
    withSink.sinks = [HandoverSinkRef(kind: .file, locator: "packet.json", digest: "d", writtenAt: Date(timeIntervalSince1970: 5))]
    XCTAssertEqual(try sealed.canonicalDigest(), try withSink.canonicalDigest())
    XCTAssertEqual(try sealed.sealed().digest, sealed.digest)
  }

  func testHandoverValueModelsRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 5)
    let sink = HandoverSinkRef(kind: .file, locator: "packet", digest: "sha", writtenAt: now)
    let reason = HandoverReason.operatorMove(reason: "capacity")
    let workflow = HandoverWorkflowRef(workflowId: "flow", scope: "project", workflowDefinitionDir: "/work", entryStepId: "start", resumeStepId: "next")
    let budget = BudgetSnapshot(attemptsUsed: 1, maxAttempts: 4, tokensUsed: 12, maxTotalTokens: 100, wallClockMsUsed: 20, maxWallClockMs: 500)
    let summary = HandoverStepSummary(stepId: "start", stepExecutionId: "exec", status: .completed,
                                      acceptedOutput: ["ok": .bool(true)], responseExcerpt: "done", backend: "codex")
    let progress = HandoverProgress(acceptedSteps: [summary], remainingSteps: ["next"], latestGateResults: [],
                                    openFindings: [], evidenceSummary: ["handover": 1], remainingBudget: budget)
    let packet = samplePacket()
    let values: [any Codable & Equatable] = [
      OwnerLossEvidence(attemptId: AttemptID("attempt-1"), lastHeartbeatAt: now, expiredAt: now, fence: 2, forcedBy: .human(principal: "op")),
      workflow, budget, summary, progress, PublicationState.unpublished(lastKnown: nil),
      RepositoryDeliverable(root: "/repo", remote: "origin", branch: "riela/task/x/g1", baseRevision: "abc", state: .published),
      DocumentDeliverable(store: "kaiba", instance: "i", ids: ["n1"], producedByStepIds: ["write"]),
      ArtifactFileRef(path: "out.txt", sha256: "abc", bytes: 3), ArtifactBundleRef(files: [], location: sink),
      LocalOnlyDeliverable(kind: "kv", path: ".riela/kv.sqlite", bytes: 12),
      HandoverContinuationContract(resumeStepId: "next", completion: CompletionContract(), verification: [VerificationRequirement(name: "tests")], guardPolicy: GuardPolicy()),
      HandoverAnswer(questionId: "q", payload: ["v": .integer(1)], answeredBy: .human(principal: "op"), answeredAt: now),
      packet, TakeoverPlacement(hostId: "host", requiredTraits: [.gui], backend: .codexAgent, model: "model"),
      TakeoverLineage(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("h1"), hops: 2),
      AttemptLease(attemptId: AttemptID("attempt-1"), taskId: TaskID("task-1"), sessionId: "s", tokenDigest: "sha", fence: 1, heartbeatAt: now, expiresAt: now, hostId: "host"),
      LeasePolicy(), CheckpointPolicy.none, CheckpointPolicy.stepBoundary, CheckpointPolicy.everyMs(10), PublicationPolicy(), HandoverPolicy(),
      TaskHandoverSummary(taskId: TaskID("task-1"), handoverId: HandoverID("h1"), reasonKind: "operatorMove", requiredTraits: [], needsAnswer: false, createdAt: now),
      HandoverRequestRecord(requestId: "r", taskId: TaskID("task-1"), attemptId: AttemptID("attempt-1"), reason: "move", immediate: false, sinks: [.file], requestedAt: now)
    ]
    for value in values { try assertRoundTrip(value) }
    try assertRoundTrip(reason)
    try assertRoundTrip(DeliverableRef.repository(RepositoryDeliverable(root: "/repo", remote: "origin", branch: "b", baseRevision: "abc", state: .published)))
    try assertRoundTrip(DeliverableRef.document(DocumentDeliverable(store: "kaiba", ids: ["x"], producedByStepIds: ["write"])))
    try assertRoundTrip(DeliverableRef.artifactBundle(ArtifactBundleRef(files: [], location: sink)))
    try assertRoundTrip(DeliverableRef.localOnly(LocalOnlyDeliverable(kind: "memory", path: ".riela/memory")))
    try assertRoundTrip(AttemptEntry.takeover(fromAttemptId: AttemptID("attempt-1"), handoverId: HandoverID("h1")))
    try assertRoundTrip(Attempt(id: AttemptID("attempt-1"), taskId: TaskID("task-1"), sessionId: "s",
      takeoverLineage: TakeoverLineage(fromAttemptId: AttemptID("attempt-0"), handoverId: HandoverID("h1"), hops: 1),
      supersededByFence: 7))
    try assertRoundTrip(GuardPolicy(lease: LeasePolicy(ttlMs: 100, heartbeatMs: 10), handover: HandoverPolicy(onWaitSignal: false)))
    try assertRoundTrip(DeterministicDirectorRules(handoverOnInactivity: true))
    try assertRoundTrip(WorkTask(id: TaskID("task-1"), intentId: IntentID("intent-1"), title: "t", instruction: "i", fence: 8))
  }

  private func samplePacket() -> HandoverPacket {
    HandoverPacket(id: HandoverID("handover-1"), taskId: TaskID("task-1"), intentId: IntentID("intent-1"),
      fromAttemptId: AttemptID("attempt-1"), fromSessionId: "session-1", generation: 1,
      reason: .userInputRequired(HandoverQuestion(id: "q", text: "Proceed?")),
      workflow: HandoverWorkflowRef(workflowId: "w", entryStepId: "start", resumeStepId: "next"),
      progress: HandoverProgress(acceptedSteps: [], remainingSteps: ["next"], latestGateResults: [], openFindings: [],
                                 evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 1, tokensUsed: 0, wallClockMsUsed: 1)),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(resumeStepId: "next", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()),
      brief: "Continue.", producedBy: .runtime, producedOn: "host", createdAt: Date(timeIntervalSince1970: 5))
  }

  private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
  }
}

private extension HandoverReason {
  static func decode(_ json: String) throws -> HandoverReason? {
    try JSONDecoder().decode(HandoverReason.self, from: Data(json.utf8))
  }
}
