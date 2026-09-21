import Foundation
import RielaCore

// Template rendering and JSON coercion every add-on family needs. It lives in
// its own target so add-on targets (RielaKaibaAddons and any future one) can
// reuse it without importing RielaCLI.

/// Forward application fields, not the runtime's input-only history views.
/// `_rielaInput` contains both messages and a latest-message alias; copying it
/// into accepted output makes each subsequent hop retain the preceding tree
/// three times. `upstream` and `runtime` are likewise reconstructed per step.
public func addonForwardedApplicationPayload(_ resolvedInput: JSONObject) -> JSONObject {
  var payload = resolvedInput
  for key in ["_rielaInput", "upstream", "runtime"] { payload.removeValue(forKey: key) }
  return payload
}

public func addonBaseVariables(for input: WorkflowAddonExecutionInput) -> JSONObject {
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
  return variables
}

public func addonVariables(
  for input: WorkflowAddonExecutionInput,
  additionalVariables: JSONObject = [:]
) throws -> JSONObject {
  var variables = addonBaseVariables(for: input)
  for (key, value) in try renderAddonInputs(input.addon.inputs, variables: variables) {
    variables[key] = value
  }
  for (key, value) in additionalVariables {
    variables[key] = value
  }
  if let config = input.addon.config {
    _ = try renderAddonConfig(.object(config), variables: variables)
  }
  return variables
}

public func renderAddonInputs(_ inputs: JSONObject?, variables: JSONObject) throws -> JSONObject {
  guard let inputs else { return [:] }
  return try inputs.mapValues {
    try renderAddonTemplates($0, variables: variables, surface: .addonInputs)
  }
}

public func renderAddonConfig(_ value: JSONValue, variables: JSONObject) throws -> JSONValue {
  try renderAddonTemplates(value, variables: variables, surface: .addonConfig(addonInputKeys: []))
}

private func renderAddonTemplates(
  _ value: JSONValue,
  variables: JSONObject,
  surface: TemplateSurface
) throws -> JSONValue {
  switch value {
  case let .string(template):
    if let exactValue = exactTemplateValue(template, variables: variables) { return exactValue }
    try rejectUnresolvedPayloadReferences(in: template, variables: variables, surface: surface)
    return .string(renderPromptTemplate(template, variables: variables))
  case let .array(values):
    return .array(try values.map { try renderAddonTemplates($0, variables: variables, surface: surface) })
  case let .object(object):
    return .object(try object.mapValues { try renderAddonTemplates($0, variables: variables, surface: surface) })
  case .null, .bool, .integer, .number:
    return value
  }
}

private func rejectUnresolvedPayloadReferences(
  in template: String,
  variables: JSONObject,
  surface: TemplateSurface
) throws {
  for path in templateReferencePaths(in: .string(template))
  where classifyTemplateReference(path, surface: surface) == .payload
    && lookupTemplatePath(path, in: variables) == nil {
    let consumerStep = nonEmptyString(variables["stepId"]) ?? "an unknown step"
    let consumerNode = nonEmptyString(variables["nodeId"]) ?? "an unknown node"
    let addon = nonEmptyString(variables["addonName"]) ?? "an unknown addon"
    let producer = deliveringStep(in: variables)
    let field = payloadField(inTemplatePath: path, surface: surface) ?? path
    throw AdapterExecutionError(
      .templateResolutionFailed,
      "templateResolutionFailed: step '\(consumerStep)' node '\(consumerNode)' addon '\(addon)' template '{{\(path)}}' resolved to nothing; step '\(producer)' delivered this input without payload field '\(field)'"
    )
  }
}

private func deliveringStep(in variables: JSONObject) -> String {
  guard case let .object(metadata)? = variables["_rielaInput"] else { return "an upstream step" }
  if case let .object(latest)? = metadata["latest"],
     let fromStepId = nonEmptyString(latest["fromStepId"]) {
    return fromStepId
  }
  if case let .array(sourceStepIds)? = metadata["sourceStepIds"] {
    let ids = sourceStepIds.compactMap(nonEmptyString)
    if ids.count == 1 { return ids[0] }
  }
  return "an upstream step"
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
