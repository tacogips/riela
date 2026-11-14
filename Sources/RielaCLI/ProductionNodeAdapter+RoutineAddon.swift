import Foundation
import RielaAddonSupport
import RielaCore
import RielaWorkflowRegistry

enum BuiltinRoutineAddon: String {
  case create = "riela/routine-create"
  case complete = "riela/routine-complete"
  case get = "riela/routine-get"
  case list = "riela/routine-list"
  case updateStatus = "riela/routine-update-status"
  case delete = "riela/routine-delete"
}

extension BuiltinWorkflowAddonResolver {
  func executeRoutineAddon(
    _ input: WorkflowAddonExecutionInput,
    operation: BuiltinRoutineAddon
  ) throws -> AdapterExecutionOutput {
    guard input.addon.version == nil || input.addon.version == "1" else {
      throw AdapterExecutionError(.policyBlocked, "unsupported \(input.addon.name) version '\(input.addon.version ?? "")'")
    }
    let config = input.addon.config ?? [:]
    let variables = addonVariables(for: input)
    let service = RoutineService(
      workingDirectory: workingDirectory.path,
      environment: environment
    )
    func value(_ key: String) -> String? {
      memoryConfigString(key, config: config, variables: variables) ?? nonEmptyString(variables[key])
    }
    let routineStoreRoot = value("routineStoreRoot") ?? value("routineStore")

    func requiredRoutineId() throws -> String {
      guard let routineId = value("routineId") else {
        throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires routineId (config.routineId or inputs.routineId)")
      }
      return routineId
    }

    do {
      switch operation {
      case .create:
        guard let name = value("name") ?? value("routineName") else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires name")
        }
        guard let task = value("task") else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires task")
        }
        guard let workflowName = value("workflowName") ?? value("workflow") else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires workflowName")
        }
        var origin: JSONObject?
        if case let .object(configOrigin)? = config["origin"] {
          origin = configOrigin
        } else if case let .object(variableOrigin)? = variables["origin"] {
          origin = variableOrigin
        }
        let result = try service.create(RoutineCreateRequest(
          name: name,
          instruction: value("instruction"),
          task: task,
          schedule: value("schedule"),
          every: value("every"),
          timezone: value("timezone"),
          workflowName: workflowName,
          completionCriteria: value("completionCriteria"),
          eventRoot: value("eventRoot"),
          routineStoreRoot: routineStoreRoot,
          deactivateWorkflowOnCompletion: boolValue(config["deactivateWorkflowOnCompletion"])
            ?? boolValue(variables["deactivateWorkflowOnCompletion"]),
          origin: origin
        ))
        return routineAddonOutput(input: input, operation: operation, payload: [
          "created": .bool(true),
          "routineId": .string(result.routine.routineId),
          "routine": try routineJSON(result.routine),
          "diagnostics": .array(result.diagnostics.map { .string($0) })
        ])
      case .complete:
        // The condition gate comes first so a workflow can call this addon
        // unconditionally on every tick: a not-met condition is a no-op even
        // when the run had no routine context (e.g. mock-scenario runs).
        let conditionMet = boolValue(config["conditionMet"]) ?? boolValue(variables["conditionMet"]) ?? true
        guard conditionMet else {
          return routineAddonOutput(input: input, operation: operation, payload: [
            "completed": .bool(false),
            "routineId": .string(value("routineId") ?? "-"),
            "reason": .string("completion condition not met; routine stays active")
          ])
        }
        let routineId = try requiredRoutineId()
        let result = try service.complete(
          routineId: routineId,
          note: value("note"),
          routineStoreRoot: routineStoreRoot
        )
        return routineAddonOutput(input: input, operation: operation, payload: [
          "completed": .bool(true),
          "routineId": .string(routineId),
          "routine": try routineJSON(result.routine),
          "diagnostics": .array(result.diagnostics.map { .string($0) })
        ])
      case .get:
        let routineId = try requiredRoutineId()
        let record = try service.get(routineId: routineId, routineStoreRoot: routineStoreRoot)
        return routineAddonOutput(input: input, operation: operation, payload: [
          "routineId": .string(routineId),
          "routine": try routineJSON(record)
        ])
      case .list:
        let statusFilter = try value("status").map { raw -> RoutineStatus in
          guard let status = RoutineStatus(rawValue: raw) else {
            throw AdapterExecutionError(.policyBlocked, "unknown routine status '\(raw)'")
          }
          return status
        }
        let limit = intValue(config["limit"]) ?? intValue(variables["limit"])
        let routines = try service.list(
          filter: RoutineListFilter(status: statusFilter, workflowName: value("workflowName"), limit: limit),
          routineStoreRoot: routineStoreRoot
        )
        return routineAddonOutput(input: input, operation: operation, payload: [
          "count": .integer(Int64(routines.count)),
          "routines": .array(try routines.map(routineJSON))
        ])
      case .updateStatus:
        let routineId = try requiredRoutineId()
        guard let rawStatus = value("status"), let status = RoutineStatus(rawValue: rawStatus) else {
          throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) requires status active or disabled")
        }
        let result = try service.setStatus(
          routineId: routineId,
          status: status,
          routineStoreRoot: routineStoreRoot
        )
        return routineAddonOutput(input: input, operation: operation, payload: [
          "routineId": .string(routineId),
          "status": .string(result.routine.status.rawValue),
          "routine": try routineJSON(result.routine),
          "diagnostics": .array(result.diagnostics.map { .string($0) })
        ])
      case .delete:
        let routineId = try requiredRoutineId()
        let result = try service.delete(routineId: routineId, routineStoreRoot: routineStoreRoot)
        return routineAddonOutput(input: input, operation: operation, payload: [
          "deleted": .bool(true),
          "routineId": .string(routineId),
          "diagnostics": .array(result.diagnostics.map { .string($0) })
        ])
      }
    } catch let error as RoutineServiceError {
      throw AdapterExecutionError(.policyBlocked, "\(input.addon.name) failed: \(error.message)")
    } catch let error as RoutineStoreError {
      throw AdapterExecutionError(.providerError, "\(input.addon.name) failed: \(error.message)")
    }
  }

  private func routineJSON(_ record: RoutineRecord) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(record))
  }

  private func routineAddonOutput(
    input: WorkflowAddonExecutionInput,
    operation: BuiltinRoutineAddon,
    payload extraPayload: JSONObject
  ) -> AdapterExecutionOutput {
    var payload: JSONObject = [
      "status": .string("ok"),
      "addon": .string(input.addon.name),
      "operation": .string(operation.rawValue.replacingOccurrences(of: "riela/routine-", with: "")),
      "stepId": .string(input.stepId)
    ]
    for (key, value) in extraPayload {
      payload[key] = value
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: payload
    )
  }
}
