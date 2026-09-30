import Foundation
import RielaAdapters
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private actor StallingHandoverScenarioAdapter: NodeAdapter {
  let scenario: ScenarioNodeAdapter

  init(scenarioPath: String) throws {
    scenario = ScenarioNodeAdapter(scenario: try WorkflowMockScenarioLoader().loadScenario(at: scenarioPath))
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try await Task.sleep(for: .milliseconds(500))
    return try await scenario.execute(input, context: context)
  }
}

private struct HandoverTraitHostResolver: HostCapabilityResolving {
  var traits: [HostTrait] = []

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [HostCapabilitySnapshot(hostId: "local", capacity: 1, backends: [], refreshedAt: Date(), traits: traits)]
  }
}

final class TaskHandoverDispatchTests: XCTestCase {
  func testAdoptAndSealCreatesOperatorMovePacket() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let workflowId = "adopted-handover-fixture"
    let project = harness.sessionStore.appendingPathComponent("adoption-project", isDirectory: true)
    let workflowDirectory = project.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try "gitdir: \(project.appendingPathComponent("missing-git-dir").path)\n"
      .write(to: project.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    let workflow: [String: Any] = [
      "workflowId": workflowId,
      "defaults": ["nodeTimeoutMs": 2_000, "maxLoopIterations": 1],
      "entryStepId": "start",
      "nodes": [["id": "node", "nodeFile": "node.json"]],
      "steps": [
        ["id": "start", "nodeId": "node", "transitions": [["toStepId": "resume"]]],
        ["id": "resume", "nodeId": "node"]
      ]
    ]
    let node: [String: Any] = [
      "id": "node", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/usr/bin/true", "arguments": []]
    ]
    try JSONSerialization.data(withJSONObject: workflow, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("node.json"))

    let sessionId = "adopted-handover-session"
    let now = Date()
    let session = WorkflowSession(
      workflowId: workflowId, sessionId: sessionId, status: .suspended,
      entryStepId: "start", currentStepId: "resume", createdAt: now, updatedAt: now,
      suspend: SuspendRecord(
        reasonKind: .operatorMove, stepId: "resume", progressNote: "Resume adopted work",
        suspendedAt: now, producer: .runtime
      )
    )
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: harness.sessionStore.path)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).save(
      WorkflowRuntimePersistenceSnapshot(session: session)
    )
    let placeholder = WorkTask(
      id: TaskID("task-adoption-placeholder"), intentId: IntentID("intent-adoption-placeholder"),
      title: "Adoption runtime", instruction: "unused", plan: .workflow(WorkflowReference(name: workflowId))
    )
    let options = TaskStoreOptions(
      scope: .project, workingDirectory: project.path, sessionStore: harness.sessionStore.path
    )
    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: placeholder, store: harness.store, root: harness.store.rootDirectory),
      options: options
    )
    let (adopted, packet) = try await runtime.adoptAndSeal(
      sessionId: sessionId, workingDirectory: project.path, reason: "move to a worker",
      principal: "test", cliSinks: []
    )
    guard case let .operatorMove(reason) = packet.reason else {
      return XCTFail("expected operatorMove packet, got \(packet.reason)")
    }
    XCTAssertEqual(reason, "move to a worker")
    XCTAssertEqual(packet.contract.resumeStepId, "resume")
    XCTAssertEqual(try harness.store.loadTask(id: adopted.id)?.state, .waiting)
    XCTAssertEqual(try harness.store.loadHandover(id: packet.id)?.digest, packet.digest)
    XCTAssertEqual(try harness.store.listAttempts(taskId: adopted.id).last?.sessionId, sessionId)
  }

  func testAdoptedRepositorySessionPublishesAndTakesOverFromSecondClone() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let repository = try TaskHandoverRepositoryFixture()
    defer { repository.remove() }
    let workflowId = "adopted-repository-handover-fixture"
    let workflowDirectory = repository.clone.appendingPathComponent(".riela/workflows/\(workflowId)", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let workflowJSON: [String: Any] = [
      "workflowId": workflowId,
      "defaults": ["nodeTimeoutMs": 2_000, "maxLoopIterations": 1],
      "entryStepId": "start",
      "nodes": [["id": "node", "nodeFile": "node.json"]],
      "steps": [
        ["id": "start", "nodeId": "node", "transitions": [["toStepId": "resume"]]],
        ["id": "resume", "nodeId": "node"]
      ]
    ]
    let nodeJSON: [String: Any] = [
      "id": "node", "nodeType": "command", "model": "", "modelFreeze": false,
      "command": ["executable": "/usr/bin/true", "arguments": []]
    ]
    try JSONSerialization.data(withJSONObject: workflowJSON, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("workflow.json"))
    try JSONSerialization.data(withJSONObject: nodeJSON, options: [.sortedKeys])
      .write(to: workflowDirectory.appendingPathComponent("node.json"))
    try repository.write("dirty adoption change", to: "README.md")

    let sessionId = "adopted-repository-session"
    let now = Date()
    let session = WorkflowSession(
      workflowId: workflowId, sessionId: sessionId, status: .suspended,
      entryStepId: "start", currentStepId: "resume", createdAt: now, updatedAt: now,
      suspend: SuspendRecord(
        reasonKind: .operatorMove, stepId: "resume", progressNote: "Move this repository task",
        suspendedAt: now, producer: .runtime
      )
    )
    let runtimeRoot = canonicalRuntimeStoreRoot(sessionStoreRoot: harness.sessionStore.path)
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot).save(
      WorkflowRuntimePersistenceSnapshot(session: session)
    )
    let placeholder = WorkTask(
      id: TaskID("adopted-repository-placeholder"), intentId: IntentID("adopted-repository-placeholder"),
      title: "Adoption runtime", instruction: "unused", plan: .workflow(WorkflowReference(name: workflowId))
    )
    let options = TaskStoreOptions(
      scope: .project, workingDirectory: repository.clone.path, sessionStore: harness.sessionStore.path
    )
    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: placeholder, store: harness.store, root: harness.store.rootDirectory),
      options: options
    )
    let refusedBranch = "riela/task/task-adopted-\(sessionId)/g1"
    _ = try repository.git(["branch", refusedBranch])
    do {
      _ = try await runtime.adoptAndSeal(
        sessionId: sessionId, workingDirectory: repository.clone.path, reason: "move to second clone",
        principal: "test", cliSinks: []
      )
      XCTFail("expected existing target branch to refuse adoption")
    } catch {
      XCTAssertTrue(String(describing: error).contains("session adoption refused"))
    }
    XCTAssertNil(try harness.store.loadTask(id: TaskID("task-adopted-\(sessionId)")))
    _ = try repository.git(["branch", "-D", refusedBranch])
    let (adopted, packet) = try await runtime.adoptAndSeal(
      sessionId: sessionId, workingDirectory: repository.clone.path, reason: "move to second clone",
      principal: "test", cliSinks: []
    )
    let repositoryDeliverable = try XCTUnwrap(packet.deliverables.compactMap { value -> RepositoryDeliverable? in
      if case let .repository(item) = value { return item }
      return nil
    }.first)
    XCTAssertEqual(repositoryDeliverable.state, .published)
    let branch = "riela/task/\(adopted.id.rawValue)/g\(try XCTUnwrap(harness.store.listAttempts(taskId: adopted.id).last?.generation))"
    XCTAssertEqual(repositoryDeliverable.branch, branch)
    let adoptedAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: adopted.id).last)
    XCTAssertEqual(adoptedAttempt.isolation?.branch, branch)
    XCTAssertEqual(try repository.git(["show", "\(repositoryDeliverable.headCommit ?? ""):README.md"])
      .trimmingCharacters(in: .whitespacesAndNewlines), "dirty adoption change")

    _ = try runtime.requestTakeover(taskId: adopted.id, traits: [], producer: .human(principal: "test"))
    let successorRoot = try repository.secondClone()
    let workflow = WorkflowDefinition(
      workflowId: workflowId,
      defaults: .init(nodeTimeoutMs: 2_000, maxLoopIterations: 1),
      entryStepId: "start",
      nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [.init(id: "start", nodeId: "node", transitions: [.init(toStepId: "resume")]), .init(id: "resume", nodeId: "node")],
      nodes: [.init(id: "node", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["node": .init(
        id: "node", nodeType: .command, model: "", command: .init(executable: "/usr/bin/true", arguments: [])
      )],
      sourceScope: .project, workflowDirectory: repository.clone.path
    )
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    let dispatch = TaskDispatch(
      resolver: resolver, hostResolver: TaskHandoverTestHostResolver(), runner: WorkflowRunCommand(resolver: resolver)
    )
    let takeoverOptions = TaskStoreOptions(
      scope: .project, workingDirectory: successorRoot.path, sessionStore: harness.sessionStore.path
    )
    let result = await dispatch.run(taskId: adopted.id.rawValue, options: takeoverOptions, dryRun: false, output: .json)
    XCTAssertEqual(result.exitCode, .success, "stderr: \(result.stderr); stdout: \(result.stdout)")
    XCTAssertEqual(try harness.store.loadTask(id: adopted.id)?.state, .succeeded)
  }

  func testEnvelopeSealsThenAnswerTakeoverImportsHistoryAndCompletes() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let workflowId = "handover-answer-fixture"
    let taskId = TaskID("task-handover-answer-fixture")
    let task = WorkTask(
      id: taskId, intentId: IntentID("intent-handover-answer-fixture"), title: "Answer handover",
      instruction: "Ask then resume", plan: .workflow(WorkflowReference(
        name: workflowId, scope: WorkflowScope.project.rawValue
      )), state: .ready
    )
    try harness.store.saveTask(task)
    let bundle = harness.handoverEnvelopeBundle(workflowId: workflowId)
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    let command = TaskDispatch(
      resolver: resolver, hostResolver: TaskHandoverTestHostResolver(),
      runner: WorkflowRunCommand(resolver: resolver)
    )
    let options = TaskStoreOptions(
      scope: .project, workingDirectory: harness.repository.path,
      sessionStore: harness.sessionStore.path
    )

    let suspendedResult = await command.run(
      taskId: taskId.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(
      suspendedResult.exitCode, .suspended,
      "stderr: \(suspendedResult.stderr); stdout: \(suspendedResult.stdout)"
    )
    let suspended = try harness.decode(suspendedResult)
    XCTAssertEqual(suspended.statusKind, .suspended)
    let handoverId = HandoverID(rawValue: try XCTUnwrap(suspended.handoverId))
    let packet = try XCTUnwrap(harness.store.loadHandover(id: handoverId))
    XCTAssertEqual(packet.digest, try packet.canonicalDigest())
    XCTAssertEqual(try harness.store.loadTask(id: taskId)?.state, .waiting)
    let predecessor = try XCTUnwrap(harness.store.loadAttempt(id: AttemptID(try XCTUnwrap(suspended.attemptId))))
    XCTAssertEqual(predecessor.state, .reconciled)
    XCTAssertNil(try harness.store.loadLease(attemptId: predecessor.id))

    let located = TaskCommandRunner.LocatedTask(task: task, store: harness.store, root: harness.store.rootDirectory)
    let handoverRuntime = TaskHandoverRuntime(located: located, options: options)
    _ = try handoverRuntime.answer(
      taskId: taskId, questionId: "q1", payload: ["choice": .string("A")],
      producer: .human(principal: "test")
    )
    let takeoverResult = await command.run(
      taskId: taskId.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(
      takeoverResult.exitCode, .success,
      "stderr: \(takeoverResult.stderr); stdout: \(takeoverResult.stdout)"
    )
    let successor = try XCTUnwrap(harness.store.listAttempts(taskId: taskId).last)
    XCTAssertEqual(successor.entry, .takeover(fromAttemptId: predecessor.id, handoverId: handoverId))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: successor.sessionId)
    XCTAssertTrue(snapshot.session.executions.contains(where: {
      $0.stepId == "prelude" && $0.importedFrom?.handoverId == handoverId.rawValue
    }))
    XCTAssertEqual(successor.takeoverLineage?.handoverId, handoverId)
    XCTAssertEqual(successor.takeoverLineage?.hops, 1)
    XCTAssertTrue(snapshot.workflowMessages.contains(where: { message in
      guard case let .object(handover)? = message.payload["handover"],
            case let .object(answer)? = handover["answer"] else { return false }
      return message.toStepId == "resume" && answer["choice"] == .string("A")
    }), "persisted messages: \(snapshot.workflowMessages)")
    XCTAssertTrue(snapshot.session.executions.contains(where: { execution in
      guard execution.stepId == "resume",
            case let .object(variables)? = execution.inputSnapshot?["variables"],
            case let .object(delivered)? = variables["delivered"],
            case let .object(handover)? = delivered["handover"],
            case let .object(answer)? = handover["answer"] else { return false }
      return answer["choice"] == .string("A")
    }))
    XCTAssertEqual(try harness.store.loadTask(id: taskId)?.state, .succeeded)
  }

  func testDirectorInactivityHandoverAcknowledgesCancellationAndAcceptsTakeover() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 100, monitorIntervalMs: 50, heartbeatBackends: ["codex-agent"]
      ),
      onViolation: .askDirector,
      handover: HandoverPolicy()
    )
    task.director.deterministic.handoverOnInactivity = true
    try harness.store.saveTask(task)

    let scenarioPath = harness.examples.appendingPathComponent("task-repair-loop/mock-scenario.json").path
    let adapter = try StallingHandoverScenarioAdapter(scenarioPath: scenarioPath)
    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)
    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let run = try harness.decode(result)
    let predecessor = try XCTUnwrap(harness.store.loadAttempt(id: AttemptID(try XCTUnwrap(run.attemptId))))
    let packets = try harness.store.listHandovers(taskId: task.id)
    let packet = try XCTUnwrap(packets.first)
    guard case .inactivity = packet.reason else { return XCTFail("unexpected handover reason: \(packet.reason)") }
    XCTAssertEqual(packets.count, 1)
    XCTAssertEqual(predecessor.outcome?.failureKind, .stalled)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: predecessor.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .stalled)
    XCTAssertEqual(snapshot.session.failureReason, "task handover trigger: stalled")
    let cancellation = try harness.store.attemptCancellation(
      taskId: task.id, attemptId: predecessor.id, sessionId: predecessor.sessionId
    )
    XCTAssertTrue(cancellation == nil || cancellation?.acknowledged == true)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)

    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: task, store: harness.store, root: harness.store.rootDirectory),
      options: TaskStoreOptions(
        scope: .project, workingDirectory: harness.repository.path, sessionStore: harness.sessionStore.path
      )
    )
    let scheduled = try runtime.requestTakeover(
      taskId: task.id, traits: [], producer: .human(principal: "test")
    )
    XCTAssertEqual(scheduled.state, .scheduled)
    let pending = try XCTUnwrap(TaskDispatcher(store: harness.store).pendingReservation(taskId: task.id))
    XCTAssertEqual(pending.entry, .takeover(fromAttemptId: predecessor.id, handoverId: packet.id))
  }

  func testPresenceTakeoverRequiresTraitsWithoutBackendRequirements() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/work-handover/wh-14-task-dispatch-runtime/trait-placement-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let workflowId = "task-handover-trait-test"
    let workflow = WorkflowDefinition(
      workflowId: workflowId,
      defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "resume",
      nodeRegistry: [.init(id: "node", nodeFile: "node.json")],
      steps: [.init(id: "resume", nodeId: "node")],
      nodes: [.init(id: "node", nodeFile: "node.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["node": .init(
        id: "node", nodeType: .command, model: "",
        command: .init(executable: "/usr/bin/true", arguments: [])
      )],
      sourceScope: .project, workflowDirectory: root.path
    )
    let taskId = TaskID("task-handover-trait-test")
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: root.path))
    try store.saveTask(WorkTask(
      id: taskId, intentId: IntentID("intent-handover-trait-test"), title: "Trait takeover",
      instruction: "Resume the task", plan: .workflow(WorkflowReference(
        name: workflowId, scope: WorkflowScope.project.rawValue
      )), state: .ready
    ))
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    let packet = try presencePacket(taskId: taskId, workflowId: workflowId)
    let command = TaskDispatch(
      resolver: resolver, hostResolver: HandoverTraitHostResolver(), runner: WorkflowRunCommand(resolver: resolver)
    )
    let options = TaskStoreOptions(scope: .project, workingDirectory: root.path, sessionStore: root.path)
    let refused = try await command.prepareDispatchPlan(
      taskId: taskId, task: XCTUnwrap(store.loadTask(id: taskId)), options: options,
      store: store, localTraits: [], packetOverride: packet
    )
    XCTAssertEqual(refused.placement.failures.first?.reason, "host-traits-unavailable: userReachable")
    XCTAssertTrue(try store.listAttempts(taskId: taskId).isEmpty)

    let capable = TaskDispatch(
      resolver: resolver, hostResolver: HandoverTraitHostResolver(), runner: WorkflowRunCommand(resolver: resolver)
    )
    let admitted = try await capable.prepareDispatchPlan(
      taskId: taskId, task: XCTUnwrap(store.loadTask(id: taskId)), options: options,
      store: store, localTraits: [.userReachable], packetOverride: packet
    )
    XCTAssertTrue(admitted.placement.complete)
    XCTAssertTrue(try store.listAttempts(taskId: taskId).isEmpty)
  }

  private func presencePacket(taskId: TaskID, workflowId: String) throws -> HandoverPacket {
    try HandoverPacket(
      id: HandoverID(rawValue: "handover-trait-test"), taskId: taskId,
      intentId: IntentID("intent-handover-trait-test"), fromAttemptId: AttemptID("attempt-old"),
      fromSessionId: "session-old", generation: 1,
      reason: .userPresenceRequired(PresenceRequirement(traits: [.userReachable], instructions: "Use a reachable host")),
      workflow: HandoverWorkflowRef(workflowId: workflowId, entryStepId: "resume", resumeStepId: "resume"),
      progress: HandoverProgress(
        acceptedSteps: [], remainingSteps: ["resume"], latestGateResults: [], openFindings: [],
        evidenceSummary: [:], remainingBudget: BudgetSnapshot(
          attemptsUsed: 0, tokensUsed: 0, wallClockMsUsed: 0
        )
      ),
      history: HandoverHistoryBundle(executions: [], messages: [], compatibilityDigests: [:], truncated: false),
      contract: HandoverContinuationContract(
        resumeStepId: "resume", completion: CompletionContract(), verification: [], guardPolicy: GuardPolicy()
      ), brief: "Presence takeover", producedBy: .runtime, producedOn: "test", createdAt: Date()
    ).sealed()
  }
}
