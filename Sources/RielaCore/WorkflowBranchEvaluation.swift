import Foundation

public struct WorkflowBranchEvaluator: Sendable {
  public init() {}

  public func evaluate(label: String?, when: [String: Bool], payload: JSONObject = [:]) -> Bool {
    guard let label else { return true }
    guard let condition = try? ParsedWorkflowCondition(label) else { return false }
    return (try? condition.evaluate { identifier in
      if let value = when[identifier] { return .boolean(value, source: .when) }
      if case let .bool(value)? = payload[identifier] { return .boolean(value, source: .payload) }
      return .boolean(false, source: .legacyDefault)
    }) ?? false
  }
}
