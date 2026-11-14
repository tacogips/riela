import ArgumentParser
import Foundation
import RielaCore
import RielaWorkflowRegistry

struct ParsedRoutineOptions: ParsableArguments, Sendable {
  @Option var name: String?
  @Option var task: String?
  @Option var schedule: String?
  @Option var every: String?
  @Option var timezone: String?
  @Option var workflow: String?
  @Option(name: .customLong("completion-criteria")) var completionCriteria: String?
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

extension ScopedParityCommandRunner {
  func routineResult(options: CLICommandOptions) throws -> ScopedParityCommandResult {
    let action = options.command ?? "list"
    let parsed = try ParsedRoutineOptions(options.arguments)
    let workingDirectory = parsed.workingDirectory ?? FileManager.default.currentDirectoryPath
    let service = RoutineService(
      workingDirectory: workingDirectory,
      environment: CLIRuntimeEnvironment.mergedProcessEnvironment()
    )
    do {
      switch action {
      case "create":
        guard let name = parsed.name, !name.isEmpty else {
          throw CLIUsageError("routine create requires --name")
        }
        guard let task = parsed.task, !task.isEmpty else {
          throw CLIUsageError("routine create requires --task")
        }
        guard let workflow = parsed.workflow, !workflow.isEmpty else {
          throw CLIUsageError("routine create requires --workflow <workflow-name>")
        }
        let result = try service.create(RoutineCreateRequest(
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
          deactivateWorkflowOnCompletion: parsed.deactivateWorkflowOnCompletion
        ))
        return routineCommandResult(
          action: action,
          target: result.routine.routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case "list":
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
      case "inspect":
        guard let routineId = options.target else {
          throw CLIUsageError("routine inspect requires <routine-id>")
        }
        let record = try service.get(routineId: routineId, routineStoreRoot: parsed.routineStore)
        return routineCommandResult(
          action: action,
          target: routineId,
          records: routineDetailLines(record)
        )
      case "complete":
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
      case "enable", "disable":
        guard let routineId = options.target else {
          throw CLIUsageError("routine \(action) requires <routine-id>")
        }
        let result = try service.setStatus(
          routineId: routineId,
          status: action == "enable" ? .active : .disabled,
          routineStoreRoot: parsed.routineStore
        )
        return routineCommandResult(
          action: action,
          target: routineId,
          records: [routineSummaryLine(result.routine)] + result.diagnostics
        )
      case "delete":
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
          "unknown routine command '\(action)'; expected create, list, inspect, complete, enable, disable, or delete"
        )
      }
    } catch let error as RoutineServiceError {
      throw CLIUsageError(error.message)
    } catch let error as RoutineStoreError {
      throw CLIUsageError(error.message)
    }
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
