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

private actor TriggeringHandoverScenarioAdapter: NodeAdapter {
  enum Trigger {
    case waitSignal
    case immediate(WorkStore, TaskID)
    case cooperative(WorkStore, TaskID)
  }

  private let trigger: Trigger
  private var hasTriggered = false
  private var executedSteps: [String] = []

  init(trigger: Trigger) {
    self.trigger = trigger
  }

  func steps() -> [String] { executedSteps }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if let stepId = input.executionIdentity?.stepId { executedSteps.append(stepId) }
    if !hasTriggered {
      hasTriggered = true
      switch trigger {
      case .waitSignal:
        await context.backendEventHandler?(AdapterBackendEvent(
          provider: "codex-agent", eventType: "tool_call_update", channel: .tool,
          toolName: "calendar", metadata: ["status": .string("pending"), "title": .string("Approve calendar access")],
          at: Date()
        ))
        await Self.waitIgnoringCancellation(milliseconds: 1_000)
      case let .immediate(store, taskId):
        _ = try store.requestHandover(
          taskId: taskId, reason: "move now", immediate: true, target: nil, sinks: [], now: Date()
        )
        await Self.waitIgnoringCancellation(milliseconds: 1_000)
      case let .cooperative(store, taskId):
        _ = try store.requestHandover(
          taskId: taskId, reason: "move at boundary", immediate: false, target: nil, sinks: [], now: Date()
        )
      }
    }
    return AdapterExecutionOutput(
      provider: "test", model: "test", promptText: input.promptText,
      completionPassed: true, payload: ["ok": .bool(true)]
    )
  }

  private static func waitIgnoringCancellation(milliseconds: Int) async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
        continuation.resume()
      }
    }
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
    let root = try TaskHandoverHermeticGit.makeRoot("riela-wh14-nonrepo")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowId = "adopted-handover-fixture"
    let project = root.appendingPathComponent("adoption-project", isDirectory: true)
    let sessionId = "adopted-handover-session"
    try harness.writeSuspendedAdoptionFixture(project: project, workflowId: workflowId, sessionId: sessionId)
    // The fixture must not be inside any repository: neither with a ceiling above the temp root nor with the
    // plain process environment that production adoption effectively uses.
    let hermetic = try TaskHandoverHermeticGit.run(
      ["rev-parse", "--show-toplevel"], at: project,
      environment: TaskHandoverHermeticGit.environment(ceiling: root.deletingLastPathComponent())
    )
    XCTAssertNotEqual(hermetic.exitCode, 0, "project resolved a repository: \(hermetic.output)")
    let plain = try TaskHandoverHermeticGit.run(
      ["rev-parse", "--show-toplevel"], at: project, environment: ProcessInfo.processInfo.environment
    )
    XCTAssertNotEqual(plain.exitCode, 0, "project resolved a repository: \(plain.output)")

    let runtime = harness.adoptionRuntime(workflowId: workflowId, workingDirectory: project)
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
    XCTAssertNil(adopted.context)
    XCTAssertFalse(packet.deliverables.contains { value in
      if case .repository = value { return true }
      return false
    }, "\(packet.deliverables)")
  }

  func testAdoptionRefusesUnbornHead() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let root = try TaskHandoverHermeticGit.makeRoot("riela-wh14-unborn")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = TaskHandoverHermeticGit.environment(ceiling: root.deletingLastPathComponent())
    let repo = root.appendingPathComponent("repo", isDirectory: true)
    let initResult = try TaskHandoverHermeticGit.run(["init", repo.path], at: root, environment: environment)
    XCTAssertEqual(initResult.exitCode, 0, initResult.output)
    let topLevel = try TaskHandoverHermeticGit.run(["rev-parse", "--show-toplevel"], at: repo, environment: environment)
    XCTAssertEqual(topLevel.exitCode, 0, topLevel.output)
    let resolvedTopLevel = URL(fileURLWithPath: topLevel.output.trimmingCharacters(in: .whitespacesAndNewlines))
      .resolvingSymlinksInPath().path
    XCTAssertTrue(resolvedTopLevel.hasPrefix(root.path + "/"), "repository escaped the fixture root: \(resolvedTopLevel)")
    try "untracked".write(to: repo.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
    let workflowId = "adopted-unborn-fixture"
    let sessionId = "adopted-unborn-session"
    try harness.writeSuspendedAdoptionFixture(project: repo, workflowId: workflowId, sessionId: sessionId)
    let unbornHead = try TaskHandoverHermeticGit.run(["rev-parse", "--verify", "HEAD^{commit}"], at: repo, environment: environment)
    XCTAssertNotEqual(unbornHead.exitCode, 0, "HEAD must be unborn: \(unbornHead.output)")

    func snapshot() throws -> [String] {
      try [["status", "--porcelain=v1", "--untracked-files=all"], ["for-each-ref"]].map {
        let result = try TaskHandoverHermeticGit.run($0, at: repo, environment: environment)
        XCTAssertEqual(result.exitCode, 0, result.output)
        return result.output
      }
    }
    let before = try snapshot()
    XCTAssertTrue(before[0].contains("untracked.txt"), "\(before)")

    let runtime = harness.adoptionRuntime(workflowId: workflowId, workingDirectory: repo)
    do {
      _ = try await runtime.adoptAndSeal(
        sessionId: sessionId, workingDirectory: repo.path, reason: "move to a worker",
        principal: "test", cliSinks: []
      )
      XCTFail("expected an unborn HEAD to refuse adoption")
    } catch {
      XCTAssertTrue(
        String(describing: error).contains("session adoption refused: HEAD is not a commit"), "\(error)"
      )
    }
    XCTAssertNil(try harness.store.loadTask(id: TaskID("task-adopted-\(sessionId)")))
    XCTAssertEqual(try snapshot(), before)
  }

  func testAdoptedRepositorySessionIsReadOnlyAndTakesOverFromSecondClone() async throws {
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
    try repository.write("staged", to: "staged.txt")
    _ = try repository.git(["add", "--", "staged.txt"])
    try repository.write("untracked", to: "notes/untracked.txt")

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
    let branchBefore = try repository.git(["branch", "--show-current"])
    let headBefore = try repository.git(["rev-parse", "HEAD"])
    let statusBefore = try repository.git(["status", "--porcelain=v1", "--untracked-files=all"])
    let indexBefore = try Data(contentsOf: repository.clone.appendingPathComponent(".git/index"))
    let refsBefore = try repository.git(["for-each-ref", "--format=%(refname):%(objectname)"])
    let remoteRefsBefore = try repository.git(["ls-remote", "--heads", "origin"])
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
    XCTAssertEqual(repositoryDeliverable.state, .unpublished(lastKnown: headBefore))
    XCTAssertNil(repositoryDeliverable.headCommit)
    for path in ["README.md", "staged.txt", "notes/untracked.txt"] {
      XCTAssertTrue(repositoryDeliverable.dirtyPaths.contains(path), "\(path) missing from \(repositoryDeliverable.dirtyPaths)")
    }
    let branch = "riela/task/\(adopted.id.rawValue)/g\(try XCTUnwrap(harness.store.listAttempts(taskId: adopted.id).last?.generation))"
    XCTAssertEqual(repositoryDeliverable.branch, branch)
    let adoptedAttempt = try XCTUnwrap(harness.store.listAttempts(taskId: adopted.id).last)
    XCTAssertEqual(adoptedAttempt.isolation?.branch, branch)
    XCTAssertEqual(adoptedAttempt.isolation?.baseRevision, headBefore)
    XCTAssertEqual(try repository.git(["branch", "--show-current"]), branchBefore)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]), headBefore)
    XCTAssertEqual(try Data(contentsOf: repository.clone.appendingPathComponent(".git/index")), indexBefore)
    XCTAssertEqual(try repository.git(["status", "--porcelain=v1", "--untracked-files=all"]), statusBefore)
    XCTAssertEqual(try repository.git(["for-each-ref", "--format=%(refname):%(objectname)"]), refsBefore)
    XCTAssertEqual(try repository.git(["ls-remote", "--heads", "origin"]), remoteRefsBefore)

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
    // The successor never touched the adopted checkout.
    XCTAssertEqual(try repository.git(["branch", "--show-current"]), branchBefore)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"]), headBefore)
    XCTAssertEqual(try Data(contentsOf: repository.clone.appendingPathComponent(".git/index")), indexBefore)
    XCTAssertEqual(try repository.git(["status", "--porcelain=v1", "--untracked-files=all"]), statusBefore)
    XCTAssertEqual(try repository.git(["for-each-ref", "--format=%(refname):%(objectname)"]), refsBefore)
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"], at: successorRoot), headBefore)
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

  func testWaitSignalSealsPresenceHandoverExactlyOnce() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    var task = try harness.seed("task-repair-loop")
    task.guardPolicy = GuardPolicy(
      inactivity: InactivityGuard(
        stallTimeoutMs: 100, monitorIntervalMs: 50, heartbeatBackends: ["codex-agent"]
      ),
      onViolation: .askDirector,
      handover: HandoverPolicy(onWaitSignal: true)
    )
    try harness.store.saveTask(task)
    let adapter = TriggeringHandoverScenarioAdapter(trigger: .waitSignal)

    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)

    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let run = try harness.decode(result)
    let packets = try harness.store.listHandovers(taskId: task.id)
    let packet = try XCTUnwrap(packets.first)
    XCTAssertEqual(packets.count, 1)
    guard case let .userPresenceRequired(presence) = packet.reason else {
      return XCTFail("unexpected handover reason: \(packet.reason)")
    }
    XCTAssertEqual(presence.traits, [.interactive, .userReachable])
    XCTAssertTrue(presence.instructions.contains("Approve calendar access"))
    let predecessor = try XCTUnwrap(harness.store.loadAttempt(id: AttemptID(try XCTUnwrap(run.attemptId))))
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
    XCTAssertEqual(
      try runtime.requestTakeover(taskId: task.id, traits: presence.traits, producer: .human(principal: "test")).state,
      .scheduled
    )
    XCTAssertEqual(try harness.store.listHandovers(taskId: task.id).count, 1)
  }

  func testImmediateOperatorHandoverCancelsRunningAttemptAndSealsOnce() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let adapter = TriggeringHandoverScenarioAdapter(trigger: .immediate(harness.store, task.id))

    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)

    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let run = try harness.decode(result)
    let packets = try harness.store.listHandovers(taskId: task.id)
    XCTAssertEqual(packets.count, 1)
    guard case let .operatorMove(reason) = try XCTUnwrap(packets.first).reason else {
      return XCTFail("expected operatorMove, got \(try XCTUnwrap(packets.first).reason)")
    }
    XCTAssertEqual(reason, "move now")
    let predecessor = try XCTUnwrap(harness.store.loadAttempt(id: AttemptID(try XCTUnwrap(run.attemptId))))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: predecessor.sessionId)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
    XCTAssertEqual(snapshot.session.failureReason, "task handover trigger: cancelled")
    XCTAssertNil(try harness.store.pendingHandoverRequest(attemptId: predecessor.id))
    let cancellation = try harness.store.attemptCancellation(
      taskId: task.id, attemptId: predecessor.id, sessionId: predecessor.sessionId
    )
    XCTAssertTrue(cancellation == nil || cancellation?.acknowledged == true)
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
  }

  func testCooperativeOperatorHandoverSuspendsAtNextStepBoundary() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let task = try harness.seed("task-repair-loop")
    let adapter = TriggeringHandoverScenarioAdapter(trigger: .cooperative(harness.store, task.id))

    let result = try await harness.dispatch("task-repair-loop", nodeAdapter: adapter)

    XCTAssertEqual(result.exitCode, .suspended, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let run = try harness.decode(result)
    let packets = try harness.store.listHandovers(taskId: task.id)
    XCTAssertEqual(packets.count, 1)
    let packet = try XCTUnwrap(packets.first)
    guard case let .operatorMove(reason) = packet.reason else {
      return XCTFail("expected operatorMove, got \(packet.reason)")
    }
    XCTAssertEqual(reason, "move at boundary")
    XCTAssertEqual(packet.contract.resumeStepId, "verify")
    let predecessor = try XCTUnwrap(harness.store.loadAttempt(id: AttemptID(try XCTUnwrap(run.attemptId))))
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: harness.store.rootDirectory)
      .load(sessionId: predecessor.sessionId)
    XCTAssertEqual(snapshot.session.status, .suspended)
    XCTAssertEqual(snapshot.session.suspend?.reasonKind, .operatorMove)
    XCTAssertEqual(snapshot.session.suspend?.stepId, "verify")
    XCTAssertNil(try harness.store.pendingHandoverRequest(attemptId: predecessor.id))
    let executedSteps = await adapter.steps()
    XCTAssertEqual(executedSteps, ["repair"])
    XCTAssertEqual(try harness.store.loadTask(id: task.id)?.state, .waiting)
    _ = try harness.store.requestTakeover(
      taskId: task.id, placement: TakeoverPlacement(hostId: "local"),
      producer: .human(principal: "test"), decisionId: .generate(), now: Date()
    )
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
