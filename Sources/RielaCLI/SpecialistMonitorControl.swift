import Foundation
import RielaCore

/// Private launch capability plus durable SQLite control. Only the monitor
/// holding the nonce may heartbeat, and it cancels its own Task/owned process
/// groups. No service or cancellation command ever signals a persisted PID.
struct SpecialistMonitorControl: Codable, Sendable {
  static let environmentKey = "RIELA_SPECIALIST_MONITOR_CONTROL"
  let stateRoot: String
  let dispatchId: String
  let childSessionId: String
  let nonce: String

  init(stateRoot: String, dispatchId: String, childSessionId: String) {
    self.stateRoot = URL(fileURLWithPath: stateRoot).resolvingSymlinksInPath().standardizedFileURL.path
    self.dispatchId = dispatchId
    self.childSessionId = childSessionId
    self.nonce = UUID().uuidString + UUID().uuidString
  }

  func launchEnvironment() throws -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment[Self.environmentKey] = String(data: try JSONEncoder().encode(self), encoding: .utf8)
    return environment
  }

  /// Called only at executable entry, before threads/tasks or node processes
  /// are created. Descendant commands must not inherit the launch capability.
  static func takeLaunchEnvironment() throws -> Self? {
    guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
    unsetenv(environmentKey)
    return try JSONDecoder().decode(Self.self, from: Data(value.utf8))
  }

  func run(
    options: WorkflowRunOptions, operation: @escaping @Sendable () async -> CLICommandResult
  ) async -> CLICommandResult {
    do {
      guard options.resumeSessionId == childSessionId, options.target == dispatchId,
            options.endpoint == nil,
            options.sessionStore.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }) == stateRoot else {
        throw CLIUsageError("specialist monitor execution does not match its launch binding")
      }
      let pin = try SpecialistMonitorStorePin(stateRoot: stateRoot, repairPermissions: false)
      let store = SpecialistSupervisorStore(rootDirectory: stateRoot)
      let directive = try await awaitBinding(store: store, pin: pin)
      if directive == .cancel {
        try pin.withVerifiedIdentity { try persistCancelledBeforeLaunch() }
        return CLICommandResult(exitCode: .failure, stderr: "specialist child cancelled before launch")
      }
      try pin.withVerifiedIdentity {
        _ = try store.beginChildNodeExecution(dispatchId: dispatchId, childSessionId: childSessionId, token: nonce)
      }
      let execution = Task { await operation() }
      return try await withTaskCancellationHandler {
        let monitor = Task {
          do {
            while !Task.isCancelled {
              let next = try pin.withVerifiedIdentity {
                try store.pollChildMonitorControl(dispatchId: dispatchId, childSessionId: childSessionId, token: nonce)
              }
              guard next == .run else { execution.cancel(); return }
              try await Task.sleep(nanoseconds: 100_000_000)
            }
          } catch {
            if !Task.isCancelled { execution.cancel() }
          }
        }
        let result = await execution.value
        monitor.cancel()
        await monitor.value
        let finalDirective = try pin.withVerifiedIdentity {
          try store.pollChildMonitorControl(dispatchId: dispatchId, childSessionId: childSessionId, token: nonce)
        }
        if finalDirective == .cancel {
          try pin.withVerifiedIdentity { try persistCancelledAfterRunIfNeeded() }
        }
        return result
      } onCancel: {
        execution.cancel()
      }
    } catch {
      return CLICommandResult(exitCode: .failure, stderr: "specialist monitor control failed: \(error)")
    }
  }

  private func awaitBinding(store: SpecialistSupervisorStore, pin: SpecialistMonitorStorePin) async throws -> SpecialistMonitorDirective {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let directive = try pin.withVerifiedIdentity {
        try store.pollChildMonitorControl(dispatchId: dispatchId, childSessionId: childSessionId, token: nonce)
      }
      if directive != .awaitingBinding {
        _ = try pin.withVerifiedIdentity {
          try store.bindChildMonitor(dispatchId: dispatchId, childSessionId: childSessionId, token: nonce)
        }
        return directive
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    throw CLIUsageError("specialist monitor launch binding timed out")
  }

  private func persistCancelledBeforeLaunch() throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: stateRoot))
    var snapshot = try runtime.load(sessionId: childSessionId)
    guard snapshot.session.status == .created, snapshot.session.executions.isEmpty else {
      throw CLIUsageError("specialist child has uncertain effects before monitor launch")
    }
    snapshot.session.status = .failed
    snapshot.session.failureKind = .cancelled
    snapshot.session.failureReason = "specialist child cancelled before launch"
    snapshot.session.updatedAt = Date()
    try runtime.save(snapshot)
  }

  /// Cancellation is a requested monitor control action, not an inference
  /// from process exit. Once this monitor has observed that request and its
  /// owned run task has stopped, it writes the canonical cancelled terminal so
  /// the service can project it without relaunching the child.
  private func persistCancelledAfterRunIfNeeded() throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: stateRoot))
    var snapshot = try runtime.load(sessionId: childSessionId)
    guard snapshot.session.status == .created || snapshot.session.status == .running else { return }
    snapshot.session.status = .failed
    snapshot.session.currentStepId = nil
    snapshot.session.failureKind = .cancelled
    snapshot.session.failureReason = "specialist child cancellation was confirmed by its monitor"
    snapshot.session.updatedAt = Date()
    try runtime.save(snapshot)
  }
}
