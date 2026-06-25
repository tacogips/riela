import Foundation
import CoreFoundation

func error(_ path: String, _ message: String) -> WorkflowValidationDiagnostic {
  WorkflowValidationDiagnostic(severity: .error, path: path, message: message)
}

func validateNonEmptyString(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
}

func nonEmptyString(_ value: Any?) -> String? {
  guard let string = value as? String else {
    return nil
  }
  let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

func validateWorkflowRelativePath(
  _ value: Any?,
  fieldName: String,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let string = value as? String, !string.isEmpty else {
    diagnostics.append(error(path, "must be a non-empty string"))
    return
  }
  guard isSafeWorkflowRelativePath(string) else {
    diagnostics.append(error(path, "\(fieldName) '\(string)' must be a workflow-relative path without '.' or '..' segments"))
    return
  }
}

func validateNumberField(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let value, isFiniteNumber(value) else {
    diagnostics.append(error(path, "must be a finite number"))
    return
  }
}

func validatePositiveInteger(
  _ value: Any?,
  path: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let number = value as? NSNumber,
    !isBooleanNumber(number),
    number.doubleValue > 0,
    floor(number.doubleValue) == number.doubleValue
  else {
    diagnostics.append(error(path, "must be a positive integer"))
    return
  }
}

private func isFiniteNumber(_ value: Any) -> Bool {
  if let number = value as? NSNumber {
    return !isBooleanNumber(number) && number.doubleValue.isFinite
  }
  switch value {
  case let int as Int:
    return Double(int).isFinite
  case let int as Int64:
    return Double(int).isFinite
  case let int as UInt64:
    return Double(int).isFinite
  case let double as Double:
    return double.isFinite
  case let float as Float:
    return float.isFinite
  default:
    return false
  }
}

private func isBooleanNumber(_ number: NSNumber) -> Bool {
  CFGetTypeID(number) == CFBooleanGetTypeID()
}

func isSafeWorkflowId(_ value: String) -> Bool {
  matches(value, pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#)
}

func isSafeNodeId(_ value: String) -> Bool {
  matches(value, pattern: #"^[a-z0-9][a-z0-9-]{1,63}$"#)
}

private func isSafeWorkflowRelativePath(_ value: String) -> Bool {
  if value.isEmpty || value.hasPrefix("/") || value.hasPrefix("\\") || matches(value, pattern: #"^[A-Za-z]:[\\/]"#) {
    return false
  }
  let segments = value.split { character in
    character == "/" || character == "\\"
  }
  if segments.isEmpty {
    return false
  }
  return !segments.contains { segment in
    segment == "." || segment == ".."
  }
}

private func matches(_ value: String, pattern: String) -> Bool {
  value.range(of: pattern, options: .regularExpression) != nil
}
