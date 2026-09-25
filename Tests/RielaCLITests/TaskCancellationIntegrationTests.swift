import Foundation
import RielaCore
@testable import RielaWork
import XCTest
@testable import RielaCLI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

final class TaskCancellationIntegrationTests: XCTestCase {
  func testTaskBackedSelectedHostCancellationWaitsForWorkerStopProof() async throws {
    try await assertSelectedHostCancellation()
  }

  func testLateSelectedHostCancellationAfterObservationRetriesWithStopProof() async throws {
    try await assertSelectedHostCancellation(lateBoundary: true)
  }

  func testTerminalProjectionFailureKeepsCancellationFence() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let database = try harness.store.openWritable()
    try database.execute("""
      CREATE TRIGGER fail_terminal_evidence BEFORE INSERT ON work_evidence
      WHEN NEW.evidence_id LIKE 'evidence-terminal-%'
      BEGIN SELECT RAISE(ABORT, 'injected terminal projection failure'); END
      """)
    let result = try await harness.dispatch("scheduled-sleep", beforeExecution: { reservation in
      let evidence = try harness.store.listEvidence(taskId: task.id)
        .first { $0.attemptId == reservation.attempt.id }
      guard let evidence, let version = try harness.store.loadTask(id: task.id)?.version else {
        throw WorkStoreError("reserved task evidence is missing")
      }
      _ = try harness.store.applyDecision(
        Decision(
          id: DecisionID("decision-projection-failure"), taskId: task.id,
          attemptId: reservation.attempt.id, producer: .human(principal: "operator"),
          kind: .cancel, reason: "cancel before launch", causedBy: [evidence.id], createdAt: Date()
        ), expectedTaskVersion: version, completion: .unmet([]),
        decisionEvidenceId: EvidenceID("evidence-decision-projection-failure")
      )
    })
    XCTAssertEqual(result.exitCode, .failure)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(TaskRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(response.statusKind, .error)
    XCTAssertEqual(response.attemptId, attempt.id.rawValue)
    XCTAssertEqual(response.sessionId, attempt.sessionId)
    XCTAssertEqual(attempt.state, .prepared)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .running)
    XCTAssertFalse(try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    )).acknowledged)
    XCTAssertEqual(try database.query("SELECT attempt_id FROM work_leases").count, 1)
    try database.execute("DROP TRIGGER fail_terminal_evidence")
  }

  func testSignalBeforeCapacityWaitCommitsWithoutReservation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let signal = TaskRunSignalState()
    signal.request(2)
    let result = try await harness.dispatch("scheduled-sleep", capacity: 0, signalState: signal)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 1)
  }

  func testReservedExecutionFailureReturnsIdentityAndKeepsFence() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let result = try await harness.dispatch("scheduled-sleep", beforeExecution: { _ in
      throw WorkStoreError("simulated prelaunch persistence failure")
    })
    XCTAssertEqual(result.exitCode, .failure)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(TaskRunCommandResult.self, from: Data(result.stdout.utf8))
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(response.attemptId, attempt.id.rawValue)
    XCTAssertEqual(response.sessionId, attempt.sessionId)
    XCTAssertEqual(response.statusKind, .error)
    XCTAssertEqual(attempt.state, .prepared)
    XCTAssertEqual(attempt.launch?.phase, .reserved)
  }

  func testSignalBeforeReservationCancelsTaskWithoutAttempt() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let signal = TaskRunSignalState()
    let result = try await harness.dispatch(
      "scheduled-sleep", beforeReservation: { signal.request(2) }, signalState: signal
    )
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 1)
  }

  func testSignalBeforeAuthorizationCancelsReservedSnapshot() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let signal = TaskRunSignalState()
    let result = try await harness.dispatch(
      "scheduled-sleep", beforeExecution: { _ in signal.request(2) }, signalState: signal
    )
    XCTAssertEqual(result.exitCode, .failure)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertNil(attempt.launch?.authorizedAt)
    XCTAssertEqual(attempt.state, .reconciled)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertTrue(snapshot.session.executions.isEmpty)
    XCTAssertTrue(try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    )).acknowledged)
  }

  func testTaskSignalCommitsDecisionBeforeLocalInterruption() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let signal = TaskRunSignalState()
    let dispatch = Task {
      try await harness.dispatch("scheduled-sleep", signalState: signal)
    }
    defer { dispatch.cancel() }
    let deadline = Date().addingTimeInterval(3)
    var active: Attempt?
    while Date() < deadline {
      active = try harness.store.listAttempts(taskId: task.id).first
      if active?.launch?.phase == .nodeStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let attempt = try XCTUnwrap(active)
    XCTAssertEqual(attempt.launch?.phase, .nodeStarted)
    signal.request(2)
    let result = try await dispatch.value
    XCTAssertEqual(result.exitCode, .failure)
    let decisions = try harness.store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }
    XCTAssertEqual(decisions.count, 1)
    XCTAssertEqual(decisions.first?.producer, .human(principal: "cli-signal"))
    let cancellation = try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertEqual(cancellation.decisionId, decisions.first?.id)
    XCTAssertTrue(cancellation.acknowledged)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
  }

  func testTaskRunSubprocessSIGINTCommitsAndAcknowledgesCancellation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let workflowRoot = harness.sessionStore.appendingPathComponent("signal-workflows")
    let workflowDirectory = workflowRoot.appendingPathComponent("scheduled-sleep")
    try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: harness.examples.appendingPathComponent("scheduled-sleep"), to: workflowDirectory
    )
    let sleepNode = workflowDirectory.appendingPathComponent("nodes/node-wait.json")
    var sleepSource = try String(contentsOf: sleepNode, encoding: .utf8)
    let duration = try XCTUnwrap(sleepSource.range(of: "\"durationMs\": 1000"))
    sleepSource.replaceSubrange(duration, with: "\"durationMs\": 20000")
    try sleepSource.write(to: sleepNode, atomically: true, encoding: .utf8)
    let workflowSource = """
      {
        "workflowId": "scheduled-sleep",
        "defaults": { "maxLoopIterations": 1, "nodeTimeoutMs": 30000 },
        "entryStepId": "wait",
        "nodes": [{ "id": "wait-node", "nodeFile": "nodes/node-wait.json" }],
        "steps": [{ "id": "wait", "nodeId": "wait-node", "role": "worker" }]
      }
      """
    try workflowSource.write(
      to: workflowDirectory.appendingPathComponent("workflow.json"),
      atomically: true, encoding: .utf8
    )

    let task = WorkTask(
      id: TaskID("task-signal-subprocess"), intentId: IntentID("intent-signal-subprocess"),
      title: "Interrupt owned task run", instruction: "Wait for SIGINT",
      plan: .workflow(WorkflowReference(
        name: "scheduled-sleep", scope: WorkflowScope.project.rawValue,
        workflowDefinitionDir: workflowRoot.path
      )), state: .ready
    )
    try harness.store.saveTask(task)
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let stdoutURL = harness.sessionStore.appendingPathComponent("signal-run.stdout")
    let stderrURL = harness.sessionStore.appendingPathComponent("signal-run.stderr")
    try Data().write(to: stdoutURL)
    try Data().write(to: stderrURL)
    let stdout = try FileHandle(forWritingTo: stdoutURL)
    let stderr = try FileHandle(forWritingTo: stderrURL)
    defer { try? stdout.close(); try? stderr.close() }
    let process = Process()
    process.executableURL = executable
    process.currentDirectoryURL = harness.sessionStore
    let isolatedHome = harness.sessionStore.appendingPathComponent("cli-home")
    try FileManager.default.createDirectory(at: isolatedHome, withIntermediateDirectories: true)
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = isolatedHome.path
    process.environment = environment
    process.arguments = [
      "task", "run", task.id.rawValue, "--scope", "project",
      "--working-dir", harness.sessionStore.path, "--session-store", harness.sessionStore.path,
      "--output", "json"
    ]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    defer {
      if process.isRunning {
        _ = kill(process.processIdentifier, SIGKILL)
        try? WorkflowSubprocessTestSupport.waitForExit(process, timeout: 3)
      }
    }

    let startDeadline = Date().addingTimeInterval(12)
    var active: Attempt?
    while Date() < startDeadline, process.isRunning {
      active = try harness.store.listAttempts(taskId: task.id).first
      if active?.launch?.phase == .nodeStarted { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    let preSignalOutput = try String(contentsOf: stdoutURL, encoding: .utf8)
    let preSignalError = try String(contentsOf: stderrURL, encoding: .utf8)
    let attempt = try XCTUnwrap(active, preSignalOutput + preSignalError)
    XCTAssertEqual(attempt.launch?.phase, .nodeStarted)
    XCTAssertTrue(process.isRunning)
    XCTAssertEqual(kill(process.processIdentifier, SIGINT), 0)
    try WorkflowSubprocessTestSupport.waitForExit(process, timeout: 5)
    XCTAssertFalse(process.isRunning)
    let output = try String(contentsOf: stdoutURL, encoding: .utf8)
    let error = try String(contentsOf: stderrURL, encoding: .utf8)
    XCTAssertEqual(process.terminationReason, .exit, output + error)
    XCTAssertEqual(process.terminationStatus, CLIExitCode.failure.rawValue, output + error)

    let reopened = WorkStore(rootDirectory: harness.store.rootDirectory)
    let decisions = try reopened.listDecisions(taskId: task.id).filter { $0.kind == .cancel }
    XCTAssertEqual(decisions.count, 1)
    let decision = try XCTUnwrap(decisions.first)
    XCTAssertEqual(decision.producer, .human(principal: "cli-signal"))
    XCTAssertEqual(decision.attemptId, attempt.id)
    XCTAssertEqual(decision.causedBy.count, 1)
    let cancellation = try XCTUnwrap(reopened.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertEqual(cancellation.decisionId, decision.id)
    XCTAssertTrue(cancellation.acknowledged)
    XCTAssertEqual(try reopened.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertEqual(try reopened.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try reopened.listAttempts(taskId: task.id).count, 1)
    XCTAssertTrue(try reopened.openWritable().query("SELECT attempt_id FROM work_leases").isEmpty)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: reopened.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
  }

  func testCancellationBeforeAuthorizationPersistsExactReservedTerminal() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let result = try await harness.dispatch("scheduled-sleep", beforeExecution: { reservation in
      let evidence = try harness.store.listEvidence(taskId: task.id)
        .first { $0.attemptId == reservation.attempt.id }
      guard let evidence else { throw WorkStoreError("reserved placement evidence is missing") }
      let decision = Decision(
        id: DecisionID("decision-prelaunch-cancel"), taskId: task.id,
        attemptId: reservation.attempt.id, producer: .human(principal: "operator"),
        kind: .cancel, reason: "cancel before launch", causedBy: [evidence.id], createdAt: Date()
      )
      let version = try harness.store.loadTask(id: task.id)?.version
      guard let version else { throw WorkStoreError("reserved task is missing") }
      _ = try harness.store.applyDecision(
        decision, expectedTaskVersion: version, completion: .unmet([]),
        decisionEvidenceId: EvidenceID("evidence-prelaunch-cancel")
      )
    })
    XCTAssertEqual(result.exitCode, .failure)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertNil(attempt.launch?.authorizedAt)
    XCTAssertNil(attempt.launch?.nodeStartedAt)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertTrue(snapshot.session.executions.isEmpty)
    XCTAssertTrue(try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    )).acknowledged)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter {
      $0.id == DecisionID("decision-prelaunch-cancel")
    }.count, 1)
  }

  func testSeparateDecisionInterruptsAndAcknowledgesOwnedLocalRunOnce() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("scheduled-sleep")
    let dispatch = Task { try await harness.dispatch("scheduled-sleep", sleepDurationMs: 10_000) }
    defer { dispatch.cancel() }

    let deadline = Date().addingTimeInterval(3)
    var active: Attempt?
    while Date() < deadline {
      active = try harness.store.listAttempts(taskId: task.id).first
      if active?.launch?.phase == .nodeStarted { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let attempt = try XCTUnwrap(active)
    XCTAssertEqual(attempt.launch?.phase, .nodeStarted)
    let version = try XCTUnwrap(harness.store.loadTask(id: task.id)).version
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let decision = Process()
    decision.executableURL = executable
    decision.arguments = [
      "task", "decide", task.id.rawValue, "--cancel",
      "--principal", "operator", "--expected-version", String(version),
      "--decision-id", "decision-live-cancel", "--session-store", harness.sessionStore.path,
      "--output", "json"
    ]
    let decisionOutput = Pipe()
    let decisionError = Pipe()
    decision.standardOutput = decisionOutput
    decision.standardError = decisionError
    try decision.run()
    decision.waitUntilExit()
    let stderr = String(bytes: decisionError.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stdout = String(bytes: decisionOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(decision.terminationStatus, 0, stderr + stdout)
    _ = try await dispatch.value

    let cancellation = try XCTUnwrap(harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertEqual(cancellation.decisionId, DecisionID("decision-live-cancel"))
    XCTAssertTrue(cancellation.acknowledged)
    XCTAssertEqual(try harness.store.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .cancelled)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 1)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter {
      $0.id == DecisionID("decision-live-cancel")
    }.count, 1)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
  }

  func testRequestFirstAtCanonicalTerminalBoundaryCancelsSIGINTAndExternalRequest() async throws {
    for signalDriven in [false, true] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      let task = try harness.seed("task-repair-loop")
      let store = harness.store
      let signal = signalDriven ? TaskRunSignalState() : nil
      let result = try await harness.dispatch(
        "task-repair-loop",
        beforeTerminalPersistence: {
          let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
          XCTAssertTrue(try boundaryCancellation(
            store: store, taskId: task.id, attemptId: attempt.id, signal: signal
          ))
          XCTAssertFalse(try XCTUnwrap(store.attemptCancellation(
            taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
          )).acknowledged)
        },
        signalState: signal
      )
      XCTAssertEqual(result.exitCode, .failure, result.stdout + result.stderr)
      let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
        .load(sessionId: attempt.sessionId)
      XCTAssertEqual(snapshot.session.status, .failed)
      XCTAssertEqual(snapshot.session.failureKind, .cancelled)
      XCTAssertEqual(attempt.state, .reconciled)
      XCTAssertTrue(try XCTUnwrap(store.attemptCancellation(
        taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
      )).acknowledged)
      XCTAssertEqual(try store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 1)
      XCTAssertEqual(try store.loadTask(id: task.id)?.state, .cancelled)
    }
  }

  func testTerminalFirstAtCanonicalBoundaryRejectsSIGINTAndExternalRequest() async throws {
    for signalDriven in [false, true] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      let task = try harness.seed("task-repair-loop")
      let store = harness.store
      let signal = signalDriven ? TaskRunSignalState() : nil
      let result = try await harness.dispatch(
        "task-repair-loop",
        afterTerminalPersistence: {
          let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
          let version = try XCTUnwrap(store.loadTask(id: task.id)).version
          if signalDriven {
            XCTAssertFalse(try boundaryCancellation(
              store: store, taskId: task.id, attemptId: attempt.id, signal: signal
            ))
          } else {
            XCTAssertThrowsError(try boundaryCancellation(
              store: store, taskId: task.id, attemptId: attempt.id, signal: nil
            )) { error in
              XCTAssertTrue((error as? WorkStoreError)?.isAlreadyTerminal == true)
            }
          }
          XCTAssertEqual(try store.loadTask(id: task.id)?.version, version)
          XCTAssertNil(try store.attemptCancellation(
            taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
          ))
        },
        signalState: signal
      )
      XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
      let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
        .load(sessionId: attempt.sessionId)
      XCTAssertEqual(snapshot.session.status, .completed)
      XCTAssertEqual(attempt.state, .reconciled)
      XCTAssertNil(try store.attemptCancellation(
        taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
      ))
      XCTAssertEqual(try store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 0)
      XCTAssertEqual(try store.loadTask(id: task.id)?.state, .succeeded)
    }
  }

  func testPendingCancellationRollsBackBothCLIRecordSnapshotSaves() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let store = harness.store
    let cliStore = CLIWorkflowSessionStore(rootDirectory: harness.sessionStore.path)
    let result = try await harness.dispatch("task-repair-loop", beforeExecution: { reservation in
      XCTAssertTrue(try boundaryCancellation(
        store: store, taskId: task.id, attemptId: reservation.attempt.id, signal: nil
      ))
      let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
      var snapshot = try persistence.load(sessionId: reservation.attempt.sessionId)
      snapshot.session.status = .completed
      snapshot.session.updatedAt = Date()
      let record = PersistedCLIWorkflowSession(
        workflowName: "task-repair-loop", session: snapshot.session,
        resolution: WorkflowResolutionOptions(
          workflowName: "task-repair-loop", scope: .project,
          workflowDefinitionDir: harness.examples.path,
          workingDirectory: harness.repository.path
        )
      )
      let before = try cliStore.loadAll()
      XCTAssertThrowsError(try cliStore.save(record, runtimeSnapshot: snapshot))
      XCTAssertEqual(try cliStore.loadAll(), before)
      XCTAssertThrowsError(try cliStore.save(
        record, runtimeSnapshot: snapshot, appendingWorkflowMessages: []
      ))
      XCTAssertEqual(try cliStore.loadAll(), before)
      XCTAssertEqual(try persistence.load(sessionId: reservation.attempt.sessionId).session.status, .created)
    })
    XCTAssertEqual(result.exitCode, .failure)
    let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
      .load(sessionId: attempt.sessionId).session.failureKind, .cancelled)
  }

  func testTerminalFirstOrdinaryFailureSurvivesLateSIGINTAndExternalRequest() async throws {
    for signalDriven in [false, true] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("scheduled-sleep")
      task.director.deterministic.rerunOnAdapterFailure = false
      try harness.store.saveTask(task)
      let taskId = task.id
      let store = harness.store
      let signal = signalDriven ? TaskRunSignalState() : nil
      let result = try await harness.dispatch(
        "scheduled-sleep", failWaitNode: true,
        afterTerminalPersistence: {
          let attempt = try XCTUnwrap(store.listAttempts(taskId: taskId).first)
          let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
            .load(sessionId: attempt.sessionId)
          XCTAssertEqual(snapshot.session.status, .failed)
          XCTAssertEqual(snapshot.session.failureKind, .adapterFailure)
          if signalDriven {
            XCTAssertFalse(try boundaryCancellation(
              store: store, taskId: taskId, attemptId: attempt.id, signal: signal
            ))
          } else {
            XCTAssertThrowsError(try boundaryCancellation(
              store: store, taskId: taskId, attemptId: attempt.id, signal: nil
            )) { error in
              XCTAssertTrue((error as? WorkStoreError)?.isAlreadyTerminal == true)
            }
          }
        }, signalState: signal
      )
      XCTAssertEqual(result.exitCode, .failure, result.stdout + result.stderr)
      let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
      XCTAssertEqual(attempt.state, .reconciled)
      XCTAssertEqual(attempt.outcome?.sessionStatus, .failed)
      XCTAssertEqual(attempt.outcome?.failureKind, .adapterFailure)
      let persisted = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
        .load(sessionId: attempt.sessionId)
      XCTAssertEqual(persisted.session.status, .failed)
      XCTAssertEqual(persisted.session.failureKind, .adapterFailure)
      XCTAssertEqual(try store.loadTask(id: task.id)?.state, .waiting)
      XCTAssertNil(try TaskDispatcher(store: store).pendingReservation(taskId: task.id))
      XCTAssertNil(try store.attemptCancellation(
        taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
      ))
      XCTAssertEqual(try store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 0)
    }
  }

  func testTerminalFirstRetryableFailurePreservesOnePendingRequestAfterLateCancellation() async throws {
    for signalDriven in [false, true] {
      let harness = try TaskExampleHarness()
      defer { harness.remove() }
      var task = try harness.seed("scheduled-sleep")
      task.director.deterministic.rerunOnAdapterFailure = true
      try harness.store.saveTask(task)
      let taskId = task.id
      let store = harness.store
      let signal = signalDriven ? TaskRunSignalState() : nil
      let result = try await harness.dispatch(
        "scheduled-sleep", failWaitNode: true,
        afterTerminalPersistence: {
          let attempt = try XCTUnwrap(store.listAttempts(taskId: taskId).first)
          let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
            .load(sessionId: attempt.sessionId)
          XCTAssertEqual(snapshot.session.status, .failed)
          XCTAssertEqual(snapshot.session.failureKind, .adapterFailure)
          if signalDriven {
            XCTAssertFalse(try boundaryCancellation(
              store: store, taskId: taskId, attemptId: attempt.id, signal: signal
            ))
          } else {
            XCTAssertThrowsError(try boundaryCancellation(
              store: store, taskId: taskId, attemptId: attempt.id, signal: nil
            )) { error in
              XCTAssertTrue((error as? WorkStoreError)?.isAlreadyTerminal == true)
            }
          }
        }, signalState: signal
      )
      XCTAssertEqual(result.exitCode, .failure, result.stdout + result.stderr)
      let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
      XCTAssertEqual(attempt.state, .reconciled)
      XCTAssertEqual(attempt.outcome?.failureKind, .adapterFailure)
      let reopened = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
        .load(sessionId: attempt.sessionId)
      XCTAssertEqual(reopened.session.status, .failed)
      XCTAssertEqual(reopened.session.failureKind, .adapterFailure)
      XCTAssertEqual(try store.loadTask(id: task.id)?.state, .scheduled)
      XCTAssertEqual(try TaskDispatcher(store: store).pendingReservation(taskId: task.id)?
        .predecessorAttemptId, attempt.id)
      XCTAssertEqual(try store.listDecisions(taskId: task.id).filter {
        if case .rerun = $0.kind { return true }
        return false
      }.count, 1)
      XCTAssertEqual(try store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 0)
      XCTAssertNil(try store.attemptCancellation(
        taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
      ))
    }
  }

  func testTerminalFirstExternalDecisionProcessReportsAlreadyTerminal() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let store = harness.store
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("riela")
    let result = try await harness.dispatch("task-repair-loop", afterTerminalPersistence: {
      let version = try XCTUnwrap(store.loadTask(id: task.id)).version
      let decision = Process()
      decision.executableURL = executable
      decision.arguments = [
        "task", "decide", task.id.rawValue, "--cancel",
        "--principal", "operator", "--expected-version", String(version),
        "--decision-id", "decision-terminal-first-process",
        "--session-store", harness.sessionStore.path, "--output", "json"
      ]
      let output = Pipe()
      let error = Pipe()
      decision.standardOutput = output
      decision.standardError = error
      try decision.run()
      try WorkflowSubprocessTestSupport.waitForExit(decision, timeout: 5)
      let response = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      let diagnostic = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      XCTAssertEqual(decision.terminationStatus, CLIExitCode.failure.rawValue, response + diagnostic)
      XCTAssertTrue((response + diagnostic).contains("already terminal"), response + diagnostic)
      XCTAssertEqual(try store.loadTask(id: task.id)?.version, version)
    })
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let attempt = try XCTUnwrap(store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertNil(try store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertEqual(try store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 0)
  }

  func testSIGINTAfterObserverJoinPreservesCommittedSuccess() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let signal = TaskRunSignalState()
    let result = try await harness.dispatch(
      "task-repair-loop", afterObserverJoin: { signal.request(SIGINT) }, signalState: signal
    )
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertNil(try harness.store.attemptCancellation(
      taskId: task.id, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).filter { $0.kind == .cancel }.count, 0)
  }
}

private func boundaryCancellation(
  store: WorkStore, taskId: TaskID, attemptId: AttemptID, signal: TaskRunSignalState?
) throws -> Bool {
  if let signal {
    signal.request(SIGINT)
    return try signal.commitIfRequested(store: store, taskId: taskId, attemptId: attemptId)
  }
  let evidence = try XCTUnwrap(store.listEvidence(taskId: taskId)
    .first { $0.attemptId == attemptId })
  let version = try XCTUnwrap(store.loadTask(id: taskId)).version
  _ = try store.applyDecision(
    Decision(
      id: DecisionID("decision-boundary-cancel"), taskId: taskId, attemptId: attemptId,
      producer: .human(principal: "operator"), kind: .cancel,
      reason: "boundary cancellation", causedBy: [evidence.id], createdAt: Date()
    ), expectedTaskVersion: version, completion: .unmet([]),
    decisionEvidenceId: EvidenceID("evidence-boundary-cancel")
  )
  return true
}
