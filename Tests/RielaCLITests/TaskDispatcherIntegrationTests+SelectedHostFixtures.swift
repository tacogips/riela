import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
@testable import RielaServer
@testable import RielaWork
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

struct TaskWorkerHostResolver: HostCapabilityResolving {
  let defaultWorkspace: String?

  func resolve(
    host: String, scope: WorkflowScope, workingDirectory: String, readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date())]
  }

  func taskTopology(
    store: WorkStore, scope: WorkflowScope, workingDirectory: String,
    localAddonExecutables: [String: Bool]
  ) async throws -> TaskHostTopology {
    TaskHostTopology(
      local: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date()),
      workers: try store.loadHostSnapshots(),
      defaultWorkspace: defaultWorkspace
    )
  }
}

private actor TaskWorkerExecutionBarrier {
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func pause() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

private actor TaskWorkerRecordingAdapter: NodeAdapter {
  private(set) var inputs: [AdapterExecutionInput] = []
  let barrier: TaskWorkerExecutionBarrier?
  let entered: XCTestExpectation?

  init(barrier: TaskWorkerExecutionBarrier? = nil, entered: XCTestExpectation? = nil) {
    self.barrier = barrier
    self.entered = entered
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    entered?.fulfill()
    if let barrier { await barrier.pause() }
    return try await DeterministicLocalNodeAdapter().execute(input, context: context)
  }
}

private struct TaskWorkerHandoffObservation {
  let store: WorkStore
  let taskId: TaskID
  let controller: DistributedJobController
  let adapter: TaskWorkerRecordingAdapter
  let secondAdapter: TaskWorkerRecordingAdapter
  let expectedWorker: String
  let reusedNodePlacements: Bool
  let includeCallee: Bool
  let authoredWorkspace: String?
  let verifyWorkspace: Bool
  let workerRoot: URL
  let authoredRoot: URL
  let runNodePatch: String?
}

extension TaskDispatcherIntegrationTests {
  func assertTaskWorkerHandoff(
    includeCallee: Bool,
    authoredWorkspace: String? = nil,
    verifyWorkspace: Bool = false,
    target: DistributedWorkerTarget? = nil,
    expectedWorker: String = "remote",
    reusedNodePlacements: Bool = false,
    claimedWorkerLoss: Bool = false,
    runNodePatch: String? = nil
  ) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/work-runtime-p1-selected-host-delivery/tests/\(includeCallee ? "T2" : "T1")/\(UUID().uuidString)",
      isDirectory: true
    )
    let workerRoot = root.appendingPathComponent("worker", isDirectory: true)
    try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
    let authoredRoot = root.appendingPathComponent("authored", isDirectory: true)
    if authoredWorkspace != nil {
      try FileManager.default.createDirectory(at: authoredRoot, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let taskId = TaskID("task-remote-root")
    try store.saveTask(WorkTask(
      id: taskId, intentId: IntentID("intent-remote-root"), title: "Remote root",
      instruction: "Run on selected worker",
      plan: .workflow(WorkflowReference(name: "remote-root", scope: WorkflowScope.project.rawValue)),
      state: .ready
    ))
    let workflow = WorkflowDefinition(
      workflowId: "remote-root", defaults: .init(nodeTimeoutMs: 10_000, maxLoopIterations: 1),
      entryStepId: "run", nodeRegistry: [.init(id: "node", nodeFile: "node.json")]
        + (includeCallee ? [.init(id: "done-node", nodeFile: "done.json")] : []),
      steps: [.init(
        id: "run", nodeId: "node",
        transitions: reusedNodePlacements ? [.init(toStepId: "second")] : includeCallee
          ? [.init(toStepId: "child-run", toWorkflowId: "child", resumeStepId: "done")] : nil,
        placement: (authoredWorkspace != nil || target != nil || reusedNodePlacements) ? .init(
          target: target ?? .init(workerId: "remote"), workspace: authoredWorkspace ?? "project"
        ) : nil
      )] + (reusedNodePlacements ? [.init(
        id: "second", nodeId: "node",
        transitions: [.init(toStepId: "child-run", toWorkflowId: "child", resumeStepId: "done")],
        placement: .init(target: .init(workerId: "remote-b"), workspace: "project")
      )] : []) + (includeCallee ? [.init(id: "done", nodeId: "done-node")] : []),
      nodes: [.init(id: "node", nodeFile: "node.json")]
        + (includeCallee ? [.init(id: "done-node", nodeFile: "done.json")] : [])
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["node": reusedNodePlacements ? AgentNodePayload(
        id: "node", backendPolicy: WorkflowBackendPolicy(
          allowed: [.codexAgent, .claudeCodeAgent],
          modelByBackend: [.codexAgent: "gpt-test", .claudeCodeAgent: "claude-test"]
        ), model: "", agentSandbox: .readOnly
      ) : AgentNodePayload(
        id: "node", executionBackend: .codexAgent, model: "gpt-test", agentSandbox: .readOnly
      )].merging(includeCallee ? ["done-node": AgentNodePayload(
        id: "done-node", nodeType: .command, model: "", command: .init(executable: "/usr/bin/true")
      )] : [:]) { first, _ in first },
      sourceScope: .project, workflowDirectory: root.path
    )
    let child = taskWorkerChildBundle(root: root, reusedNodeID: reusedNodePlacements)
    let resolver = TaskExampleBundleResolver(bundle: bundle, callees: includeCallee ? ["child": child] : [:])
    let token = String(repeating: "t", count: 40)
    let secondToken = String(repeating: "u", count: 40)
    let hasSecondWorker = target != nil || reusedNodePlacements
    let groups: Set<String> = hasSecondWorker ? ["capable"] : []
    let configURL = root.appendingPathComponent("controller.json")
    let config = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "remote", groups: groups, tokenEnvironment: "TEST_TOKEN", maxCapacity: 1)]
        + (hasSecondWorker ? [.init(
          id: "remote-b", groups: groups, tokenEnvironment: "TEST_TOKEN_B", maxCapacity: 1
        )] : []),
      defaultWorkspace: "project"
    )
    try JSONEncoder().encode(config).write(to: configURL)
    let controller = try config.controller(relativeTo: configURL)
    let registered = expectation(description: "worker capability snapshot")
    registered.assertForOverFulfill = false
    let secondRegistered = hasSecondWorker ? expectation(description: "second worker capability snapshot") : nil
    secondRegistered?.assertForOverFulfill = false
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "remote", groups: groups, token: token)]
        + (hasSecondWorker ? [.init(workerId: "remote-b", groups: groups, token: secondToken)] : []),
      capabilitySnapshotSink: { snapshot in
        try store.saveHostSnapshot(snapshot)
        if snapshot.hostId == "remote" { registered.fulfill() }
        if snapshot.hostId == "remote-b" { secondRegistered?.fulfill() }
      }
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    let executionBarrier = claimedWorkerLoss ? TaskWorkerExecutionBarrier() : nil
    let adapterEntered = claimedWorkerLoss ? expectation(description: "chosen worker entered adapter") : nil
    let adapter = TaskWorkerRecordingAdapter(barrier: executionBarrier, entered: adapterEntered)
    let secondAdapter = TaskWorkerRecordingAdapter()
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: workerRoot), "authored": .init(root: authoredRoot)], adapter: adapter,
      stdio: LocalWorkflowStdioNodeExecutor()
    )
    let client = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token
    )
    let secondClient = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: secondToken
    )
    let capability = BackendCapability(
      backend: .codexAgent, source: .observed, observedAt: Date(),
      availability: .available, authentication: .available, models: ["gpt-test"]
    )
    let childCapability = BackendCapability(
      backend: .claudeCodeAgent, source: .observed, observedAt: Date(),
      availability: .available, authentication: .available, models: ["claude-test"]
    )
    let loop = try DistributedWorkerLoop(
      client: client, capacity: 1,
      capabilities: includeCallee ? [capability, childCapability] : [capability]
    ) {
      try await executor.execute($0)
    }
    let worker = Task { try await loop.run() }
    let secondWorker: Task<Void, Error>? = if hasSecondWorker {
      Task {
        let secondExecutor = DistributedWorkerNodeExecutor(
          workspaces: ["project": .init(root: workerRoot)], adapter: secondAdapter,
          stdio: LocalWorkflowStdioNodeExecutor()
        )
        let secondLoop = try DistributedWorkerLoop(
          client: secondClient, capacity: 1,
          capabilities: reusedNodePlacements ? [childCapability] : [capability]
        ) {
          try await secondExecutor.execute($0)
        }
        try await secondLoop.run()
      }
    } else { nil }
    do {
      await fulfillment(of: [registered], timeout: 5)
      if let secondRegistered { await fulfillment(of: [secondRegistered], timeout: 5) }
      let previous = getenv(DistributedControllerConfiguration.environmentKey).map { String(cString: $0) }
      setenv(DistributedControllerConfiguration.environmentKey, configURL.path, 1)
      defer {
        if let previous {
          setenv(DistributedControllerConfiguration.environmentKey, previous, 1)
        } else {
          unsetenv(DistributedControllerConfiguration.environmentKey)
        }
      }
      let command = TaskDispatch(
        resolver: resolver, hostResolver: TaskWorkerHostResolver(defaultWorkspace: config.defaultWorkspace),
        runner: WorkflowRunCommand(resolver: resolver), nodePatch: runNodePatch
      )
      let options = TaskStoreOptions(scope: .project, workingDirectory: repository.path, sessionStore: root.path)
      if let executionBarrier, let adapterEntered {
        let running = Task { await command.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json) }
        do {
          await fulfillment(of: [adapterEntered], timeout: 5)
          let leased = try await controller.jobs(now: Date())
          XCTAssertEqual(leased.count, 1)
          XCTAssertEqual(leased.first?.status, .leased)
          XCTAssertEqual(leased.first?.lease?.workerId, "remote")
          let retry = await command.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json)
          XCTAssertEqual(retry.exitCode, .failure)
          XCTAssertEqual(try store.listAttempts(taskId: taskId).count, 1)
          let lost = try await controller.jobs(now: Date().addingTimeInterval(120))
          XCTAssertEqual(lost.map(\.status), [.lost])
          let retryAfterLoss = await command.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json)
          XCTAssertEqual(retryAfterLoss.exitCode, .failure)
          XCTAssertEqual(try store.listAttempts(taskId: taskId).count, 1)
          let jobsAfterRetry = try await controller.jobs(now: Date())
          XCTAssertEqual(jobsAfterRetry.count, 1)
          let alternateInputs = await secondAdapter.inputs
          XCTAssertTrue(alternateInputs.isEmpty)
          await executionBarrier.release()
          let result = await running.value
          XCTAssertEqual(result.exitCode, .failure)
          XCTAssertEqual(try store.listAttempts(taskId: taskId).count, 1)
          let terminalJobs = try await controller.jobs(now: Date())
          XCTAssertEqual(terminalJobs.count, 1)
          let selectedInputs = await adapter.inputs
          let otherInputs = await secondAdapter.inputs
          XCTAssertEqual(selectedInputs.count, 1)
          XCTAssertTrue(otherInputs.isEmpty)
        } catch {
          await executionBarrier.release()
          running.cancel()
          _ = await running.value
          throw error
        }
        await stopTaskWorkers(worker, secondWorker: secondWorker, server: server)
        return
      }
      let result = await command.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json)
      try await assertCompletedWorkerHandoff(result, observation: .init(
        store: store, taskId: taskId, controller: controller,
        adapter: adapter, secondAdapter: secondAdapter, expectedWorker: expectedWorker,
        reusedNodePlacements: reusedNodePlacements, includeCallee: includeCallee,
        authoredWorkspace: authoredWorkspace, verifyWorkspace: verifyWorkspace,
        workerRoot: workerRoot, authoredRoot: authoredRoot, runNodePatch: runNodePatch
      ))
      await stopTaskWorkers(worker, secondWorker: secondWorker, server: server)
    } catch {
      await stopTaskWorkers(worker, secondWorker: secondWorker, server: server)
      throw error
    }
  }

  private func stopTaskWorkers(
    _ worker: Task<Void, Error>, secondWorker: Task<Void, Error>?, server: RielaLocalHTTPServer
  ) async {
    worker.cancel()
    secondWorker?.cancel()
    _ = try? await worker.value
    _ = try? await secondWorker?.value
    await server.stop()
  }

  private func assertCompletedWorkerHandoff(
    _ result: CLICommandResult, observation: TaskWorkerHandoffObservation
  ) async throws {
    let store = observation.store
    let taskId = observation.taskId
    let controller = observation.controller
    let adapter = observation.adapter
    let secondAdapter = observation.secondAdapter
    let expectedWorker = observation.expectedWorker
    let reusedNodePlacements = observation.reusedNodePlacements
    let includeCallee = observation.includeCallee
    let authoredWorkspace = observation.authoredWorkspace
    let verifyWorkspace = observation.verifyWorkspace
    let workerRoot = observation.workerRoot
    let authoredRoot = observation.authoredRoot
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let response = try decoder.decode(TaskRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(response.status, "completed")
    XCTAssertEqual(response.placement?.choices.first?.hostId, expectedWorker)
    XCTAssertEqual(response.placement?.choices.first?.provenance.stepId, "run")
    XCTAssertEqual(response.placement?.choices.first?.backend, .codexAgent)
    let inputs = expectedWorker == "remote" ? await adapter.inputs : await secondAdapter.inputs
    let unusedInputs = expectedWorker == "remote" ? await secondAdapter.inputs : await adapter.inputs
    if reusedNodePlacements {
      let secondChoice = try XCTUnwrap(response.placement?.choices.first {
        $0.provenance.workflowId == "remote-root" && $0.provenance.stepId == "second"
      })
      XCTAssertEqual(secondChoice.provenance.nodeId, "node")
      XCTAssertEqual(secondChoice.hostId, "remote-b")
      XCTAssertEqual(secondChoice.backend, .claudeCodeAgent)
      XCTAssertEqual(secondChoice.model, "claude-test")
      XCTAssertEqual(unusedInputs.count, 1)
      XCTAssertEqual(unusedInputs.first?.node.executionBackend, .claudeCodeAgent)
      XCTAssertEqual(unusedInputs.first?.node.model, "claude-test")
    } else {
      XCTAssertTrue(unusedInputs.isEmpty)
    }
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.node.executionBackend, .codexAgent)
    XCTAssertEqual(input.node.model, "gpt-test")
    if authoredWorkspace != nil || verifyWorkspace {
      let expectedRoot = authoredWorkspace == nil ? workerRoot : authoredRoot
      XCTAssertEqual(input.node.workingDirectory, expectedRoot.path)
    }
    let sessions = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.rootDirectory).loadAll()
    let rootSession = try XCTUnwrap(sessions.first { $0.session.sessionId == response.sessionId })
    XCTAssertEqual(rootSession.session.status, .completed)
    XCTAssertTrue(rootSession.session.executions.contains { $0.acceptedOutput != nil })
    if includeCallee {
      let childChoice = try XCTUnwrap(response.placement?.choices.first {
        $0.provenance.workflowId == "child"
      })
      XCTAssertEqual(childChoice.hostId, "remote")
      XCTAssertEqual(childChoice.backend, .claudeCodeAgent)
      XCTAssertEqual(childChoice.model, "claude-test")
      XCTAssertEqual(childChoice.provenance.nodeId, reusedNodePlacements ? "node" : "child-node")
      XCTAssertEqual(inputs.count, 2)
      XCTAssertTrue(inputs.contains {
        $0.node.executionBackend == .claudeCodeAgent && $0.node.model == "claude-test"
      })
      let childSession = try XCTUnwrap(sessions.first { $0.session.workflowId == "child" })
      XCTAssertEqual(childSession.session.parentSessionId, response.sessionId)
      XCTAssertEqual(childSession.session.status, .completed)
      XCTAssertTrue(childSession.session.executions.contains { $0.acceptedOutput != nil })
    }
    try assertTerminalTaskEvidence(store: store, taskId: taskId, sessionId: response.sessionId)
    let jobs = try await controller.jobs(now: Date())
    if reusedNodePlacements {
      XCTAssertEqual(jobs.count, 3)
      XCTAssertEqual(jobs.filter { $0.lease?.workerId == "remote-b" }.count, 1)
      XCTAssertEqual(jobs.filter { $0.lease?.workerId == "remote" }.count, 2)
    } else {
      assertWorkerJobs(
        jobs, includeCallee: includeCallee, expectedWorker: expectedWorker,
        expectedWorkspace: authoredWorkspace != nil || verifyWorkspace ? authoredWorkspace ?? "project" : nil
      )
    }
  }

  private func taskWorkerChildBundle(root: URL, reusedNodeID: Bool = false) -> ResolvedWorkflowBundle {
    let nodeID = reusedNodeID ? "node" : "child-node"
    return ResolvedWorkflowBundle(
      workflow: .init(
        workflowId: "child", defaults: .init(nodeTimeoutMs: 10_000, maxLoopIterations: 1),
        entryStepId: "child-run", nodeRegistry: [.init(id: nodeID, nodeFile: "child.json")],
        steps: [.init(id: "child-run", nodeId: nodeID)],
        nodes: [.init(id: nodeID, nodeFile: "child.json")]
      ),
      nodePayloads: [nodeID: .init(
        id: nodeID, executionBackend: .claudeCodeAgent, model: "claude-test", agentSandbox: .readOnly
      )],
      sourceScope: .project, workflowDirectory: root.path
    )
  }

  private func assertTerminalTaskEvidence(store: WorkStore, taskId: TaskID, sessionId: String?) throws {
    let attempts = try store.listAttempts(taskId: taskId)
    XCTAssertEqual(attempts.count, 1)
    XCTAssertEqual(attempts.first?.sessionId, sessionId)
    XCTAssertEqual(attempts.first?.state, .reconciled)
    XCTAssertEqual(attempts.first?.outcome?.sessionStatus, .completed)
    let terminalEvidence = try XCTUnwrap(store.listEvidence(taskId: taskId).first {
      $0.payloadRef.inlinePayload?["sessionStatus"] == .string("completed")
    })
    XCTAssertEqual(terminalEvidence.attemptId, attempts.first?.id)
    XCTAssertEqual(try store.loadTask(id: taskId)?.state, .succeeded)
    XCTAssertTrue(try store.listDecisions(taskId: taskId).contains {
      $0.kind == .accept && $0.causedBy.contains(terminalEvidence.id)
    })
  }

  private func assertWorkerJobs(
    _ jobs: [DistributedJob], includeCallee: Bool, expectedWorker: String, expectedWorkspace: String?
  ) {
    XCTAssertEqual(jobs.count, includeCallee ? 2 : 1)
    XCTAssertTrue(jobs.allSatisfy { $0.lease?.workerId == expectedWorker })
    if let expectedWorkspace {
      XCTAssertEqual(jobs.first?.payload["workspace"], .string(expectedWorkspace))
    }
  }

}
