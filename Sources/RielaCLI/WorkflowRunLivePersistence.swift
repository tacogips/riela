import Foundation

struct WorkflowRunLivePersistenceSnapshot: Sendable {
  var latestSessionId: String?
  var storeRoot: String?
  var persistedSession: Bool?
  var diagnostics: [String]
}

actor WorkflowRunLivePersistenceState {
  private var latestSessionId: String?
  private var storeRoot: String?
  private var persistedSessionIds: Set<String> = []
  private var diagnostics: [String] = []

  func configure(storeRoot: String) {
    self.storeRoot = storeRoot
  }

  func recordSuccess(sessionId: String) {
    latestSessionId = sessionId
    persistedSessionIds.insert(sessionId)
  }

  func recordFailure(sessionId: String, error: String) {
    latestSessionId = sessionId
    appendDiagnostic("live session persistence failed for \(sessionId): \(boundedWorkflowRunDiagnostic(error))")
  }

  func snapshot() -> WorkflowRunLivePersistenceSnapshot {
    WorkflowRunLivePersistenceSnapshot(
      latestSessionId: latestSessionId,
      storeRoot: storeRoot,
      persistedSession: latestSessionId.map { persistedSessionIds.contains($0) },
      diagnostics: diagnostics
    )
  }

  private func appendDiagnostic(_ diagnostic: String) {
    diagnostics.append(diagnostic)
    if diagnostics.count > 5 {
      diagnostics.removeFirst(diagnostics.count - 5)
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
