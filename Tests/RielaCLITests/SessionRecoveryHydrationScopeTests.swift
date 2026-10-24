import Foundation
import XCTest

@testable import RielaCLI
@testable import RielaCore

final class SessionRecoveryHydrationScopeTests: XCTestCase {
  func testFamilyHydrationSkipsLargeUnrelatedHistoriesAndPreservesIdentityHighWaterMarks() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-recovery-hydration-family")
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = CLIWorkflowSessionStore(rootDirectory: root.path)
    let canonical = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var highestSessionSuffix = 0

    for index in 1...200 {
      let suffix = 1_000 + index
      highestSessionSuffix = suffix
      let sessionId = "recovery-hydration-session-\(suffix)"
      let session = makeSession(sessionId: sessionId, now: now, executions: [makeLargeExecution(suffix: suffix, now: now)])
      let messages = [makeMessage(sessionId: sessionId, suffix: suffix, now: now)]
      try sessionStore.save(
        makeRecord(session: session, root: root),
        runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages)
      )
    }

    let targetId = "recovery-hydration-session-10"
    var target = makeSession(
      sessionId: targetId,
      now: now,
      executions: [makeLargeExecution(suffix: 10, now: now)]
    )
    target.status = .failed
    target.failureKind = .maxStepsExceeded
    target.failureReason = "step budget reached"
    target.failedAt = now
    let targetMessages = [makeMessage(sessionId: targetId, suffix: 10, now: now)]
    try sessionStore.save(
      makeRecord(session: target, root: root),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: target, workflowMessages: targetMessages)
    )

    let childId = "recovery-hydration-session-11"
    let child = makeSession(sessionId: childId, now: now, parentSessionId: targetId, rootSessionId: targetId)
    try sessionStore.save(
      makeRecord(session: child, root: root),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: child)
    )

    let reservedId = "recovery-hydration-session-12"
    let reserved = makeSession(sessionId: reservedId, now: now, parentSessionId: targetId, rootSessionId: targetId)
    try canonical.save(WorkflowRuntimePersistenceSnapshot(session: reserved))

    let startedAt = ContinuousClock.now
    let runtime = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydration: .family(of: targetId)
    )
    let seedDuration = startedAt.duration(to: .now)
    FileHandle.standardError.write(Data("family-only seed duration: \(seedDuration)\n".utf8))
    XCTAssertLessThan(seedDuration, .seconds(5))

    for id in [targetId, childId, reservedId] {
      let familyMember = try await runtime.loadSession(id: id)
      XCTAssertNotNil(familyMember, "expected family member \(id)")
    }
    let seededTargetMessages = try await runtime.listMessages(for: targetId, toStepId: nil)
    XCTAssertEqual(seededTargetMessages, targetMessages)
    for suffix in [1_001, 1_025, 1_050, 1_075, 1_100, 1_125, 1_150, 1_175, 1_200, 1_201] {
      let unrelated = try await runtime.loadSession(id: "recovery-hydration-session-\(suffix)")
      XCTAssertNil(unrelated)
    }
    let created = try await runtime.createSession(
      WorkflowSessionCreateInput(workflowId: "recovery-hydration", entryStepId: "start")
    )
    XCTAssertGreaterThan(sessionSuffix(created.sessionId), highestSessionSuffix)

    let noneRuntime = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydration: .none
    )
    let noneTarget = try await noneRuntime.loadSession(id: targetId)
    XCTAssertNil(noneTarget)
    let noneCreated = try await noneRuntime.createSession(
      WorkflowSessionCreateInput(workflowId: "recovery-hydration", entryStepId: "start")
    )
    XCTAssertGreaterThan(sessionSuffix(noneCreated.sessionId), highestSessionSuffix)

    let failClosedBacking = InMemoryWorkflowRuntimeStore()
    let failClosed = FailClosedSQLiteWorkflowRuntimeStore(
      backing: failClosedBacking,
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path)
    )
    try await failClosed.hydrate(familyOf: targetId)
    let failClosedFamilyMember = try await failClosed.loadSession(id: reservedId)
    let failClosedUnrelated = try await failClosed.loadSession(id: "recovery-hydration-session-1050")
    XCTAssertNotNil(failClosedFamilyMember)
    XCTAssertNil(failClosedUnrelated)
  }

  func testFamilyHydrationSupportsCliOnlyTarget() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-recovery-hydration-cli-only")
    defer { try? FileManager.default.removeItem(at: root) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let target = makeSession(sessionId: "cli-only-session-7", now: now)
    try CLIWorkflowSessionStore(rootDirectory: root.path).save(makeRecord(session: target, root: root))

    let runtime = try await makeSeededProductionRuntimeStore(
      sessionStoreRoot: root.path,
      executionLocks: SessionExecutionLockRegistry(sessionStoreRoot: root.path),
      hydration: .family(of: target.sessionId)
    )
    let seededTarget = try await runtime.loadSession(id: target.sessionId)
    XCTAssertEqual(seededTarget, target)
  }

  func testResumeAndRerunEmitFirstJSONLRecordPromptlyWithLargeUnrelatedHistory() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("session-recovery-hydration-jsonl")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let examples = repository.appendingPathComponent("examples", isDirectory: true)
    let scenario = examples.appendingPathComponent("recent-change-quality-loop/mock-scenario.json")
    let workflowName = "recent-change-quality-loop"
    let sessionStore = CLIWorkflowSessionStore(rootDirectory: root.path)
    let interrupted = await RielaCLIApplication().run([
      "workflow", "run", workflowName,
      "--workflow-definition-dir", examples.path,
      "--mock-scenario", scenario.path,
      "--working-directory", root.path,
      "--session-store", root.path,
      "--max-steps", "1",
      "--output", "json"
    ], environment: ["HOME": root.path])
    XCTAssertEqual(interrupted.exitCode, .failure, interrupted.stderr)
    let interruptedResult = try JSONDecoder().decode(
      WorkflowRunFailureResult.self,
      from: Data(interrupted.stdout.utf8)
    )
    XCTAssertEqual(interruptedResult.failureKind, .maxStepsExceeded)
    let targetId = try XCTUnwrap(interruptedResult.sessionId)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    for suffix in 1_001...1_200 {
      let sessionId = "recovery-hydration-session-\(suffix)"
      let unrelated = makeSession(
        sessionId: sessionId,
        now: now,
        executions: [makeLargeExecution(suffix: suffix, now: now)]
      )
      try sessionStore.save(
        makeRecord(session: unrelated, root: root),
        runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(
          session: unrelated,
          workflowMessages: [makeMessage(sessionId: sessionId, suffix: suffix, now: now)]
        )
      )
    }

    let source = try sessionStore.load(sessionId: targetId)
    let stepId = try XCTUnwrap(source.session.executions.last?.stepId)
    let rerunTimer = FirstJSONLRecordTimer()
    let rerun = await RielaCLIApplication(
      sessionRerunCommand: SessionRerunCommand(jsonlRecordWriter: rerunTimer.record)
    ).run([
      "session", "rerun", targetId, stepId,
      "--workflow-definition-dir", examples.path,
      "--mock-scenario", scenario.path,
      "--working-directory", root.path,
      "--session-store", root.path,
      "--output", "jsonl"
    ], environment: ["HOME": root.path])
    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    let rerunFirstRecordSeconds = try XCTUnwrap(rerunTimer.firstRecordElapsedSeconds())
    FileHandle.standardError.write(Data("rerun first JSONL record: \(rerunFirstRecordSeconds) seconds\n".utf8))
    XCTAssertLessThan(rerunFirstRecordSeconds, 5)

    let resumeTimer = FirstJSONLRecordTimer()
    let resumed = await RielaCLIApplication(
      sessionResumeCommand: SessionResumeCommand(jsonlRecordWriter: resumeTimer.record)
    ).run([
      "session", "resume", targetId,
      "--workflow-definition-dir", examples.path,
      "--mock-scenario", scenario.path,
      "--working-directory", root.path,
      "--session-store", root.path,
      "--max-steps", "10",
      "--output", "jsonl"
    ], environment: ["HOME": root.path])
    XCTAssertEqual(resumed.exitCode, .success, resumed.stderr)
    let resumeFirstRecordSeconds = try XCTUnwrap(resumeTimer.firstRecordElapsedSeconds())
    FileHandle.standardError.write(Data("resume first JSONL record: \(resumeFirstRecordSeconds) seconds\n".utf8))
    XCTAssertLessThan(resumeFirstRecordSeconds, 5)
  }

  private func makeSession(
    sessionId: String,
    now: Date,
    executions: [WorkflowStepExecution] = [],
    parentSessionId: String? = nil,
    rootSessionId: String? = nil
  ) -> WorkflowSession {
    WorkflowSession(
      workflowId: "recovery-hydration",
      sessionId: sessionId,
      status: .running,
      entryStepId: "start",
      currentStepId: "start",
      createdAt: now,
      updatedAt: now,
      executions: executions,
      parentSessionId: parentSessionId,
      rootSessionId: rootSessionId
    )
  }

  private func makeLargeExecution(suffix: Int, now: Date) -> WorkflowStepExecution {
    WorkflowStepExecution(
      executionId: "start-attempt-1-exec-\(suffix)",
      stepId: "start",
      nodeId: "worker",
      attempt: 1,
      inputSnapshot: ["payload": .string(String(repeating: "x", count: 256 * 1024))],
      recentBackendEvents: [WorkflowBackendEventRecord(
        sequence: 1,
        at: now,
        eventType: "assistant_message",
        content: String(repeating: "e", count: 4 * 1024)
      )],
      createdAt: now,
      updatedAt: now
    )
  }

  private func makeMessage(sessionId: String, suffix: Int, now: Date) -> WorkflowMessageRecord {
    WorkflowMessageRecord(
      communicationId: "comm-\(String(format: "%06d", suffix))",
      workflowExecutionId: sessionId,
      fromStepId: "start",
      toStepId: "worker",
      sourceStepExecutionId: "start-attempt-1-exec-\(suffix)",
      payload: ["payload": .string(String(repeating: "m", count: 4 * 1024))],
      lifecycleStatus: .delivered,
      createdOrder: 1,
      createdAt: now
    )
  }

  private func makeRecord(session: WorkflowSession, root: URL) -> PersistedCLIWorkflowSession {
    PersistedCLIWorkflowSession(
      workflowName: "recovery-hydration",
      session: session,
      resolution: WorkflowResolutionOptions(
        workflowName: "recovery-hydration",
        scope: .direct,
        workingDirectory: root.path
      )
    )
  }

  private func sessionSuffix(_ sessionId: String) -> Int {
    Int(sessionId.split(separator: "-").last ?? "0") ?? 0
  }
}

private final class FirstJSONLRecordTimer: @unchecked Sendable {
  private let lock = NSLock()
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var firstRecordElapsed: Double?

  func record(_: String) {
    lock.lock()
    defer { lock.unlock() }
    guard firstRecordElapsed == nil else { return }
    firstRecordElapsed = ProcessInfo.processInfo.systemUptime - startedAt
  }

  func firstRecordElapsedSeconds() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    return firstRecordElapsed
  }
}
