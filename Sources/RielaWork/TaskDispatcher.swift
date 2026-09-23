import Foundation
import RielaSQLite

/// A read-only admission result. The caller resolves the workflow definition
/// and fresh host capabilities before asking the dispatcher to preview it.
public enum TaskDispatchPreview: Equatable, Sendable {
  case ready(TaskDispatchReady)
  case wait(WaitReason)
}

/// The version and placement that reservation must use. A concurrent task
/// change is rejected by `reserveAttempt` instead of silently replanning.
public struct TaskDispatchReady: Equatable, Sendable {
  public let task: WorkTask
  public let workflowId: String
  public let entryStepId: String
  public let entry: AttemptEntry
  public let placement: BackendCapabilityPlacementResult
}

/// Coordinates admission and fencing; the CLI owns actual workflow execution.
/// In particular, it must run the exact `Attempt.sessionId` returned by
/// reservation, then project terminal evidence before guard evaluation.
public struct TaskDispatcher: Sendable {
  public var store: WorkStore

  public init(store: WorkStore) {
    self.store = store
  }

  /// Reads the one unconsumed rerun/recovery request before entry selection.
  /// Reservation rechecks and consumes this exact request in its transaction.
  /// A missing database has no request; an incompatible database is an error.
  public func pendingReservation(taskId: TaskID) throws -> PendingAttemptReservation? {
    guard FileManager.default.fileExists(atPath: store.databasePath) else { return nil }
    let database = try SQLiteDatabase.open(
      path: store.databasePath,
      mode: store.immutableReadOnly ? .strictReadOnlyWithImmutableFallback : .readOnly,
      options: .readOnlyDefault
    )
    guard try database.tableExists("work_pending_reservations") else {
      throw WorkStoreError("work store has no pending reservation table")
    }
    let rows = try database.query(
      """
      SELECT request_id, decision_id, predecessor_attempt_id, json(entry_record) AS entry_record
      FROM work_pending_reservations
      WHERE task_id = ? AND consumed_attempt_id IS NULL
      """,
      bindings: [.text(taskId.rawValue)]
    )
    guard rows.count <= 1 else {
      throw WorkStoreError("task '\(taskId.rawValue)' has multiple pending reservations")
    }
    guard let row = rows.first else { return nil }
    guard let requestId = row["request_id"], !requestId.isEmpty,
          let decisionId = row["decision_id"], !decisionId.isEmpty,
          let entryRecord = row["entry_record"] else {
      throw WorkStoreError("task '\(taskId.rawValue)' has an invalid pending reservation")
    }
    let entry: AttemptEntry
    do {
      entry = try JSONDecoder().decode(AttemptEntry.self, from: Data(entryRecord.utf8))
    } catch {
      throw WorkStoreError("task '\(taskId.rawValue)' has an invalid pending entry: \(error)")
    }
    return PendingAttemptReservation(
      id: requestId,
      taskId: taskId,
      decisionId: DecisionID(decisionId),
      predecessorAttemptId: row["predecessor_attempt_id"].map(AttemptID.init),
      entry: entry
    )
  }

  /// Reads only existing records. No schema initialization, reservation,
  /// snapshot creation, probe persistence, or task version bump occurs here.
  public func preview(
    taskId: TaskID,
    workflowId: String,
    entryStepId: String,
    entry: AttemptEntry,
    placement: BackendCapabilityPlacementResult
  ) throws -> TaskDispatchPreview {
    guard let task = try store.loadTask(id: taskId) else {
      throw WorkStoreError("task '\(taskId.rawValue)' was not found")
    }
    guard let plan = task.plan else {
      throw WorkStoreError("task '\(taskId.rawValue)' has no executable plan")
    }
    let plannedWorkflowId: String
    switch plan {
    case let .workflow(reference): plannedWorkflowId = reference.name
    case let .temporaryWorkflow(temporary): plannedWorkflowId = temporary.name
    }
    guard !workflowId.isEmpty, plannedWorkflowId == workflowId else {
      throw WorkStoreError("task '\(taskId.rawValue)' plan does not match workflow '\(workflowId)'")
    }
    guard !entryStepId.isEmpty else {
      throw WorkStoreError("task '\(taskId.rawValue)' has no selected workflow entry step")
    }
    guard WorkStore.dispatchEligibleStates.contains(task.state) else {
      throw WorkStoreError("task '\(taskId.rawValue)' is not eligible for dispatch from state '\(task.state.rawValue)'")
    }
    for dependencyId in task.dependsOn {
      guard let dependency = try store.loadTask(id: dependencyId) else {
        throw WorkStoreError("task '\(taskId.rawValue)' has missing dependency '\(dependencyId.rawValue)'")
      }
      guard dependency.state == .succeeded else {
        return .wait(.dependency)
      }
    }
    guard placement.complete else {
      return .wait(.capacity)
    }
    return .ready(TaskDispatchReady(
      task: task,
      workflowId: workflowId,
      entryStepId: entryStepId,
      entry: entry,
      placement: placement
    ))
  }

  /// The store transaction rechecks task version, dependencies, budget and
  /// live-attempt exclusion, and commits the exact reserved session.
  public func reserve(
    _ ready: TaskDispatchReady,
    attemptId: AttemptID,
    sessionId: String,
    decisionId: DecisionID,
    producer: DecisionProducer,
    reason: String,
    placementEvidence: Evidence? = nil,
    pendingRequestId: String? = nil,
    now: Date = Date()
  ) throws -> AttemptReservationResult {
    try store.reserveAttempt(AttemptReservationRequest(
      taskId: ready.task.id,
      expectedTaskVersion: ready.task.version,
      attemptId: attemptId,
      sessionId: sessionId,
      workflowId: ready.workflowId,
      entryStepId: ready.entryStepId,
      entry: ready.entry,
      decisionId: decisionId,
      producer: producer,
      reason: reason,
      placementEvidence: placementEvidence,
      pendingRequestId: pendingRequestId,
      now: now
    ))
  }

  /// Consumes the one-use launch token immediately before runner execution.
  public func authorize(_ reservation: AttemptReservation, now: Date = Date()) throws -> Attempt {
    try store.authorizeAttemptLaunch(
      attemptId: reservation.attempt.id,
      launchToken: reservation.launchToken,
      now: now
    )
  }
}
