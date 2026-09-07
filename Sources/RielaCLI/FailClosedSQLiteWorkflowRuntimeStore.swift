import Foundation
import RielaCore

/// Runtime-store adapter for the independently supervised child process.
/// Effect-enabling mutations are committed to the canonical SQLite snapshot
/// before they are returned to the runner. A staged publication is deliberately
/// an in-memory prepare phase: a nested route publishes it only with its
/// immutable child reservation and waiting checkpoint in the one canonical
/// SQLite transaction below.
public actor FailClosedSQLiteWorkflowRuntimeStore: WorkflowRuntimeStore {
  typealias PersistenceWriter = @Sendable (WorkflowRuntimePersistenceSnapshot) throws -> Void

  private let backing: InMemoryWorkflowRuntimeStore
  private let persistence: SQLiteWorkflowRuntimePersistenceStore
  private let persistenceWriter: PersistenceWriter
  private let faultAtCanonicalWrite: Int?
  private var canonicalWriteCount = 0

  init(
    backing: InMemoryWorkflowRuntimeStore,
    rootDirectory: String,
    persistenceWriter: PersistenceWriter? = nil
  ) {
    self.backing = backing
    persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: rootDirectory)
    self.persistenceWriter = persistenceWriter ?? { [persistence] snapshot in
      try persistence.save(snapshot)
    }
    if failClosedTestEnvironmentValue("RIELA_ENABLE_TEST_FAILPOINTS") == "1" {
      faultAtCanonicalWrite = failClosedTestEnvironmentValue(
        "RIELA_TEST_FAIL_CLOSED_SQLITE_WRITE"
      ).flatMap(Int.init)
    } else {
      faultAtCanonicalWrite = nil
    }
  }

  func hydrate() async throws {
    for snapshot in try persistence.loadAll() {
      await backing.seedSession(snapshot.session)
      await backing.seedWorkflowMessages(snapshot.workflowMessages)
    }
  }

  public func createSession(_ input: WorkflowSessionCreateInput) async throws -> WorkflowSession {
    let result = try await backing.createSession(input)
    try await persist(sessionId: result.sessionId)
    return result
  }

  public func recordStepExecution(_ input: WorkflowStepExecutionRecordInput) async throws -> WorkflowStepExecution {
    let result = try await backing.recordStepExecution(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func updateStepExecution(_ input: WorkflowStepExecutionUpdateInput) async throws -> WorkflowStepExecution {
    let result = try await backing.updateStepExecution(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func stageWorkflowPublication(_ input: WorkflowPublicationStageInput) async throws -> WorkflowPublicationStageResult {
    // Do not persist this intermediate parent state. Persisting it here would
    // create a process-death window in which accepted parent output is durable
    // without the immutable nested intent and waiting checkpoint. A normal
    // publication persists from commitWorkflowPublication; a nested one uses
    // commitNestedWorkflowPublication's SQLite transaction.
    try await backing.stageWorkflowPublication(input)
  }

  public func commitWorkflowPublication(_ input: WorkflowPublicationCommitInput) async throws -> WorkflowPublicationCommitResult {
    let result = try await backing.commitWorkflowPublication(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func abortWorkflowPublication(_ input: WorkflowPublicationAbortInput) async throws -> WorkflowStepExecution {
    let result = try await backing.abortWorkflowPublication(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func redirectPendingWorkflowStep(_ input: WorkflowPendingStepRedirectInput) async throws -> WorkflowPendingStepRedirectResult {
    let result = try await backing.redirectPendingWorkflowStep(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func markSessionFailed(_ input: WorkflowSessionFailureInput) async throws -> WorkflowSession {
    let result = try await backing.markSessionFailed(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func recordStepBackendEvent(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowStepExecution {
    let result = try await backing.recordStepBackendEvent(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func recordStepBackendEventReceipt(_ input: WorkflowStepBackendEventInput) async throws -> WorkflowBackendEventReceipt {
    let result = try await backing.recordStepBackendEventReceipt(input)
    try await persist(sessionId: input.sessionId)
    return result
  }

  public func appendWorkflowMessage(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    let result = try await backing.appendWorkflowMessage(input)
    try await persist(sessionId: input.workflowExecutionId)
    return result
  }

  public func appendWorkflowMessages(_ inputs: [WorkflowMessageAppendInput]) async throws -> [WorkflowMessageRecord] {
    let result = try await backing.appendWorkflowMessages(inputs)
    for sessionId in Set(inputs.map(\.workflowExecutionId)) { try await persist(sessionId: sessionId) }
    return result
  }

  public func appendWorkflowMessageOnce(_ input: WorkflowMessageAppendInput) async throws -> WorkflowMessageRecord {
    let result = try await backing.appendWorkflowMessageOnce(input)
    try await persist(sessionId: input.workflowExecutionId)
    return result
  }

  public func listMessages(for sessionId: String, toStepId: String?) async throws -> [WorkflowMessageRecord] {
    try await backing.listMessages(for: sessionId, toStepId: toStepId)
  }

  public func loadSession(id: String) async throws -> WorkflowSession? {
    try await backing.loadSession(id: id)
  }

  private func persist(sessionId: String) async throws {
    guard let session = try await backing.loadSession(id: sessionId) else {
      throw WorkflowRuntimeStoreError.sessionNotFound(sessionId)
    }
    let messages = try await backing.listMessages(for: sessionId, toStepId: nil)
    try consumeCanonicalWriteBudget()
    try persistenceWriter(WorkflowRuntimePersistenceSnapshot(session: session, workflowMessages: messages))
  }

  private func consumeCanonicalWriteBudget() throws {
    canonicalWriteCount += 1
    if canonicalWriteCount == faultAtCanonicalWrite {
      throw WorkflowRuntimePersistenceStoreError.sqliteFailed("injected canonical SQLite persistence failure")
    }
  }
}

private func failClosedTestEnvironmentValue(_ name: String) -> String? {
  guard let value = getenv(name) else { return nil }
  return String(cString: value)
}

extension FailClosedSQLiteWorkflowRuntimeStore: WorkflowNestedPublicationCommitting {
  /// Commits the in-memory staged parent output, immutable invocation intent,
  /// created child, and parent waiting checkpoint through one SQLite
  /// transaction. The in-memory backing is only a live execution cache;
  /// failure here stops the runner before the child can enter a node.
  public func commitNestedWorkflowPublication(
    _ input: WorkflowPublicationCommitInput,
    plan: WorkflowNestedPublicationPlan
  ) async throws -> WorkflowPublicationCommitResult {
    let result = try await backing.commitWorkflowPublication(input)
    let parentMessages = try await backing.listMessages(for: result.session.sessionId, toStepId: nil)
    try consumeCanonicalWriteBudget()
    try persistence.commitNestedPublication(
      parentSnapshot: WorkflowRuntimePersistenceSnapshot(session: result.session, workflowMessages: parentMessages),
      reservation: plan.reservation
    )
    if try await backing.loadSession(id: plan.reservation.childSnapshot.session.sessionId) == nil {
      await backing.seedSession(plan.reservation.childSnapshot.session)
      await backing.seedWorkflowMessages(plan.reservation.childSnapshot.workflowMessages)
    }
    return result
  }
}
