import Foundation

/// Authored backend selection constraints for one executable workflow node.
/// A pin is mutually exclusive with a policy: a pinned backend never falls
/// back to another backend.
public struct WorkflowBackendPolicy: Codable, Equatable, Sendable {
  public let allowed: [NodeExecutionBackend]
  public let preferred: [NodeExecutionBackend]
  public let modelByBackend: [NodeExecutionBackend: String]

  public init(
    allowed: [NodeExecutionBackend],
    preferred: [NodeExecutionBackend] = [],
    modelByBackend: [NodeExecutionBackend: String] = [:]
  ) {
    self.allowed = allowed
    self.preferred = preferred
    self.modelByBackend = modelByBackend
  }

  public func orderedCandidates() -> [NodeExecutionBackend] {
    preferred + allowed.filter { !preferred.contains($0) }
  }
}

public enum WorkflowBackendPolicyValidation {
  public static func diagnostics(
    pin: NodeExecutionBackend?,
    policy: WorkflowBackendPolicy?,
    knownModels: [NodeExecutionBackend: Set<String>] = [:],
    fallbackModel: String? = nil,
    path: String = "node"
  ) -> [WorkflowValidationDiagnostic] {
    guard let policy else {
      return []
    }

    var diagnostics: [WorkflowValidationDiagnostic] = []
    if pin != nil {
      diagnostics.append(error("\(path).backendPolicy", "cannot be combined with executionBackend"))
    }
    if policy.allowed.isEmpty {
      diagnostics.append(error("\(path).backendPolicy.allowed", "must contain at least one backend"))
    }
    if Set(policy.allowed).count != policy.allowed.count {
      diagnostics.append(error("\(path).backendPolicy.allowed", "must not contain duplicate backends"))
    }
    if Set(policy.preferred).count != policy.preferred.count {
      diagnostics.append(error("\(path).backendPolicy.preferred", "must not contain duplicate backends"))
    }
    if fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
       !policy.modelByBackend.isEmpty {
      diagnostics.append(error("\(path).backendPolicy.modelByBackend", "cannot be combined with a shared model"))
    }
    for backend in policy.preferred where !policy.allowed.contains(backend) {
      diagnostics.append(error("\(path).backendPolicy.preferred", "must be included in allowed"))
    }
    for (backend, model) in policy.modelByBackend {
      if !policy.allowed.contains(backend) {
        diagnostics.append(error("\(path).backendPolicy.modelByBackend.\(backend.rawValue)", "requires an allowed backend"))
      }
      if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        diagnostics.append(error("\(path).backendPolicy.modelByBackend.\(backend.rawValue)", "must not be empty"))
      } else if let models = knownModels[backend], !models.contains(model) {
        diagnostics.append(error("\(path).backendPolicy.modelByBackend.\(backend.rawValue)", "is not known for this backend"))
      }
    }
    return diagnostics
  }
}
