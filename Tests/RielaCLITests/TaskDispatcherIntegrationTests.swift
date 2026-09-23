import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
@testable import RielaServer
@testable import RielaWork
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

private struct TaskExampleBundleResolver: WorkflowBundleResolving {
  let bundle: ResolvedWorkflowBundle
  var callees: [String: ResolvedWorkflowBundle] = [:]

  func resolve(_ options: WorkflowResolutionOptions) throws -> ResolvedWorkflowBundle {
    if let callee = callees[options.workflowName] { return callee }
    guard options.workflowName == bundle.workflow.workflowId else {
      throw WorkStoreError("unexpected workflow \(options.workflowName)")
    }
    return bundle
  }
}

private struct TaskExampleHostResolver: HostCapabilityResolving {
  let capacity: Int

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    let now = Date()
    return [HostCapabilitySnapshot(
      hostId: "local",
      capacity: capacity,
      backends: [BackendCapability(
        backend: .codexAgent,
        source: .observed,
        observedAt: now,
        availability: .available,
        authentication: .available,
        models: ["gpt-5.4-mini"]
      )],
      refreshedAt: now
    )]
  }
}

private struct TaskWorkerHostResolver: HostCapabilityResolving {
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

private actor TaskWorkerRecordingAdapter: NodeAdapter {
  private(set) var inputs: [AdapterExecutionInput] = []

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    inputs.append(input)
    return try await DeterministicLocalNodeAdapter().execute(input, context: context)
  }
}

struct TaskExampleHarness {
  let repository: URL
  let examples: URL
  let sessionStore: URL
  let store: WorkStore

  init() throws {
    var root = URL(fileURLWithPath: #filePath)
    while root.pathComponents.count > 1,
          !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
      root.deleteLastPathComponent()
    }
    repository = root
    examples = root.appendingPathComponent("examples", isDirectory: true)
    sessionStore = root.appendingPathComponent("tmp/task-example-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path))
  }

  func remove() {
    try? FileManager.default.removeItem(at: sessionStore)
  }

  func bundle(_ name: String) throws -> ResolvedWorkflowBundle {
    let directory = examples.appendingPathComponent(name, isDirectory: true)
    return try WorkflowRegistryBundleLoader().loadBundle(
      at: directory,
      rootDirectory: examples,
      scope: .direct,
      expectedWorkflowId: name
    )
  }

  func seed(_ name: String, state: TaskState = .ready, dependsOn: [TaskID] = []) throws -> WorkTask {
    let task = WorkTask(
      id: TaskID("task-\(name)"),
      intentId: IntentID("intent-\(name)"),
      dependsOn: dependsOn,
      title: "Run \(name)",
      instruction: "Complete the example task",
      plan: .workflow(WorkflowReference(
        name: name,
        scope: WorkflowScope.project.rawValue,
        workflowDefinitionDir: examples.path
      )),
      state: state
    )
    try store.saveTask(task)
    return task
  }

  func dispatch(
    _ name: String,
    capacity: Int = 1,
    dryRun: Bool = false,
    hostResolver: (any HostCapabilityResolving)? = nil
  ) async throws -> CLICommandResult {
    let loaded = try bundle(name)
    let resolver = TaskExampleBundleResolver(bundle: loaded)
    let command = TaskDispatch(
      resolver: resolver,
      hostResolver: hostResolver ?? TaskExampleHostResolver(capacity: capacity),
      runner: WorkflowRunCommand(resolver: resolver),
      mockScenarioPath: examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json").path
    )
    return await command.run(
      taskId: "task-\(name)",
      options: TaskStoreOptions(
        scope: .project,
        workingDirectory: repository.path,
        sessionStore: sessionStore.path
      ),
      dryRun: dryRun,
      output: .json
    )
  }

  func decode(_ result: CLICommandResult) throws -> TaskRunCommandResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TaskRunCommandResult.self, from: Data(result.stdout.utf8))
  }

  func fileBytes() throws -> [String: Data] {
    var result: [String: Data] = [:]
    guard let files = FileManager.default.enumerator(
      at: sessionStore, includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return result }
    for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
      let relative = file.path.replacingOccurrences(of: sessionStore.path + "/", with: "")
      result[relative] = try Data(contentsOf: file)
    }
    return result
  }

  func rowCounts(taskId: TaskID) throws -> [String: Int] {
    [
      "work_intents": try store.listIntents().count,
      "work_tasks": try store.listTasks(filter: TaskListFilter()).count,
      "work_attempts": try store.listAttempts(taskId: taskId).count,
      "work_decisions": try store.listDecisions(taskId: taskId).count,
      "work_evidence": try store.listEvidence(taskId: taskId).count,
      "work_findings": try store.listFindings(taskId: taskId).count,
      "work_hosts": try store.loadHostSnapshots().count
    ]
  }
}

final class TaskDispatcherIntegrationTests: XCTestCase {
  func testTaskPlacementKeepsSharedNodeStepsSeparateAndPinsChosenGroupWorker() throws {
    let workflow = WorkflowDefinition(
      workflowId: "shared", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "first", nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [
        .init(id: "first", nodeId: "node"),
        .init(id: "second", nodeId: "node", placement: .init(
          target: .init(group: "capable"), workspace: "project"
        ))
      ],
      nodes: [.init(id: "node", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["node": .init(id: "node", executionBackend: .codexAgent, model: "old")],
      sourceScope: .project, workflowDirectory: "/unused"
    )
    let first = BackendPlacementChoice(
      provenance: .init(workflowId: "shared", stepId: "first", nodeId: "node"),
      hostId: "local", backend: .codexAgent, model: "gpt-new",
      source: .observed, observedAt: Date(), fresh: true, verified: true
    )
    let second = BackendPlacementChoice(
      provenance: .init(workflowId: "shared", stepId: "second", nodeId: "node"),
      hostId: "worker-b", backend: .claudeCodeAgent, model: "claude-new",
      source: .observed, observedAt: Date(), fresh: true, verified: true
    )
    let context = TaskPlacementExecutionContext(
      bundles: ["shared": bundle], placement: .init(choices: [first, second], failures: []),
      defaultWorkspace: nil
    )
    let placed = try WorkflowRunCommand().applyingTaskPlacement(context, to: bundle)
    let firstStep = try XCTUnwrap(placed.workflow.steps.first { $0.id == "first" })
    let secondStep = try XCTUnwrap(placed.workflow.steps.first { $0.id == "second" })
    XCTAssertNotEqual(firstStep.nodeId, secondStep.nodeId)
    XCTAssertEqual(placed.nodePayloads[firstStep.nodeId]?.executionBackend, .codexAgent)
    XCTAssertEqual(placed.nodePayloads[firstStep.nodeId]?.model, "gpt-new")
    XCTAssertEqual(placed.nodePayloads[secondStep.nodeId]?.executionBackend, .claudeCodeAgent)
    XCTAssertEqual(placed.nodePayloads[secondStep.nodeId]?.model, "claude-new")
    XCTAssertEqual(secondStep.placement?.target.workerId, "worker-b")
    XCTAssertEqual(secondStep.placement?.target.group, "capable")
    XCTAssertEqual(secondStep.placement?.workspace, "project")
    XCTAssertEqual(bundle.nodePayloads["node"]?.model, "old")
  }

  func testTaskCalleeResolverUsesFrozenSelectedBackendAndWorker() async throws {
    let child = ResolvedWorkflowBundle(
      workflow: .init(
        workflowId: "child", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
        entryStepId: "run", nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
        steps: [.init(id: "run", nodeId: "node")], nodes: [.init(id: "node", nodeFile: "node.json")]
      ),
      nodePayloads: ["node": .init(id: "node", executionBackend: .codexAgent, model: "old")],
      sourceScope: .project, workflowDirectory: "/unused"
    )
    let choice = BackendPlacementChoice(
      provenance: .init(workflowId: "child", stepId: "run", nodeId: "node"),
      hostId: "worker-b", backend: .claudeCodeAgent, model: "claude-new",
      source: .observed, observedAt: Date(), fresh: true, verified: true
    )
    let context = TaskPlacementExecutionContext(
      bundles: ["child": child], placement: .init(choices: [choice], failures: []),
      defaultWorkspace: "project"
    )
    let resolver = FileSystemWorkflowCalleeResolver(
      resolver: TaskExampleBundleResolver(bundle: child),
      baseResolution: .init(workflowName: "child"), taskContext: context
    )
    let resolved = try await resolver.resolveCallee(workflowId: "child")
    let step = try XCTUnwrap(resolved.workflow.steps.first)
    XCTAssertEqual(step.placement?.target.workerId, "worker-b")
    XCTAssertEqual(step.placement?.workspace, "project")
    XCTAssertEqual(resolved.nodePayloads[step.nodeId]?.executionBackend, .claudeCodeAgent)
    XCTAssertEqual(resolved.nodePayloads[step.nodeId]?.model, "claude-new")
    XCTAssertEqual(child.nodePayloads["node"]?.model, "old")
  }

  func testTaskTopologyRejectsCachedWorkerWithoutLiveControllerRegistration() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/work-runtime-p1-selected-host-delivery/tests/T5-topology/\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    try store.saveHostSnapshot(.init(
      hostId: "remote", capacity: 1, backends: [], refreshedAt: Date()
    ))
    let configURL = root.appendingPathComponent("controller.json")
    let config = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "remote", groups: [], tokenEnvironment: "TOKEN", maxCapacity: 1)],
      defaultWorkspace: "project"
    )
    try JSONEncoder().encode(config).write(to: configURL)
    let profile = RielaAppDaemonWorkflowStore(stateURL: root.appendingPathComponent("profile.json"))
    let resolver = HostCapabilityResolver(
      profileStore: profile, activeProfileStore: RielaAppProfileStore(appRootURL: root),
      environment: [DistributedControllerConfiguration.environmentKey: configURL.path]
    )
    let before = try Data(contentsOf: URL(fileURLWithPath: store.databasePath))
    let topology = try await resolver.taskTopology(
      store: store, scope: .project, workingDirectory: repository.path, localAddonExecutables: [:]
    )
    XCTAssertTrue(topology.workers.isEmpty)
    XCTAssertEqual(topology.defaultWorkspace, "project")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.databasePath)), before)
  }

  func testRemoteTaskWithoutDefaultWorkspaceFailsBeforeReservation() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/work-runtime-p1-selected-host-delivery/tests/T5/\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    let taskId = TaskID("task-no-workspace")
    try store.saveTask(WorkTask(
      id: taskId, intentId: IntentID("intent-no-workspace"), title: "No workspace",
      instruction: "Wait for configuration",
      plan: .workflow(WorkflowReference(name: "no-workspace", scope: WorkflowScope.project.rawValue)),
      state: .ready
    ))
    let observed = Date()
    try store.saveHostSnapshot(HostCapabilitySnapshot(
      hostId: "remote", capacity: 1,
      backends: [.init(
        backend: .codexAgent, source: .observed, observedAt: observed,
        availability: .available, authentication: .available, models: ["gpt"]
      )], refreshedAt: observed
    ))
    let workflow = WorkflowDefinition(
      workflowId: "no-workspace", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "run", nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [.init(id: "run", nodeId: "node")], nodes: [.init(id: "node", nodeFile: "node.json")]
    )
    let resolver = TaskExampleBundleResolver(bundle: .init(
      workflow: workflow,
      nodePayloads: ["node": .init(
        id: "node", executionBackend: .codexAgent, model: "gpt", agentSandbox: .readOnly
      )],
      sourceScope: .project, workflowDirectory: root.path
    ))
    let before = try Data(contentsOf: URL(fileURLWithPath: store.databasePath))
    let result = await TaskDispatch(
      resolver: resolver, hostResolver: TaskWorkerHostResolver(defaultWorkspace: nil),
      runner: WorkflowRunCommand(resolver: resolver)
    ).run(
      taskId: taskId.rawValue,
      options: TaskStoreOptions(scope: .project, workingDirectory: repository.path, sessionStore: root.path),
      dryRun: false, output: .json
    )
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("default workspace"), result.stderr)
    XCTAssertTrue(try store.listAttempts(taskId: taskId).isEmpty)
    XCTAssertTrue(try store.listEvidence(taskId: taskId).isEmpty)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.databasePath)), before)
  }

  func testTaskRootUsesSelectedAuthenticatedWorkerBackendAndReservedSession() async throws {
    try await assertTaskWorkerHandoff(includeCallee: false)
  }

  func testTaskCalleeUsesSelectedAuthenticatedWorkerAndOrdinaryChildSession() async throws {
    try await assertTaskWorkerHandoff(includeCallee: true)
  }

  private func assertTaskWorkerHandoff(includeCallee: Bool) async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent(
      "tmp/work-runtime-p1-selected-host-delivery/tests/\(includeCallee ? "T2" : "T1")/\(UUID().uuidString)",
      isDirectory: true
    )
    let workerRoot = root.appendingPathComponent("worker", isDirectory: true)
    try FileManager.default.createDirectory(at: workerRoot, withIntermediateDirectories: true)
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
        transitions: includeCallee ? [.init(toStepId: "child-run", toWorkflowId: "child", resumeStepId: "done")] : nil
      )] + (includeCallee ? [.init(id: "done", nodeId: "done-node")] : []),
      nodes: [.init(id: "node", nodeFile: "node.json")]
        + (includeCallee ? [.init(id: "done-node", nodeFile: "done.json")] : [])
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["node": AgentNodePayload(
        id: "node", executionBackend: .codexAgent, model: "gpt-test", agentSandbox: .readOnly
      )].merging(includeCallee ? ["done-node": AgentNodePayload(
        id: "done-node", nodeType: .command, model: "", command: .init(executable: "/usr/bin/true")
      )] : [:]) { first, _ in first },
      sourceScope: .project, workflowDirectory: root.path
    )
    let child = ResolvedWorkflowBundle(
      workflow: .init(
        workflowId: "child", defaults: .init(nodeTimeoutMs: 10_000, maxLoopIterations: 1),
        entryStepId: "child-run", nodeRegistry: [.init(id: "child-node", nodeFile: "child.json")],
        steps: [.init(id: "child-run", nodeId: "child-node")],
        nodes: [.init(id: "child-node", nodeFile: "child.json")]
      ),
      nodePayloads: ["child-node": .init(
        id: "child-node", executionBackend: .claudeCodeAgent, model: "claude-test", agentSandbox: .readOnly
      )],
      sourceScope: .project, workflowDirectory: root.path
    )
    let resolver = TaskExampleBundleResolver(bundle: bundle, callees: includeCallee ? ["child": child] : [:])
    let token = String(repeating: "t", count: 40)
    let configURL = root.appendingPathComponent("controller.json")
    let config = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "remote", groups: [], tokenEnvironment: "TEST_TOKEN", maxCapacity: 1)],
      defaultWorkspace: "project"
    )
    try JSONEncoder().encode(config).write(to: configURL)
    let controller = try config.controller(relativeTo: configURL)
    let registered = expectation(description: "worker capability snapshot")
    registered.assertForOverFulfill = false
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "remote", groups: [], token: token)],
      capabilitySnapshotSink: { snapshot in
        try store.saveHostSnapshot(snapshot)
        registered.fulfill()
      }
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    let adapter = TaskWorkerRecordingAdapter()
    let executor = DistributedWorkerNodeExecutor(
      workspaces: ["project": .init(root: workerRoot)], adapter: adapter,
      stdio: LocalWorkflowStdioNodeExecutor()
    )
    let client = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: token
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
      let result = await TaskDispatch(
        resolver: resolver, hostResolver: TaskWorkerHostResolver(defaultWorkspace: config.defaultWorkspace),
        runner: WorkflowRunCommand(resolver: resolver)
      ).run(
        taskId: taskId.rawValue,
        options: TaskStoreOptions(scope: .project, workingDirectory: repository.path, sessionStore: root.path),
        dryRun: false, output: .json
      )
      XCTAssertEqual(result.exitCode, .success, result.stderr)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      let response = try decoder.decode(TaskRunCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(response.status, "completed")
      XCTAssertEqual(response.placement?.choices.first?.hostId, "remote")
      XCTAssertEqual(response.placement?.choices.first?.provenance.stepId, "run")
      XCTAssertEqual(response.placement?.choices.first?.backend, .codexAgent)
      let inputs = await adapter.inputs
      let input = try XCTUnwrap(inputs.first)
      XCTAssertEqual(input.node.executionBackend, .codexAgent)
      XCTAssertEqual(input.node.model, "gpt-test")
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
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs.contains {
          $0.node.executionBackend == .claudeCodeAgent && $0.node.model == "claude-test"
        })
        let childSession = try XCTUnwrap(sessions.first { $0.session.workflowId == "child" })
        XCTAssertEqual(childSession.session.parentSessionId, response.sessionId)
        XCTAssertEqual(childSession.session.status, .completed)
        XCTAssertTrue(childSession.session.executions.contains { $0.acceptedOutput != nil })
      }
      let attempts = try store.listAttempts(taskId: taskId)
      XCTAssertEqual(attempts.count, 1)
      XCTAssertEqual(attempts.first?.sessionId, response.sessionId)
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
      let jobs = try await controller.jobs(now: Date())
      XCTAssertEqual(jobs.count, includeCallee ? 2 : 1)
      XCTAssertTrue(jobs.allSatisfy { $0.lease?.workerId == "remote" })
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

  func testTaskLaunchAdmissionConsumesOnlyTheReservedRootToken() throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let reservation = try XCTUnwrap(harness.store.reserveAttempt(AttemptReservationRequest(
      taskId: task.id,
      expectedTaskVersion: task.version,
      attemptId: AttemptID("attempt-root"),
      sessionId: "session-root",
      workflowId: "task-repair-loop",
      entryStepId: "repair",
      entry: .start,
      decisionId: DecisionID("decision-root"),
      producer: .policy(rule: "test"),
      reason: "test launch"
    )).reservation)
    let admission = try XCTUnwrap(WorkflowRunCommand().makeTaskAdmission(
      (reservation, harness.store), processAdmission: { _ in }
    ))

    try admission("session-root")
    XCTAssertEqual(try harness.store.loadAttempt(id: reservation.attempt.id)?.launch?.phase, .nodeStarted)
    try admission("session-child")
    XCTAssertEqual(try harness.store.loadAttempt(id: reservation.attempt.id)?.launch?.phase, .nodeStarted)
    XCTAssertThrowsError(try admission("session-root"))
  }

  func testRepairRunUsesItsReservedSessionAndProjectsTerminalEvidence() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")

    let result = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let response = try harness.decode(result)
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(response.attemptId, attempt.id.rawValue)
    XCTAssertEqual(response.sessionId, attempt.sessionId)
    XCTAssertEqual(attempt.state, .reconciled)
    XCTAssertEqual(attempt.outcome?.sessionStatus, .completed)
    XCTAssertFalse(try harness.store.listEvidence(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).last?.kind, .accept)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: attempt.sessionId)
    XCTAssertEqual(snapshot.session.status, .completed)
  }

  func testCLIRerunConsumesOnePendingRequestAndReplayDoesNotDuplicate() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.completion.requiresHumanAccept = true
    try harness.store.saveTask(task)
    let dispatcher = TaskDispatcher(store: harness.store)

    let firstRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr + firstRun.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    XCTAssertEqual(firstAttempt.state, .reconciled)
    let version = try XCTUnwrap(harness.store.loadTask(id: task.id)).version
    let decideArguments = [
      "task", "decide", task.id.rawValue, "--rerun", "repair",
      "--principal", "operator", "--expected-version", String(version),
      "--decision-id", "decision-rerun-1", "--session-store", harness.sessionStore.path,
      "--output", "json"
    ]
    let decision = await RielaCLIApplication().run(decideArguments)
    XCTAssertEqual(decision.exitCode, .success, decision.stderr + decision.stdout)
    let pending = try XCTUnwrap(dispatcher.pendingReservation(taskId: task.id))
    XCTAssertEqual(pending.decisionId, DecisionID("decision-rerun-1"))
    XCTAssertEqual(pending.predecessorAttemptId, firstAttempt.id)
    XCTAssertEqual(pending.entry, .rerunFromStep("repair"))
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 1)

    let secondRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(secondRun.exitCode, .success, secondRun.stderr + secondRun.stdout)
    let secondResponse = try harness.decode(secondRun)
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    let secondAttempt = try XCTUnwrap(attempts.last)
    XCTAssertNotEqual(secondAttempt.id, firstAttempt.id)
    XCTAssertNotEqual(secondAttempt.sessionId, firstAttempt.sessionId)
    XCTAssertEqual(secondAttempt.entry, .rerunFromStep("repair"))
    XCTAssertEqual(secondResponse.sessionId, secondAttempt.sessionId)
    XCTAssertEqual(secondAttempt.state, .reconciled)
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
    let decisions = try harness.store.listDecisions(taskId: task.id)
    XCTAssertEqual(decisions.filter { $0.id == DecisionID("decision-rerun-1") }.count, 1)

    let replay = await RielaCLIApplication().run(decideArguments)
    XCTAssertEqual(replay.exitCode, .success, replay.stderr + replay.stdout)
    XCTAssertEqual(replay.stdout, decision.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try harness.store.listDecisions(taskId: task.id).count, decisions.count)
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
  }

  func testSecondRunStopsWhenEarlierDurableSessionExhaustsWallClockBudget() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.completion.requiresHumanAccept = true
    try harness.store.saveTask(task)

    let firstRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(firstRun.exitCode, .success, firstRun.stderr + firstRun.stdout)
    let firstAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).first)
    let runtimeStore = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
    var firstSnapshot = try runtimeStore.load(sessionId: firstAttempt.sessionId)
    firstSnapshot.session.createdAt = firstSnapshot.session.updatedAt.addingTimeInterval(-5)
    try runtimeStore.save(firstSnapshot)

    task = try XCTUnwrap(harness.store.loadTask(id: task.id))
    task.guardPolicy.budget = BudgetGuard(maxWallClockMs: 4_000)
    try harness.store.saveTask(task)
    let version = try XCTUnwrap(harness.store.loadTask(id: task.id)).version
    let decision = await RielaCLIApplication().run([
      "task", "decide", task.id.rawValue, "--rerun", "repair",
      "--principal", "operator", "--expected-version", String(version),
      "--decision-id", "decision-wall-clock-rerun", "--session-store", harness.sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(decision.exitCode, .success, decision.stderr + decision.stdout)

    let secondRun = try await harness.dispatch("task-repair-loop")
    XCTAssertEqual(secondRun.exitCode, .success, secondRun.stderr + secondRun.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 2)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .failed)
    let violations = try harness.store.listEvidence(taskId: task.id, kind: .guardViolation)
    XCTAssertTrue(violations.contains {
      $0.payloadRef.inlinePayload?["dimension"] == .string(BudgetDimension.wallClock.rawValue)
    })
  }

  func testCapacityWaitLeavesNoAttemptOrReservedSession() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")

    let result = try await harness.dispatch("task-repair-loop", capacity: 0)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let response = try harness.decode(result)
    XCTAssertEqual(response.status, "waiting")
    XCTAssertEqual(response.waitReason, .capacity)
    XCTAssertNil(response.attemptId)
    XCTAssertNil(response.sessionId)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
  }

  func testDryRunIncludesReachableCalleeBackendBeforeReservation() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let defaults = WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 1)
    let root = WorkflowDefinition(
      workflowId: "task-repair-loop",
      defaults: defaults,
      entryStepId: "call",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "root-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(
        id: "call", nodeId: "root-node",
        transitions: [WorkflowStepTransition(toStepId: "run", toWorkflowId: "child")]
      )],
      nodes: [WorkflowNodeRef(id: "root-node", nodeFile: "node.json")]
    )
    let child = WorkflowDefinition(
      workflowId: "child",
      defaults: defaults,
      entryStepId: "run",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "child-node", nodeFile: "node.json")],
      steps: [WorkflowStepRef(id: "run", nodeId: "child-node")],
      nodes: [WorkflowNodeRef(id: "child-node", nodeFile: "node.json")]
    )
    let resolver = TaskExampleBundleResolver(
      bundle: ResolvedWorkflowBundle(
        workflow: root,
        nodePayloads: ["root-node": AgentNodePayload(
          id: "root-node", executionBackend: .codexAgent, model: "gpt-5.4-mini", agentSandbox: .readOnly
        )],
        sourceScope: .project,
        workflowDirectory: "/tmp/root"
      ),
      callees: ["child": ResolvedWorkflowBundle(
        workflow: child,
        nodePayloads: ["child-node": AgentNodePayload(
          id: "child-node", executionBackend: .officialAnthropicSDK, model: "claude", agentSandbox: .readOnly
        )],
        sourceScope: .project,
        workflowDirectory: "/tmp/child"
      )]
    )
    let result = await TaskDispatch(
      resolver: resolver,
      hostResolver: TaskExampleHostResolver(capacity: 1),
      runner: WorkflowRunCommand(resolver: resolver)
    ).run(
      taskId: task.id.rawValue,
      options: TaskStoreOptions(
        scope: .project,
        workingDirectory: harness.repository.path,
        sessionStore: harness.sessionStore.path
      ),
      dryRun: true,
      output: .json
    )
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let response = try harness.decode(result)
    XCTAssertEqual(response.waitReason, .capacity)
    XCTAssertEqual(response.placement?.failures.first?.provenance.workflowId, "child")
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
  }

  func testDryRunReturnsPlacementWithoutAdvancingTask() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    try harness.store.saveHostSnapshot(HostCapabilitySnapshot(
      hostId: "recorded", backends: [], refreshedAt: Date()
    ))
    let beforeRows = try harness.rowCounts(taskId: task.id)
    let beforeBytes = try harness.fileBytes()

    let result = try await harness.dispatch("task-repair-loop", dryRun: true)
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let response = try harness.decode(result)
    XCTAssertEqual(response.status, "ready")
    XCTAssertTrue(response.placement?.complete == true)
    XCTAssertNil(response.attemptId)
    XCTAssertEqual(try harness.store.loadTask(id: task.id), task)
    XCTAssertTrue(try harness.store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeRows)
    XCTAssertEqual(try harness.fileBytes(), beforeBytes)
    XCTAssertEqual(beforeRows["work_hosts"], 1)
    XCTAssertNotNil(beforeBytes[harness.store.databasePath.replacingOccurrences(
      of: harness.sessionStore.path + "/", with: ""
    )])
  }

  func testDryRunOnAbsentStoreLeavesDatabaseAndSidecarsAbsent() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let taskId = TaskID("task-task-repair-loop")
    let beforeRows = try harness.rowCounts(taskId: taskId)
    let beforeBytes = try harness.fileBytes()

    let result = try await harness.dispatch("task-repair-loop", dryRun: true)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("not found"), result.stderr)
    XCTAssertEqual(try harness.rowCounts(taskId: taskId), beforeRows)
    XCTAssertEqual(try harness.fileBytes(), beforeBytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.databasePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.databasePath + "-wal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.databasePath + "-shm"))
  }

  func testDryRunWithCorruptProfilePreservesItsBytesAndStoreRows() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let profile = harness.sessionStore.appendingPathComponent("profile/daemon-workflows.json")
    try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("corrupt-profile".utf8).write(to: profile)
    let beforeRows = try harness.rowCounts(taskId: task.id)
    let beforeBytes = try harness.fileBytes()
    let resolver = HostCapabilityResolver(
      profileStore: RielaAppDaemonWorkflowStore(stateURL: profile),
      activeProfileStore: RielaAppProfileStore(appRootURL: harness.sessionStore)
    )

    let result = try await harness.dispatch("task-repair-loop", dryRun: true, hostResolver: resolver)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("invalidProfile"), result.stderr)
    XCTAssertEqual(try harness.rowCounts(taskId: task.id), beforeRows)
    XCTAssertEqual(try harness.fileBytes(), beforeBytes)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: RielaAppDaemonWorkflowStore.corruptStateQuarantineURL(for: profile).path
    ))
  }
}
