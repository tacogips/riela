import Foundation

func validateLiteralAddonTemplates(
  _ addon: WorkflowNodeAddonRef?,
  nodeId: String,
  path: String
) -> [WorkflowValidationDiagnostic] {
  guard let addon else {
    return []
  }

  let literalField: String
  let templateField: String
  switch addon.name {
  case "riela/kv-set":
    literalField = "value"
    templateField = "valueTemplate"
  case "riela/memory-save", "riela/memory-update":
    literalField = "payload"
    templateField = "payloadTemplate"
  default:
    return []
  }

  // Only config is literal; addon.inputs are rendered before the add-on runs.
  guard let value = addon.config?[literalField] else {
    return []
  }
  var diagnostics: [WorkflowValidationDiagnostic] = []
  collectTemplateStringDiagnostics(
    in: value,
    nodeId: nodeId,
    path: "\(path).config.\(literalField)",
    templateField: templateField,
    diagnostics: &diagnostics
  )
  return diagnostics
}

private func collectTemplateStringDiagnostics(
  in value: JSONValue,
  nodeId: String,
  path: String,
  templateField: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  switch value {
  case let .string(string):
    let placeholderPattern = #"\{\{\s*[^{}]+?\s*\}\}"#
    guard string.range(of: placeholderPattern, options: .regularExpression) != nil else {
      return
    }
    let isWholePlaceholder = string.range(
      of: #"^\s*\{\{\s*[^{}]+?\s*\}\}\s*$"#,
      options: .regularExpression
    ) != nil
    diagnostics.append(WorkflowValidationDiagnostic(
      severity: isWholePlaceholder ? .error : .warning,
      path: path,
      message: "node '\(nodeId)' value is stored literally; use config.\(templateField) to render template syntax"
    ))
  case let .array(values):
    for (index, nestedValue) in values.enumerated() {
      collectTemplateStringDiagnostics(
        in: nestedValue,
        nodeId: nodeId,
        path: "\(path)[\(index)]",
        templateField: templateField,
        diagnostics: &diagnostics
      )
    }
  case let .object(values):
    for key in values.keys.sorted() {
      guard let nestedValue = values[key] else {
        continue
      }
      collectTemplateStringDiagnostics(
        in: nestedValue,
        nodeId: nodeId,
        path: "\(path).\(key)",
        templateField: templateField,
        diagnostics: &diagnostics
      )
    }
  case .null, .bool, .integer, .number:
    return
  }
}
