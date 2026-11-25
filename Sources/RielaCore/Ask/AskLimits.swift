public struct AskLimits: Codable, Equatable, Sendable {
  public var userMessageBytes = 16_384
  public var assistantMessageBytes = 32_768
  public var messagesPerConversation = 200
  public var conversationsPerStore = 200
  public var historyMessages = 12
  public var historyMessageCharacters = 4_000
  public var turnsPerConversation = 50
  public var toolCallsPerTurn = 24
  public var toolCallsPerConversation = 400
  public var toolResultBytes = 16_384
  public var toolBytesPerTurn = 262_144
  public var toolBytesPerConversation = 4_194_304
  public var roundsPerTurn = 12
  public var turnDeadlineSeconds = 600
  public var draftDefinitionBytes = 524_288
  public var actionsPerTurn = 5
  public var actionLifetimeSeconds = 86_400
  public var contextSummaryBytes = 4_096

  public static let standard = AskLimits()

  public init() {}

  public static func prefix(_ text: String, utf8Limit: Int) -> String {
    var bytes = 0
    let prefix = text.prefix { character in
      bytes += character.utf8.count
      return bytes <= utf8Limit
    }
    return String(prefix)
  }
}
