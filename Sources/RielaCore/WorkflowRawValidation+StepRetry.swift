import Foundation
import CoreFoundation

func validateStepDeadlineAndRetry(
  _ entry: [String: Any], path: String, nodeEntries: [Any], diagnostics: inout [WorkflowValidationDiagnostic]
) {
  let deadline = entry["deadlineMs"]
  let retry = entry["retry"]
  guard deadline != nil || retry != nil else { return }
  if let deadline {
    validateRetryInteger(deadline, path: "\(path).deadlineMs", range: 1...86_400_000, diagnostics: &diagnostics)
  }
  if let retry {
    if let policy = retry as? [String: Any] {
      validateRetryPolicy(policy, path: "\(path).retry", diagnostics: &diagnostics)
    } else {
      diagnostics.append(error("\(path).retry", "must be an object"))
    }
    if deadline == nil {
      diagnostics.append(error("\(path).retry", "retry requires deadlineMs (total elapsed budget)"))
    }
  }
  if let timeout = retryNumber(entry["timeoutMs"]), let limit = retryNumber(deadline), timeout > limit {
    diagnostics.append(error("\(path).timeoutMs", "must not exceed deadlineMs"))
  }
  let node = (entry["nodeId"] as? String).flatMap { nodeId in
    nodeEntries.compactMap { $0 as? [String: Any] }.first { ($0["id"] as? String) == nodeId }
  }
  let addon = node?["addon"] as? [String: Any]
  if addon == nil {
    if deadline != nil { diagnostics.append(error("\(path).deadlineMs", "is supported only on add-on-backed steps")) }
    if retry != nil { diagnostics.append(error("\(path).retry", "is supported only on add-on-backed steps")) }
  }
  if retry != nil, let config = addon?["config"] as? [String: Any], config["writeRetry"] != nil {
    diagnostics.append(error("\(path).retry", "cannot be combined with addon config.writeRetry (nested retry)"))
  }
  if entry["placement"] != nil {
    diagnostics.append(error("\(path).placement", "cannot be combined with deadlineMs or retry"))
  }
}

private func validateRetryPolicy(_ policy: [String: Any], path: String, diagnostics: inout [WorkflowValidationDiagnostic]) {
  let allowed: Set<String> = ["maxAttempts", "initialDelayMs", "multiplier", "maxDelayMs", "jitter"]
  for key in policy.keys.sorted() where !allowed.contains(key) {
    diagnostics.append(error("\(path).\(key)", "uses an unsupported retry field"))
  }
  validateRetryInteger(policy["maxAttempts"], path: "\(path).maxAttempts", range: 1...10, diagnostics: &diagnostics)
  for key in ["initialDelayMs", "maxDelayMs"] where policy[key] != nil {
    validateRetryInteger(policy[key], path: "\(path).\(key)", range: 0...3_600_000, diagnostics: &diagnostics)
  }
  if let value = policy["multiplier"], !(retryNumber(value).map { (1.0...10.0).contains($0) } ?? false) {
    diagnostics.append(error("\(path).multiplier", "must be a finite number in 1...10"))
  }
  if let maximum = retryNumber(policy["maxDelayMs"]),
    let initial = policy["initialDelayMs"] == nil ? 1_000 : retryNumber(policy["initialDelayMs"]), maximum < initial {
    diagnostics.append(error("\(path).maxDelayMs", "must be greater than or equal to initialDelayMs"))
  }
  if let jitter = policy["jitter"], !["none", "deterministic"].contains(jitter as? String ?? "") {
    diagnostics.append(error("\(path).jitter", "must be 'none' or 'deterministic'"))
  }
}

private func retryNumber(_ value: Any?) -> Double? {
  guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
    return nil
  }
  return number.doubleValue
}

private func validateRetryInteger(
  _ value: Any?, path: String, range: ClosedRange<Int>, diagnostics: inout [WorkflowValidationDiagnostic]
) {
  guard let number = retryNumber(value), number.rounded(.towardZero) == number,
    Double(range.lowerBound)...Double(range.upperBound) ~= number else {
    diagnostics.append(error(path, "must be an integer in \(range.lowerBound)...\(range.upperBound)"))
    return
  }
}
