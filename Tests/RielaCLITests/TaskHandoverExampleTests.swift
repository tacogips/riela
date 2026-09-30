import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private struct TaskHandoverExampleHostResolver: HostCapabilityResolving {
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
      capacity: 1,
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

final class TaskHandoverExampleTests: XCTestCase {
  func testAnswerExampleResumesAtApplyWithAnswerAndImportedPlan() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-handover-answer")
    let options = taskOptions(harness)
    let command = try taskDispatch(harness, name: "task-handover-answer")

    let suspendedResult = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(suspendedResult.exitCode, .suspended, "\(suspendedResult.stderr)\n\(suspendedResult.stdout)")
    let suspended = try harness.decode(suspendedResult)
    XCTAssertEqual(suspended.statusKind, .suspended)
    let handoverId = HandoverID(rawValue: try XCTUnwrap(suspended.handoverId))
    let packet = try XCTUnwrap(harness.store.loadHandover(id: handoverId))
    XCTAssertEqual(packet.digest, try packet.canonicalDigest())
    XCTAssertEqual(try harness.store.loadHandover(id: handoverId)?.digest, packet.digest)

    let currentTask = try XCTUnwrap(harness.store.loadTask(id: task.id))
    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: currentTask, store: harness.store, root: harness.store.rootDirectory),
      options: options
    )
    _ = try runtime.answer(
      taskId: task.id,
      questionId: "q-deploy-target",
      payload: ["option": .string("staging")],
      producer: .human(principal: "test")
    )

    let takeoverResult = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(takeoverResult.exitCode, .success, "\(takeoverResult.stderr)\n\(takeoverResult.stdout)")
    let successor = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).last)
    XCTAssertEqual(successor.entry, .takeover(fromAttemptId: packet.fromAttemptId, handoverId: handoverId))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: successor.sessionId)
    XCTAssertTrue(snapshot.session.executions.contains {
      $0.stepId == "plan" && $0.importedFrom?.handoverId == handoverId.rawValue
    })
    let applyExecutions = snapshot.session.executions.filter { $0.stepId == "apply" }
    XCTAssertTrue(applyExecutions.contains { execution in
      guard execution.stepId == "apply",
            case let .object(arguments)? = execution.inputSnapshot?["arguments"],
            case let .object(delivered)? = arguments["delivered"],
            case let .object(handover)? = delivered["handover"],
            case let .object(answer)? = handover["answer"] else { return false }
      return answer["option"] == .string("staging")
    }, "apply execution must receive the handover answer")
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
  }

  func testPresenceExampleRequiresUserReachableTraitThenCompletes() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-handover-presence")
    let options = taskOptions(harness)
    let command = try taskDispatch(harness, name: "task-handover-presence")

    let suspendedResult = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(suspendedResult.exitCode, .suspended, "\(suspendedResult.stderr)\n\(suspendedResult.stdout)")
    let suspended = try harness.decode(suspendedResult)
    XCTAssertEqual(suspended.statusKind, .suspended)
    XCTAssertNotNil(suspended.handoverId)

    let currentTask = try XCTUnwrap(harness.store.loadTask(id: task.id))
    let runtime = TaskHandoverRuntime(
      located: TaskCommandRunner.LocatedTask(task: currentTask, store: harness.store, root: harness.store.rootDirectory),
      options: options
    )
    _ = try runtime.requestTakeover(
      taskId: task.id, traits: [], producer: .human(principal: "test")
    )
    let refused = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false, output: .json, localTraits: []
    )
    XCTAssertEqual(refused.exitCode, .success, "\(refused.stderr)\n\(refused.stdout)")
    let refusedResult = try harness.decode(refused)
    XCTAssertEqual(refusedResult.statusKind, .waiting)
    XCTAssertTrue(refused.stdout.contains("host-traits-unavailable: userReachable"), refused.stdout)
    XCTAssertEqual(try harness.store.listAttempts(taskId: task.id).count, 1)

    let takeover = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false,
      output: .json, localTraits: [.userReachable]
    )
    XCTAssertEqual(takeover.exitCode, .success, "\(takeover.stderr)\n\(takeover.stdout)")
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
    let successor = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).last)
    guard case .takeover = successor.entry else { return XCTFail("expected a takeover entry") }
  }

  func testOrphanExampleFencesNeverLaunchedOwner() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-handover-orphan")
    task.guardPolicy.lease = LeasePolicy(ttlMs: 1_000, heartbeatMs: 500)
    try harness.store.saveTask(task)
    let options = taskOptions(harness)
    let command = try taskDispatch(harness, name: "task-handover-orphan")

    var interruptedCommand = command
    interruptedCommand.beforeExecution = { _ in
      throw WorkStoreError("simulated owner stopped before launch")
    }
    let interrupted = await interruptedCommand.run(
      taskId: task.id.rawValue,
      options: options,
      dryRun: false,
      output: .json
    )
    XCTAssertEqual(interrupted.exitCode, .failure)
    let predecessor = try XCTUnwrap(harness.store.listAttempts(taskId: task.id).last)
    let lease = try XCTUnwrap(harness.store.loadLease(attemptId: predecessor.id))
    let predecessorFence = lease.fence
    XCTAssertEqual(predecessor.state, .prepared)

    task = try XCTUnwrap(harness.store.loadTask(id: task.id))
    let located = TaskCommandRunner.LocatedTask(task: task, store: harness.store, root: harness.store.rootDirectory)
    let earlyRuntime = TaskHandoverRuntime(located: located, options: options, now: {
      lease.expiresAt.addingTimeInterval(-0.001)
    })
    do {
      _ = try await earlyRuntime.forceOrphan(
        taskId: task.id, producer: .policy(rule: "wh-17-example"), cliSinks: []
      )
      XCTFail("force-orphan must refuse before lease expiry")
    } catch {
      XCTAssertTrue(String(describing: error).contains("has not expired"), "\(error)")
    }

    let runtime = TaskHandoverRuntime(located: located, options: options, now: {
      lease.expiresAt.addingTimeInterval(1)
    })
    let packet = try await runtime.forceOrphan(
      taskId: task.id, producer: .policy(rule: "wh-17-example"), cliSinks: []
    )
    guard case .ownerLost = packet.reason else { return XCTFail("expected ownerLost packet: \(packet.reason)") }
    XCTAssertEqual(packet.digest, try packet.canonicalDigest())
    XCTAssertEqual(try harness.store.loadHandover(id: packet.id)?.digest, packet.digest)
    let fenced = try XCTUnwrap(harness.store.loadAttempt(id: predecessor.id))
    XCTAssertEqual(fenced.state, .reconciled)
    XCTAssertEqual(fenced.outcome?.failureKind, .leaseLost)
    XCTAssertNotNil(fenced.supersededByFence)
    let takeover = await command.run(
      taskId: task.id.rawValue, options: options, dryRun: false, output: .json
    )
    XCTAssertEqual(takeover.exitCode, .success, "\(takeover.stderr)\n\(takeover.stdout)")
    XCTAssertFalse(try harness.store.heartbeat(
      attemptId: predecessor.id, fence: predecessorFence,
      now: lease.expiresAt.addingTimeInterval(2), ttlMs: 1_000
    ))
    let attempts = try harness.store.listAttempts(taskId: task.id)
    XCTAssertEqual(attempts.count, 2)
    XCTAssertEqual(attempts[1].entry, .takeover(fromAttemptId: predecessor.id, handoverId: packet.id))
    XCTAssertEqual(attempts[1].takeoverLineage?.fromAttemptId, predecessor.id)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .succeeded)
  }

  private func taskOptions(_ harness: TaskExampleHarness) -> TaskStoreOptions {
    TaskStoreOptions(
      scope: .project,
      workingDirectory: harness.repository.path,
      sessionStore: harness.sessionStore.path
    )
  }

  private func taskDispatch(_ harness: TaskExampleHarness, name: String) throws -> TaskDispatch {
    let bundle = try harness.bundle(name)
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    return TaskDispatch(
      resolver: resolver,
      hostResolver: TaskHandoverExampleHostResolver(),
      runner: WorkflowRunCommand(resolver: resolver),
      mockScenarioPath: harness.examples.appendingPathComponent(name)
        .appendingPathComponent("mock-scenario.json").path
    )
  }
}
