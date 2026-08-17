import Foundation
import RielaCore

// Template rendering and JSON coercion every add-on family needs. It lives in
// its own target so add-on targets (RielaKaibaAddons and any future one) can
// reuse it without importing RielaCLI.

public func addonVariables(for input: WorkflowAddonExecutionInput) -> JSONObject {
  var variables = input.variables
  for (key, value) in input.resolvedInputPayload {
    variables[key] = value
  }
  if case let .object(inputMetadata)? = input.resolvedInputPayload["_rielaInput"],
     case let .object(latest)? = inputMetadata["latest"],
     case let .object(latestPayload)? = latest["payload"] {
    variables["inbox"] = .object([
      "latest": .object([
        "output": .object([
          "payload": .object(latestPayload)
        ])
      ])
    ])
  }
  variables["input"] = .object(input.resolvedInputPayload)
  variables["workflowId"] = .string(input.workflowId)
  variables["stepId"] = .string(input.stepId)
  variables["nodeId"] = .string(input.nodeId)
  variables["addonName"] = .string(input.addon.name)
  for (key, value) in renderAddonInputs(input.addon.inputs, variables: variables) {
    variables[key] = value
  }
  return variables
}

public func renderAddonInputs(_ inputs: JSONObject?, variables: JSONObject) -> JSONObject {
  guard let inputs else { return [:] }
  return inputs.mapValues { renderJSONTemplates($0, variables: variables) }
}

public func renderJSONTemplates(_ value: JSONValue, variables: JSONObject) -> JSONValue {
  switch value {
  case let .string(template):
    if let exactValue = exactTemplateValue(template, variables: variables) { return exactValue }
    return .string(renderPromptTemplate(template, variables: variables))
  case let .array(values):
    return .array(values.map { renderJSONTemplates($0, variables: variables) })
  case let .object(object):
    return .object(object.mapValues { renderJSONTemplates($0, variables: variables) })
  case .null, .bool, .integer, .number:
    return value
  }
}

private func exactTemplateValue(_ template: String, variables: JSONObject) -> JSONValue? {
  let pattern = #"^\s*\{\{\s*([a-zA-Z0-9_.-]+)\s*\}\}\s*$"#
  guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(
          in: template,
          range: NSRange(template.startIndex..<template.endIndex, in: template)
        ),
        let pathRange = Range(match.range(at: 1), in: template) else {
    return nil
  }
  return lookupTemplatePath(String(template[pathRange]), in: variables)
}

private func lookupTemplatePath(_ path: String, in variables: JSONObject) -> JSONValue? {
  let keys = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
  guard !keys.isEmpty else { return nil }
  var current: JSONValue? = .object(variables)
  for key in keys {
    guard case let .object(object) = current else { return nil }
    current = object[key]
  }
  return current
}

public func nonEmptyString(_ value: JSONValue?) -> String? {
  guard case let .string(text) = value, !text.isEmpty else { return nil }
  return text
}

public func boolValue(_ value: JSONValue?) -> Bool? {
  guard case let .bool(value) = value else { return nil }
  return value
}

public func intValue(_ value: JSONValue?) -> Int? {
  guard let int64 = value?.asInt64 else { return nil }
  return Int(exactly: int64)
}

public func objectValue(_ value: JSONValue?) -> JSONObject? {
  guard case let .object(object) = value else { return nil }
  return object
}

extension JSONValue {
  public func compactJSONStringOrEmpty() -> String {
    (try? compactJSONString()) ?? ""
  }
}
