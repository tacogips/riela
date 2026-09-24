import Foundation
import RielaAdapters
import RielaCore
@testable import RielaServer
@testable import RielaWork
import XCTest
@testable import RielaCLI
#if canImport(Darwin)
import Darwin
#endif

private actor SelectedHostStopGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false
  private(set) var paused = false

  func pause() async {
    paused = true
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor SelectedHostProofRetryProbe {
  private(set) var count = 0

  func record() { count += 1 }
}

extension TaskCancellationIntegrationTests {
  func assertSelectedHostCancellation(lateBoundary: Bool = false) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/work-runtime-p1/p1-6c/remote-live/\(UUID().uuidString)")
    let workerRoot = root.appendingPathComponent("worker")
    try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let taskId = TaskID("task-remote-cancel")
    try store.saveTask(WorkTask(
      id: taskId, intentId: IntentID("intent-remote-cancel"), title: "Remote cancellation",
      instruction: "Run the selected worker", plan: .workflow(WorkflowReference(
        name: "remote-cancel", scope: WorkflowScope.project.rawValue
      )), state: .ready
    ))
    let longRunningScript = """
    trap '' TERM
    printf '%s' "$$" > leader.pid
    /bin/sh -c 'trap "" TERM; printf "%s" "$$" > child.pid; exec /bin/sleep 20'
    """
    let script = lateBoundary ? "true" : longRunningScript
    let workflow = WorkflowDefinition(
      workflowId: "remote-cancel", defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "run", nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [.init(id: "run", nodeId: "node", placement: .init(
        target: .init(workerId: "remote"), workspace: "project"
      ))], nodes: [.init(id: "node", nodeFile: "node.json")]
    )
    let resolver = TaskExampleBundleResolver(bundle: .init(
      workflow: workflow,
      nodePayloads: ["node": .init(
        id: "node", nodeType: .command, model: "",
        command: .init(executable: "/bin/sh", arguments: ["-c", script])
      )], sourceScope: .project, workflowDirectory: root.path
    ))
    let configURL = root.appendingPathComponent("controller.json")
    let config = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "remote", groups: [], tokenEnvironment: "TEST_TOKEN", maxCapacity: 1)],
      defaultWorkspace: "project"
    )
    try JSONEncoder().encode(config).write(to: configURL)
    let controller = try config.controller(relativeTo: configURL)
    let token = String(repeating: "c", count: 40)
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "remote", groups: [], token: token)],
      capabilitySnapshotSink: { snapshot in
        try store.saveHostSnapshot(snapshot)
      }
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token
    )
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: workerRoot)], adapter: DeterministicLocalNodeAdapter(),
      stdio: LocalWorkflowStdioNodeExecutor()
    )
    let stopGate = SelectedHostStopGate()
    let proofRetryProbe = SelectedHostProofRetryProbe()
    let capability = BackendCapability(
      backend: .codexAgent, source: .observed, observedAt: Date(),
      availability: .available, authentication: .available, models: ["gpt-test"]
    )
    let loop = try DistributedWorkerLoop(client: client, capacity: 1, capabilities: [capability]) { job in
      do { return try await executor.execute(job) } catch {
        if Task.isCancelled { await stopGate.pause() }
        throw error
      }
    }
    let worker = Task { try await loop.run() }
    addTeardownBlock {
      await stopGate.release()
      worker.cancel()
      _ = try? await worker.value
    }
    try await waitForSelectedHostRegistration(store: store)

    let previous = getenv(DistributedControllerConfiguration.environmentKey).map { String(cString: $0) }
    setenv(DistributedControllerConfiguration.environmentKey, configURL.path, 1)
    defer {
      if let previous { setenv(DistributedControllerConfiguration.environmentKey, previous, 1) } else {
        unsetenv(DistributedControllerConfiguration.environmentKey)
      }
    }
    var runner = WorkflowRunCommand(resolver: resolver)
    if lateBoundary { runner.deferTerminalPersistence = { true } }
    var command = TaskDispatch(
      resolver: resolver, hostResolver: TaskWorkerHostResolver(defaultWorkspace: "project"),
      runner: runner
    )
    if lateBoundary {
      command.afterCancellationObservation = {
        try requestLateSelectedHostCancellation(storeRoot: store.rootDirectory, taskId: taskId)
      }
      command.afterSelectedHostProofRequired = { await proofRetryProbe.record() }
    }
    let options = TaskStoreOptions(scope: .project, workingDirectory: repository.path, sessionStore: root.path)
    let running = Task { await command.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json) }
    addTeardownBlock {
      await stopGate.release()
      running.cancel()
      _ = await running.value
    }

    if lateBoundary {
      let result = await running.value
      let jobs = try await controller.jobs(now: Date())
      try assertLateSelectedHostOutcome(store: store, taskId: taskId, jobs: jobs, result: result)
      let proofRetryCount = await proofRetryProbe.count
      XCTAssertEqual(proofRetryCount, 1)
      return
    }

    let childFile = workerRoot.appendingPathComponent("child.pid")
    let readyDeadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: childFile.path), Date() < readyDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let leader = try XCTUnwrap(Int32(String(contentsOf: workerRoot.appendingPathComponent("leader.pid"), encoding: .utf8)))
    let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
    XCTAssertTrue(selectedHostProcessIsExecuting(leader))
    XCTAssertTrue(selectedHostProcessIsExecuting(child))
    let attempt = try XCTUnwrap(store.listAttempts(taskId: taskId).first)
    let admissionDecisions = try store.listDecisions(taskId: taskId)
    XCTAssertEqual(admissionDecisions.count, 1)
    let admission = try XCTUnwrap(admissionDecisions.first)
    XCTAssertEqual(admission.taskId, taskId)
    XCTAssertEqual(admission.attemptId, attempt.id)
    XCTAssertEqual(admission.kind, .start)
    XCTAssertEqual(admission.producer, .policy(rule: "task-run"))
    XCTAssertTrue(admission.causedBy.isEmpty)
    let leasedJobs = try await controller.jobs(now: Date())
    let leased = try XCTUnwrap(leasedJobs.first)
    XCTAssertTrue(leased.id.hasPrefix(attempt.sessionId + "/"))
    XCTAssertEqual(leased.lease?.workerId, "remote")
    XCTAssertEqual(leased.status, .leased)
    let version = try XCTUnwrap(store.loadTask(id: taskId)).version
    try runSelectedHostDecisionProcess(taskId: taskId, version: version, sessionStore: root.path)

    let proofDeadline = Date().addingTimeInterval(4)
    while !(await stopGate.paused), Date() < proofDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let proofPaused = await stopGate.paused
    XCTAssertTrue(proofPaused, "Worker did not reach its delayed stop receipt")
    let pending = try XCTUnwrap(store.attemptCancellation(
      taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertFalse(pending.acknowledged)
    let beforeProofJobs = try await controller.jobs(now: Date())
    let beforeProof = try XCTUnwrap(beforeProofJobs.first)
    XCTAssertEqual(beforeProof.status, .cancelled)
    XCTAssertNil(beforeProof.stoppedAt)
    let afterLeaseAndHeartbeat = Date().addingTimeInterval(3_600)
    let offlineWorker = try await controller.workers(now: afterLeaseAndHeartbeat)
      .first { $0.workerId == "remote" }
    XCTAssertEqual(offlineWorker?.online, false)
    let stopProvenAfterLoss = try await controller.provesCancellationStopped(
      sessionId: attempt.sessionId, runtimeRoot: store.rootDirectory, now: afterLeaseAndHeartbeat
    )
    XCTAssertFalse(stopProvenAfterLoss)
    let stillPending = try XCTUnwrap(store.attemptCancellation(
      taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertFalse(stillPending.acknowledged)
    XCTAssertEqual(try store.openWritable().query("SELECT attempt_id FROM work_leases").count, 1)
    try await assertSelectedHostProcessesStopped(leader: leader, child: child)
    await stopGate.release()
    let result = await running.value
    XCTAssertEqual(result.exitCode, .failure)

    let stoppedJobs = try await controller.jobs(now: Date())
    let stopped = try XCTUnwrap(stoppedJobs.first)
    XCTAssertNotNil(stopped.stoppedAt)
    XCTAssertNil(stopped.result)
    let reopenedController = try config.controller(relativeTo: configURL)
    let durableJobs = try await reopenedController.jobs(now: Date())
    XCTAssertEqual(durableJobs.first?.stoppedAt, stopped.stoppedAt)
    let reopened = WorkStore(rootDirectory: store.rootDirectory)
    let cancellation = try XCTUnwrap(reopened.attemptCancellation(
      taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertTrue(cancellation.acknowledged)
    XCTAssertEqual(try reopened.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertEqual(try reopened.loadTask(id: taskId)?.state, .cancelled)
    XCTAssertEqual(try reopened.listAttempts(taskId: taskId).count, 1)
    let decisions = try assertSelectedHostDecisions(
      in: reopened, taskId: taskId, attempt: attempt, admission: admission, cancellation: cancellation
    )
    XCTAssertEqual(try reopened.openWritable().query("SELECT attempt_id FROM work_leases").count, 0)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    try await assertSelectedHostProcessesStopped(leader: leader, child: child)
    let evidenceCount = try reopened.listEvidence(taskId: taskId).count
    let outcome = try reopened.loadAttempt(id: attempt.id)?.outcome
    try runSelectedHostDecisionProcess(taskId: taskId, version: version, sessionStore: root.path)
    XCTAssertEqual(try reopened.listAttempts(taskId: taskId).count, 1)
    XCTAssertEqual(try reopened.listDecisions(taskId: taskId), decisions)
    XCTAssertEqual(try reopened.listEvidence(taskId: taskId).count, evidenceCount)
    XCTAssertEqual(try reopened.loadAttempt(id: attempt.id)?.outcome, outcome)
  }

  private func assertSelectedHostDecisions(
    in store: WorkStore, taskId: TaskID, attempt: Attempt,
    admission: Decision, cancellation: AttemptCancellationRecord
  ) throws -> [Decision] {
    let decisions = try store.listDecisions(taskId: taskId)
    XCTAssertEqual(decisions.count, 2)
    XCTAssertEqual(decisions.first, admission)
    let humanCancel = try XCTUnwrap(decisions.last)
    XCTAssertEqual(humanCancel.id, DecisionID("decision-remote-live-cancel"))
    XCTAssertEqual(humanCancel.taskId, taskId)
    XCTAssertEqual(humanCancel.attemptId, attempt.id)
    XCTAssertEqual(humanCancel.kind, .cancel)
    XCTAssertEqual(humanCancel.producer, .human(principal: "operator"))
    XCTAssertEqual(humanCancel.causedBy.count, 1)
    XCTAssertLessThanOrEqual(admission.createdAt, humanCancel.createdAt)
    XCTAssertEqual(cancellation.decisionId, humanCancel.id)
    let causalEvidence = try XCTUnwrap(store.listEvidence(taskId: taskId)
      .first { $0.id == humanCancel.causedBy.first })
    XCTAssertEqual(causalEvidence.taskId, taskId)
    XCTAssertEqual(causalEvidence.attemptId, attempt.id)
    XCTAssertLessThanOrEqual(causalEvidence.createdAt, humanCancel.createdAt)
    print("selected-host decisions: admission=\(admission.id.rawValue) kind=\(admission.kind.kindName) " +
      "producer=policy:task-run causedBy=[]; cancellation=\(humanCancel.id.rawValue) " +
      "kind=\(humanCancel.kind.kindName) producer=human:operator " +
      "causedBy=\(humanCancel.causedBy.map(\.rawValue))")
    return decisions
  }

  private func assertLateSelectedHostOutcome(
    store: WorkStore, taskId: TaskID, jobs: [DistributedJob], result: CLICommandResult
  ) throws {
    XCTAssertEqual(result.exitCode, .failure)
    let attempt = try XCTUnwrap(store.listAttempts(taskId: taskId).first)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    let cancellation = try XCTUnwrap(store.attemptCancellation(
      taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
    ))
    XCTAssertTrue(cancellation.acknowledged)
    XCTAssertEqual(try store.loadTask(id: taskId)?.state, .cancelled)
    XCTAssertEqual(try store.loadAttempt(id: attempt.id)?.state, .reconciled)
    XCTAssertEqual(jobs.first?.status, .succeeded, String(describing: jobs.first))
  }

  private func waitForSelectedHostRegistration(store: WorkStore) async throws {
    let registrationDeadline = Date().addingTimeInterval(5)
    while try !store.loadHostSnapshots().contains(where: { $0.hostId == "remote" }),
          Date() < registrationDeadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(try store.loadHostSnapshots().contains { $0.hostId == "remote" })
  }

  private func runSelectedHostDecisionProcess(taskId: TaskID, version: Int, sessionStore: String) throws {
    let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("riela")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    let process = Process()
    process.executableURL = executable
    process.arguments = [
      "task", "decide", taskId.rawValue, "--cancel", "--principal", "operator",
      "--expected-version", String(version), "--decision-id", "decision-remote-live-cancel",
      "--session-store", sessionStore, "--output", "json"
    ]
    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    try process.run()
    process.waitUntilExit()
    let stderr = String(bytes: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stdout = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, stderr + stdout)
  }

  private func selectedHostProcessIsExecuting(_ processID: Int32) -> Bool {
    guard kill(processID, 0) == 0 else { return false }
    #if os(Linux)
    if let status = try? String(contentsOfFile: "/proc/\(processID)/stat", encoding: .utf8),
       let end = status.lastIndex(of: ")"), status[status.index(after: end)...].hasPrefix(" Z ") { return false }
    #endif
    return true
  }

  private func assertSelectedHostProcessesStopped(leader: Int32, child: Int32) async throws {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if !selectedHostProcessIsExecuting(leader) && !selectedHostProcessIsExecuting(child) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertFalse(selectedHostProcessIsExecuting(leader), "Selected worker leader remains active")
    XCTAssertFalse(selectedHostProcessIsExecuting(child), "Selected worker child remains active")
  }
}

private func requestLateSelectedHostCancellation(storeRoot: String, taskId: TaskID) throws {
  let requester = WorkStore(rootDirectory: storeRoot)
  let attempt = try XCTUnwrap(requester.listAttempts(taskId: taskId).first)
  let before = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: storeRoot)
    .load(sessionId: attempt.sessionId)
  XCTAssertFalse(before.session.status == .completed || before.session.status == .failed)
  XCTAssertNil(try requester.attemptCancellation(
    taskId: taskId, attemptId: attempt.id, sessionId: attempt.sessionId
  ))
  let decision = Decision(
    id: DecisionID("decision-remote-late-cancel"), taskId: taskId, attemptId: attempt.id,
    producer: .human(principal: "operator"), kind: .cancel,
    reason: "late selected-host cancellation", createdAt: Date()
  )
  try requester.saveDecision(decision)
  try requester.requestAttemptCancellation(attemptId: attempt.id, decisionId: decision.id)
}
