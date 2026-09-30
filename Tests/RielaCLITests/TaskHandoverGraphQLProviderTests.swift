import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import RielaWork
import XCTest
@testable import RielaCLI

private enum ConcurrentReportOutcome: Equatable, Sendable {
  case success(taskState: String?, decisionKind: String?)
  case unauthorized
}

@MainActor
final class TaskHandoverGraphQLProviderTests: XCTestCase {
  func testPacketLookupAndAwaitingHandoverTraitFiltering() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let packet = try savePresencePacket(task: task, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)

    let loadedPacket = try await provider.taskHandover(
      taskId: task.id.rawValue, handoverId: packet.id.rawValue, context: context
    )
    let loaded = try XCTUnwrap(loadedPacket)
    XCTAssertEqual(loaded.digest, packet.digest)
    XCTAssertEqual(loaded.packet["digest"], .string(packet.digest))
    let withoutTraits = try await provider.tasksAwaitingHandover(traits: nil, context: context)
    XCTAssertEqual(withoutTraits.map(\.taskId), [task.id.rawValue])
    let eligible = try await provider.tasksAwaitingHandover(traits: ["userReachable"], context: context)
    XCTAssertEqual(eligible.map(\.taskId), [task.id.rawValue])
    do {
      _ = try await provider.tasksAwaitingHandover(traits: ["unknown"], context: context)
      XCTFail("unknown traits must be rejected")
    } catch let error as TaskHandoverGraphQLError {
      XCTAssertEqual(error.code, "invalid_input")
    }
  }

  func testRequestHandoverWithoutRunningAttemptFailsAndAnswerSchedulesTask() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    _ = try saveQuestionPacket(task: task, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)

    do {
      _ = try await provider.requestTaskHandover(
        GraphQLRequestTaskHandoverInput(taskId: task.id.rawValue, reason: "move", immediate: true),
        context: context
      )
      XCTFail("request without a running attempt should fail")
    } catch {
      XCTAssertTrue(String(describing: error).contains("running attempt"))
    }

    let result = try await provider.answerTask(
      GraphQLAnswerTaskInput(taskId: task.id.rawValue, questionId: "approval", answer: ["approved": .bool(true)]),
      context: context
    )
    XCTAssertEqual(result.decisionKind, "answer")
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .scheduled)
  }

  func testTakeoverValidatesTraitsReservesOnRemoteHostAndHeartbeatsLease() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let predecessorId = AttemptID("attempt-predecessor-test")
    try savePredecessor(task: task, attemptId: predecessorId, store: harness.store)
    let packet = try savePresencePacket(task: task, fromAttemptId: predecessorId, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)

    do {
      _ = try await provider.takeoverTask(
        GraphQLTakeoverTaskInput(
          taskId: task.id.rawValue, handoverId: packet.id.rawValue,
          hostId: "worker-a", traits: []
        ),
        context: context
      )
      XCTFail("missing required traits should conflict")
    } catch let error as TaskHandoverGraphQLError {
      XCTAssertEqual(error.code, "conflict")
      XCTAssertTrue(error.message.contains("host-traits-unavailable"))
    }

    let reservation = try await provider.takeoverTask(
      GraphQLTakeoverTaskInput(
        taskId: task.id.rawValue, handoverId: packet.id.rawValue,
        hostId: "worker-a", traits: ["userReachable"]
      ),
      context: context
    )
    let attemptId = try XCTUnwrap(reservation.attemptId)
    let lease = try XCTUnwrap(harness.store.loadLease(attemptId: AttemptID(attemptId)))
    XCTAssertEqual(lease.hostId, "worker-a")
    XCTAssertEqual(reservation.fence, task.fence + 1)
    XCTAssertNotNil(reservation.heartbeatToken)

    do {
      _ = try await provider.heartbeatAttempt(attemptId: attemptId, token: "wrong", context: context)
      XCTFail("wrong lease token should be unauthorized")
    } catch let error as TaskHandoverGraphQLError {
      XCTAssertEqual(error.code, "unauthorized")
    }
    let heartbeat = try await provider.heartbeatAttempt(
      attemptId: attemptId,
      token: try XCTUnwrap(reservation.heartbeatToken),
      context: context
    )
    XCTAssertFalse(heartbeat.fenced)
    XCTAssertGreaterThan(try XCTUnwrap(heartbeat.expiresAt), try XCTUnwrap(reservation.expiresAt))
  }

  func testReportCompletedAttemptAcceptsLeaseCredentialAndReconcilesTask() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let predecessorId = AttemptID("attempt-report-completed-predecessor")
    try savePredecessor(task: task, attemptId: predecessorId, store: harness.store)
    let packet = try savePresencePacket(task: task, fromAttemptId: predecessorId, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)
    let reservation = try await provider.takeoverTask(
      GraphQLTakeoverTaskInput(
        taskId: task.id.rawValue, handoverId: packet.id.rawValue,
        hostId: "worker-completed", traits: ["userReachable"]
      ),
      context: context
    )
    let attemptId = try XCTUnwrap(reservation.attemptId)
    let now = Date()
    let session = WorkflowSession(
      workflowId: "task-repair-loop", sessionId: try XCTUnwrap(reservation.sessionId),
      status: .completed, entryStepId: "repair", currentStepId: nil,
      createdAt: now, updatedAt: now
    )

    let report = try await provider.reportAttempt(
      GraphQLReportAttemptInput(
        attemptId: attemptId,
        token: try XCTUnwrap(reservation.heartbeatToken),
        snapshot: snapshotObject(WorkflowRuntimePersistenceSnapshot(session: session)),
        deliverables: []
      ),
      context: context
    )
    XCTAssertEqual(report.taskState, TaskState.succeeded.rawValue)
    XCTAssertEqual(report.decisionKind, "accept")

    let taskAfterFirstReport = try XCTUnwrap(harness.store.loadTask(id: task.id))
    let decisionCountAfterFirstReport = try harness.store.listDecisions(taskId: task.id).count
    do {
      _ = try await provider.reportAttempt(
        GraphQLReportAttemptInput(
          attemptId: attemptId,
          token: try XCTUnwrap(reservation.heartbeatToken),
          snapshot: snapshotObject(WorkflowRuntimePersistenceSnapshot(session: session)),
          deliverables: []
        ),
        context: context
      )
      XCTFail("replaying a reconciled report should be unauthorized")
    } catch let error as TaskHandoverGraphQLError {
      XCTAssertEqual(error.code, "unauthorized")
    }
    XCTAssertEqual(try harness.store.loadTask(id: task.id), taskAfterFirstReport)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).count, decisionCountAfterFirstReport)
  }

  func testConcurrentReportsWithSameCredentialReconcileExactlyOnce() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let predecessorId = AttemptID("attempt-report-concurrent-predecessor")
    try savePredecessor(task: task, attemptId: predecessorId, store: harness.store)
    let packet = try savePresencePacket(task: task, fromAttemptId: predecessorId, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)
    let reservation = try await provider.takeoverTask(
      GraphQLTakeoverTaskInput(
        taskId: task.id.rawValue, handoverId: packet.id.rawValue,
        hostId: "worker-concurrent", traits: ["userReachable"]
      ),
      context: context
    )
    let attemptId = try XCTUnwrap(reservation.attemptId)
    let token = try XCTUnwrap(reservation.heartbeatToken)
    let now = Date()
    let session = WorkflowSession(
      workflowId: "task-repair-loop", sessionId: try XCTUnwrap(reservation.sessionId),
      status: .completed, entryStepId: "repair", currentStepId: nil,
      createdAt: now, updatedAt: now
    )
    let snapshot = try snapshotObject(WorkflowRuntimePersistenceSnapshot(session: session))
    let taskBeforeReports = try XCTUnwrap(harness.store.loadTask(id: task.id))

    let outcomes = try await withThrowingTaskGroup(of: ConcurrentReportOutcome.self) { group in
      for _ in 0..<2 {
        group.addTask {
          do {
            let report = try await provider.reportAttempt(
              GraphQLReportAttemptInput(
                attemptId: attemptId, token: token, snapshot: snapshot, deliverables: []
              ),
              context: context
            )
            return .success(taskState: report.taskState, decisionKind: report.decisionKind)
          } catch let error as TaskHandoverGraphQLError where error.code == "unauthorized" {
            return .unauthorized
          }
        }
      }
      var collected: [ConcurrentReportOutcome] = []
      for try await outcome in group { collected.append(outcome) }
      return collected
    }

    let successes = outcomes.compactMap { outcome -> (String?, String?)? in
      guard case let .success(taskState, decisionKind) = outcome else { return nil }
      return (taskState, decisionKind)
    }
    XCTAssertEqual(successes.count, 1)
    XCTAssertEqual(successes.first?.0, TaskState.succeeded.rawValue)
    XCTAssertEqual(successes.first?.1, "accept")
    XCTAssertEqual(outcomes.filter { $0 == .unauthorized }.count, 1)

    let decisions = try harness.store.listDecisions(taskId: task.id)
    XCTAssertEqual(decisions.filter { $0.attemptId == AttemptID(attemptId) && $0.kind.kindName == "accept" }.count, 1)
    let taskAfterReports = try XCTUnwrap(harness.store.loadTask(id: task.id))
    XCTAssertEqual(taskAfterReports.state, .succeeded)
    // One terminal reconciliation moves running to verifying; its single accept moves to succeeded.
    XCTAssertEqual(taskAfterReports.version, taskBeforeReports.version + 2)
  }

  func testReportSuspendedAttemptAcceptsLeaseCredentialAndSealsHandover() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop", state: .waiting)
    let predecessorId = AttemptID("attempt-report-suspended-predecessor")
    try savePredecessor(task: task, attemptId: predecessorId, store: harness.store)
    let packet = try savePresencePacket(task: task, fromAttemptId: predecessorId, store: harness.store)
    let provider = provider(harness)
    let context = context(harness)
    let reservation = try await provider.takeoverTask(
      GraphQLTakeoverTaskInput(
        taskId: task.id.rawValue, handoverId: packet.id.rawValue,
        hostId: "worker-suspended", traits: ["userReachable"]
      ),
      context: context
    )
    let attemptId = try XCTUnwrap(reservation.attemptId)
    let now = Date()
    let session = WorkflowSession(
      workflowId: "task-repair-loop", sessionId: try XCTUnwrap(reservation.sessionId),
      status: .suspended, entryStepId: "repair", currentStepId: "repair",
      createdAt: now, updatedAt: now,
      suspend: SuspendRecord(
        reasonKind: .operatorMove, stepId: "repair", progressNote: "Continue elsewhere",
        suspendedAt: now, producer: .runtime
      )
    )

    let report = try await provider.reportAttempt(
      GraphQLReportAttemptInput(
        attemptId: attemptId,
        token: try XCTUnwrap(reservation.heartbeatToken),
        snapshot: snapshotObject(WorkflowRuntimePersistenceSnapshot(session: session)),
        deliverables: []
      ),
      context: context
    )
    XCTAssertNotNil(report.handoverId)
    XCTAssertNotEqual(report.handoverId, packet.id.rawValue)
  }

  func testServeRequiresManagerBearerForTaskHandoverFields() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wh16-serve-\(UUID().uuidString)")
    let home = root.appendingPathComponent("home")
    let project = root.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let host = ServeWebHost(
      homeDirectory: home,
      workingDirectory: project,
      sessionStoreRoot: nil,
      host: "127.0.0.1",
      port: 8787,
      fallback: DeterministicServerHTTPAdapter(),
      environment: ["HOME": home.path, "RIELA_MANAGER_AUTH_TOKEN": "manager-secret"]
    )
    let bootstrapResponse = await host.response(for: request("/api/v1/bootstrap"))
    let bootstrap = try XCTUnwrap(try JSONSerialization.jsonObject(with: bootstrapResponse.body) as? [String: Any])
    let csrf = try XCTUnwrap(bootstrap["csrfToken"] as? String)
    let query = #"{"query":"query { taskHandover(taskId: \"missing\") { handover { taskId } errors { code } } }"}"#
    var unauthorized = graphqlRequest(body: Data(query.utf8), csrf: csrf)
    let rejected = await host.response(for: unauthorized)
    XCTAssertTrue((String(data: rejected.body, encoding: .utf8) ?? "").contains("UNAUTHENTICATED"))

    unauthorized.headers["authorization"] = "Bearer manager-secret"
    let authorized = await host.response(for: unauthorized)
    let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: authorized.body) as? [String: Any])
    XCTAssertFalse((String(data: authorized.body, encoding: .utf8) ?? "").contains("UNAUTHENTICATED"))
    XCTAssertNotNil((json["data"] as? [String: Any])?["taskHandover"])
  }

  private func provider(_ harness: TaskExampleHarness) -> TaskHandoverGraphQLProvider {
    TaskHandoverGraphQLProvider(
      workingDirectory: harness.repository.path,
      sessionStore: harness.sessionStore.path,
      scope: .project
    )
  }

  private func snapshotObject(_ snapshot: WorkflowRuntimePersistenceSnapshot) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: JSONCanonical.encode(snapshot))
  }

  private func context(_ harness: TaskExampleHarness) -> GraphQLDocumentRequest {
    GraphQLDocumentRequest(
      query: "{ taskHandover(taskId: \"task-task-repair-loop\") { handover { taskId } } }",
      isLocallyTrusted: true,
      localWorkingDirectory: harness.repository.path
    )
  }

  private func savePresencePacket(
    task: WorkTask,
    fromAttemptId: AttemptID? = nil,
    store: WorkStore
  ) throws -> HandoverPacket {
    let packet = try makePacket(task: task, reason: .userPresenceRequired(
      PresenceRequirement(traits: [.userReachable], instructions: "Use a reachable host")
    ), fromAttemptId: fromAttemptId)
    try store.saveHandover(packet)
    return packet
  }

  private func saveQuestionPacket(task: WorkTask, store: WorkStore) throws -> HandoverPacket {
    let packet = try makePacket(task: task, reason: .userInputRequired(
      HandoverQuestion(id: "approval", text: "Approve the repair?", answerSchema: ["type": .string("object")])
    ))
    try store.saveHandover(packet)
    return packet
  }

  private func savePredecessor(task: WorkTask, attemptId: AttemptID, store: WorkStore) throws {
    let now = Date()
    try store.saveAttempt(Attempt(
      id: attemptId,
      taskId: task.id,
      generation: 1,
      sessionId: "session-predecessor",
      state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed, failureKind: .stalled)
    ))
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory).save(
      WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
        workflowId: "task-repair-loop",
        sessionId: "session-predecessor",
        status: .failed,
        entryStepId: "start",
        currentStepId: "repair",
        createdAt: now,
        updatedAt: now,
        failureKind: WorkflowSessionFailureKind(rawValue: "stalled"),
        failedAt: now
      ))
    )
  }

  private func makePacket(
    task: WorkTask,
    reason: HandoverReason,
    fromAttemptId: AttemptID? = nil
  ) throws -> HandoverPacket {
    try HandoverPacket(
      id: HandoverID(rawValue: "handover-\(UUID().uuidString.lowercased())"),
      taskId: task.id,
      intentId: task.intentId,
      fromAttemptId: fromAttemptId ?? AttemptID(rawValue: "attempt-predecessor-\(UUID().uuidString.lowercased())"),
      fromSessionId: "session-predecessor",
      generation: 1,
      reason: reason,
      workflow: HandoverWorkflowRef(workflowId: "task-repair-loop", entryStepId: "start", resumeStepId: "repair"),
      progress: HandoverProgress(
        acceptedSteps: [], remainingSteps: ["repair"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0)
      ),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(
        resumeStepId: "repair", completion: task.completion, verification: [], guardPolicy: task.guardPolicy
      ),
      brief: "Continue the repair",
      producedBy: .runtime,
      producedOn: "test",
      createdAt: Date()
    ).sealed()
  }

  private func request(_ path: String) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "GET", path: path, headers: ["host": "127.0.0.1:8787"])
  }

  private func graphqlRequest(body: Data, csrf: String) -> RielaHTTPRequest {
    RielaHTTPRequest(
      method: "POST",
      path: "/graphql",
      headers: [
        "host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
        "content-type": "application/json", "x-riela-csrf": csrf, "x-riela-profile": "default"
      ],
      body: body
    )
  }
}
