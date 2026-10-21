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

  let rawOverlapPolicy = defaults["overlapPolicy"]
  let overlapPolicy = rawOverlapPolicy as? String
  if let rawOverlapPolicy {
    if let value = rawOverlapPolicy as? String, EventOverlapPolicy(rawValue: value) == nil {
      diagnostics.append(error(
        "workflow.triggerDefaults.overlapPolicy",
        "must be one of \(EventOverlapPolicy.allowedValuesText)"
      ))
    } else if overlapPolicy == nil {
      diagnostics.append(error(
        "workflow.triggerDefaults.overlapPolicy",
        "must be one of \(EventOverlapPolicy.allowedValuesText)"
      ))
    }
  }

  validateTriggerDefaultsCap(defaults["maxQueuedRuns"], key: "maxQueuedRuns", diagnostics: &diagnostics)
  validateTriggerDefaultsCap(defaults["maxConcurrentRuns"], key: "maxConcurrentRuns", diagnostics: &diagnostics)

  if defaults["maxQueuedRuns"] != nil, overlapPolicy != EventOverlapPolicy.queue.rawValue {
    diagnostics.append(error(
      "workflow.triggerDefaults.maxQueuedRuns",
      "requires workflow.triggerDefaults.overlapPolicy queue"
    ))
  }
  if defaults["maxConcurrentRuns"] != nil, overlapPolicy != EventOverlapPolicy.concurrent.rawValue {
    diagnostics.append(error(
      "workflow.triggerDefaults.maxConcurrentRuns",
      "requires workflow.triggerDefaults.overlapPolicy concurrent"
    ))
  }
}

private func validateTriggerDefaultsCap(
  _ value: Any?,
  key: String,
  diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let value else { return }
  let path = "workflow.triggerDefaults.\(key)"
  guard let number = value as? NSNumber,
    CFGetTypeID(number) != CFBooleanGetTypeID(),
    number.doubleValue == Double(number.intValue),
    number.intValue >= 1
  else {
    diagnostics.append(error(path, "must be an integer >= 1"))
    return
  }
}
