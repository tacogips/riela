import Foundation
import RielaCore
import Testing
@testable import RielaCLI

struct AskScriptedBackendTests {
  @Test func returnsEachRoundAndRepeatsTheLast() async throws {
    let file = try makeScript(#"{"rounds":["first","second"]}"#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let backend = try AskScriptedBackend(fileURL: file)
    let input = AdapterExecutionInput(node: AgentNodePayload(id: "ask", model: "fixture"), promptText: "test")

    let first = try await backend.execute(input, context: .init())
    let second = try await backend.execute(input, context: .init())
    let repeated = try await backend.execute(input, context: .init())

    #expect(first.payload == ["text": .string("first")])
    #expect(second.payload == ["text": .string("second")])
    #expect(repeated.payload == second.payload)
  }

  @Test func rejectsEmptyRounds() throws {
    let file = try makeScript(#"{"rounds":[]}"#)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    #expect(throws: AdapterExecutionError(.invalidInput, "The Ask Riela script must contain at least one round")) {
      try AskScriptedBackend(fileURL: file)
    }
  }

  private func makeScript(_ json: String) throws -> URL {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/ask-riela/ask-03-turn-engine/adapter/fixtures/\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("script.json")
    try Data(json.utf8).write(to: file)
    return file
  }
}
