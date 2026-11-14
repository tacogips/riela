import Foundation
import RielaCore

private indirect enum WorkflowRegistrySelectionShape {
  case scalar
  case object(typeName: String, fields: [String: WorkflowRegistrySelectionShape])
  case list(WorkflowRegistrySelectionShape)
}

func validateWorkflowRegistryRootFields(
  _ roots: [ParsedNoteGraphQLRootField]
) throws {
  guard !roots.isEmpty else {
    throw WorkflowRegistryError(code: .invalidWorkflow, message: "registry operation has no root fields")
  }
  try requireUniqueResponseKeys(roots.map(\.responseKey), context: "registry root")
  for root in roots {
    try validateArguments(for: root)
    try validateSelections(
      root.selections,
      shape: rootSelectionShape(for: root.fieldName),
      context: root.fieldName
    )
  }
}

func validateUniqueGraphQLRootResponseKeys(
  _ roots: [ParsedNoteGraphQLRootField]
) throws {
  try requireUniqueResponseKeys(roots.map(\.responseKey), context: "GraphQL root")
}

private func validateArguments(for root: ParsedNoteGraphQLRootField) throws {
  switch root.fieldName {
  case "workflows":
    try requireKeys(root.arguments, allowed: ["filter"], required: [], context: "workflows")
    if let value = root.arguments["filter"], value != .null {
      let object = try requireObject(value, context: "WorkflowFilter")
      try requireKeys(
        object,
        allowed: ["query", "description", "scope", "sourceKind", "provenance", "mutable", "activationState"],
        required: [],
        context: "WorkflowFilter"
      )
      let _: GraphQLWorkflowFilterInput = try decodeRegistryValue(value, context: "WorkflowFilter")
    }
  case "workflow":
    try requireKeys(root.arguments, allowed: ["target"], required: ["target"], context: "workflow")
    try validateTarget(root.arguments["target"], context: "WorkflowTargetInput")
  case "registerMutableWorkflow":
    let input = try requiredInputObject(root, context: "RegisterMutableWorkflowInput")
    try requireKeys(
      input,
      allowed: ["bundle", "overwrite", "activationState"],
      required: ["bundle"],
      context: "RegisterMutableWorkflowInput"
    )
    try validateBundle(input["bundle"], context: "RegisterMutableWorkflowInput.bundle")
    let _: GraphQLRegisterMutableWorkflowInput = try decodeRegistryValue(
      root.arguments["input"] ?? .null,
      context: "RegisterMutableWorkflowInput"
    )
  case "updateMutableWorkflow":
    let input = try requiredInputObject(root, context: "UpdateMutableWorkflowInput")
    try requireKeys(
      input,
      allowed: ["target", "bundle"],
      required: ["target", "bundle"],
      context: "UpdateMutableWorkflowInput"
    )
    try validateTarget(input["target"], context: "UpdateMutableWorkflowInput.target")
    try validateBundle(input["bundle"], context: "UpdateMutableWorkflowInput.bundle")
    let _: GraphQLUpdateMutableWorkflowInput = try decodeRegistryValue(
      root.arguments["input"] ?? .null,
      context: "UpdateMutableWorkflowInput"
    )
  case "deleteMutableWorkflow":
    try validateTargetMutation(root, context: "DeleteMutableWorkflowInput")
    let _: GraphQLDeleteMutableWorkflowInput = try decodeRegistryValue(
      root.arguments["input"] ?? .null,
      context: "DeleteMutableWorkflowInput"
    )
  case "activateWorkflow", "deactivateWorkflow":
    try validateTargetMutation(root, context: "SetWorkflowActivationInput")
    let _: GraphQLSetWorkflowActivationInput = try decodeRegistryValue(
      root.arguments["input"] ?? .null,
      context: "SetWorkflowActivationInput"
    )
  case "consolidateWorkflows":
    let input = try requiredInputObject(root, context: "ConsolidateWorkflowsInput")
    try requireKeys(
      input,
      allowed: ["sources", "replacement", "retireMode", "activateReplacement"],
      required: ["sources", "replacement", "retireMode"],
      context: "ConsolidateWorkflowsInput"
    )
    guard case let .array(sources)? = input["sources"] else {
      throw invalidInput("ConsolidateWorkflowsInput.sources must be a list")
    }
    for (index, source) in sources.enumerated() {
      try validateTarget(source, context: "ConsolidateWorkflowsInput.sources[\(index)]")
    }
    try validateBundle(input["replacement"], context: "ConsolidateWorkflowsInput.replacement")
    let _: GraphQLConsolidateWorkflowsInput = try decodeRegistryValue(
      root.arguments["input"] ?? .null,
      context: "ConsolidateWorkflowsInput"
    )
  default:
    throw invalidInput("unsupported registry root field '\(root.fieldName)'")
  }
}

private func validateTargetMutation(
  _ root: ParsedNoteGraphQLRootField,
  context: String
) throws {
  let input = try requiredInputObject(root, context: context)
  try requireKeys(input, allowed: ["target"], required: ["target"], context: context)
  try validateTarget(input["target"], context: "\(context).target")
}

private func requiredInputObject(
  _ root: ParsedNoteGraphQLRootField,
  context: String
) throws -> JSONObject {
  try requireKeys(root.arguments, allowed: ["input"], required: ["input"], context: root.fieldName)
  return try requireObject(root.arguments["input"] ?? .null, context: context)
}

private func validateTarget(_ value: JSONValue?, context: String) throws {
  let object = try requireObject(value ?? .null, context: context)
  try requireKeys(
    object,
    allowed: ["workflowId", "scope", "originId"],
    required: ["workflowId"],
    context: context
  )
  let _: GraphQLWorkflowTargetInput = try decodeRegistryValue(value ?? .null, context: context)
}

private func validateBundle(_ value: JSONValue?, context: String) throws {
  let object = try requireObject(value ?? .null, context: context)
  try requireKeys(object, allowed: ["kind", "value"], required: ["kind", "value"], context: context)
  let _: GraphQLWorkflowBundleReferenceInput = try decodeRegistryValue(value ?? .null, context: context)
}

private func requireKeys(
  _ object: JSONObject,
  allowed: Set<String>,
  required: Set<String>,
  context: String
) throws {
  let unknown = Set(object.keys).subtracting(allowed)
  guard unknown.isEmpty else {
    throw invalidInput("\(context) contains unsupported field(s): \(unknown.sorted().joined(separator: ", "))")
  }
  let missing = required.subtracting(object.keys)
  guard missing.isEmpty else {
    throw invalidInput("\(context) is missing required field(s): \(missing.sorted().joined(separator: ", "))")
  }
}

private func requireObject(_ value: JSONValue, context: String) throws -> JSONObject {
  guard case let .object(object) = value else {
    throw invalidInput("\(context) must be an input object")
  }
  return object
}

private func decodeRegistryValue<T: Decodable>(
  _ value: JSONValue,
  context: String
) throws -> T {
  do {
    return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
  } catch {
    throw invalidInput("\(context) is invalid: \(error)")
  }
}

private func validateSelections(
  _ selections: [ParsedNoteGraphQLSelectionField],
  shape: WorkflowRegistrySelectionShape,
  context: String
) throws {
  switch shape {
  case .scalar:
    guard selections.isEmpty else {
      throw invalidInput("scalar field '\(context)' cannot have a selection set")
    }
  case let .list(element):
    try validateSelections(selections, shape: element, context: context)
  case let .object(typeName, fields):
    guard !selections.isEmpty else {
      throw invalidInput("object field '\(context)' requires a selection set")
    }
    try requireUniqueResponseKeys(selections.map(\.responseKey), context: context)
    for selection in selections {
      guard selection.fragmentTypeConditions.allSatisfy({ $0 == typeName }) else {
        throw invalidInput(
          "fragment type condition is incompatible with '\(typeName)' at \(context)"
        )
      }
      guard selection.arguments.isEmpty else {
        throw invalidInput("selection '\(context).\(selection.fieldName)' does not accept arguments")
      }
      guard let childShape = fields[selection.fieldName] else {
        throw invalidInput("unsupported selection '\(context).\(selection.fieldName)'")
      }
      try validateSelections(
        selection.selections,
        shape: childShape,
        context: "\(context).\(selection.fieldName)"
      )
    }
  }
}

private func requireUniqueResponseKeys(
  _ keys: [String],
  context: String
) throws {
  var seen = Set<String>()
  for key in keys where !seen.insert(key).inserted {
    throw invalidInput("duplicate response key '\(key)' in \(context)")
  }
}

private func rootSelectionShape(for fieldName: String) -> WorkflowRegistrySelectionShape {
  let scalar = WorkflowRegistrySelectionShape.scalar
  let diagnostic = WorkflowRegistrySelectionShape.object(typeName: "WorkflowRegistryDiagnostic", fields: [
    "severity": scalar,
    "path": scalar,
    "message": scalar
  ])
  let error = WorkflowRegistrySelectionShape.object(typeName: "WorkflowRegistryError", fields: [
    "code": scalar,
    "message": scalar,
    "workflowId": scalar,
    "originId": scalar
  ])
  let entry = WorkflowRegistrySelectionShape.object(typeName: "WorkflowRegistryEntry", fields: [
    "originId": scalar,
    "workflowId": scalar,
    "name": scalar,
    "description": scalar,
    "scope": scalar,
    "sourceKind": scalar,
    "provenance": scalar,
    "mutable": scalar,
    "activationState": scalar,
    "valid": scalar,
    "packageName": scalar,
    "packageVersion": scalar,
    "diagnostics": .list(diagnostic)
  ])
  switch fieldName {
  case "workflows":
    return .object(
      typeName: "WorkflowListPayload",
      fields: ["workflows": .list(entry), "errors": .list(error)]
    )
  case "workflow":
    return .object(
      typeName: "WorkflowQueryPayload",
      fields: ["workflow": entry, "errors": .list(error)]
    )
  default:
    return .object(
      typeName: "WorkflowMutationPayload",
      fields: [
        "accepted": scalar,
        "overwritten": scalar,
        "workflow": entry,
        "retiredWorkflows": .list(entry),
        "errors": .list(error)
      ]
    )
  }
}

private func invalidInput(_ message: String) -> WorkflowRegistryError {
  WorkflowRegistryError(code: .invalidWorkflow, message: message)
}
