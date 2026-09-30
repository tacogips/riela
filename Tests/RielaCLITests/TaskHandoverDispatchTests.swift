import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

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
