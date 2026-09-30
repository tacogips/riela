import Foundation
import RielaSQLite

extension WorkStore {
  func adoptSession(intent: Intent?, task: WorkTask, attempt: Attempt, evidence: Evidence,
                    existingTaskVersion: Int?, now: Date) throws -> Attempt {
    let database = try openWritable()
    return try database.transaction { database in
      if try database.query("SELECT 1 AS found FROM work_attempts WHERE session_id = ? LIMIT 1",
                            bindings: [.text(attempt.sessionId)]).first != nil {
        throw WorkStoreError("session '\(attempt.sessionId)' was already adopted")
      }
      var attempt = attempt
      attempt.generation = try nextGeneration(for: task.id, in: database)
      if let existingTaskVersion {
        var updated = task
        updated.state = .running
        updated.version = existingTaskVersion + 1
        try updateTask(updated, expectedVersion: existingTaskVersion, in: database)
      } else if let intent {
        try database.execute("INSERT INTO work_intents (intent_id, record, created_at) VALUES (?, jsonb(?), ?)",
          bindings: [.text(intent.id.rawValue), .text(try encode(intent)), .text(Self.timestamp(now))])
        try database.execute("INSERT INTO work_tasks (task_id, record, updated_at) VALUES (?, jsonb(?), ?)",
          bindings: [.text(task.id.rawValue), .text(try encode(task)), .text(Self.timestamp(now))])
      }
      try insertAttempt(attempt, in: database, createdAt: now)
      try insertEvidence(evidence, in: database)
      return attempt
    }
  }
}
