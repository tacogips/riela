import Foundation

public enum BotBoardProjector {
  private static let closedLimit = 20
  private static let autoSettleAge: TimeInterval = 7 * 24 * 60 * 60

  public static func board(_ input: BotBoardInput) -> BotBoard {
    makeBoard(input, items: items(input))
  }

  public static func overviewRow(_ input: BotBoardInput) -> BotOverviewRow {
    overview(input).row
  }

  public static func overviewList(_ inputs: [BotBoardInput], groupBy: BotListGrouping) -> BotOverviewList {
    let rows = inputs.map(overview).sorted { lhs, rhs in
      precedes(
        OrderKey(lhs.row.listState, lhs.bumpedAt ?? lhs.row.lastActivityAt, lhs.row.bot.botId, lhs.row.origin.remote),
        OrderKey(rhs.row.listState, rhs.bumpedAt ?? rhs.row.lastActivityAt, rhs.row.bot.botId, rhs.row.origin.remote)
      )
    }.map(\.row)
    guard groupBy == .workspace else { return BotOverviewList(rows: rows, groups: []) }

    let byWorkspace = Dictionary(grouping: rows, by: \.workspaceGroup)
    var seen: Set<String> = []
    let groups = rows.compactMap { row -> BotWorkspaceGroup? in
      let key = row.workspaceGroup
      guard seen.insert(key).inserted, let members = byWorkspace[key] else { return nil }
      return BotWorkspaceGroup(key: key, needsYou: members.contains { $0.counts.needsYou > 0 }, botIds: members.map(\.bot.botId))
    }
    return BotOverviewList(rows: rows, groups: groups)
  }

  public static func lastResultLine(
    session: WorkflowSession, finalMessageLine: String?, redact: (String) -> String
  ) -> String {
    let stepId = session.currentStepId ?? session.executions.last?.stepId ?? session.entryStepId
    let fallback = "\(session.status.rawValue) at step \(stepId)"
    let failure = session.status == .failed ? session.failureReason : nil
    let source = [failure, finalMessageLine].compactMap { $0 }.first { firstLine($0) != nil } ?? fallback
    return String((firstLine(redact(source)) ?? "").prefix(200))
  }

  public static func canSettle(_ item: BotBoardItem) -> Bool {
    item.pendingRequests.isEmpty && (item.group == .planned || item.group == .closed)
  }

  public static func canSettleBot(_ board: BotBoard) -> Bool {
    board.groups.values.joined().allSatisfy(canSettle)
  }

  private static func firstLine(_ text: String) -> String? {
    let line = text.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? nil : line
  }

  private static func makeBoard(_ input: BotBoardInput, items: [Projection]) -> BotBoard {
    let byGroup = Dictionary(grouping: items, by: \.item.group)
    let groups = Dictionary(uniqueKeysWithValues: BotBoardGroup.allCases.map { group in
      let candidates = byGroup[group] ?? []
      let visible = group == .closed ? Array(candidates.sorted(by: newerTerminal).prefix(closedLimit)) : candidates
      let ordered = visible.map(\.item).sorted { precedes(OrderKey($0), OrderKey($1)) }
      return (group, ordered)
    })
    return BotBoard(botId: input.bot.botId, groups: groups, closedTotal: byGroup[.closed]?.count ?? 0)
  }

  private static func overview(_ input: BotBoardInput) -> (row: BotOverviewRow, bumpedAt: Date?) {
    let items = items(input)
    let board = makeBoard(input, items: items)
    let activeItems = board.groups[.inProgress] ?? []
    let counts = BotOverviewCounts(
      needsYou: board.groups[.needsYou]?.count ?? 0, working: activeItems.count,
      waiting: board.groups[.waiting]?.count ?? 0, planned: board.groups[.planned]?.count ?? 0
    )
    let lastActivityAt = items.compactMap(\.item.lastActivityAt).max()
    let latestClosed = items.filter { $0.item.group == .closed }.min(by: newerTerminal)
    let state = input.listStates[.bot] ?? BotListState()
    let row = BotOverviewRow(
      bot: input.bot, counts: counts, inProgress: activeItems, lastActivityAt: lastActivityAt,
      lastResult: activeItems.isEmpty ? latestClosed?.item.lastResult : nil,
      listState: state, section: section(state, now: input.now, items: items),
      workspaceGroup: input.bot.workspace ?? "ungrouped", origin: input.origin
    )
    return (row, items.compactMap(\.item.bumpedAt).max())
  }

  private static func section(_ state: BotListState, now: Date, items: [Projection]) -> BotListSection {
    let open = items.map(\.item).filter { $0.group != .closed }
    if let settledAt = state.settledAt {
      let newWork = items.contains { projection in
        let item = projection.item
        return isNewer(projection.workAt, than: settledAt)
          || isNewer(projection.terminalAt, than: settledAt)
          || (item.group != .closed && isNewer(item.lastActivityAt, than: settledAt))
      }
      return newWork ? .active : .settled
    }
    if let until = state.snoozedUntil, now < until {
      let wake = items.contains {
        ($0.item.group == .needsYou && isNewer($0.item.bumpedAt, than: state.snoozedAt))
          || isNewer($0.failureAt, than: state.snoozedAt)
      }
      return wake ? .active : .snoozed
    }
    if !open.isEmpty, open.allSatisfy({ $0.group == .inProgress || $0.group == .waiting }) {
      return .working
    }
    return .active
  }

  private static func isNewer(_ date: Date?, than cutoff: Date?) -> Bool {
    guard let date else { return false }
    return cutoff.map { date > $0 } ?? true
  }

  private static func items(_ input: BotBoardInput) -> [Projection] {
    let families = input.sessions.map(SessionFamily.init)
    let attemptIds = Set(input.tasks.flatMap(\.attemptSessionIds))
    let familiesByAttempt = families.reduce(into: [String: SessionFamily]()) { result, family in
      for session in family.sessions where attemptIds.contains(session.sessionId) {
        result[session.sessionId] = family
      }
    }

    var projected = families.compactMap { family -> Projection? in
      guard !family.sessions.contains(where: { attemptIds.contains($0.sessionId) }) else { return nil }
      return family.project(input)
    }
    for task in input.tasks {
      var seen: Set<String> = []
      let attempts = task.attemptSessionIds.compactMap { familiesByAttempt[$0] }.filter {
        seen.insert($0.root.sessionId).inserted
      }
      projected.append(project(task, attempts: attempts, input: input))
    }
    projected += input.routines.compactMap { routine in
      guard routine.active, let nextFireAt = routine.nextFireAt else { return nil }
      var item = BotBoardItem(
        itemKind: "routine", itemId: routine.routineId, group: .planned, title: routine.name, status: "scheduled", origin: input.origin
      )
      item.workflowId = routine.workflowName
      item.startedAt = nextFireAt
      return Projection(item: item)
    }
    projected += input.suggestions.compactMap { suggestion in
      guard suggestion.status == "accepted", suggestion.startedSessionId == nil else { return nil }
      let item = BotBoardItem(
        itemKind: "suggestion", itemId: suggestion.suggestionId, group: .planned,
        title: suggestion.title, status: suggestion.status, origin: input.origin
      )
      return Projection(item: item, workAt: suggestion.acceptedAt)
    }

    return projected.map { projection in
      var projection = projection
      let key = BotListStateKey(itemKind: projection.item.itemKind, itemId: projection.item.itemId)
      var state = input.listStates[key] ?? BotListState()
      if projection.item.group == .closed, projection.item.pendingRequests.isEmpty,
        state.settledAt == nil, let lastActivityAt = projection.item.lastActivityAt {
        let eligibleAt = lastActivityAt.addingTimeInterval(autoSettleAge)
        if input.now >= eligibleAt {
          state.settledAt = eligibleAt
          state.settledBy = "auto"
        }
      }
      projection.item.listState = state
      return projection
    }
  }

  private static func newerTerminal(_ lhs: Projection, _ rhs: Projection) -> Bool {
    if lhs.terminalAt != rhs.terminalAt {
      return isNewer(lhs.terminalAt, than: rhs.terminalAt)
    }
    return (lhs.item.itemId, lhs.item.itemKind) < (rhs.item.itemId, rhs.item.itemKind)
  }

  private static func precedes(_ lhs: OrderKey, _ rhs: OrderKey) -> Bool {
    if lhs.state.pinned != rhs.state.pinned { return lhs.state.pinned }
    if lhs.state.manualOrder != rhs.state.manualOrder {
      guard let left = lhs.state.manualOrder else { return false }
      return rhs.state.manualOrder.map { left < $0 } ?? true
    }
    if lhs.activityAt != rhs.activityAt {
      return isNewer(lhs.activityAt, than: rhs.activityAt)
    }
    return (lhs.id, lhs.discriminator) < (rhs.id, rhs.discriminator)
  }

  private struct OrderKey {
    let state: BotListState
    let activityAt: Date?
    let id: String
    let discriminator: String

    init(_ state: BotListState, _ activityAt: Date?, _ id: String, _ discriminator: String) {
      self.state = state
      self.activityAt = activityAt
      self.id = id
      self.discriminator = discriminator
    }

    init(_ item: BotBoardItem) {
      self.init(item.listState, item.bumpedAt ?? item.lastActivityAt, item.itemId, item.itemKind)
    }
  }

  struct Projection {
    var item: BotBoardItem
    var terminalAt: Date?
    var failureAt: Date?
    var workAt: Date?
  }
}
