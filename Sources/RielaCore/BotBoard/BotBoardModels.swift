import Foundation

public enum BotBoardGroup: String, Codable, CaseIterable, Sendable {
  case needsYou, inProgress, waiting, planned, closed
}

public struct BotBoardPendingRequest: Codable, Equatable, Sendable {
  public let requestId: String
  public let title: String?
  public let options: [AdapterPermissionOption]
  public let createdAt: Date
  public let expiresAt: Date

  public init(requestId: String, title: String?, options: [AdapterPermissionOption], createdAt: Date, expiresAt: Date) {
    self.requestId = requestId
    self.title = title
    self.options = options
    self.createdAt = createdAt
    self.expiresAt = expiresAt
  }
}

public struct BotBoardQuestion: Codable, Equatable, Sendable {
  public let questionId: String
  public let text: String
  public let optionIds: [String]

  public init(questionId: String, text: String, optionIds: [String]) {
    self.questionId = questionId
    self.text = text
    self.optionIds = optionIds
  }
}

public struct BotBoardSessionInput: Sendable {
  public var session: WorkflowSession
  public var descendants: [WorkflowSession]
  public var activity: ActivityState?
  public var descendantActivities: [String: ActivityState]
  /// Pending requests for the root and every descendant.
  public var pendingRequests: [BotBoardPendingRequest]
  public var finalMessageLine: String?
  public var requestedModel: String?

  public init(
    session: WorkflowSession, descendants: [WorkflowSession] = [], activity: ActivityState? = nil,
    descendantActivities: [String: ActivityState] = [:], pendingRequests: [BotBoardPendingRequest] = [],
    finalMessageLine: String? = nil, requestedModel: String? = nil
  ) {
    self.session = session
    self.descendants = descendants
    self.activity = activity
    self.descendantActivities = descendantActivities
    self.pendingRequests = pendingRequests
    self.finalMessageLine = finalMessageLine
    self.requestedModel = requestedModel
  }
}

public struct BotBoardTaskInput: Sendable {
  public var taskId: String
  public var title: String
  public var state: String
  public var updatedAt: Date
  public var waitReason: String?
  public var question: BotBoardQuestion?
  public var attemptSessionIds: [String]

  public init(
    taskId: String, title: String, state: String, updatedAt: Date, waitReason: String? = nil,
    question: BotBoardQuestion? = nil, attemptSessionIds: [String] = []
  ) {
    self.taskId = taskId
    self.title = title
    self.state = state
    self.updatedAt = updatedAt
    self.waitReason = waitReason
    self.question = question
    self.attemptSessionIds = attemptSessionIds
  }
}

public struct BotBoardRoutineInput: Sendable {
  public let routineId: String
  public let name: String
  public let workflowName: String
  public let nextFireAt: Date?
  public let active: Bool

  public init(routineId: String, name: String, workflowName: String, nextFireAt: Date?, active: Bool) {
    self.routineId = routineId
    self.name = name
    self.workflowName = workflowName
    self.nextFireAt = nextFireAt
    self.active = active
  }
}

public struct BotBoardSuggestionInput: Sendable {
  public let suggestionId: String
  public let title: String
  public let status: String
  public let acceptedAt: Date?
  public let startedSessionId: String?

  public init(suggestionId: String, title: String, status: String, acceptedAt: Date?, startedSessionId: String?) {
    self.suggestionId = suggestionId
    self.title = title
    self.status = status
    self.acceptedAt = acceptedAt
    self.startedSessionId = startedSessionId
  }
}

public struct BotListState: Codable, Equatable, Sendable {
  public var pinned: Bool
  public var manualOrder: Int?
  public var snoozedUntil: Date?
  public var snoozedAt: Date?
  public var settledAt: Date?
  public var settledBy: String?

  public init(
    pinned: Bool = false, manualOrder: Int? = nil, snoozedUntil: Date? = nil,
    snoozedAt: Date? = nil, settledAt: Date? = nil, settledBy: String? = nil
  ) {
    self.pinned = pinned
    self.manualOrder = manualOrder
    self.snoozedUntil = snoozedUntil
    self.snoozedAt = snoozedAt
    self.settledAt = settledAt
    self.settledBy = settledBy
  }
}

public struct BotListStateKey: Hashable, Sendable {
  public let itemKind: String
  public let itemId: String

  public init(itemKind: String, itemId: String) {
    self.itemKind = itemKind
    self.itemId = itemId
  }

  public static let bot = Self(itemKind: "bot", itemId: "")
}

public struct BotBoardInput: Sendable {
  public var bot: BotRecord
  public var sessions: [BotBoardSessionInput]
  public var tasks: [BotBoardTaskInput]
  public var routines: [BotBoardRoutineInput]
  public var suggestions: [BotBoardSuggestionInput]
  public var listStates: [BotListStateKey: BotListState]
  public var now: Date
  public var origin: BotOrigin
  public var redact: @Sendable (String) -> String

  public init(
    bot: BotRecord, sessions: [BotBoardSessionInput] = [], tasks: [BotBoardTaskInput] = [],
    routines: [BotBoardRoutineInput] = [], suggestions: [BotBoardSuggestionInput] = [],
    listStates: [BotListStateKey: BotListState] = [:], now: Date, origin: BotOrigin,
    redact: @escaping @Sendable (String) -> String
  ) {
    self.bot = bot
    self.sessions = sessions
    self.tasks = tasks
    self.routines = routines
    self.suggestions = suggestions
    self.listStates = listStates
    self.now = now
    self.origin = origin
    self.redact = redact
  }
}

public struct BotBoardItem: Codable, Equatable, Sendable {
  public let itemKind: String
  public let itemId: String
  public internal(set) var group: BotBoardGroup
  public let title: String
  public internal(set) var workflowId: String?
  public internal(set) var stepId: String?
  public internal(set) var nodeId: String?
  public internal(set) var backend: String?
  public internal(set) var model: String?
  public internal(set) var startedAt: Date?
  public internal(set) var elapsedMs: Int?
  public internal(set) var lastActivityAt: Date?
  public internal(set) var status: String
  public internal(set) var waitingReason: String?
  public internal(set) var limitedResetAt: Date?
  public internal(set) var activitySource = "session"
  public internal(set) var doingNow: String?
  public internal(set) var checklist: [ActivityPlan] = []
  public internal(set) var pendingRequests: [BotBoardPendingRequest] = []
  public internal(set) var answerPath: String?
  public internal(set) var question: BotBoardQuestion?
  public internal(set) var lastResult: String?
  public internal(set) var sessionId: String?
  public internal(set) var bumpedAt: Date?
  public internal(set) var listState = BotListState()
  public let origin: BotOrigin

  init(itemKind: String, itemId: String, group: BotBoardGroup, title: String, status: String, origin: BotOrigin) {
    self.itemKind = itemKind
    self.itemId = itemId
    self.group = group
    self.title = title
    self.status = status
    self.origin = origin
  }
}

public struct BotBoard: Codable, Equatable, Sendable {
  public let botId: String
  public let groups: [BotBoardGroup: [BotBoardItem]]
  public let closedTotal: Int

  private enum CodingKeys: String, CodingKey { case botId, groups, closedTotal }

  init(botId: String, groups: [BotBoardGroup: [BotBoardItem]], closedTotal: Int) {
    self.botId = botId
    self.groups = groups
    self.closedTotal = closedTotal
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    botId = try values.decode(String.self, forKey: .botId)
    closedTotal = try values.decode(Int.self, forKey: .closedTotal)
    let namedGroups = try values.decode([String: [BotBoardItem]].self, forKey: .groups)
    groups = Dictionary(uniqueKeysWithValues: BotBoardGroup.allCases.map { ($0, namedGroups[$0.rawValue] ?? []) })
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(botId, forKey: .botId)
    try values.encode(closedTotal, forKey: .closedTotal)
    let namedGroups = Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value) })
    try values.encode(namedGroups, forKey: .groups)
  }
}

public struct BotOverviewCounts: Codable, Equatable, Sendable {
  public let needsYou: Int
  public let working: Int
  public let waiting: Int
  public let planned: Int
}

public enum BotListSection: String, Codable, Sendable {
  case active, working, snoozed, settled
}

public struct BotOverviewRow: Codable, Equatable, Sendable {
  public let bot: BotRecord
  public let counts: BotOverviewCounts
  public let inProgress: [BotBoardItem]
  public let lastActivityAt: Date?
  public let lastResult: String?
  public let listState: BotListState
  public let section: BotListSection
  public let workspaceGroup: String
  public let origin: BotOrigin
}

public enum BotListGrouping: String, Codable, Sendable {
  case none, workspace
}

public struct BotWorkspaceGroup: Codable, Equatable, Sendable {
  public let key: String
  public let needsYou: Bool
  public let botIds: [String]
}

public struct BotOverviewList: Codable, Equatable, Sendable {
  public let rows: [BotOverviewRow]
  public let groups: [BotWorkspaceGroup]
}
