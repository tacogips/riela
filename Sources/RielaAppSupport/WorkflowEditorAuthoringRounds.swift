import Foundation
import RielaCore

/// Keep generation progressive even when a vendor CLI buffers a whole reply.
/// Each real provider turn makes one edit; publish it before asking for the next.
public enum WorkflowEditorAuthoringRounds {
  public enum AuthoringError: Error { case invalidProtocol, outputLimit, roundLimit }
  public typealias Round = @Sendable (JSONObject, Int, @escaping AdapterBackendEventHandler) async throws -> String

  public static func run(initial: JSONObject, handler: @escaping AdapterBackendEventHandler,
                         round: Round) async throws -> String {
    var definition = initial
    var totalBytes = 0
    for index in 0..<12 {
      try Task.checkCancellation()
      // Reset only the provider-message buffer, not the graph or revision history.
      await handler(AdapterBackendEvent(provider: "workflow-editor", eventType: "round-start",
        channel: .assistant, contentSnapshot: ""))
      let collected = WorkflowEditorRoundText()
      let returned = try await round(definition, index) { event in
        await collected.receive(event)
        await handler(event)
      }
      // Adapter payloads may contain only an extracted result or final message;
      // the assistant event transcript remains the authoring protocol source.
      let streamed = await collected.text
      guard await !collected.exceededLimit else { throw AuthoringError.outputLimit }
      let text = hasContinuation(streamed) ? streamed : returned
      try Task.checkCancellation()
      totalBytes += text.utf8.count
      guard totalBytes <= 1_048_576 else { throw AuthoringError.outputLimit }
      var shouldContinue: Bool?
      var changed = false
      for line in text.split(separator: "\n") {
        guard let record = try? JSONDecoder().decode(JSONObject.self, from: Data(line.utf8)),
              case let .string(type)? = record["type"] else { continue }
        if type == "definition", case let .object(next)? = record["definition"],
           case .string = next["workflowId"], case .array = next["nodes"], case .array = next["steps"] {
          definition = next
          changed = true
        } else if type == "continue", case let .bool(value)? = record["value"] {
          shouldContinue = value
        }
      }
      guard let shouldContinue, !shouldContinue || changed else { throw AuthoringError.invalidProtocol }
      // Some providers omit the trailing newline or emit only a final snapshot.
      // Frame that real response so its definition is visible during the next turn.
      await handler(AdapterBackendEvent(provider: "workflow-editor", eventType: "round-complete",
        channel: .assistant, contentSnapshot: text + "\n"))
      if !shouldContinue { return text }
    }
    throw AuthoringError.roundLimit
  }

  private static func hasContinuation(_ text: String) -> Bool {
    text.split(separator: "\n").contains { line in
      guard let record = try? JSONDecoder().decode(JSONObject.self, from: Data(line.utf8)),
            record["type"] == .string("continue"), case .bool = record["value"] else { return false }
      return true
    }
  }
}

private actor WorkflowEditorRoundText {
  private var buffer = ""
  private var previous: [String] = []
  private var records: [String] = []
  private var bytes = 0
  private(set) var exceededLimit = false
  var text: String { records.joined(separator: "\n") }

  func receive(_ event: AdapterBackendEvent) {
    guard event.channel == .assistant, !exceededLimit else { return }
    if let snapshot = event.contentSnapshot, !event.isDelta { buffer = snapshot } else if let delta = event.contentDelta { buffer += delta }
    guard buffer.utf8.count <= 1_048_576 else { exceededLimit = true; buffer = ""; return }
    // A final assistant-message event need not end in a newline. Decode the
    // tail only if it is already a complete JSON record.
    let lines = buffer.split(separator: "\n").map(String.init).filter {
      (try? JSONDecoder().decode(JSONObject.self, from: Data($0.utf8))) != nil
    }
    let prefix = zip(previous, lines).prefix { $0 == $1 }.count
    let newLines = lines.dropFirst(prefix)
    bytes += newLines.reduce(0) { $0 + $1.utf8.count }
    guard bytes <= 1_048_576 else { exceededLimit = true; records = []; return }
    records.append(contentsOf: newLines)
    previous = lines
  }
}
