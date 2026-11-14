import Foundation
import RielaCore
import RielaSQLite

struct WorkflowRunLivePersistenceSaveInput: Sendable {
  var persistedSession: PersistedCLIWorkflowSession
  var runtimeSnapshot: WorkflowRuntimePersistenceSnapshot
  var workflowMessages: [WorkflowMessageRecord]
  var artifactRoot: String?
}

struct WorkflowRunLivePersistenceSnapshot: Sendable {
  var latestSessionId: String?
  var storeRoot: String?
  var persistedSession: Bool?
  var connectionOpenCount: Int
  var diagnostics: [String]
}

actor WorkflowRunLivePersistenceState {
  static let backendEventPersistenceInterval: TimeInterval = 1

  private var latestSessionId: String?
  private var storeRoot: String?
  private var persistedSessionIds: Set<String> = []
  private var persistedBackendSessionIdsBySessionId: [String: String] = [:]
  private var lastBackendEventPersistenceAtBySessionId: [String: Date] = [:]
  private var lastPersistedMessageOrderBySessionId: [String: Int] = [:]
  private var connection: WorkflowRunLivePersistenceConnection?
  private var connectionOpenCount = 0
  private var diagnostics: [String] = []

  func configure(storeRoot: String) {
    if self.storeRoot != storeRoot {
      connection = nil
    }
    self.storeRoot = storeRoot
  }

  func pendingMessages(
    sessionId: String,
    from messages: [WorkflowMessageRecord]
  ) -> [WorkflowMessageRecord] {
    let lastPersistedOrder = lastPersistedMessageOrderBySessionId[sessionId] ?? 0
    return messages.filter { $0.workflowExecutionId == sessionId && $0.createdOrder > lastPersistedOrder }
  }

  func recordSuccess(sessionId: String, persistedMessages: [WorkflowMessageRecord] = []) {
    latestSessionId = sessionId
    persistedSessionIds.insert(sessionId)
    guard let highestOrder = persistedMessages.map(\.createdOrder).max() else {
      return
    }
    lastPersistedMessageOrderBySessionId[sessionId] = max(
      lastPersistedMessageOrderBySessionId[sessionId] ?? 0,
      highestOrder
    )
  }

  func persistLiveSnapshot(_ input: WorkflowRunLivePersistenceSaveInput) throws {
    let sessionId = input.persistedSession.session.sessionId
    guard let storeRoot else {
      throw CLIWorkflowSessionStoreError.io("live session persistence store root is not configured")
    }
    let pendingMessages = pendingMessages(sessionId: sessionId, from: input.workflowMessages)
    try liveConnection(storeRoot: storeRoot).save(
      input.persistedSession,
      runtimeSnapshot: input.runtimeSnapshot,
      appendingWorkflowMessages: pendingMessages
    )
    if let artifactRoot = input.artifactRoot {
      try FileWorkflowRuntimePersistenceStore(rootDirectory: artifactRoot).save(
        input.runtimeSnapshot,
        appendingWorkflowMessages: pendingMessages
      )
    }
    recordSuccess(sessionId: sessionId, persistedMessages: pendingMessages)
  }

  func recordFailure(sessionId: String, error: String) {
    latestSessionId = sessionId
    appendDiagnostic("live session persistence failed for \(sessionId): \(boundedWorkflowRunDiagnostic(error))")
  }

  func shouldPersist(
    event: WorkflowRunEvent,
    observedAt: Date = Date()
  ) -> Bool {
    guard workflowRunEventTriggersLiveSessionPersistence(event) else {
      return false
    }
    guard event.type == .backendEvent else {
      return true
    }
    if let backendSessionId = event.backendSessionId,
       persistedBackendSessionIdsBySessionId[event.sessionId] != backendSessionId {
      persistedBackendSessionIdsBySessionId[event.sessionId] = backendSessionId
      lastBackendEventPersistenceAtBySessionId[event.sessionId] = observedAt
      return true
    }
    if let lastPersistedAt = lastBackendEventPersistenceAtBySessionId[event.sessionId],
       observedAt.timeIntervalSince(lastPersistedAt) < Self.backendEventPersistenceInterval {
      return false
    }
    lastBackendEventPersistenceAtBySessionId[event.sessionId] = observedAt
    return true
  }

  func snapshot() -> WorkflowRunLivePersistenceSnapshot {
    WorkflowRunLivePersistenceSnapshot(
      latestSessionId: latestSessionId,
      storeRoot: storeRoot,
      persistedSession: latestSessionId.map { persistedSessionIds.contains($0) },
      connectionOpenCount: connectionOpenCount,
      diagnostics: diagnostics
    )
  }

  private func appendDiagnostic(_ diagnostic: String) {
    diagnostics.append(diagnostic)
    if diagnostics.count > 5 {
      diagnostics.removeFirst(diagnostics.count - 5)
    }
  }

  private func liveConnection(storeRoot: String) throws -> WorkflowRunLivePersistenceConnection {
    if let connection {
      return connection
    }
    let connection = try WorkflowRunLivePersistenceConnection(storeRoot: storeRoot)
    self.connection = connection
    connectionOpenCount += 1
    return connection
  }
}

private final class WorkflowRunLivePersistenceConnection: @unchecked Sendable {
  private let sessionStore: CLIWorkflowSessionStore
  private let runtimeStore: SQLiteWorkflowRuntimePersistenceStore
  private let database: SQLiteDatabase

  init(storeRoot: String) throws {
    sessionStore = CLIWorkflowSessionStore(rootDirectory: storeRoot)
    runtimeStore = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: storeRoot)
    )
    database = try sessionStore.openPersistenceDatabase()
    try sessionStore.prepareRuntimePersistenceSchemas(in: database, runtimeStore: runtimeStore)
  }

  func save(
    _ record: PersistedCLIWorkflowSession,
    runtimeSnapshot snapshot: WorkflowRuntimePersistenceSnapshot,
    appendingWorkflowMessages messages: [WorkflowMessageRecord]
  ) throws {
    try sessionStore.save(
      record,
      runtimeSnapshot: snapshot,
      appendingWorkflowMessages: messages,
      in: database,
      runtimeStore: runtimeStore
    )
  }
}

func workflowRunEventTriggersLiveSessionPersistence(_ event: WorkflowRunEvent) -> Bool {
  switch event.type {
  case .sessionStarted, .stepStarted, .backendEvent, .silenceWarning,
       .loopStall, .budgetExceeded, .stepCompleted, .sessionCompleted:
    return true
  }
}

struct WorkflowRunLivePersistenceContext: Sendable {
  var workflowName: String
  var resolution: WorkflowResolutionOptions
  var bundle: ResolvedWorkflowBundle
  var variables: JSONObject
  var runtimeStore: InMemoryWorkflowRuntimeStore
  var mockScenarioPath: String?
  var artifactRoot: String?
  var workingDirectory: String
  var recorder: WorkflowRunJSONLRecorder?
}

func persistWorkflowRunLiveSessionRecord(
  sessionId: String,
  context: WorkflowRunLivePersistenceContext,
  state: WorkflowRunLivePersistenceState
) async {
  do {
    guard let session = try await context.runtimeStore.loadSession(id: sessionId) else {
      return
    }
    let workflowMessages = try await context.runtimeStore.listMessages(for: sessionId, toStepId: nil)
    let loopEvidence = try? DefaultLoopEvidenceProjector().project(
      LoopEvidenceProjectionInput(
        workflow: context.bundle.workflow,
        session: session,
        workflowMessages: workflowMessages,
        workflowSource: LoopWorkflowSource(
          scope: context.bundle.sourceScope.rawValue,
          kind: context.bundle.packageManifest == nil ? "workflow-directory" : "package",
          workflowDirectory: context.bundle.workflowDirectory,
          packageName: context.bundle.packageManifest?.name,
          packageVersion: context.bundle.packageManifest?.version,
          packageDirectory: context.bundle.packageDirectory,
          mutable: context.bundle.packageManifest == nil
        ),
        variables: context.variables
      )
    )
    let snapshot = WorkflowRuntimePersistenceProjector.snapshot(
      session: session,
      workflowMessages: workflowMessages,
      loopEvidence: loopEvidence,
      loopMetadata: context.bundle.workflow.loop
    )
    let resolvedArtifactRoot = context.artifactRoot.map {
      absoluteURL(
        $0,
        relativeTo: URL(fileURLWithPath: context.workingDirectory, isDirectory: true)
      ).path
    }
    try await state.persistLiveSnapshot(
      WorkflowRunLivePersistenceSaveInput(
        persistedSession: PersistedCLIWorkflowSession(
          workflowName: context.workflowName,
          session: session,
          resolution: context.resolution,
          mockScenarioPath: context.mockScenarioPath,
          runtimeVariables: context.variables
        ),
        runtimeSnapshot: snapshot,
        workflowMessages: workflowMessages,
        artifactRoot: resolvedArtifactRoot
      )
    )
  } catch {
    await state.recordFailure(sessionId: sessionId, error: "\(error)")
    if let recorder = context.recorder {
      await recorder.append(
        (try? jsonString(WorkflowRunPersistenceFailureRecord(
          sessionId: sessionId,
          error: "\(error)"
        ))) ?? ""
      )
    }
  }
}

func boundedWorkflowRunDiagnostic(_ diagnostic: String, limit: Int = 8_000) -> String {
  guard diagnostic.count > limit else {
    return diagnostic
  }
  return String(diagnostic.prefix(limit)) + "...(truncated)"
}

func workflowRunTerminationDiagnostic(from error: String) -> (childExitCode: Int32?, terminationSignal: Int32?) {
  guard let match = error.firstMatch(of: /exit code (-?\d+)/),
    let childExitCode = Int32(match.1)
  else {
    return (nil, nil)
  }
  return (childExitCode, childExitCode < 0 ? abs(childExitCode) : nil)
}
