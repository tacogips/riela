import Foundation
import RielaCore

public typealias GraphQLBot = BotRecord
public typealias GraphQLBotCounts = BotOverviewCounts
public typealias GraphQLBotBoardItem = BotBoardItem
public typealias GraphQLBotOverviewRow = BotOverviewRow
public typealias GraphQLBotWorkspaceGroup = BotWorkspaceGroup
public typealias GraphQLBotOrigin = BotOrigin
public typealias GraphQLBotListState = BotListState

public struct GraphQLBotBoard: Codable, Equatable, Sendable {
  public let needsYou: [GraphQLBotBoardItem]
  public let inProgress: [GraphQLBotBoardItem]
  public let waiting: [GraphQLBotBoardItem]
  public let planned: [GraphQLBotBoardItem]
  public let closed: [GraphQLBotBoardItem]
  public let closedTotal: Int

  public init(_ board: BotBoard) {
    needsYou = board.groups[.needsYou] ?? []
    inProgress = board.groups[.inProgress] ?? []
    waiting = board.groups[.waiting] ?? []
    planned = board.groups[.planned] ?? []
    closed = board.groups[.closed] ?? []
    closedTotal = board.closedTotal
  }
}

public struct GraphQLBotRoutine: Codable, Equatable, Sendable {
  public let routineId: String
  public let name: String
  public let workflowName: String
  public let status: String
  public let nextRunAt: Date?

  public init(routineId: String, name: String, workflowName: String, status: String, nextRunAt: Date?) {
    self.routineId = routineId
    self.name = name
    self.workflowName = workflowName
    self.status = status
    self.nextRunAt = nextRunAt
  }
}

public struct BotListPayload: Codable, Equatable, Sendable {
  public let bots: [GraphQLBotOverviewRow]
  public let groups: [GraphQLBotWorkspaceGroup]

  public init(bots: [GraphQLBotOverviewRow], groups: [GraphQLBotWorkspaceGroup]) {
    self.bots = bots
    self.groups = groups
  }
}

public struct BotDetailPayload: Codable, Equatable, Sendable {
  public let bot: GraphQLBot
  public let board: GraphQLBotBoard
  public let routines: [GraphQLBotRoutine]
  public let origin: GraphQLBotOrigin

  public var suggestions: [JSONValue] { [] }
  public var memory: JSONValue { .null }

  public init(bot: GraphQLBot, board: GraphQLBotBoard, routines: [GraphQLBotRoutine], origin: GraphQLBotOrigin) {
    self.bot = bot
    self.board = board
    self.routines = routines
    self.origin = origin
  }

  private enum CodingKeys: String, CodingKey { case bot, board, routines, origin, suggestions, memory }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      bot: try values.decode(GraphQLBot.self, forKey: .bot),
      board: try values.decode(GraphQLBotBoard.self, forKey: .board),
      routines: try values.decode([GraphQLBotRoutine].self, forKey: .routines),
      origin: try values.decode(GraphQLBotOrigin.self, forKey: .origin)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(bot, forKey: .bot)
    try values.encode(board, forKey: .board)
    try values.encode(routines, forKey: .routines)
    try values.encode(origin, forKey: .origin)
    try values.encode(suggestions, forKey: .suggestions)
    try values.encode(memory, forKey: .memory)
  }
}

public struct BotMutationPayload: Codable, Equatable, Sendable {
  public let bot: GraphQLBot
  public let warnings: [String]

  public init(bot: GraphQLBot, warnings: [String] = []) {
    self.bot = bot
    self.warnings = warnings
  }
}

public struct BotFilter: Codable, Equatable, Sendable {
  public var groupBy: BotListGrouping?
  public var remote: String?

  public init(groupBy: BotListGrouping? = nil, remote: String? = nil) {
    self.groupBy = groupBy
    self.remote = remote
  }
}

/// Shared record fields used to decode flat create and update inputs.
public struct BotRecordInput: Codable, Equatable, Sendable {
  public var id: String?
  public var botId: String?
  public var name: String?
  public var purpose: String?
  public var personaId: String?
  public var defaultBackend: String?
  public var defaultModel: String?
  public var providerInstanceId: String?
  public var workspace: String?
  public var memoryUpkeep: BotJobSchedule?
  public var lookAround: BotJobSchedule?
  public var permissionWaitMs: Int?
  public var remote: String?

  public init() {}
}

public typealias CreateBotInput = BotRecordInput
public typealias UpdateBotInput = BotRecordInput

public struct SetBotPausedInput: Codable, Equatable, Sendable {
  public let botId: String
  public let paused: Bool
  public let remote: String?
}

public struct RemoveBotInput: Codable, Equatable, Sendable {
  public let botId: String
  public let remote: String?
}

public struct SetBotListStateInput: Codable, Equatable, Sendable {
  public let botId: String
  public var itemKind: String?
  public var itemId: String?
  public var pinned: Bool?
  public var manualOrder: Int?
  public var snoozedUntil: String?
  public var clearSnooze: Bool?
  public var settled: Bool?
  public var remote: String?

  public init(botId: String) { self.botId = botId }
}

public enum BotSurfaceJSON {
  public static func value<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(value))
    guard value is BotListPayload, case var .object(payload) = encoded,
      case let .array(rows)? = payload["bots"] else { return encoded }
    payload["bots"] = .array(rows.map { row in
      guard case var .object(fields) = row else { return row }
      fields["lastActivityAt"] = fields["lastActivityAt"] ?? .null
      fields["lastResult"] = fields["lastResult"] ?? .null
      return .object(fields)
    })
    return .object(payload)
  }
}
