import Foundation

func validateNodeSource(
  nodeFile: String?,
  nodeRef: WorkflowSharedNodeRef?,
  addon: WorkflowNodeAddonRef?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let sourceCount = [nodeFile != nil, nodeRef != nil, addon != nil].filter { $0 }.count
  if sourceCount == 0 {
    diagnostics.append(error(path, "must define exactly one of nodeFile, nodeRef, or addon"))
  } else if sourceCount > 1 {
    diagnostics.append(error(path, "must define only one of nodeFile, nodeRef, or addon"))
  }
}

func validateRawNodeSource(
  _ entry: [String: Any],
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let sourceCount = ["nodeFile", "nodeRef", "addon"].filter { entry[$0] != nil }.count
  if sourceCount == 0 {
    diagnostics.append(error(path, "must define exactly one of nodeFile, nodeRef, or addon"))
  } else if sourceCount > 1 {
    diagnostics.append(error(path, "must define only one of nodeFile, nodeRef, or addon"))
  }
}

func validateNodeReference(
  _ nodeRef: WorkflowSharedNodeRef?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let nodeRef else {
    return
  }
  validateNonEmptyString(nodeRef.workflowId, path: "\(path).workflowId", diagnostics: &diagnostics)
  if !nodeRef.workflowId.isEmpty, !isSafeWorkflowId(nodeRef.workflowId) {
    diagnostics.append(
      error(
        "\(path).workflowId",
        "must start with an alphanumeric character and contain only letters, digits, hyphens, or underscores"
      )
    )
  }
  validateNonEmptyString(nodeRef.nodeId, path: "\(path).nodeId", diagnostics: &diagnostics)
  if !nodeRef.nodeId.isEmpty, !isSafeNodeId(nodeRef.nodeId) {
    diagnostics.append(error("\(path).nodeId", "must match ^[a-z0-9][a-z0-9-]{1,63}$"))
  }
}

func validateRawNodeReference(_ raw: Any?, path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else {
    return
  }
  guard let object = raw as? [String: Any] else {
    diagnostics.append(error(path, "must be an object when provided"))
    return
  }
  let allowedKeys: Set<String> = ["workflowId", "nodeId"]
  for key in object.keys where !allowedKeys.contains(key) {
    diagnostics.append(error("\(path).\(key)", "uses an unsupported nodeRef field"))
  }
  validateNonEmptyString(object["workflowId"], path: "\(path).workflowId", diagnostics: &diagnostics)
  if let workflowId = object["workflowId"] as? String, !workflowId.isEmpty, !isSafeWorkflowId(workflowId) {
    diagnostics.append(
      error(
        "\(path).workflowId",
        "must start with an alphanumeric character and contain only letters, digits, hyphens, or underscores"
      )
    )
  }
  validateNonEmptyString(object["nodeId"], path: "\(path).nodeId", diagnostics: &diagnostics)
  if let nodeId = object["nodeId"] as? String, !nodeId.isEmpty, !isSafeNodeId(nodeId) {
    diagnostics.append(error("\(path).nodeId", "must match ^[a-z0-9][a-z0-9-]{1,63}$"))
  }
}

func validateInputFilters(
  _ filters: [WorkflowInputFilter]?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let filters else {
    return
  }
  if filters.isEmpty {
    diagnostics.append(error(path, "must contain at least one filter when present"))
  }
  for (index, filter) in filters.enumerated() {
    let filterPath = "\(path)[\(index)]"
    if filter.kind.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      diagnostics.append(error("\(filterPath).kind", "must be a non-empty string"))
    } else if filter.kind != .telegram {
      diagnostics.append(error("\(filterPath).kind", "must be 'telegram'"))
    }
    let hasExpression = filter.expression?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasBuiltin = filter.builtin != nil
    if hasExpression == hasBuiltin {
      diagnostics.append(error(filterPath, "must specify exactly one of expression or builtin"))
    }
  }
}

func validateRawInputFilters(
  _ rawFilters: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let rawFilters else {
    return
  }
  guard let filters = rawFilters as? [Any] else {
    diagnostics.append(error(path, "must be an array"))
    return
  }
  if filters.isEmpty {
    diagnostics.append(error(path, "must contain at least one filter when present"))
  }
  for (index, rawFilter) in filters.enumerated() {
    let filterPath = "\(path)[\(index)]"
    guard let filter = rawFilter as? [String: Any] else {
      diagnostics.append(error(filterPath, "must be an object"))
      continue
    }
    let allowedKeys: Set<String> = ["kind", "language", "expression", "builtin", "config"]
    for key in filter.keys where !allowedKeys.contains(key) {
      diagnostics.append(error("\(filterPath).\(key)", "uses an unsupported input filter field"))
    }
    validateNonEmptyString(filter["kind"], path: "\(filterPath).kind", diagnostics: &diagnostics)
    if let kind = filter["kind"] as? String, !kind.isEmpty, kind != WorkflowInputFilterKind.telegram.rawValue {
      diagnostics.append(error("\(filterPath).kind", "must be 'telegram'"))
    }
    let hasExpression = nonEmptyString(filter["expression"]) != nil
    let hasBuiltin = nonEmptyString(filter["builtin"]) != nil
    if hasExpression == hasBuiltin {
      diagnostics.append(error(filterPath, "must specify exactly one of expression or builtin"))
    }
    if hasExpression {
      validateNonEmptyString(filter["language"], path: "\(filterPath).language", diagnostics: &diagnostics)
    }
    if let language = filter["language"] as? String, language != WorkflowInputFilterLanguage.javascript.rawValue {
      diagnostics.append(error("\(filterPath).language", "must be 'javascript'"))
    }
    if let builtin = filter["builtin"] as? String,
      !WorkflowInputFilterBuiltin.allCases.map(\.rawValue).contains(builtin) {
      diagnostics.append(error("\(filterPath).builtin", "uses an unsupported builtin input filter"))
    }
    if let config = filter["config"], !(config is [String: Any]) {
      diagnostics.append(error("\(filterPath).config", "must be an object"))
    }
  }
}
