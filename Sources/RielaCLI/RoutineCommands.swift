import ArgumentParser
import Foundation
import RielaCore
import RielaGraphQL
import RielaWorkflowRegistry

struct ParsedRoutineOptions: ParsableArguments, Sendable {
  @Option var name: String?
  @Option var task: String?
  @Option var schedule: String?
  @Option var every: String?
  @Option var timezone: String?
  @Option var workflow: String?
  @Option var bot: String?
  @Option var remote: String?
  @Option(name: .customLong("completion-criteria")) var completionCriteria: String?
  @Option(name: .customLong("overlap-policy")) var overlapPolicy: String?
  @Option(name: .customLong("max-queued-runs")) var maxQueuedRuns: Int?
  @Option(name: .customLong("max-concurrent-runs")) var maxConcurrentRuns: Int?
  @Flag(name: .customLong("clear-overlap-policy")) var clearOverlapPolicy = false
  @Option var instruction: String?
  @Option var eventRoot: String?
  @Option(name: .customLong("routine-store")) var routineStore: String?
  @Flag(name: .customLong("deactivate-workflow-on-completion")) var deactivateWorkflowOnCompletion = false
  @Option var note: String?
  @Option var status: String?
  @Option var limit: Int?
  @Option(name: [.customLong("working-dir"), .customLong("working-directory")]) var workingDirectory: String?
  @Option var output: String?

  init() {}

  init(_ arguments: [String]) throws {
    do {
      self = try Self.parse(arguments)
    } catch {
      throw CLIUsageError(Self.message(for: error))
    }
  }
}

private struct RemoteRoutineCreated: Decodable {
  struct Routine: Decodable {
    let routineId: String
    let name: String
    let status: GraphQLRoutineStatus
    let schedule: String
    let workflowName: String
    let runCount: Int
    let botId: String?

    var summary: String {
      "routine=\(routineId) name=\(name) status=\(status.routineStatus.rawValue) "
        + "schedule=\"\(schedule)\" workflow=\(workflowName) runs=\(runCount)"
        + (botId.map { " botId=\($0)" } ?? "")
    }
  }

  let accepted: Bool
  let diagnostics: [String]
  let routine: Routine?
}

extension ScopedParityCommandRunner {
  func routineResult(
    options: CLICommandOptions, transport: @escaping RemoteHTTP.Transport
  ) async throws -> ScopedParityCommandResult {
    let action = options.command ?? RoutineClientAction.list.rawValue
    let parsed = try ParsedRoutineOptions(options.arguments)
    if parsed.remote != nil && action != RoutineClientAction.create.rawValue {
      throw CLIUsageError("--remote is supported only by routine create")
    }
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let environment = CLIRuntimeEnvironment.mergedProcessEnvironment()
    let sessionStoreRoot = CLIWorkflowSessionStore.resolveRootDirectory(
      sessionStore: nil, scope: .auto, workingDirectory: workingDirectory, environment: environment
    )
    let service = RoutineService(
      workingDirectory: workingDirectory,
      environment: environment,
      botExists: BotRunLinker.botExists(sessionStoreRoot: sessionStoreRoot)
    )
    do {
      switch action {
      case RoutineClientAction.create.rawValue:
        guard let name = parsed.name, !name.isEmpty else {
          throw CLIUsageError("routine create requires --name")
        }
        guard let task = parsed.task, !task.isEmpty else {
          throw CLIUsageError("routine create requires --task")
        }
        guard let workflow = parsed.workflow, !workflow.isEmpty else {
          throw CLIUsageError("routine create requires --workflow <workflow-name>")
        }
        let request = RoutineCreateRequest(
          name: name,
          instruction: parsed.instruction,
          task: task,
          schedule: parsed.schedule,
          every: parsed.every,
          timezone: parsed.timezone,
          workflowName: workflow,
          completionCriteria: parsed.completionCriteria,
          eventRoot: parsed.eventRoot,
          routineStoreRoot: parsed.routineStore,
          deactivateWorkflowOnCompletion: parsed.deactivateWorkflowOnCompletion,
          overlapPolicy: parsed.overlapPolicy,
          maxQueuedRuns: parsed.maxQueuedRuns,
          maxConcurrentRuns: parsed.maxConcurrentRuns,
          botId: parsed.bot
        )
        if let remote = parsed.remote, remote != "local" {
          return try await createRemoteRoutine(
            request, remote: remote, environment: environment, transport: transport
          )
        }
        let result = try service.create(request)
        return routineCommandResult(
          action: action,
          target: result.routine.routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case RoutineClientAction.list.rawValue:
        let statusFilter = try parsed.status.map { raw -> RoutineStatus in
          guard let status = RoutineStatus(rawValue: raw) else {
            throw CLIUsageError("unknown routine status '\(raw)'; expected active, disabled, or completed")
          }
          return status
        }
        let routines = try service.list(
          filter: RoutineListFilter(status: statusFilter, limit: parsed.limit),
          routineStoreRoot: parsed.routineStore
        )
        return routineCommandResult(
          action: action,
          target: options.target,
          records: routines.map(routineSummaryLine)
        )
      case RoutineClientAction.inspect.rawValue:
        guard let routineId = options.target else {
          throw CLIUsageError("routine inspect requires <routine-id>")
        }
        let record = try service.get(routineId: routineId, routineStoreRoot: parsed.routineStore)
        return routineCommandResult(
          action: action,
          target: routineId,
          records: routineDetailLines(record)
        )
      case RoutineClientAction.complete.rawValue:
        guard let routineId = options.target else {
          throw CLIUsageError("routine complete requires <routine-id>")
        }
        let result = try service.complete(
          routineId: routineId,
          note: parsed.note,
          routineStoreRoot: parsed.routineStore
        )
        return routineCommandResult(
          action: action,
          target: routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case RoutineClientAction.enable.rawValue, RoutineClientAction.disable.rawValue:
        guard let routineId = options.target else {
          throw CLIUsageError("routine \(action) requires <routine-id>")
        }
        let result = try service.setStatus(
          routineId: routineId,
          status: action == RoutineClientAction.enable.rawValue ? .active : .disabled,
          routineStoreRoot: parsed.routineStore
        )
        return routineCommandResult(
          action: action,
          target: routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case RoutineClientAction.setOverlapPolicy.rawValue:
        guard let routineId = options.target else {
          throw CLIUsageError("routine set-overlap-policy requires <routine-id>")
        }
        guard (parsed.overlapPolicy != nil) != parsed.clearOverlapPolicy else {
          throw CLIUsageError(
            "routine set-overlap-policy requires exactly one of --overlap-policy or --clear-overlap-policy"
          )
        }
        // The service owns the clear-with-cap rule and every policy/cap rule,
        // so the CLI, GraphQL and add-on surfaces report the same message.
        let result = try service.setOverlapPolicy(
          routineId: routineId,
          overlapPolicy: parsed.clearOverlapPolicy ? nil : parsed.overlapPolicy,
          maxQueuedRuns: parsed.maxQueuedRuns,
          maxConcurrentRuns: parsed.maxConcurrentRuns,
          routineStoreRoot: parsed.routineStore
        )
        return routineCommandResult(
          action: action,
          target: routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case RoutineClientAction.delete.rawValue:
        guard let routineId = options.target else {
          throw CLIUsageError("routine delete requires <routine-id>")
        }
        let result = try service.delete(routineId: routineId, routineStoreRoot: parsed.routineStore)
        return routineCommandResult(
          action: action,
          target: routineId,
          records: ["deleted=\(result.routine.routineId)"] + result.diagnostics
        )
      default:
        throw CLIUsageError(
          "unknown routine command '\(action)'; expected create, list, inspect, complete, enable, disable, set-overlap-policy, or delete"
        )
      }
    } catch let error as RoutineServiceError {
      throw CLIUsageError(error.message)
    } catch let error as RoutineStoreError {
      throw CLIUsageError(error.message)
    }
  }

  private func createRemoteRoutine(
    _ request: RoutineCreateRequest, remote: String, environment: [String: String],
    transport: @escaping RemoteHTTP.Transport
  ) async throws -> ScopedParityCommandResult {
    guard remote != "*" else {
      throw CLIUsageError("remote_selector_invalid: routine create requires one remote")
    }
    guard request.eventRoot == nil, request.routineStoreRoot == nil else {
      throw CLIUsageError("routine create --remote uses the server's event and routine stores")
    }
    if let overlapPolicy = request.overlapPolicy, EventOverlapPolicy(rawValue: overlapPolicy) == nil {
      throw CLIUsageError("unknown routine overlap policy; expected \(EventOverlapPolicy.allowedValuesText)")
    }
    let credentials = try RemoteRegistry(environment: environment).credentials(name: remote)
    let input = try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(request))
    let client = RemoteGraphQLClient(record: credentials.record, token: credentials.token, transport: transport)
    let result = try await client.execute(
      query: """
        mutation CreateRoutine($input: CreateRoutineInput!) {
          createRoutine(input: $input) {
            accepted diagnostics
            routine { routineId name status schedule workflowName runCount botId }
          }
        }
        """,
      variables: ["input": .object(input)],
      operationName: "CreateRoutine"
    )
    guard let response = result["createRoutine"] else {
      throw CLIUsageError("remote routine create response missing payload")
    }
    let payload = try JSONDecoder().decode(RemoteRoutineCreated.self, from: JSONEncoder().encode(response))
    guard payload.accepted, let routine = payload.routine else {
      throw CLIUsageError("remote routine create was rejected")
    }
    return routineCommandResult(
      action: RoutineClientAction.create.rawValue,
      target: routine.routineId,
      records: [routine.summary] + payload.diagnostics
    )
  }

  private func routineCommandResult(
    action: String,
    target: String?,
    records: [String]
  ) -> ScopedParityCommandResult {
    ScopedParityCommandResult(
      scope: "routine",
      command: action,
      target: target,
      status: "ok",
      records: records
    )
  }

  private func routineSummaryLine(_ record: RoutineRecord) -> String {
    "routine=\(record.routineId) name=\(record.name) status=\(record.status.rawValue) "
      + "schedule=\"\(record.schedule)\" workflow=\(record.workflowName) runs=\(record.runCount)"
      + (record.botId.map { " botId=\($0)" } ?? "")
  }

  private func routineDetailLines(_ record: RoutineRecord) -> [String] {
    var lines = [
      "routine=\(record.routineId)",
      "name=\(record.name)",
      "status=\(record.status.rawValue)",
      "schedule=\(record.schedule)",
      "timezone=\(record.timezone ?? "UTC")",
      "workflow=\(record.workflowName)",
      "task=\(record.task)",
      "completionCriteria=\(record.completionCriteria ?? "-")",
      "createdAt=\(record.createdAt)",
      "updatedAt=\(record.updatedAt)",
      "lastRunAt=\(record.lastRunAt ?? "-")",
      "runCount=\(record.runCount)",
      "eventRoot=\(record.eventRoot)",
      "sourceId=\(record.sourceId)",
      "bindingId=\(record.bindingId)",
      "deactivateWorkflowOnCompletion=\(record.deactivateWorkflowOnCompletion)"
    ]
    if let botId = record.botId {
      lines.append("botId=\(botId)")
    }
    lines.append("overlapPolicy=\(record.overlapPolicy ?? "inherit")")
    if let maxQueuedRuns = record.maxQueuedRuns {
      lines.append("maxQueuedRuns=\(maxQueuedRuns)")
    }
    if let maxConcurrentRuns = record.maxConcurrentRuns {
      lines.append("maxConcurrentRuns=\(maxConcurrentRuns)")
    }
    if let instruction = record.instruction {
      lines.append("instruction=\(instruction)")
    }
    if let completedAt = record.completedAt {
      lines.append("completedAt=\(completedAt)")
    }
    if let completionNote = record.completionNote {
      lines.append("completionNote=\(completionNote)")
    }
    return lines
  }
}
