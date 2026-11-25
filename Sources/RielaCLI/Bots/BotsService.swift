import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

struct BotsService: Sendable {
  let workingDirectory: String
  let sessionStoreRoot: String
  let environment: [String: String]
  var now: @Sendable () -> Date = Date.init
  var origin: @Sendable (Date) -> BotOrigin = {
    BotOrigin.local(serverId: nil, serverName: nil, at: $0)
  }
  var activityClock: @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now }
  var activitySleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  var activityWaiters = BotActivityWaiters.shared

  var store: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStoreRoot)) }

  var routineStore: RoutineStore {
    RoutineStore(rootDirectory: RoutineStore.resolveRootDirectory(
      explicit: nil, workingDirectory: workingDirectory, environment: environment
    ))
  }

  func overview(groupBy: BotListGrouping) throws -> BotListPayload {
    let bots = try store.list()
    let at = now()
    guard !bots.isEmpty else { return BotListPayload(bots: [], groups: [], origin: origin(at)) }
    let routines = try routineStore.list()
    let workStore = WorkStore(rootDirectory: store.sessionStoreRoot)
    let tasks = try workStore.listTasks()
    let list = try BotBoardProjector.overviewList(bots.map { bot in
      try projection(bot: bot, routines: routines, tasks: tasks, at: at).input
    }, groupBy: groupBy)
    return BotListPayload(bots: list.rows, groups: list.groups, origin: origin(at))
  }

  func detail(botId: String, memoryRoot: String? = nil) throws -> BotDetailPayload {
    let result = try projection(botId: botId)
    let suggestions = try store.suggestions(botId: botId)
      .filter { $0.status == .open || $0.status == .accepted }.map { $0.withOrigin(result.input.origin) }
    return BotDetailPayload(
      bot: result.input.bot, board: GraphQLBotBoard(BotBoardProjector.board(result.input)),
      routines: result.routines, origin: result.input.origin,
      memory: try memorySummary(botId: botId, explicitRoot: memoryRoot),
      suggestions: suggestions, jobs: try jobSummaries(bot: result.input.bot)
    )
  }

  var modelCatalog: ModelCatalogService {
    ModelCatalogService(store: store, environment: environment, now: now, origin: origin)
  }

  func create(_ input: CreateBotInput) throws -> BotMutationPayload {
    guard let name = input.name else { throw BotStoreError(code: "bot_invalid", message: "Bot name is required") }
    let stamp = RoutineStore.timestamp(now())
    var record = BotRecord(botId: input.id, name: name, createdAt: stamp, updatedAt: stamp)
    apply(input, to: &record)
    let warnings = try modelWarnings(for: record)
    return BotMutationPayload(bot: try store.create(record), warnings: warnings, origin: origin(now()))
  }

  func update(_ input: UpdateBotInput) throws -> BotMutationPayload {
    guard let botId = input.botId else { throw BotStoreError(code: "bot_invalid", message: "Bot id is required") }
    var warnings: [String] = []
    let record = try store.update(botId: botId) {
      apply(input, to: &$0)
      warnings = try modelWarnings(for: $0)
    }
    return BotMutationPayload(bot: record, warnings: warnings, origin: origin(now()))
  }

  private func modelWarnings(for record: BotRecord) throws -> [String] {
    let catalog = modelCatalog
    let provider = try record.providerInstanceId.map { try catalog.configuredInstance(id: $0) }
    guard let model = record.defaultModel, !model.isEmpty, model != ModelSentinel.defaultModel,
      let driver = provider?.driver ?? record.defaultBackend.flatMap(NodeExecutionBackend.init(rawValue:)),
      try !ModelCatalog.isKnown(model: model, driver: driver, catalog: catalog.catalog()) else {
      return []
    }
    return ["model_unknown: \(String(reflecting: model)) is not in the catalog for \(driver.rawValue)"]
  }

  private func apply(_ input: BotRecordInput, to record: inout BotRecord) {
    record.name = input.name ?? record.name
    record.purpose = input.purpose ?? record.purpose
    record.personaId = input.personaId ?? record.personaId
    record.defaultBackend = input.defaultBackend ?? record.defaultBackend
    record.defaultModel = input.defaultModel ?? record.defaultModel
    record.providerInstanceId = input.providerInstanceId ?? record.providerInstanceId
    record.workspace = input.workspace ?? record.workspace
    record.memoryUpkeep = input.memoryUpkeep ?? record.memoryUpkeep
    record.lookAround = input.lookAround ?? record.lookAround
    record.permissionWaitMs = input.permissionWaitMs ?? record.permissionWaitMs
  }

  func remove(botId: String) throws -> BotRecord {
    let result = try projection(botId: botId)
    let board = BotBoardProjector.board(result.input)
    let running = result.input.sessions.contains { family in
      family.session.status == .running || family.descendants.contains { $0.status == .running }
    }
    guard !running, !result.hasPendingRequests, board.groups[.inProgress]?.isEmpty != false else {
      throw BotStoreError(code: "bot_busy", message: "Bot '\(botId)' has work in progress or a pending request")
    }
    for routine in result.routines {
      try routineStore.update(routineId: routine.routineId) {
        if $0.botId == botId { $0.botId = nil }
      }
    }
    try store.remove(botId: botId)
    return result.input.bot
  }

  func setListState(_ request: SetBotListStateInput) throws -> BotRecord {
    let result = try projection(botId: request.botId)
    let input = result.input
    let key = try listKey(request, input: input)
    if request.settled == true && key == .bot {
      guard !result.hasPendingRequests, BotBoardProjector.canSettleBot(BotBoardProjector.board(input)) else {
        throw BotStoreError(code: "list_item_busy", message: "Bot has open work")
      }
    }
    let until = try request.snoozedUntil.map { value in
      guard let date = botDate(value), date > input.now, request.clearSnooze != true else {
        throw BotStoreError(code: "bot_invalid", message: "Snooze requires a future ISO-8601 date")
      }
      return date
    }
    if let order = request.manualOrder, order < 0 {
      throw BotStoreError(code: "bot_invalid", message: "List position must be nonnegative")
    }
    try store.setListState(botId: request.botId, key: key) { state in
      if let pinned = request.pinned { state.pinned = pinned }
      if let order = request.manualOrder { state.manualOrder = order }
      if let until { state.snoozedUntil = until; state.snoozedAt = input.now }
      if request.clearSnooze == true { state.snoozedUntil = nil; state.snoozedAt = nil }
      if let settled = request.settled {
        state.settledAt = settled ? input.now : nil
        state.settledBy = settled ? "user" : nil
      }
    }
    return input.bot
  }

  private func listKey(_ request: SetBotListStateInput, input: BotBoardInput) throws -> BotListStateKey {
    if request.itemKind == nil && request.itemId == nil { return .bot }
    let missing = BotStoreError(code: "list_item_not_found", message: "Item does not belong to bot '\(request.botId)'")
    guard let kind = request.itemKind, let id = request.itemId else { throw missing }
    var target = input
    target.routines = []
    if kind == "session" {
      guard !input.tasks.contains(where: { $0.attemptSessionIds.contains(id) }) else { throw missing }
      target.tasks = []
      target.sessions = input.sessions.filter { $0.session.sessionId == id }
    } else if kind == "task" {
      target.tasks = input.tasks.filter { $0.taskId == id }
      let attempts = Set(target.tasks.flatMap(\.attemptSessionIds))
      target.sessions = input.sessions.filter { attempts.contains($0.session.sessionId) }
    } else {
      throw missing
    }
    let board = BotBoardProjector.board(target)
    guard let item = board.groups.values.joined().first(where: { $0.itemKind == kind && $0.itemId == id }) else {
      throw missing
    }
    if request.settled == true && !BotBoardProjector.canSettle(item) {
      throw BotStoreError(code: "list_item_busy", message: "Item has open work")
    }
    return BotListStateKey(itemKind: kind, itemId: id)
  }
}

func botDate(_ value: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  if let date = formatter.date(from: value) { return date }
  formatter.formatOptions.insert(.withFractionalSeconds)
  return formatter.date(from: value)
}
