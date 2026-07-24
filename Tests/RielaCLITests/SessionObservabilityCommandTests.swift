import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class SessionObservabilityCommandTests: XCTestCase {
  func testProductionCompositionRegistersBothAcceptedBackendProbes() {
    XCTAssertEqual(
      SessionObservabilityComposition.makeProbeRegistry().registeredBackends,
      Set([.codexAgent, .claudeCodeAgent])
    )
  }

  func testFollowEmitsAlreadyTerminalSessionOnceWithoutSleeping() async throws {
    let fixture = try makeFixture(status: .completed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let observedAt = Date(timeIntervalSince1970: 2_000)
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(observedAt),
      sleeper: UnexpectedSessionFollowSleeper()
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--follow", "--output", "jsonl"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let lines = result.stdout.split(whereSeparator: \.isNewline)
    XCTAssertEqual(lines.count, 1)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let view = try decoder.decode(SessionObservabilityView.self, from: Data(lines[0].utf8))
    XCTAssertEqual(view.root.digest.status, .completed)
    XCTAssertNil(view.root.digest.previousStatus)
  }

  func testFollowFailsInsteadOfClaimingTerminalWhenChildRollupIsTruncated() async throws {
    let fixture = try makeFixture(status: .completed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let parent = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "parent-workflow",
      sessionId: fixture.sessionId,
      status: .completed,
      entryStepId: "parent-step",
      createdAt: createdAt,
      updatedAt: createdAt,
      rootSessionId: fixture.sessionId
    ))
    let visibleChild = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "visible-child-workflow",
      sessionId: "visible-child",
      status: .completed,
      entryStepId: "visible-step",
      createdAt: createdAt,
      updatedAt: createdAt,
      parentSessionId: fixture.sessionId,
      rootSessionId: fixture.sessionId
    ))
    let omittedRunningChild = WorkflowRuntimePersistenceSnapshot(session: WorkflowSession(
      workflowId: "omitted-child-workflow",
      sessionId: "omitted-running-child",
      status: .running,
      entryStepId: "omitted-step",
      createdAt: createdAt,
      updatedAt: createdAt,
      parentSessionId: fixture.sessionId,
      rootSessionId: fixture.sessionId
    ))
    let allSnapshots = [parent, visibleChild, omittedRunningChild]
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000)),
      sleeper: UnexpectedSessionFollowSleeper(),
      followRecordWriter: nil,
      observabilityServiceFactory: { _, clock in
        SessionObservabilityService(
          loadSnapshot: { _ in parent },
          loadRollupSnapshotPage: { _ in
            SessionRollupSnapshotPage(
              snapshots: Array(allSnapshots.prefix(2)),
              truncated: true,
              limit: 2
            )
          },
          clock: clock
        )
      }
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--include-children", "--follow", "--output", "jsonl"
    ])

    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("cannot confirm terminal state"))
    let views = try result.stdout.split(whereSeparator: \.isNewline).map {
      try decode(SessionObservabilityView.self, from: String($0))
    }
    XCTAssertEqual(views.count, 1)
    XCTAssertEqual(views[0].rollupTruncated, true)
    XCTAssertTrue(SessionObservabilityService.isTerminal(views[0].root))
    XCTAssertEqual(allSnapshots.last?.session.status, .running)
  }

  func testFollowFlagsAreRejectedOutsideProgressAndJSONIsRejectedForFollow() async {
    let app = RielaCLIApplication()
    let health = await app.run(["session", "health", "session", "--follow"])
    XCTAssertEqual(health.exitCode, .usage)
    XCTAssertTrue(health.stderr.contains("valid only for session progress"))

    let json = await app.run(["session", "progress", "session", "--follow", "--output", "json"])
    XCTAssertEqual(json.exitCode, .usage)
    XCTAssertTrue(json.stderr.contains("use --output jsonl"))
  }

  func testSidecarFreeObserversUseImmutableFallbackWithoutMutation() async throws {
    let fixture = try makeFixture(status: .completed)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let databasePath = CLIWorkflowSessionStore.defaultDatabasePath(
      rootDirectory: fixture.sessionStore.path
    )
    let checkpoint = runSQLite(databasePath, "PRAGMA wal_checkpoint(TRUNCATE);")
    XCTAssertEqual(checkpoint.exitCode, 0, checkpoint.stderr)
    removeSQLiteSidecars(for: databasePath)
    let before = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date
    )
    let bytesBefore = try Data(contentsOf: URL(fileURLWithPath: databasePath))

    let progress = await RielaCLIApplication().run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--output", "json"
    ])
    let health = await RielaCLIApplication().run([
      "session", "health", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--output", "json"
    ])
    let follow = await RielaCLIApplication().run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--follow", "--output", "jsonl"
    ])

    XCTAssertEqual(progress.exitCode, .success, progress.stderr + progress.stdout)
    XCTAssertEqual(health.exitCode, .success, health.stderr + health.stdout)
    XCTAssertEqual(follow.exitCode, .success, follow.stderr + follow.stdout)
    XCTAssertEqual(follow.stdout.split(whereSeparator: \.isNewline).count, 1)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: databasePath)), bytesBefore)
    XCTAssertEqual(
      try XCTUnwrap(FileManager.default.attributesOfItem(atPath: databasePath)[.modificationDate] as? Date),
      before
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-shm"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: databasePath + "-wal"))
  }

  func testFollowEmitsStatusTransitionAndUsesConfiguredCadence() async throws {
    let fixture = try makeFixture(status: .running)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let date = Date(timeIntervalSince1970: 1_000)
    let completed = WorkflowSession(
      workflowId: "workflow",
      sessionId: fixture.sessionId,
      status: .completed,
      entryStepId: "step",
      createdAt: date,
      updatedAt: date,
      effectiveStepBudget: 4
    )
    let sleeper = CompletingSessionFollowSleeper(
      store: SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.sessionStore.path)
      ),
      snapshot: WorkflowRuntimePersistenceSnapshot(session: completed)
    )
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000)),
      sleeper: sleeper
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--follow", "--poll-interval", "0.25", "--output", "jsonl"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let views = try result.stdout.split(whereSeparator: \.isNewline).map {
      try decoder.decode(SessionObservabilityView.self, from: Data($0.utf8))
    }
    XCTAssertEqual(views.map(\.root.digest.status), [.running, .completed])
    XCTAssertNil(views[0].root.digest.previousStatus)
    XCTAssertEqual(views[1].root.digest.previousStatus, .running)
    let recordedIntervals = await sleeper.recordedIntervals()
    XCTAssertEqual(recordedIntervals, [0.25])
  }

  func testFollowUsesDocumentedDefaultCadence() async throws {
    let fixture = try makeFixture(status: .running)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let date = Date(timeIntervalSince1970: 1_000)
    let completed = WorkflowSession(
      workflowId: "workflow",
      sessionId: fixture.sessionId,
      status: .completed,
      entryStepId: "step",
      createdAt: date,
      updatedAt: date,
      effectiveStepBudget: 4
    )
    let sleeper = CompletingSessionFollowSleeper(
      store: SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.sessionStore.path)
      ),
      snapshot: WorkflowRuntimePersistenceSnapshot(session: completed)
    )
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000)),
      sleeper: sleeper
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--follow", "--output", "jsonl"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
        let recordedIntervals = await sleeper.recordedIntervals()
        XCTAssertEqual(recordedIntervals, [2.0])
  }

  func testFollowRejectsNonFiniteAndOutOfRangePollIntervals() async {
    let app = RielaCLIApplication()
    for value in ["nan", "0.09", "3600.1"] {
      let result = await app.run([
        "session", "progress", "session",
        "--follow", "--poll-interval", value
      ])
      XCTAssertEqual(result.exitCode, .usage, value)
      XCTAssertTrue(result.stderr.contains("between 0.1 and 3600"), result.stderr)
    }
  }

  func testOneShotIncludeChildrenRendersEveryAcceptedDigestFieldInTextAndJSON() async throws {
    let fixture = try makeRollupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000))
    ))
    let arguments = [
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--include-children"
    ]

    let text = await app.run(arguments + ["--output", "text"])

    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.contains("sessionId: parent-session"))
    XCTAssertTrue(text.stdout.contains("currentStepId: translate-step"))
    XCTAssertTrue(text.stdout.contains("currentStage: Translation in progress"))
    XCTAssertTrue(text.stdout.contains("executions: 2/7"))
    XCTAssertTrue(text.stdout.contains("gateVisits: implementation-review=3"))
    XCTAssertTrue(text.stdout.contains("lastBackendEventType: assistant"))
    XCTAssertTrue(text.stdout.contains("lastBackendEventAgeMs: 5000"))
    XCTAssertTrue(text.stdout.contains("rollupTruncated: false"))
    XCTAssertTrue(text.stdout.contains("rollupSnapshotLimit: 1000"))
    XCTAssertTrue(text.stdout.contains("child:\n  sessionId: child-session"))

    let json = await app.run(arguments + ["--output", "json"])
    let result = try decode(SessionInspectionCommandResult.self, from: json.stdout)
    let rollup = try XCTUnwrap(result.rollup)
    XCTAssertEqual(rollup.digest.currentStepId, "translate-step")
    XCTAssertEqual(rollup.digest.currentStage, "Translation in progress")
    XCTAssertEqual(rollup.digest.executionCount, 2)
    XCTAssertEqual(rollup.digest.effectiveStepBudget, 7)
    XCTAssertEqual(rollup.digest.gateVisitCounts, ["implementation-review": 3])
    XCTAssertEqual(rollup.digest.lastBackendEventType, "assistant")
    XCTAssertEqual(rollup.digest.lastBackendEventAgeMs, 5_000)
    XCTAssertEqual(rollup.children.map(\.digest.sessionId), ["child-session"])
    XCTAssertEqual(result.progress?.sessionId, "parent-session")
  }

  func testOneShotProgressUsesOneCoherentSnapshotWhenWriterAdvancesDuringRead() async throws {
    let fixture = try makeFixture(status: .running)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let runningSnapshot = try XCTUnwrap(fixture.snapshots.first)
    let completedSnapshot: WorkflowRuntimePersistenceSnapshot = {
      var snapshot = runningSnapshot
      snapshot.session.status = .completed
      snapshot.session.currentStepId = nil
      return snapshot
    }()
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000)),
      sleeper: UnexpectedSessionFollowSleeper(),
      followRecordWriter: nil,
      observabilityServiceFactory: { store, clock in
        SessionObservabilityService(
          loadSnapshot: { _ in
            try store.save(completedSnapshot)
            return runningSnapshot
          },
          loadRollupSnapshots: { _ in [runningSnapshot] },
          clock: clock
        )
      }
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let decoded = try decode(SessionInspectionCommandResult.self, from: result.stdout)
    XCTAssertEqual(decoded.status, .running)
    XCTAssertEqual(decoded.progress?.status, .running)
    let persisted = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.sessionStore.path)
    ).load(sessionId: fixture.sessionId)
    XCTAssertEqual(persisted.session.status, .completed)
  }

  func testTextFollowWritesEachParentChildRefreshBeforeSleepingAndStopsWhenTreeIsTerminal() async throws {
    let fixture = try makeRollupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let records = LockedSessionFollowRecords()
    let completedSnapshots = fixture.snapshots.map { snapshot -> WorkflowRuntimePersistenceSnapshot in
      var completed = snapshot
      completed.session.status = .completed
      completed.session.currentStepId = nil
      completed.session.executions = completed.session.executions.map { execution in
        var completedExecution = execution
        completedExecution.status = .completed
        return completedExecution
      }
      return completed
    }
    let sleeper = CompletingRollupSessionFollowSleeper(
      store: SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: fixture.sessionStore.path)
      ),
      completedSnapshots: completedSnapshots,
      records: records
    )
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000)),
      sleeper: sleeper,
      followRecordWriter: { records.append($0) }
    ))

    let result = await app.run([
      "session", "progress", fixture.sessionId,
      "--session-store", fixture.sessionStore.path,
      "--include-children", "--follow", "--poll-interval", "0.25",
      "--output", "text"
    ])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(result.stdout, "", "production writer mode must not buffer duplicate output")
    let emitted = records.values()
    XCTAssertEqual(emitted.count, 2)
    XCTAssertTrue(emitted[0].contains("status: running"))
    XCTAssertTrue(emitted[0].contains("child:\n  sessionId: child-session"))
    XCTAssertTrue(emitted[1].contains("status: completed"))
    XCTAssertTrue(emitted[1].contains("previousStatus: running"))
    let recordedIntervals = await sleeper.recordedIntervals()
    XCTAssertEqual(recordedIntervals, [0.25])
  }

  func testHealthRendersUnknownEvidenceAndThresholdsInTextAndJSON() async throws {
    let fixture = try makeHealthFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication(sessionInspectionCommand: SessionInspectionCommand(
      clock: FixedWorkflowRuntimeClock(Date(timeIntervalSince1970: 2_000))
    ))
    let arguments = [
      "session", "health", fixture.sessionId,
      "--session-store", fixture.sessionStore.path
    ]

    let text = await app.run(arguments + ["--output", "text"])
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.contains("backendActivity: unknown"))
    XCTAssertTrue(text.stdout.contains("backendActivityThresholdsMs: active=30000 stalled=180000"))
    XCTAssertTrue(text.stdout.contains("backendActivityEvidence: diagnostic"))

    let json = await app.run(arguments + ["--output", "json"])
    let result = try decode(SessionInspectionCommandResult.self, from: json.stdout)
    let activity = try XCTUnwrap(result.backendActivity)
    XCTAssertEqual(activity.verdict, .unknown)
    XCTAssertEqual(activity.activeThresholdMs, 30_000)
    XCTAssertEqual(activity.stalledThresholdMs, 180_000)
    XCTAssertEqual(activity.evidence.map(\.kind), [.diagnostic])
  }

  func testProductionCLIAndScopedGraphQLProgressAndHealthPreserveParity() async throws {
    let fixture = try makeRollupFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let app = RielaCLIApplication()
    let storeArguments = ["--session-store", fixture.sessionStore.path]

    let cliProgress = await app.run(
      ["session", "progress", fixture.sessionId, "--include-children"] + storeArguments + ["--output", "json"]
    )
    let graphQLProgress = await app.run(
      ["graphql", "session-progress", fixture.sessionId, "--include-children"]
        + storeArguments + ["--output", "json"]
    )
    XCTAssertEqual(cliProgress.exitCode, .success, cliProgress.stderr + cliProgress.stdout)
    XCTAssertEqual(
      graphQLProgress.exitCode,
      .success,
      graphQLProgress.stderr + graphQLProgress.stdout
    )
    let cliProgressResult = try decode(SessionInspectionCommandResult.self, from: cliProgress.stdout)
    let graphQLProgressView = try decodeScopedObservabilityView(graphQLProgress.stdout)
    let cliRoot = try XCTUnwrap(cliProgressResult.rollup)
    let graphQLRoot = try XCTUnwrap(graphQLProgressView?.root)
    XCTAssertEqual(graphQLRoot.digest.sessionId, cliRoot.digest.sessionId)
    XCTAssertEqual(graphQLRoot.digest.currentStepId, cliRoot.digest.currentStepId)
    XCTAssertEqual(graphQLRoot.digest.executionCount, cliRoot.digest.executionCount)
    XCTAssertEqual(graphQLRoot.digest.effectiveStepBudget, cliRoot.digest.effectiveStepBudget)
    XCTAssertEqual(graphQLRoot.digest.gateVisitCounts, cliRoot.digest.gateVisitCounts)
    XCTAssertEqual(graphQLRoot.children.map(\.digest.sessionId), cliRoot.children.map(\.digest.sessionId))

    let cliHealth = await app.run(
      ["session", "health", fixture.sessionId] + storeArguments + ["--output", "json"]
    )
    let graphQLHealth = await app.run(
      ["graphql", "session-health", fixture.sessionId] + storeArguments + ["--output", "json"]
    )
    XCTAssertEqual(cliHealth.exitCode, .success, cliHealth.stderr + cliHealth.stdout)
    XCTAssertEqual(graphQLHealth.exitCode, .success, graphQLHealth.stderr + graphQLHealth.stdout)
    let cliHealthResult = try decode(SessionInspectionCommandResult.self, from: cliHealth.stdout)
    let graphQLHealthView = try decodeScopedObservabilityView(graphQLHealth.stdout)
    XCTAssertEqual(graphQLHealthView?.backendActivity?.verdict, cliHealthResult.backendActivity?.verdict)
    XCTAssertEqual(
      graphQLHealthView?.backendActivity?.activeThresholdMs,
      cliHealthResult.backendActivity?.activeThresholdMs
    )
    XCTAssertEqual(
      graphQLHealthView?.backendActivity?.stalledThresholdMs,
      cliHealthResult.backendActivity?.stalledThresholdMs
    )
    XCTAssertEqual(
      graphQLHealthView?.backendActivity?.evidence.map(\.kind),
      cliHealthResult.backendActivity?.evidence.map(\.kind)
    )
  }

  private func makeFixture(status: WorkflowSessionStatus) throws -> SessionObservabilityCommandFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    let sessionStore = root.appendingPathComponent("sessions")
    let sessionId = "terminal-session"
    let date = Date(timeIntervalSince1970: 1_000)
    let session = WorkflowSession(
      workflowId: "workflow",
      sessionId: sessionId,
      status: status,
      entryStepId: "step",
      createdAt: date,
      updatedAt: date,
      effectiveStepBudget: 4
    )
    let resolution = WorkflowResolutionOptions(workflowName: "workflow", workingDirectory: root.path)
    try CLIWorkflowSessionStore(rootDirectory: sessionStore.path).save(
      PersistedCLIWorkflowSession(workflowName: "workflow", session: session, resolution: resolution),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session)
    )
    return SessionObservabilityCommandFixture(
      root: root,
      sessionStore: sessionStore,
      sessionId: sessionId,
      snapshots: [WorkflowRuntimePersistenceSnapshot(session: session)]
    )
  }

  private func makeRollupFixture() throws -> SessionObservabilityCommandFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    let sessionStore = root.appendingPathComponent("sessions")
    let createdAt = Date(timeIntervalSince1970: 1_000)
    let eventAt = Date(timeIntervalSince1970: 1_995)
    let executions = [
      WorkflowStepExecution(
        executionId: "exec-1",
        stepId: "prepare",
        nodeId: "prepare-node",
        attempt: 1,
        backend: .codexAgent,
        status: .completed,
        createdAt: createdAt,
        updatedAt: createdAt
      ),
      WorkflowStepExecution(
        executionId: "exec-2",
        stepId: "translate-step",
        nodeId: "translate-node",
        attempt: 1,
        backend: .cursorCliAgent,
        status: .running,
        lastBackendEventAt: eventAt,
        lastBackendEventType: "assistant",
        createdAt: createdAt,
        updatedAt: eventAt
      )
    ]
    let parent = WorkflowSession(
      workflowId: "parent-workflow",
      sessionId: "parent-session",
      status: .running,
      entryStepId: "prepare",
      currentStepId: "translate-step",
      createdAt: createdAt,
      updatedAt: eventAt,
      executions: executions,
      stepBudgetDiagnostic: WorkflowStepBudgetDiagnostic(
        stepBudget: 7,
        executionCount: 2,
        maxLoopIterations: 3,
        budgetSource: .computedDefault
      ),
      rootSessionId: "parent-session",
      effectiveStepBudget: 12
    )
    let child = WorkflowSession(
      workflowId: "child-workflow",
      sessionId: "child-session",
      status: .running,
      entryStepId: "child-step",
      currentStepId: "child-step",
      createdAt: createdAt.addingTimeInterval(1),
      updatedAt: eventAt,
      parentSessionId: "parent-session",
      rootSessionId: "parent-session",
      effectiveStepBudget: 4
    )
    let snapshots = [
      WorkflowRuntimePersistenceSnapshot(
        session: parent,
        loopEvidence: loopEvidence(sessionId: parent.sessionId, date: createdAt)
      ),
      WorkflowRuntimePersistenceSnapshot(session: child)
    ]
    try save(snapshots: snapshots, root: root, sessionStore: sessionStore)
    return SessionObservabilityCommandFixture(
      root: root,
      sessionStore: sessionStore,
      sessionId: parent.sessionId,
      snapshots: snapshots
    )
  }

  private func makeHealthFixture() throws -> SessionObservabilityCommandFixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/session-observability-tests/\(UUID().uuidString)")
    let sessionStore = root.appendingPathComponent("sessions")
    let date = Date(timeIntervalSince1970: 1_000)
    let execution = WorkflowStepExecution(
      executionId: "exec",
      stepId: "step",
      nodeId: "node",
      attempt: 1,
      backend: .cursorCliAgent,
      status: .running,
      createdAt: date,
      updatedAt: date
    )
    let session = WorkflowSession(
      workflowId: "health-workflow",
      sessionId: "health-session",
      status: .running,
      entryStepId: "step",
      currentStepId: "step",
      createdAt: date,
      updatedAt: date,
      executions: [execution]
    )
    let snapshots = [WorkflowRuntimePersistenceSnapshot(session: session)]
    try save(snapshots: snapshots, root: root, sessionStore: sessionStore)
    return SessionObservabilityCommandFixture(
      root: root,
      sessionStore: sessionStore,
      sessionId: session.sessionId,
      snapshots: snapshots
    )
  }

  private func save(
    snapshots: [WorkflowRuntimePersistenceSnapshot],
    root: URL,
    sessionStore: URL
  ) throws {
    let store = CLIWorkflowSessionStore(rootDirectory: sessionStore.path)
    for snapshot in snapshots {
      let workflowName = snapshot.session.workflowId
      let resolution = WorkflowResolutionOptions(workflowName: workflowName, workingDirectory: root.path)
      try store.save(
        PersistedCLIWorkflowSession(
          workflowName: workflowName,
          session: snapshot.session,
          resolution: resolution
        ),
        runtimeSnapshot: snapshot
      )
    }
  }

  private func loopEvidence(sessionId: String, date: Date) -> LoopEvidenceManifest {
    LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-\(sessionId)",
      workflowId: "parent-workflow",
      sessionId: sessionId,
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      convergence: LoopConvergenceEvidence(gateVisitCounts: ["implementation-review": 3]),
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }

  private func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(text.utf8))
  }

  private func decodeScopedObservabilityView(_ text: String) throws -> SessionObservabilityView? {
    let scoped = try decode(ScopedParityCommandResult.self, from: text)
    let record = try XCTUnwrap(scoped.records.first)
    return try decode(ScopedSessionObservabilityEnvelope.self, from: record).view
  }

  private func runSQLite(_ databasePath: String, _ sql: String) -> SQLiteCommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = [databasePath, sql]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return SQLiteCommandResult(exitCode: 1, stderr: String(describing: error))
    }
    return SQLiteCommandResult(
      exitCode: process.terminationStatus,
      stderr: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func removeSQLiteSidecars(for databasePath: String) {
    for suffix in ["-shm", "-wal"] {
      try? FileManager.default.removeItem(atPath: databasePath + suffix)
    }
  }
}

private struct SessionObservabilityCommandFixture {
  var root: URL
  var sessionStore: URL
  var sessionId: String
  var snapshots: [WorkflowRuntimePersistenceSnapshot]
}

private struct SQLiteCommandResult {
  var exitCode: Int32
  var stderr: String
}

private struct ScopedSessionObservabilityEnvelope: Decodable {
  var view: SessionObservabilityView?
}

private struct UnexpectedSessionFollowSleeper: SessionFollowSleeping {
  func sleep(seconds: Double) async throws {
    XCTFail("terminal follow should not sleep")
  }
}

private actor CompletingSessionFollowSleeper: SessionFollowSleeping {
  private let store: SQLiteWorkflowRuntimePersistenceStore
  private let snapshot: WorkflowRuntimePersistenceSnapshot
  private var intervals: [Double] = []

  init(
    store: SQLiteWorkflowRuntimePersistenceStore,
    snapshot: WorkflowRuntimePersistenceSnapshot
  ) {
    self.store = store
    self.snapshot = snapshot
  }

  func sleep(seconds: Double) async throws {
    intervals.append(seconds)
    try store.save(snapshot)
  }

  func recordedIntervals() -> [Double] {
    intervals
  }
}

private final class LockedSessionFollowRecords: @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String] = []

  func append(_ record: String) {
    lock.lock()
    records.append(record)
    lock.unlock()
  }

  func values() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return records
  }
}

private actor CompletingRollupSessionFollowSleeper: SessionFollowSleeping {
  private let store: SQLiteWorkflowRuntimePersistenceStore
  private let completedSnapshots: [WorkflowRuntimePersistenceSnapshot]
  private let records: LockedSessionFollowRecords
  private var intervals: [Double] = []

  init(
    store: SQLiteWorkflowRuntimePersistenceStore,
    completedSnapshots: [WorkflowRuntimePersistenceSnapshot],
    records: LockedSessionFollowRecords
  ) {
    self.store = store
    self.completedSnapshots = completedSnapshots
    self.records = records
  }

  func sleep(seconds: Double) async throws {
    XCTAssertEqual(records.values().count, 1, "first refresh must be written before follow sleeps")
    intervals.append(seconds)
    for snapshot in completedSnapshots {
      try store.save(snapshot)
    }
  }

  func recordedIntervals() -> [Double] {
    intervals
  }
}
