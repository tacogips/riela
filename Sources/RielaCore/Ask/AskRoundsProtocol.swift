import Foundation

public struct AskRoundToolCall: Equatable, Sendable {
  public let id: String
  public let name: String
  public let arguments: JSONObject
}

public struct AskRound: Equatable, Sendable {
  public let toolCalls: [AskRoundToolCall]
  public let answerText: String
}

public enum AskRoundsProtocol {
  private static let maxCalls = 8
  private static let fenceMarkers: Set<String> = ["```", "```json", "```jsonl", "```ndjson"]

  public static func parse(_ text: String) -> AskRound {
    let decoder = JSONDecoder()
    let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
    var calls: [AskRoundToolCall] = []
    var answer: [String] = []
    var foundMessage = false
    for line in lines {
      guard !fenceMarkers.contains(line.trimmingCharacters(in: .whitespaces)) else { continue }
      let record = try? decoder.decode(JSONObject.self, from: Data(line.utf8))
      if let record, record["type"] == .string("tool"), let call = toolCall(record, index: calls.count) {
        if calls.count < maxCalls { calls.append(call) }
      } else if record?["type"] == .string("message"), case let .string(message)? = record?["text"] {
        foundMessage = true
        answer.append(message)
      } else {
        answer.append(String(line))
      }
    }
    guard !calls.isEmpty || foundMessage else { return AskRound(toolCalls: [], answerText: text) }
    if lines.last?.isEmpty == true { answer.removeLast() }
    return AskRound(toolCalls: calls, answerText: answer.joined(separator: "\n"))
  }

  private static func toolCall(_ record: JSONObject, index: Int) -> AskRoundToolCall? {
    guard case let .string(name)? = record["name"],
      case let .string(id) = record["id"] ?? .string("t\(index)"),
      case let .object(arguments) = record["arguments"] ?? .object([:]) else { return nil }
    return AskRoundToolCall(id: id, name: name, arguments: arguments)
  }
}
