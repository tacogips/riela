import Foundation

/// Trust rule for tool-policy templates: they choose backend argv (for example
/// a Codex `-c key=value` override), so they may bind only author- or
/// operator-controlled data: the node's own `variables` and the run's workflow
/// input, which is also reachable as `runtimeVariables.*`. Upstream step
/// output is model-produced and is never a source.
public func agentToolPolicyTrustedVariables(nodeVariables: JSONObject, workflowInput: JSONObject) -> JSONObject {
  var trusted = nodeVariables
  for (key, value) in workflowInput {
    trusted[key] = value
  }
  trusted["runtimeVariables"] = .object(workflowInput)
  return trusted
}

/// Backend arguments are argv elements, never shell command text. Resolve each
/// declared template once; missing values must not silently weaken a policy.
///
/// When `trustedVariables` is supplied, every referenced path must resolve
/// there and must not be shadowed by a different value in `variables` (the
/// merged prompt variables, which include upstream output). Independently of
/// the source, a substituted value may not add line breaks, and an argument
/// that starts with a template may not render to an option (`-...`).
public func resolveAgentToolPolicy(
  _ policy: AgentToolPolicy?,
  variables: JSONObject,
  trustedVariables: JSONObject? = nil
) throws -> AgentToolPolicy? {
  guard var policy else { return nil }
  let sources = trustedVariables ?? variables
  func arguments(_ values: [String]) throws -> [String] {
    try values.map { template in
      let paths = templateReferencePaths(in: .string(template))
      for path in paths {
        let pointer = "/" + path.split(separator: ".").map {
          $0.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined(separator: "/")
        guard let value = fanoutJSONPointer(.object(sources), pointer), value != .null else {
          throw AdapterExecutionError(.templateResolutionFailed,
            trustedVariables == nil ? "agent tool policy argument has a missing template value"
              : "agent tool policy argument must bind node variables or workflow input")
        }
        if trustedVariables != nil, fanoutJSONPointer(.object(variables), pointer) != value {
          throw AdapterExecutionError(.policyBlocked,
            "agent tool policy argument binds a value that upstream step output overrides")
        }
      }
      let value = renderPromptTemplate(template, variables: sources)
      guard !value.contains("\0"), value.utf8.count <= 65_536 else {
        throw AdapterExecutionError(.invalidInput, "agent tool policy argument exceeds the permitted bounds")
      }
      guard !paths.isEmpty else { return value }
      let addsLineBreak = value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        && !template.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
      let injectsOption = template.hasPrefix("{{") && value.hasPrefix("-")
      guard !addsLineBreak, !injectsOption else {
        throw AdapterExecutionError(.policyBlocked,
          "agent tool policy template value must not start an option or add line breaks")
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
