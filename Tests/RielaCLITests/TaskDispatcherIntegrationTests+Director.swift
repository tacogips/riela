import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
@testable import RielaServer
@testable import RielaWork
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

private actor DirectorWorkerRecordingAdapter: NodeAdapter {
  private(set) var inputs: [AdapterExecutionInput] = []

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    return try await DeterministicLocalNodeAdapter().execute(input, context: context)
  }
}

extension TaskDispatcherIntegrationTests {
  func testDirectorChildUsesSelectedAuthenticatedWorkerAndReceivesJudgedInputs() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.state = .verifying
    task.director.agentWorkflow = WorkflowReference(
      name: "task-agent-director", scope: WorkflowScope.project.rawValue,
      workflowDefinitionDir: harness.examples.path
    )
    try harness.store.saveTask(task)
    let judged = Attempt(
      id: AttemptID("judged-remote"), taskId: task.id,
      sessionId: "judged-remote-session", state: .reconciled,
      outcome: AttemptOutcome(sessionStatus: .failed)
    )
    try harness.store.saveAttempt(judged)
    let evidence = Evidence(
      id: EvidenceID("judged-remote-evidence"), taskId: task.id,
      attemptId: judged.id, kind: .contextSnapshot, producedBy: .runtime,
      payloadRef: .inline(["owner": .string("judged")]),
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try harness.store.saveEvidence(evidence)
    let guardViolation = GuardViolation.gateVisitsExceeded(gateId: "quality", visits: 2)
    let blocking = LoopBlockingFinding(id: "remote-finding", severity: "high", message: "judged work failed")
    let finding = Finding(
      id: blocking.id, fingerprint: LoopFindingFingerprint.make(from: blocking),
      severity: .high, sourceStepExecutionId: "judged-execution", message: blocking.message
    )
    let view = AgentDirectorTaskView(
      task: task, judgedAttempt: judged, completion: .unmet([]),
      guardViolations: [guardViolation], openFindings: [finding],
      evidenceSummary: [evidence], remainingAttempts: 0
    )
    let workerRoot = harness.sessionStore.appendingPathComponent("worker", isDirectory: true)
    try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
    let configURL = harness.sessionStore.appendingPathComponent("director-controller.json")
    let config = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "remote", groups: [], tokenEnvironment: "TEST_DIRECTOR_TOKEN", maxCapacity: 1)],
      defaultWorkspace: "project"
    )
    try JSONEncoder().encode(config).write(to: configURL)
    let controller = try config.controller(relativeTo: configURL)
    let registered = expectation(description: "director worker capability snapshot")
    registered.assertForOverFulfill = false
    let token = String(repeating: "d", count: 40)
    let router = try DistributedWorkerHTTPRouter(
      controller: controller,
      credentials: [.init(workerId: "remote", groups: [], token: token)],
      capabilitySnapshotSink: { snapshot in
        try harness.store.saveHostSnapshot(snapshot)
        registered.fulfill()
      }
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    let adapter = DirectorWorkerRecordingAdapter()
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: workerRoot)], adapter: adapter,
      stdio: LocalWorkflowStdioNodeExecutor()
    )
    let client = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token
    )
    let capability = BackendCapability(
      backend: .codexAgent, source: .observed, observedAt: Date(),
      availability: .available, authentication: .available, models: ["gpt-5.4-mini"]
    )
    let loop = try DistributedWorkerLoop(client: client, capacity: 1, capabilities: [capability]) {
      try await executor.execute($0)
    }
    let worker = Task { try await loop.run() }
    do {
      await fulfillment(of: [registered], timeout: 5)
      let previous = getenv(DistributedControllerConfiguration.environmentKey).map { String(cString: $0) }
      setenv(DistributedControllerConfiguration.environmentKey, configURL.path, 1)
      defer {
        if let previous {
          setenv(DistributedControllerConfiguration.environmentKey, previous, 1)
        } else {
          unsetenv(DistributedControllerConfiguration.environmentKey)
        }
      }
      let bundle = try harness.bundle("task-agent-director")
      let resolver = TaskExampleBundleResolver(bundle: bundle)
      let command = TaskDispatch(
        resolver: resolver, hostResolver: TaskWorkerHostResolver(defaultWorkspace: "project"),
        runner: WorkflowRunCommand(resolver: resolver)
      )
      let result = try await command.runDirectorChild(
        view: view,
        located: TaskCommandRunner.LocatedTask(task: task, store: harness.store, root: harness.store.rootDirectory),
        options: TaskStoreOptions(
          scope: .project, workingDirectory: harness.repository.path,
          sessionStore: harness.sessionStore.path
        ),
        output: .json
      )
      XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
      let attempts = try harness.store.listAttempts(taskId: task.id)
      XCTAssertEqual(attempts.count, 2)
      let child = try XCTUnwrap(attempts.first(where: { $0.entry == .director }))
      XCTAssertEqual(child.judgedAttemptId, judged.id)
      XCTAssertEqual(child.outcome?.sessionStatus, .completed)
      let placementEvidence = try XCTUnwrap(harness.store.listEvidence(taskId: task.id).first(where: {
        $0.attemptId == child.id && $0.payloadRef.inlinePayload?["taskView"] != nil
      }))
      let payload = try XCTUnwrap(placementEvidence.payloadRef.inlinePayload)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let placement = try decoder.decode(
        BackendCapabilityPlacementResult.self,
        from: JSONEncoder().encode(try XCTUnwrap(payload["placement"]))
      )
      XCTAssertEqual(placement.choices.first?.hostId, "remote")
      XCTAssertEqual(placement.choices.first?.backend, .codexAgent)
      let host = try decoder.decode(
        WorkflowPlanningCapabilityContext.self,
        from: JSONEncoder().encode(try XCTUnwrap(payload["hostCapabilityContext"]))
      )
      XCTAssertEqual(host.host.hostId, "remote")
      let deliveredView = try decoder.decode(
        AgentDirectorTaskView.self,
        from: JSONEncoder().encode(try XCTUnwrap(payload["taskView"]))
      )
      XCTAssertEqual(deliveredView.judgedAttempt.id, judged.id)
      XCTAssertEqual(deliveredView.judgedAttempt.outcome, judged.outcome)
      XCTAssertEqual(deliveredView.completion, .unmet([]))
      XCTAssertEqual(deliveredView.guardViolations, [guardViolation])
      XCTAssertEqual(deliveredView.openFindings, [finding])
      XCTAssertEqual(deliveredView.evidenceSummary.first?.id, evidence.id)
      XCTAssertEqual(deliveredView.evidenceSummary.first?.payloadRef, evidence.payloadRef)
      let inputs = await adapter.inputs
      XCTAssertEqual(inputs.count, 1)
      XCTAssertEqual(inputs.first?.node.executionBackend, .codexAgent)
      XCTAssertEqual(inputs.first?.node.model, "gpt-5.4-mini")
      XCTAssertEqual(inputs.first?.node.workingDirectory, workerRoot.path)
      XCTAssertEqual(inputs.first?.mergedVariables["taskView"], payload["taskView"])
      XCTAssertEqual(inputs.first?.mergedVariables["hostCapabilityContext"], payload["hostCapabilityContext"])
      let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
        .load(sessionId: child.sessionId)
      if case let .object(variables)? = snapshot.session.executions.first?.inputSnapshot?["mergedVariables"] {
        XCTAssertEqual(variables["taskView"], payload["taskView"])
        XCTAssertEqual(variables["hostCapabilityContext"], payload["hostCapabilityContext"])
      } else {
        XCTFail("remote director node has no captured merged variables")
      }
      let jobs = try await controller.jobs(now: Date())
      XCTAssertEqual(jobs.count, 1)
      XCTAssertEqual(jobs.first?.lease?.workerId, "remote")
      worker.cancel()
      _ = try? await worker.value
      await server.stop()
    } catch {
      worker.cancel()
      _ = try? await worker.value
      await server.stop()
      throw error
    }
  }
}
