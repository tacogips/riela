import Crypto
import Foundation

public enum SpecialistMonitorDirective: Equatable, Sendable {
  case awaitingBinding
  case run
  case cancel
}

extension SpecialistSupervisorStore {
  /// The owner monitor pulls durable control and proves possession of its
  /// launch nonce. Neither a saved PID nor the public token digest authorizes
  /// process signalling. Cancellation still needs a canonical terminal receipt.
  public func pollChildMonitorControl(
    dispatchId: String, childSessionId: String, token: String, now: Date = Date()
  ) throws -> SpecialistMonitorDirective {
    let tokenHash = try Self.monitorControlTokenHash(token)
    let database = try openWritable()
    return try database.transaction { database in
      var record = try requiredDispatch(dispatchId: dispatchId, in: database)
      guard record.state == .running, record.childSessionId == childSessionId else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor binding is not running")
      }
      guard let expected = record.childControlTokenHash else { return .awaitingBinding }
      guard expected == tokenHash else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor authentication failed")
      }
      // `Process.run()` necessarily precedes recording its PID. The monitor
      // must not bind or enter the runner in that interval: if its launcher
      // dies before this commit, the service can fence and reopen only from
      // canonical no-effect evidence.
      guard record.childProcessId != nil else { return .awaitingBinding }
      guard let json = try database.query(
        "SELECT json(task_json) AS task_json FROM specialist_tasks WHERE task_id = ?", bindings: [.text(record.taskId)]
      ).first?["task_json"] else {
        throw SpecialistSupervisorStoreError.taskNotFound(record.taskId)
      }
      let task = try decode(SpecialistTask.self, json: json)
      guard task.state == .running || task.state == .cancelRequested else {
        throw SpecialistSupervisorStoreError.invalidTransition("child monitor task is not running")
      }
      record.childMonitorHeartbeatAt = now
      try saveDispatch(record, in: database)
      return task.state == .cancelRequested ? .cancel : .run
    }
  }

  static func monitorControlTokenHash(_ token: String) throws -> String {
    guard token.utf8.count >= 64, token.utf8.count <= 256 else {
      throw SpecialistSupervisorStoreError.invalidTransition("child monitor token is invalid")
    }
    return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
