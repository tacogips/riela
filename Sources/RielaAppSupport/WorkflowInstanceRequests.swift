import Foundation
import RielaGraphQL

public struct WorkflowInstanceCreationInput: Decodable, Sendable {
  public let sourceId: String
  public let name: String
  public let expectedProfile: String
  public let expectedRevision: Int

  public func preference(
    sources: [RielaAppDaemonWorkflowCandidate],
    existingIdentities: Set<String>,
    makeIdentity: () -> String = { "configuration-" + UUID().uuidString.lowercased() }
  ) throws -> RielaAppDaemonWorkflowPreference {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: "Provide a configuration name.")
    }
    guard sources.contains(where: { $0.id == sourceId }) else {
      throw RielaConfigurationGraphQLError(code: "SOURCE_NOT_FOUND", message: "Workflow source was not found.")
    }
    let identity = makeIdentity()
    guard !identity.isEmpty, identity.unicodeScalars.allSatisfy({
      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
    }), !existingIdentities.contains(identity), !sources.contains(where: { $0.id == identity }) else {
      throw RielaConfigurationGraphQLError(code: "IDENTITY_CONFLICT", message: "Configuration identity is unavailable. Try again.")
    }
    return .init(identity: identity, sourceIdentity: sourceId, displayName: trimmed, available: false, active: false)
  }
}

public enum WorkflowInstanceAction: String, Decodable, Sendable {
  case start, stop, restart, enableAtLaunch, disableAtLaunch

  public var startsRuntime: Bool { self == .start || self == .restart }
  public var stopsRuntime: Bool { self == .stop || self == .restart }

  public func applying(to original: RielaAppDaemonWorkflowPreference) -> RielaAppDaemonWorkflowPreference {
    var preference = original
    switch self {
    case .start, .restart:
      preference.available = true
      preference.active = true
    case .stop: preference.active = false
    case .enableAtLaunch: preference.available = true
    case .disableAtLaunch: preference.available = false
    }
    return preference
  }
}

public struct WorkflowInstanceActionInput: Decodable, Sendable {
  public let action: WorkflowInstanceAction
  public let expectedRevision: Int
  public let expectedProfile: String
}
