import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaWork

final class TaskDispatcherTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-task-dispatcher-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testPreviewOfAbsentTaskDoesNotCreateStore() throws {
    let store = WorkStore(rootDirectory: root.path)
    XCTAssertThrowsError(try TaskDispatcher(store: store).preview(
      taskId: TaskID("missing"),
      workflowId: "repair-workflow",
      entryStepId: "start",
      entry: .start,
      placement: completePlacement()
    ))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))
  }

  func testPreviewDistinguishesMissingFromUnmetDependencyWithoutWrites() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.dependsOn = [TaskID("prerequisite")]
    try store.saveTask(task)
    let before = try Data(contentsOf: URL(fileURLWithPath: store.databasePath))
    let dispatcher = TaskDispatcher(store: store)

    XCTAssertThrowsError(try preview(dispatcher)) { error in
      XCTAssertTrue(String(describing: error).contains("missing dependency"))
    }
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.databasePath)), before)

    var prerequisite = sampleTask(id: "prerequisite")
    prerequisite.state = .ready
    try store.saveTask(prerequisite)
    let beforeWait = try store.loadTask(id: task.id)
    XCTAssertEqual(try preview(dispatcher), .wait(.dependency))
    XCTAssertEqual(try store.loadTask(id: task.id), beforeWait)
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [])
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [])
  }

  func testPlacementWaitAndPlanMismatchHaveNoAttempt() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let dispatcher = TaskDispatcher(store: store)
    let provenance = WorkflowRequirementProvenance(workflowId: "repair-workflow", stepId: "start", nodeId: "worker")
    let unavailable = BackendCapabilityPlacementResult(
      choices: [], failures: [BackendPlacementFailure(provenance: provenance, reason: "no capacity")]
    )

    XCTAssertEqual(try dispatcher.preview(
      taskId: task.id,
      workflowId: "repair-workflow",
      entryStepId: "start",
      entry: .start,
      placement: unavailable
    ), .wait(.capacity))
    XCTAssertThrowsError(try dispatcher.preview(
      taskId: task.id,
      workflowId: "different-workflow",
      entryStepId: "start",
      entry: .start,
      placement: completePlacement()
    ))
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [])
    XCTAssertEqual(try store.loadTask(id: task.id), task)
  }

  func testStalePreviewCannotReserveAndSuccessfulReservationUsesExactSession() throws {
    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let dispatcher = TaskDispatcher(store: store)
    guard case let .ready(stale) = try preview(dispatcher) else {
      return XCTFail("expected ready preview")
    }
    _ = try store.updateTask(task, expectedVersion: task.version)
    XCTAssertThrowsError(try reserve(dispatcher, ready: stale)) { error in
      XCTAssertTrue((error as? WorkStoreError)?.isVersionConflict == true)
    }
    XCTAssertEqual(try store.listAttempts(taskId: task.id), [])

    guard case let .ready(fresh) = try preview(dispatcher) else {
      return XCTFail("expected refreshed preview")
    }
    let result = try reserve(dispatcher, ready: fresh)
    guard case let .reserved(reservation) = result else {
      return XCTFail("expected reservation")
    }
    XCTAssertEqual(reservation.attempt.sessionId, "reserved-session")
    XCTAssertEqual(reservation.attempt.launch?.phase, .reserved)
    XCTAssertEqual(try dispatcher.authorize(reservation).launch?.phase, .authorized)
    XCTAssertThrowsError(try dispatcher.authorize(reservation))
  }

  func testDependencyChangeBetweenPreviewAndReservationDeniesLaunch() throws {
    let store = WorkStore(rootDirectory: root.path)
    var dependency = sampleTask(id: "dependency")
    dependency.state = .succeeded
    try store.saveTask(dependency)
    var task = sampleTask()
    task.dependsOn = [dependency.id]
    try store.saveTask(task)
    let dispatcher = TaskDispatcher(store: store)
    guard case let .ready(admitted) = try preview(dispatcher) else {
      return XCTFail("expected ready preview")
    }

    dependency.state = .waiting
    try store.saveTask(dependency)
    XCTAssertEqual(try reserve(dispatcher, ready: admitted), .wait(.dependency))
    XCTAssertTrue(try store.listAttempts(taskId: task.id).isEmpty)
    XCTAssertTrue(try store.listDecisions(taskId: task.id).isEmpty)
    XCTAssertTrue(try store.listEvidence(taskId: task.id).isEmpty)
    XCTAssertEqual(try store.loadTask(id: task.id), task)
  }

  func testPendingReservationReadsExactUnconsumedRequestWithoutMutation() throws {
    let store = WorkStore(rootDirectory: root.path)
    var task = sampleTask()
    task.state = .scheduled
    try store.saveTask(task)
    let decision = Decision(
      id: DecisionID("rerun-decision"),
      taskId: task.id,
      attemptId: AttemptID("judged-attempt"),
      producer: .human(principal: "operator"),
      kind: .rerun(fromStepId: "repair"),
      reason: "repair failed step",
      createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    try store.saveDecision(decision)
    let request = PendingAttemptReservation(
      id: "pending-rerun",
      taskId: task.id,
      decisionId: decision.id,
      predecessorAttemptId: decision.attemptId,
      entry: .rerunFromStep("repair")
    )
    try store.enqueuePendingReservation(request)
    let dispatcher = TaskDispatcher(store: store)
    let databaseURL = URL(fileURLWithPath: store.databasePath)
    let before = try Data(contentsOf: databaseURL)

    XCTAssertEqual(try dispatcher.pendingReservation(taskId: task.id), request)
    XCTAssertEqual(try Data(contentsOf: databaseURL), before)
    XCTAssertEqual(try store.loadTask(id: task.id), task)
    XCTAssertEqual(try store.listDecisions(taskId: task.id), [decision])

    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate)
    try database.execute(
      "UPDATE work_pending_reservations SET consumed_attempt_id = 'next-attempt' WHERE request_id = 'pending-rerun'"
    )
    XCTAssertNil(try dispatcher.pendingReservation(taskId: task.id))
  }

  func testPendingReservationDoesNotCreateAbsentStoreAndDiagnosesIncompatibleStore() throws {
    let store = WorkStore(rootDirectory: root.path)
    let dispatcher = TaskDispatcher(store: store)
    XCTAssertNil(try dispatcher.pendingReservation(taskId: TaskID("task-1")))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.databasePath))

    _ = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate)
    XCTAssertThrowsError(try dispatcher.pendingReservation(taskId: TaskID("task-1"))) { error in
      XCTAssertTrue(String(describing: error).contains("no pending reservation table"))
    }
  }

  func testPendingReservationDiagnosesCorruptAndDuplicateRows() throws {
    let corruptRoot = root.appendingPathComponent("corrupt", isDirectory: true)
    try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: true)
    let corruptStore = WorkStore(rootDirectory: corruptRoot.path)
    try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: corruptStore.databasePath))
    XCTAssertThrowsError(try TaskDispatcher(store: corruptStore).pendingReservation(taskId: TaskID("task-1")))

    let store = WorkStore(rootDirectory: root.path)
    let task = sampleTask()
    try store.saveTask(task)
    let database = try SQLiteDatabase.open(path: store.databasePath, mode: .readWriteCreate)
    try database.execute("DROP INDEX idx_work_pending_reservations_one_unconsumed_task")
    for number in 1...2 {
      try database.execute(
        """
        INSERT INTO work_pending_reservations
          (request_id, task_id, decision_id, entry_record, created_at)
        VALUES (?, ?, ?, jsonb(?), ?)
        """,
        bindings: [
          .text("pending-\(number)"), .text(task.id.rawValue), .text("decision-\(number)"),
          .text(#"{"kind":"start"}"#), .text("2026-09-23T00:00:00Z")
        ]
      )
    }
    XCTAssertThrowsError(try TaskDispatcher(store: store).pendingReservation(taskId: task.id)) { error in
      XCTAssertTrue(String(describing: error).contains("multiple pending reservations"))
    }
  }

  private func preview(_ dispatcher: TaskDispatcher) throws -> TaskDispatchPreview {
    try dispatcher.preview(
      taskId: TaskID("task-1"),
      workflowId: "repair-workflow",
      entryStepId: "start",
      entry: .start,
      placement: completePlacement()
    )
  }

  private func reserve(_ dispatcher: TaskDispatcher, ready: TaskDispatchReady) throws -> AttemptReservationResult {
    try dispatcher.reserve(
      ready,
      attemptId: AttemptID("attempt-1"),
      sessionId: "reserved-session",
      decisionId: DecisionID("decision-1"),
      producer: .policy(rule: "dispatch"),
      reason: "ready task"
    )
  }

  private func completePlacement() -> BackendCapabilityPlacementResult {
    BackendCapabilityPlacementResult(choices: [], failures: [])
  }

  private func sampleTask(id: String = "task-1") -> WorkTask {
    WorkTask(
      id: TaskID(id),
      intentId: IntentID("intent-1"),
      title: "Repair task",
      instruction: "Run repair workflow",
      plan: .workflow(WorkflowReference(name: "repair-workflow")),
      state: .ready
    )
  }
}
