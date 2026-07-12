import Foundation
import RielaCore
import RielaNote

public enum NoteAutoActionWorkflowVariablesError: Error, Equatable, Sendable {
  case encodingFailed(String)
}

/// Serializes the workflow input variables for an auto-action dispatch as a
/// JSON string. Shared by every launcher so the variable contract stays
/// identical across the CLI and the app.
public func noteAutoActionVariablesJSON(
  for record: AutoActionDispatchRecord,
  noteRoot: String?
) throws -> String {
  let variables = noteAutoActionVariables(for: record, noteRoot: noteRoot)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(JSONValue.object(variables))
  guard let json = String(data: data, encoding: .utf8) else {
    throw NoteAutoActionWorkflowVariablesError.encodingFailed(
      "failed to encode note auto-action variables as UTF-8"
    )
  }
  return json
}

private func noteAutoActionVariables(for record: AutoActionDispatchRecord, noteRoot: String?) -> JSONObject {
  var event: JSONObject = [
    "trigger": .string(record.event.trigger.rawValue),
    "actionId": .string(record.action.actionId),
    "workflowId": .string(record.action.workflowId)
  ]
  event.setString(record.event.notebookId, forKey: "notebookId")
  event.setString(record.event.noteId, forKey: "noteId")
  event.setString(record.event.noteBodyMarkdown, forKey: "noteBodyMarkdown")
  event.setString(record.event.originatingActionId, forKey: "originatingActionId")

  var action: JSONObject = [
    "actionId": .string(record.action.actionId),
    "trigger": .string(record.action.trigger.rawValue),
    "workflowId": .string(record.action.workflowId),
    "enabled": .bool(record.action.enabled),
    "position": .integer(Int64(record.action.position)),
    "createdAt": .string(record.action.createdAt)
  ]
  action.setString(record.action.filterJSON, forKey: "filterJSON")

  var workflowInput: JSONObject = [
    "event": .object(event),
    "autoAction": .object(action),
    "trigger": .string(record.event.trigger.rawValue),
    "actionId": .string(record.action.actionId),
    "workflowId": .string(record.action.workflowId),
    "originatingActionId": .string(record.action.actionId)
  ]
  workflowInput.setString(record.event.notebookId, forKey: "notebookId")
  workflowInput.setString(record.event.noteId, forKey: "noteId")
  workflowInput.setString(record.event.noteBodyMarkdown, forKey: "noteBodyMarkdown")
  workflowInput.setString(noteRoot, forKey: "noteRoot")

  var variables = workflowInput
  variables.setString(noteRoot, forKey: "noteRoot")
  variables["workflowInput"] = .object(workflowInput)
  variables["event"] = .object(event)
  variables["autoAction"] = .object(action)
  return variables
}

private extension Dictionary where Key == String, Value == JSONValue {
  mutating func setString(_ value: String?, forKey key: String) {
    guard let value, !value.isEmpty else {
      return
    }
    self[key] = .string(value)
  }
}
