import RielaCore
import XCTest
@testable import RielaGraphQL

final class SessionObservabilityGraphQLTests: XCTestCase {
  func testGraphQLProgressEqualsSharedServiceProjection() async throws {
    let date = Date(timeIntervalSince1970: 1_000)
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let parent = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "workflow",
      sessionId: "parent",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      effectiveStepBudget: 8
    ))
    let child = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "child-workflow",
      sessionId: "child",
      status: .completed,
      entryStepId: "child-step",
      createdAt: date.addingTimeInterval(1),
      updatedAt: date.addingTimeInterval(1),
      parentSessionId: "parent",
      rootSessionId: "parent",
      effectiveStepBudget: 4
    ))
    let snapshots = [parent, child]
    let service = SessionObservabilityService(
      loadSnapshot: { _ in parent },
      loadRollupSnapshots: { _ in snapshots },
      clock: FixedWorkflowRuntimeClock(observedAt)
    )
    let graphQL = GraphQLRuntimeSnapshotQueryService(
      loadSnapshot: { _ in parent },
      loadSnapshots: { snapshots },
      observabilityService: service
    )

    let result = await graphQL.sessionProgress(GraphQLSessionProgressRequest(
      sessionId: "parent",
      includeChildren: true
    ))

    XCTAssertTrue(result.result.accepted)
    XCTAssertEqual(result.view?.root.digest.sessionId, "parent")
    XCTAssertEqual(result.view?.root.digest.observedAt, observedAt)
    XCTAssertEqual(result.view?.root.digest.currentStepId, "step")
    XCTAssertEqual(result.view?.root.digest.executionCount, 0)
    XCTAssertEqual(result.view?.root.digest.effectiveStepBudget, 8)
    XCTAssertEqual(result.view?.root.children.map(\.digest.sessionId), ["child"])
    XCTAssertEqual(result.view?.root.children.first?.digest.parentSessionId, "parent")
    XCTAssertEqual(result.view?.rollupTruncated, false)

    let encoded = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(GraphQLSessionObservabilityResult.self, from: encoded)
    XCTAssertEqual(decoded, result)
  }

  func testGraphQLHealthWithoutProbeRegistrationReturnsUnknown() async {
    let date = Date(timeIntervalSince1970: 1_000)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .cursorCliAgent,
      createdAt: date,
      updatedAt: date
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "workflow",
      sessionId: "session",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      executions: [execution]
    ))
    let graphQL = GraphQLRuntimeSnapshotQueryService(
      loadSnapshot: { _ in snapshot },
      loadSnapshots: { [snapshot] }
    )

    let result = await graphQL.sessionHealth(GraphQLSessionHealthRequest(sessionId: "session"))

    XCTAssertTrue(result.result.accepted)
    XCTAssertEqual(result.view?.backendActivity?.verdict, .unknown)
  }

  func testGraphQLHealthPreservesSharedProbeEvidenceAndThresholds() async {
    let date = Date(timeIntervalSince1970: 1_000)
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .codexAgent,
      status: .running,
      createdAt: date,
      updatedAt: date
    )
    let snapshot = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "workflow",
      sessionId: "session",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      executions: [execution]
    ))
    let service = SessionObservabilityService(
      loadSnapshot: { _ in snapshot },
      loadRollupSnapshots: { _ in [snapshot] },
      clock: FixedWorkflowRuntimeClock(observedAt),
      probes: SessionBackendActivityProbeRegistry([FixedGraphQLActivityProbe()])
    )
    let graphQL = GraphQLRuntimeSnapshotQueryService(
      loadSnapshot: { _ in snapshot },
      loadSnapshots: { [snapshot] },
      observabilityService: service
    )

    let result = await graphQL.sessionHealth(GraphQLSessionHealthRequest(sessionId: "session"))

    XCTAssertTrue(result.result.accepted)
    XCTAssertEqual(result.view?.backendActivity?.verdict, .active)
    XCTAssertEqual(result.view?.backendActivity?.activeThresholdMs, 30_000)
    XCTAssertEqual(result.view?.backendActivity?.stalledThresholdMs, 180_000)
    XCTAssertEqual(result.view?.backendActivity?.ageMs, 1_000)
    XCTAssertEqual(result.view?.backendActivity?.evidence.map(\.kind), [.artifact])
    XCTAssertEqual(result.view?.backendActivity?.evidence.first?.path, "/fixture/codex-rollout.jsonl")
  }
}

private struct FixedGraphQLActivityProbe: SessionBackendActivityProbing {
  let backend = NodeExecutionBackend.codexAgent

  func assess(_ input: SessionBackendActivityProbeInput) throws -> SessionBackendActivity {
    let activityAt = input.observedAt.addingTimeInterval(-1)
    return SessionBackendActivity(
      backend: input.backend,
      verdict: .active,
      evidence: [
        SessionBackendActivityEvidence(
          kind: .artifact,
          detail: "fixture activity",
          path: "/fixture/codex-rollout.jsonl",
          observedAt: activityAt,
          ageMs: 1_000
        )
      ],
      activeThresholdMs: input.activeThresholdMs,
      stalledThresholdMs: input.stalledThresholdMs,
      lastActivityAt: activityAt,
      ageMs: 1_000,
      observedAt: input.observedAt
    )
  }
}
