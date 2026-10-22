import Foundation

/// Backend arguments are argv elements, never shell command text. Resolve each
/// declared template once; missing values must not silently weaken a policy.
public func resolveAgentToolPolicy(_ policy: AgentToolPolicy?, variables: JSONObject) throws -> AgentToolPolicy? {
  guard var policy else { return nil }
  func arguments(_ values: [String]) throws -> [String] {
    try values.map { template in
      for path in templateReferencePaths(in: .string(template)) {
        let pointer = "/" + path.split(separator: ".").map {
          $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined(separator: "/")
        guard let value = fanoutJSONPointer(.object(variables), pointer), value != .null else {
          throw AdapterExecutionError(.templateResolutionFailed, "agent tool policy argument has a missing template value")
        }
      }
      let value = renderPromptTemplate(template, variables: variables)
      guard !value.contains("\0"), value.utf8.count <= 65_536 else {
        throw AdapterExecutionError(.invalidInput, "agent tool policy argument exceeds the permitted bounds")
      }
      return value
    }
  }
  policy.additionalArguments = try arguments(policy.additionalArguments)
  policy.codexArguments = try arguments(policy.codexArguments)
  policy.claudeArguments = try arguments(policy.claudeArguments)
  policy.cursorArguments = try arguments(policy.cursorArguments)
  return policy
}
