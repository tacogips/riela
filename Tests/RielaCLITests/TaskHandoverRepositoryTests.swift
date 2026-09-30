import Foundation
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private actor CheckpointRecordingWorkspace: WorkspaceHandoverRuntime {
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var trailers: [String] = []

  func ensureBranch(
    root: String, attempt: AttemptID, task: TaskID, generation: Int, base: String?,
    isolation: RepositoryIsolation, template: String
  ) async throws -> IsolationRef { throw WorkStoreError("unused") }

  func checkpoint(_ isolation: IsolationRef, message: String, trailer: String, paths: [String]?) async throws -> String? {
    active += 1
    maximumActive = max(maximumActive, active)
    trailers.append(trailer)
    try await Task.sleep(for: .milliseconds(20))
    active -= 1
    return "commit"
  }

  func publish(_ isolation: IsolationRef, remote: String, allowCreate: Bool, branchAllowlist: String) async throws -> PublishedBranch {
    throw WorkStoreError("unused")
  }

  func materialize(_ deliverable: RepositoryDeliverable, into root: String, worktree: Bool, attempt: AttemptID) async throws -> IsolationRef {
    throw WorkStoreError("unused")
  }

  func dirtyPaths(_ isolation: IsolationRef) async throws -> [String] { [] }
}

final class TaskHandoverRepositoryTests: XCTestCase {
  func testEveryMsCheckpointTimerCreatesRealCommitTrailer() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let repository = try TaskHandoverRepositoryFixture()
    defer { repository.remove() }
    let workflowId = "handover-timer-checkpoint-fixture"
    let workflow = WorkflowDefinition(
      workflowId: workflowId,
      defaults: .init(nodeTimeoutMs: 5_000, maxLoopIterations: 1),
      entryStepId: "work",
      nodeRegistry: [.init(id: "work", nodeFile: "work.json")],
      steps: [.init(id: "work", nodeId: "work")],
      nodes: [.init(id: "work", nodeFile: "work.json")]
    )
    let bundle = ResolvedWorkflowBundle(
      workflow: workflow,
      nodePayloads: ["work": .init(
        id: "work", nodeType: .command, model: "",
        command: .init(executable: "/bin/sh", arguments: ["-c", "echo timer > timer.txt; sleep 0.8"])
      )],
      sourceScope: .project, workflowDirectory: repository.clone.path
    )
    let taskId = TaskID("task-every-ms-checkpoint")
    var task = WorkTask(
      id: taskId, intentId: IntentID("intent-every-ms-checkpoint"), title: "Timer checkpoint",
      instruction: "Checkpoint the writing step", plan: .workflow(WorkflowReference(name: workflowId)),
      context: .repository(RepositoryContext(root: repository.clone.path, baseRevision: repository.baseRevision)),
      state: .ready
    )
    task.guardPolicy.handover = HandoverPolicy(checkpoint: .everyMs(50))
    try harness.store.saveTask(task)
    let resolver = TaskExampleBundleResolver(bundle: bundle)
    let dispatch = TaskDispatch(
      resolver: resolver, hostResolver: TaskHandoverTestHostResolver(), runner: WorkflowRunCommand(resolver: resolver)
    )
    let options = TaskStoreOptions(
      scope: .project, workingDirectory: repository.clone.path, sessionStore: harness.sessionStore.path
    )

    let result = await dispatch.run(taskId: taskId.rawValue, options: options, dryRun: false, output: .json)
    XCTAssertEqual(result.exitCode, .success, "stderr: \(result.stderr); stdout: \(result.stdout)")
    let attempt = try XCTUnwrap(harness.store.listAttempts(taskId: taskId).last)
    let trailers = try repository.git(["log", "--format=%B", "--all"])
    XCTAssertTrue(trailers.contains("Riela-Checkpoint: \(attempt.id.rawValue)/timer-"), trailers)
  }

  func testRepositoryBranchCheckpointPublishAndSecondCloneMaterialization() async throws {
    let repository = try TaskHandoverRepositoryFixture()
    defer { repository.remove() }
    let workspace = GitBranchWorkspaceRuntime()
    let taskId = TaskID("repository-handover-test")
    let attemptId = AttemptID("attempt-repository-handover")
    let isolation = try await workspace.ensureBranch(
      root: repository.clone.path, attempt: attemptId, task: taskId, generation: 1,
      base: repository.baseRevision, isolation: .shared,
      template: "riela/task/{taskId}/g{generation}"
    )
    XCTAssertEqual(try repository.git(["branch", "--show-current"]), "riela/task/repository-handover-test/g1")
    try repository.write("handover change", to: "work.txt")
    let checkpoint = try await workspace.checkpoint(
      isolation, message: "task checkpoint", trailer: "Riela-Checkpoint: \(attemptId.rawValue)/step-1", paths: nil
    )
    let head = try XCTUnwrap(checkpoint)
    XCTAssertTrue(try repository.git(["show", "-s", "--format=%B", head]).contains(
      "Riela-Checkpoint: \(attemptId.rawValue)/step-1"
    ))
    let published = try await workspace.publish(
      isolation, remote: "origin", allowCreate: true, branchAllowlist: "riela/task/*"
    )
    XCTAssertEqual(published.sha, head)
    XCTAssertTrue(try repository.git(["ls-remote", "--heads", "origin", published.branch]).contains(head))

    let successorRoot = try repository.secondClone()
    let deliverable = RepositoryDeliverable(
      root: repository.clone.path, remote: "origin", branch: published.branch,
      baseRevision: repository.baseRevision, headCommit: published.sha, state: .published
    )
    let materialized = try await workspace.materialize(
      deliverable, into: successorRoot.path, worktree: false, attempt: AttemptID("attempt-successor")
    )
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"], at: URL(fileURLWithPath: materialized.path)), head)
    XCTAssertEqual(try repository.git(["branch", "--show-current"], at: URL(fileURLWithPath: materialized.path)), published.branch)
  }

  func testFencedLiveOwnerCannotPublishRepositoryBranch() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let repository = try TaskHandoverRepositoryFixture()
    defer { repository.remove() }
    let workflow = WorkflowDefinition(
      workflowId: "fenced-publisher-fixture", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "work", nodeRegistry: [.init(id: "work", nodeFile: "work.json")],
      steps: [.init(id: "work", nodeId: "work")], nodes: [.init(id: "work", nodeFile: "work.json")]
    )
    let taskId = TaskID("task-fenced-publisher")
    let task = WorkTask(
      id: taskId, intentId: IntentID("intent-fenced-publisher"), title: "Fenced publisher",
      instruction: "Do not publish", plan: .workflow(WorkflowReference(name: workflow.workflowId)),
      context: .repository(RepositoryContext(root: repository.clone.path, baseRevision: repository.baseRevision)),
      state: .ready
    )
    try harness.store.saveTask(task)
    let reserved = try harness.store.reserveAttempt(AttemptReservationRequest(
      taskId: taskId, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-fenced-publisher"),
      sessionId: "session-fenced-publisher", workflowId: workflow.workflowId, entryStepId: "work",
      entry: .start, decisionId: DecisionID("decision-fenced-publisher"),
      producer: .policy(rule: "test"), reason: "test", now: Date()
    ))
    let isolation = try await GitBranchWorkspaceRuntime().ensureBranch(
      root: repository.clone.path, attempt: reserved.attempt.id, task: taskId,
      generation: reserved.attempt.generation, base: repository.baseRevision,
      isolation: .shared, template: "riela/task/{taskId}/g{generation}"
    )
    XCTAssertTrue(try harness.store.updateAttemptIsolation(attemptId: reserved.attempt.id, isolation: isolation))
    var attempt = reserved.attempt
    attempt.isolation = isolation
    try repository.write("must not publish", to: "fenced.txt")
    let deliverables = await TaskDeliverablePublisher(
      store: harness.store, reservationFence: 0, workflow: workflow, nodePayloads: [:]
    ).publish(task: reserved.task, attempt: attempt, snapshot: WorkflowRuntimePersistenceSnapshot(
      session: WorkflowSession(
        workflowId: workflow.workflowId, sessionId: reserved.attempt.sessionId, status: .running,
        entryStepId: "work", createdAt: Date(), updatedAt: Date()
      )
    ), ownerAlive: true)
    guard case let .repository(deliverable)? = deliverables.first else {
      return XCTFail("expected repository deliverable")
    }
    guard case let .checkpointFailed(reason) = deliverable.state else {
      return XCTFail("expected fenced publication refusal")
    }
    XCTAssertEqual(reason, "fenced")
    XCTAssertTrue(try repository.git(["ls-remote", "--heads", "origin", "riela/task/*"]).isEmpty)
  }

  func testOrphanedWorktreeIsUnpublishedAndMaterializesFromSecondClone() async throws {
    let harness = try TaskExampleHarness()
    defer { harness.remove() }
    let repository = try TaskHandoverRepositoryFixture()
    defer { repository.remove() }
    let workflow = WorkflowDefinition(
      workflowId: "orphan-worktree-fixture", defaults: .init(nodeTimeoutMs: 1_000, maxLoopIterations: 1),
      entryStepId: "work", nodeRegistry: [.init(id: "work", nodeFile: "work.json")],
      steps: [.init(id: "work", nodeId: "work")], nodes: [.init(id: "work", nodeFile: "work.json")]
    )
    let taskId = TaskID("task-orphan-worktree")
    let task = WorkTask(
      id: taskId, intentId: IntentID("intent-orphan-worktree"), title: "Orphan worktree",
      instruction: "Resume from base", plan: .workflow(WorkflowReference(name: workflow.workflowId)),
      context: .repository(RepositoryContext(
        root: repository.clone.path, baseRevision: repository.baseRevision, isolation: .worktree
      )), state: .ready
    )
    try harness.store.saveTask(task)
    let reservation = try harness.store.reserveAttempt(AttemptReservationRequest(
      taskId: taskId, expectedTaskVersion: task.version, attemptId: AttemptID("attempt-orphan-worktree"),
      sessionId: "session-orphan-worktree", workflowId: workflow.workflowId, entryStepId: "work",
      entry: .start, decisionId: DecisionID("decision-orphan-worktree"),
      producer: .policy(rule: "test"), reason: "test", now: Date()
    ))
    let workspace = GitBranchWorkspaceRuntime()
    let isolation = try await workspace.ensureBranch(
      root: repository.clone.path, attempt: reservation.attempt.id, task: taskId,
      generation: reservation.attempt.generation, base: repository.baseRevision,
      isolation: .worktree, template: "riela/task/{taskId}/g{generation}"
    )
    XCTAssertTrue(try harness.store.updateAttemptIsolation(attemptId: reservation.attempt.id, isolation: isolation))
    var attempt = reservation.attempt
    attempt.isolation = isolation
    try repository.write("orphan dirty", to: "orphan.txt", in: URL(fileURLWithPath: isolation.path))
    let deliverables = await TaskDeliverablePublisher(
      store: harness.store, reservationFence: reservation.task.fence, workflow: workflow, nodePayloads: [:]
    ).publish(task: reservation.task, attempt: attempt, snapshot: WorkflowRuntimePersistenceSnapshot(
      session: WorkflowSession(
        workflowId: workflow.workflowId, sessionId: attempt.sessionId, status: .failed,
        entryStepId: "work", createdAt: Date(), updatedAt: Date()
      )
    ), ownerAlive: false)
    guard case let .repository(deliverable)? = deliverables.first else {
      return XCTFail("expected orphan repository deliverable")
    }
    XCTAssertEqual(deliverable.state, .unpublished(lastKnown: nil))
    XCTAssertTrue(deliverable.dirtyPaths.contains("orphan.txt"))

    let successorRoot = try repository.secondClone()
    let materialized = try await workspace.materialize(
      deliverable, into: successorRoot.path, worktree: true, attempt: AttemptID("attempt-orphan-successor")
    )
    XCTAssertEqual(try repository.git(["rev-parse", "HEAD"], at: URL(fileURLWithPath: materialized.path)), repository.baseRevision)
    XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: materialized.path).appendingPathComponent("orphan.txt").path))
  }

  func testTimerCheckpointsAreSerializedAndUseUniqueTrailers() async throws {
    let workspace = CheckpointRecordingWorkspace()
    let coordinator = TaskHandoverCheckpointCoordinator()
    let isolation = IsolationRef(path: "/tmp/repository", branch: "task", baseRevision: "base")
    let attemptId = AttemptID("attempt-timer")
    async let first: Void = coordinator.checkpoint(
      workspace: workspace, isolation: isolation, attemptId: attemptId,
      message: "timer", trailerSuffix: "timer", paths: nil
    )
    async let second: Void = coordinator.checkpoint(
      workspace: workspace, isolation: isolation, attemptId: attemptId,
      message: "timer", trailerSuffix: "timer", paths: nil
    )
    try await first
    try await second

    let trailers = await workspace.trailers
    XCTAssertEqual(Set(trailers), Set([
      "Riela-Checkpoint: attempt-timer/timer-1", "Riela-Checkpoint: attempt-timer/timer-2"
    ]))
    let maximumActive = await workspace.maximumActive
    XCTAssertEqual(maximumActive, 1)
  }
}
