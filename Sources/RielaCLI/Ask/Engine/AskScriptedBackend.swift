import Foundation
import RielaCore

actor AskScriptedBackend: NodeAdapter {
  static let environmentKey = "RIELA_ASK_SCRIPTED_BACKEND"

  private struct Script: Decodable {
    let rounds: [String]
  }

  private let rounds: [String]
  private var index = 0

  init(fileURL: URL) throws {
    let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: fileURL))
    guard !script.rounds.isEmpty else {
      throw AdapterExecutionError(.invalidInput, "The Ask Riela script must contain at least one round")
    }
    rounds = script.rounds
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    try Task.checkCancellation()
    let text = rounds[index]
    index = min(index + 1, rounds.count - 1)
    return AdapterExecutionOutput(
      provider: "ask-scripted", model: input.node.model, promptText: input.promptText,
      completionPassed: true, payload: normalizeTextBusinessPayload(text)
    )
  }
}
