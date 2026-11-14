import CoreFoundation
import Foundation

private let triggerDefaultsKeys: Set<String> = ["overlapPolicy", "maxQueuedRuns", "maxConcurrentRuns"]

func validateRawTriggerDefaults(_ raw: Any?, diagnostics: inout [WorkflowValidationDiagnostic]) {
  guard let raw else { return }
  guard let defaults = raw as? [String: Any] else {
    diagnostics.append(error("workflow.triggerDefaults", "must be an object when provided"))
    return
  }

  for key in defaults.keys.sorted() where !triggerDefaultsKeys.contains(key) {
    diagnostics.append(error("workflow.triggerDefaults.\(key)", "is not a supported triggerDefaults field"))
  }

  // Type checks stay here because only this surface sees raw JSON values;
  // value rules come from the shared `eventOverlapSettingsIssues`.
  let rawOverlapPolicy = defaults["overlapPolicy"]
  let overlapPolicy = rawOverlapPolicy as? String
  if rawOverlapPolicy != nil, overlapPolicy == nil {
    diagnostics.append(error(
      "workflow.triggerDefaults.overlapPolicy",
      "must be one of \(EventOverlapPolicy.allowedValuesText)"
    ))
  }
  let maxQueuedRuns = triggerDefaultsInteger(defaults["maxQueuedRuns"], key: "maxQueuedRuns", diagnostics: &diagnostics)
  let maxConcurrentRuns = triggerDefaultsInteger(
    defaults["maxConcurrentRuns"], key: "maxConcurrentRuns", diagnostics: &diagnostics
  )
  let settings = EventOverlapSettings(
    overlapPolicy: overlapPolicy, maxQueuedRuns: maxQueuedRuns, maxConcurrentRuns: maxConcurrentRuns
  )
  for issue in eventOverlapSettingsIssues(settings) {
    let path = "workflow.triggerDefaults.\(issue.field.rawValue)"
    switch issue {
    case .unknownPolicy:
      diagnostics.append(error(path, "must be one of \(EventOverlapPolicy.allowedValuesText)"))
    case .capBelowMinimum:
      diagnostics.append(error(path, "must be an integer >= 1"))
    case let .capRequiresPolicy(_, required):
      diagnostics.append(error(path, "requires workflow.triggerDefaults.overlapPolicy \(required.rawValue)"))
    }
  }
}

/// Returns the integer value of a cap, or nil after recording a type
/// diagnostic for a boolean, fractional or non-numeric value.
private func triggerDefaultsInteger(
  _ value: Any?,
  key: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) -> Int? {
  guard let value else { return nil }
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(),
    number.doubleValue == Double(number.intValue)
  else {
    diagnostics.append(error("workflow.triggerDefaults.\(key)", "must be an integer >= 1"))
    return nil
  }
  return number.intValue
}
