import Foundation
import RielaCore
import RielaGraphQL
import RielaWork

extension BotsService {
  struct Projection {
    let input: BotBoardInput
    let routines: [GraphQLBotRoutine]
    let hasPendingRequests: Bool
  }

  func projection(botId: String) throws -> Projection {
    guard let bot = try store.load(botId: botId) else {
      throw BotStoreError(code: "bot_not_found", message: "Bot '\(botId)' was not found")
    }
    let workStore = WorkStore(rootDirectory: store.sessionStoreRoot)
    return try projection(bot: bot, routines: routineStore.list(), tasks: workStore.listTasks(), at: now())
  }

  func projection(bot: BotRecord, routines: [RoutineRecord], tasks: [WorkTask], at: Date) throws -> Projection {
    let ownedRoutines = routines.filter { $0.botId == bot.botId }
    let ownedTasks = try taskInputs(tasks.filter { $0.owner?.identity == "bot:\(bot.botId)" })
    let linkedIds = try store.links(botId: bot.botId).map(\.sessionId)
    let ids = Set(linkedIds + ownedTasks.flatMap(\.attemptSessionIds))
    let sessionData = try sessionInputs(ids.sorted())
    let routineRows = ownedRoutines.map { routine in
      GraphQLBotRoutine(
        routineId: routine.routineId, name: routine.name, workflowName: routine.workflowName,
        status: routine.status.rawValue, nextRunAt: routine.status == .active ? nextBotRoutineTick(routine, after: at) : nil
      )
    }
    let rules = BotMemoryRuntime.redactionRules(environment: environment)
    let input = BotBoardInput(
      bot: bot, sessions: sessionData.inputs, tasks: ownedTasks,
      routines: routineRows.map {
        BotBoardRoutineInput(
          routineId: $0.routineId, name: $0.name, workflowName: $0.workflowName,
          nextFireAt: $0.nextRunAt, active: $0.status == RoutineStatus.active.rawValue
        )
      },
      suggestions: try store.suggestions(botId: bot.botId, status: .accepted).map {
        BotBoardSuggestionInput(
          suggestionId: $0.suggestionId, title: rules.redactText($0.title), status: $0.status.rawValue,
          acceptedAt: $0.acceptedAt.flatMap(botDate), startedSessionId: $0.startedSessionId
        )
      },
      listStates: try store.listState(botId: bot.botId), now: at, origin: origin(at),
      redact: { rules.redactText($0) }
    )
    return Projection(input: input, routines: routineRows, hasPendingRequests: sessionData.hasPendingRequests)
  }

  private func sessionInputs(_ ids: [String]) throws -> (inputs: [BotBoardSessionInput], hasPendingRequests: Bool) {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: store.sessionStoreRoot)
    let families = try ids.map { id in
      (id, try runtime.sessionFamilyIds(of: id))
    }
    let allIds = Set(families.flatMap(\.1) + ids).sorted()
    let snapshots = try runtime.loadFamily(ids: allIds)
    let sessions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.session.sessionId, $0.session) })
    let states = try store.activityStates(sessionIds: allIds)
    let pending = try store.pendingActivityRequests(sessionIds: allIds)
    let requests = Dictionary(grouping: pending, by: \.sessionId)
    let inputs = families.compactMap { id, familyIds -> BotBoardSessionInput? in
      guard let session = sessions[id] else { return nil }
      let descendants = familyIds.compactMap { $0 == id ? nil : sessions[$0] }
      let relatedRequests = Set(familyIds + [id]).flatMap { requests[$0] ?? [] }.map {
        BotBoardPendingRequest(
          requestId: $0.requestId, title: $0.title, options: $0.options, createdAt: $0.createdAt, expiresAt: $0.expiresAt
        )
      }
      let childStates = Dictionary(uniqueKeysWithValues: descendants.compactMap { child in
        sessionActivity(child, state: states[child.sessionId]).map { (child.sessionId, $0) }
      })
      return BotBoardSessionInput(
        session: session, descendants: descendants, activity: sessionActivity(session, state: states[id]),
        descendantActivities: childStates, pendingRequests: relatedRequests
      )
    }
    return (inputs, !pending.isEmpty)
  }

  private func sessionActivity(_ session: WorkflowSession, state: ActivityState?) -> ActivityState? {
    if let state { return state }
    let execution = session.executions.last(where: { $0.stepId == session.currentStepId }) ?? session.executions.last
    guard let model = execution?.adapterOutput?.model else { return nil }
    var fallback = ActivityState()
    fallback.reportedModel = model
    return fallback
  }

  private func taskInputs(_ tasks: [WorkTask]) throws -> [BotBoardTaskInput] {
    guard !tasks.isEmpty else { return [] }
    let workStore = WorkStore(rootDirectory: store.sessionStoreRoot)
    // WorkStore owns the timestamp column, which is not in WorkTask's record.
    let updateTimes = try store.read { database in
      try database.query("SELECT task_id, updated_at FROM work_tasks", bindings: []).reduce(into: [String: Date]()) { dates, row in
        if let id = row["task_id"], let stamp = row["updated_at"] {
          dates[id] = botDate(stamp)
        }
      }
    } ?? [:]
    return try tasks.compactMap { task in
      guard let updatedAt = updateTimes[task.id.rawValue] else { return nil }
      let handover = try workStore.latestHandover(taskId: task.id)
      let question: BotBoardQuestion?
      if let handover, case let .userInputRequired(input) = handover.reason {
        question = BotBoardQuestion(questionId: input.id, text: input.text, optionIds: input.options.map(\.id))
      } else {
        question = nil
      }
      let reason = try task.state == .waiting ? workStore.listDecisions(taskId: task.id).reversed().compactMap { decision in
        if case let .wait(reason) = decision.kind { return String(describing: reason) }
        return nil
      }.first : nil
      return BotBoardTaskInput(
        taskId: task.id.rawValue, title: task.title, state: task.state.rawValue, updatedAt: updatedAt,
        waitReason: reason, question: question, attemptSessionIds: try workStore.listAttempts(taskId: task.id).compactMap(\.sessionId)
      )
    }
  }
}
