import Foundation

public enum BotJobSchedule: String, Codable, CaseIterable, Sendable {
  case off, nightly, weekly
}

public struct BotRecord: Codable, Equatable, Sendable {
  public let botId: String
  public var name: String
  public var purpose: String?
  public var personaId: String?
  public var defaultBackend: String?
  public var defaultModel: String?
  public var providerInstanceId: String?
  public var workspace: String?
  public var paused: Bool
  public var memoryUpkeep: BotJobSchedule
  public var lookAround: BotJobSchedule
  public var permissionWaitMs: Int
  public var createdAt: String
  public var updatedAt: String

  public init(
    botId: String? = nil, name: String, purpose: String? = nil, personaId: String? = nil,
    defaultBackend: String? = nil, defaultModel: String? = nil,
    providerInstanceId: String? = nil, workspace: String? = nil, paused: Bool = false,
    memoryUpkeep: BotJobSchedule = .nightly, lookAround: BotJobSchedule = .off,
    permissionWaitMs: Int = 300_000, createdAt: String, updatedAt: String
  ) {
    self.botId = botId ?? Self.slug(from: name)
    self.name = name
    self.purpose = purpose
    self.personaId = personaId
    self.defaultBackend = defaultBackend
    self.defaultModel = defaultModel
    self.providerInstanceId = providerInstanceId
    self.workspace = workspace
    self.paused = paused
    self.memoryUpkeep = memoryUpkeep
    self.lookAround = lookAround
    self.permissionWaitMs = permissionWaitMs
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public static func validate(_ record: BotRecord) throws {
    guard record.botId.wholeMatch(of: /[a-z0-9][a-z0-9-]{0,62}/) != nil else {
      throw BotStoreError(code: "bot_invalid", message: "Invalid bot id '\(record.botId)'")
    }
    guard (1...200).contains(record.name.count),
      record.name.rangeOfCharacter(from: .controlCharacters) == nil
    else {
      throw BotStoreError(code: "bot_invalid", message: "Bot name must contain 1 to 200 characters and no control characters")
    }
    guard (0...3_600_000).contains(record.permissionWaitMs) else {
      throw BotStoreError(code: "bot_invalid", message: "Bot permission wait must be between 0 and 3600000 ms")
    }
    if let backend = record.defaultBackend, NodeExecutionBackend(rawValue: backend) == nil {
      throw BotStoreError(code: "bot_invalid", message: "Unknown bot backend '\(backend)'")
    }
  }

  public static func slug(from name: String) -> String {
    let slug = name.lowercased()
      .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
      .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "bot" : String(slug.prefix(63))
  }
}

public enum ModelSentinel {
  public static let defaultModel = "default"
}
