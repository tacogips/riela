import Foundation
import RielaCore

enum AskWorkflowDraft {
  private static let editorFields: Set<String> = [
    "workflowId", "schemaVersion", "description", "entryStepId", "managerStepId", "defaults",
    "nodeTimeoutMs", "maxLoopIterations", "fanoutConcurrency", "nodes", "steps",
    "id", "nodeId", "nodeFile", "stepFile", "kind", "nodeRef", "execution", "mode", "decisionBy", "addon",
    "name", "version", "config", "promptTemplate", "model", "role", "timeoutMs", "stallTimeoutMs",
    "failurePolicy", "promptVariant", "sessionPolicy", "inheritFromStepId", "transitions",
    "toStepId", "toWorkflowId", "resumeStepId", "label", "placement", "workspace", "target", "workerId", "group", "exports"
  ]

  static func project(
    _ value: JSONValue, environment: [String: String], additionalValues: [String: String] = [:]
  ) -> JSONValue {
    switch value {
    case let .object(fields):
      if isRetainHandle(value) { return value }
      return .object(projectFields(fields, environment: environment, additionalValues: additionalValues))
    case let .array(items):
      return .array(items.map { project($0, environment: environment, additionalValues: additionalValues) })
    case let .string(text):
      guard WorkflowWebProjectionPolicy().displayText(text).value != "<redacted>" else {
        return .null
      }
      let redacted = AskRedaction.text(text, environment: environment, additionalValues: additionalValues)
      return redacted == text ? value : .null
    default:
      return value
    }
  }

  static func isRetainHandle(_ value: JSONValue) -> Bool {
    guard case let .object(fields) = value, fields.count == 1,
          case let .string(handle)? = fields["$rielaRetain"] else { return false }
    return handle.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil
  }

  private static func projectFields(
    _ fields: JSONObject, environment: [String: String], additionalValues: [String: String]
  ) -> JSONObject {
    fields.filter { key, value in
      AskRedaction.text(key, environment: environment, additionalValues: additionalValues) == key
        && (editorFields.contains(key) || isRetainHandle(value))
    }.mapValues { project($0, environment: environment, additionalValues: additionalValues) }
  }
}
