import Foundation

actor AskRuntime {
  static let shared = AskRuntime()
  nonisolated let runnerId: String

  private struct RunningTurn {
    let turnId: String
    let task: Task<Void, Error>
  }

  private var running: [String: RunningTurn] = [:]

  init(runnerId: String = UUID().uuidString) {
    self.runnerId = runnerId
  }

  func start(conversationId: String, turnId: String, operation: @escaping @Sendable () async throws -> Void) {
    let task = Task {
      defer { ended(conversationId: conversationId, turnId: turnId) }
      try await operation()
    }
    running[conversationId] = RunningTurn(turnId: turnId, task: task)
  }

  func wait(conversationId: String) async {
    guard let task = running[conversationId]?.task else { return }
    await withTaskCancellationHandler {
      _ = await task.result
    } onCancel: {
      task.cancel()
    }
  }

  func cancel(conversationId: String, turnId: String) async throws {
    guard let turn = running[conversationId], turn.turnId == turnId else { return }
    turn.task.cancel()
    try await turn.task.value
  }

  private func ended(conversationId: String, turnId: String) {
    if running[conversationId]?.turnId == turnId {
      running[conversationId] = nil
    }
  }
}
