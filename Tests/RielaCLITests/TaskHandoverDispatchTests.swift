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
