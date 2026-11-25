import Foundation
import RielaCore
import RielaGraphQL

struct AskWorkflowValidationError: Error {
  let issues: [WorkflowValidationDiagnostic]
}

struct AskWorkflowActionTarget: Sendable {
  enum Mode: String, Sendable {
    case draft, store
  }

  let mode: Mode
  let definition: JSONObject
  let workflowId: String
  let baseWorkflowId: String?
  let baseOriginId: String?
  let expectedRevision: String?

  var record: JSONObject {
    var target: JSONObject = [
      "mode": .string(mode.rawValue), "definition": .object(definition), "workflowId": .string(workflowId)
    ]
    target["baseWorkflowId"] = baseWorkflowId.map(JSONValue.string)
    target["baseOriginId"] = baseOriginId.map(JSONValue.string)
    target["expectedDefinitionRevision"] = expectedRevision.map(JSONValue.string)
    return target
  }

  init(record: JSONObject) throws {
    guard let mode = record.askString("mode").flatMap(Mode.init(rawValue:)),
          case let .object(definition)? = record["definition"],
          let workflowId = record.askString("workflowId") else {
      throw AskActionProposer.invalidTarget
    }
    self.mode = mode
    self.definition = definition
    self.workflowId = workflowId
    baseWorkflowId = record.askString("baseWorkflowId")
    baseOriginId = record.askString("baseOriginId")
    expectedRevision = record.askString("expectedDefinitionRevision")
    guard self.record == record, (baseWorkflowId == nil) == (expectedRevision == nil),
          (baseWorkflowId == nil) == (baseOriginId == nil),
          baseWorkflowId == nil || baseWorkflowId == workflowId else {
      throw AskActionProposer.invalidTarget
    }
  }

  func validate(limits: AskLimits) throws {
    let workflow = try Self.validateDefinition(definition, limits: limits)
    guard workflow.workflowId == workflowId else { throw AskActionProposer.invalidTarget }
  }

  static func validateDefinition(_ definition: JSONObject, limits: AskLimits) throws -> WorkflowDefinition {
    let encoder = JSONEncoder()
    guard try encoder.encode(definition).count <= limits.draftDefinitionBytes else {
      throw AskError(code: "workflow_too_large", message: "The workflow definition exceeds the byte limit")
    }
    do {
      try WorkflowRegistryDefinitionInputPolicy.validate(.object(definition))
    } catch {
      throw AskWorkflowValidationError(issues: [
        .init(severity: .error, path: "workflow", message: "Workflow definition exceeds the nesting limit")
      ])
    }
    let structural = validationValue(.object(definition))
    let validation = validateAuthoredWorkflowData(
      try encoder.encode(structural), validator: DefaultWorkflowValidator(context: .production())
    )
    guard let workflow = validation.workflow else {
      throw AskWorkflowValidationError(issues: Array(validation.diagnostics.filter { $0.severity == .error }.prefix(20)))
    }
    return workflow
  }

  private static func validationValue(_ value: JSONValue) -> JSONValue {
    switch value {
    case let .object(fields):
      return .object(fields.reduce(into: [:]) { result, field in
        let (key, child) = field
        if !AskWorkflowDraft.isRetainHandle(child) {
          result[key] = validationValue(child)
        } else if ["description", "label", "promptTemplate", "model"].contains(key) {
          result[key] = .string("retained")
        }
      })
    case let .array(items):
      return .array(items.map { AskWorkflowDraft.isRetainHandle($0) ? .string("retained") : validationValue($0) })
    default:
      return value
    }
  }
}

extension AskActionProposer {
  func proposeWorkflow(
    conversationId: String, turnId: String, definition: JSONObject, baseWorkflowId: String?, draft: JSONObject?
  ) async throws -> AskAction {
    let workflow = try AskWorkflowActionTarget.validateDefinition(definition, limits: limits)
    if let draft, AskWorkflowDraft.project(.object(draft), environment: environment) != .object(draft) {
      throw AskError(code: "workflow_invalid", message: "The editor draft needs retain handles for protected fields")
    }
    var record: JSONObject = [
      "mode": .string((draft == nil ? AskWorkflowActionTarget.Mode.store : .draft).rawValue),
      "definition": .object(definition), "workflowId": .string(workflow.workflowId)
    ]
    if let baseWorkflowId {
      guard workflow.workflowId == baseWorkflowId else {
        throw AskError(code: "workflow_invalid", message: "The definition must use the base workflow ID")
      }
      let base = try await surface.workflowInspect(["workflowId": .string(baseWorkflowId)]).data
      guard case let .object(entry) = base, entry["mutable"] == .bool(true),
            let originId = entry.askString("originId"),
            let revision = entry.askString("definitionRevision") else {
        throw AskError(code: "workflow_not_mutable", message: "The base workflow is not mutable")
      }
      record["baseWorkflowId"] = .string(baseWorkflowId)
      record["baseOriginId"] = .string(originId)
      record["expectedDefinitionRevision"] = .string(revision)
    }
    let at = now()
    return try store.insertAskAction(AskAction(
      conversationId: conversationId, turnId: turnId, kind: .applyWorkflow,
      target: record, reason: "", createdAt: RoutineStore.timestamp(at),
      expiresAt: RoutineStore.timestamp(at.addingTimeInterval(TimeInterval(limits.actionLifetimeSeconds)))
    ), limits: limits)
  }
}
