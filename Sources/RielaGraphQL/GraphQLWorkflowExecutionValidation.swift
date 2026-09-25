import Foundation
import RielaCore

enum WorkflowExecutionInputError: Error {
  case invalid(String)
}

func validateWorkflowExecutionRoots(_ roots: [ParsedGraphQLRootField]) throws {
  try validateUniqueGraphQLRootResponseKeys(roots)
  for root in roots {
    switch root.fieldName {
    case "executeWorkflow":
      guard root.operationType == .mutation else { throw executionInvalid("executeWorkflow requires a mutation") }
      guard Set(root.arguments.keys) == ["input"], case let .object(input)? = root.arguments["input"] else {
        throw executionInvalid("executeWorkflow requires only an input object")
      }
      let allowed: Set<String> = [
        "workflowName", "runtimeVariables", "instanceIdentity", "nodePatch", "maxSteps",
        "maxConcurrency", "maxLoopIterations", "disableDefaultLoopGuard", "defaultTimeoutMs"
      ]
      guard Set(input.keys).isSubset(of: allowed) else { throw executionInvalid("unsupported execution input field") }
      guard case let .string(name)? = input["workflowName"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw executionInvalid("workflowName must be nonempty")
      }
      for key in ["runtimeVariables", "nodePatch"] {
        if let value = input[key], value != .null {
          guard case .object = value else { throw executionInvalid("\(key) must be an object") }
        }
      }
      if let value = input["instanceIdentity"], value != .null {
        guard case let .string(identity) = value,
              !identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw executionInvalid("instanceIdentity must be nonempty")
        }
      }
      for key in ["maxSteps", "maxConcurrency", "maxLoopIterations", "defaultTimeoutMs"] {
        if let value = input[key], value != .null { try validatePositiveExecutionInt(value, field: key) }
      }
      if let value = input["disableDefaultLoopGuard"], value != .null {
        guard case .bool = value else { throw executionInvalid("disableDefaultLoopGuard must be Boolean") }
      }
      try validateExecutionSelections(root.selections, type: "ExecuteWorkflowPayload")
    case "workflowExecution":
      guard root.operationType == .query else { throw executionInvalid("workflowExecution requires a query") }
      guard Set(root.arguments.keys) == ["workflowExecutionId"],
            case let .string(sessionId)? = root.arguments["workflowExecutionId"],
            sessionId.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
            !sessionId.contains("..") else {
        throw executionInvalid("workflowExecutionId is invalid")
      }
      try validateExecutionSelections(root.selections, type: "WorkflowExecutionSummary")
    default:
      throw executionInvalid("unsupported execution root")
    }
  }
}

private func validatePositiveExecutionInt(_ value: JSONValue, field: String) throws {
  switch value {
  case let .integer(number):
    guard number > 0, number <= Int32.max else { throw executionInvalid("\(field) must be a positive Int32") }
  case let .number(number):
    guard number.isFinite, number > 0, number <= Double(Int32.max), number.rounded(.towardZero) == number else {
      throw executionInvalid("\(field) must be a positive Int32")
    }
  default:
    throw executionInvalid("\(field) must be a positive Int32")
  }
}

private func validateExecutionSelections(
  _ selections: [ParsedGraphQLSelectionField],
  type: String
) throws {
  guard !selections.isEmpty else { throw executionInvalid("\(type) requires selections") }
  var responseKeys = Set<String>()
  let fields: [String: String]
  switch type {
  case "ExecuteWorkflowPayload":
    fields = ["workflowExecutionId": "", "sessionId": "", "status": "", "exitCode": ""]
  case "WorkflowExecutionSummary":
    fields = ["session": "WorkflowExecutionSessionSummary", "nodeExecutions": "WorkflowExecutionNodeSummary"]
  case "WorkflowExecutionSessionSummary":
    fields = ["sessionId": "", "workflowName": "", "workflowId": "", "transitions": "WorkflowExecutionTransitionSummary"]
  case "WorkflowExecutionTransitionSummary":
    fields = ["when": ""]
  case "WorkflowExecutionNodeSummary":
    fields = ["nodeExecId": ""]
  default:
    throw executionInvalid("unsupported selection type")
  }
  for selection in selections {
    guard responseKeys.insert(selection.responseKey).inserted,
          selection.arguments.isEmpty,
          selection.fragmentTypeConditions.allSatisfy({ $0 == type }),
          let childType = fields[selection.fieldName] else {
      throw executionInvalid("invalid \(type) selection")
    }
    if childType.isEmpty {
      guard selection.selections.isEmpty else { throw executionInvalid("scalar selection has children") }
    } else {
      try validateExecutionSelections(selection.selections, type: childType)
    }
  }
}

private func executionInvalid(_ message: String) -> WorkflowExecutionInputError { .invalid(message) }
