import Foundation

public struct WorkflowInstance: Identifiable, Equatable, Sendable {
  public var id: String { identity }

  public var identity: String
  public var source: RielaAppDaemonWorkflowCandidate
  public var preference: RielaAppDaemonWorkflowPreference
  public var isConfigured: Bool

  public init(
    identity: String,
    source: RielaAppDaemonWorkflowCandidate,
    preference: RielaAppDaemonWorkflowPreference,
    isConfigured: Bool = true
  ) {
    var normalizedPreference = preference
    normalizedPreference.identity = identity
    self.identity = identity
    self.source = source
    self.preference = normalizedPreference
    self.isConfigured = isConfigured
  }

  public static func configured(
    identity: String,
    source: RielaAppDaemonWorkflowCandidate,
    preference: RielaAppDaemonWorkflowPreference
  ) -> WorkflowInstance {
    WorkflowInstance(
      identity: identity,
      source: source,
      preference: preference,
      isConfigured: true
    )
  }

  public static func unconfigured(source: RielaAppDaemonWorkflowCandidate) -> WorkflowInstance {
    WorkflowInstance(
      identity: source.id,
      source: source,
      preference: RielaAppDaemonWorkflowPreference(identity: source.id),
      isConfigured: false
    )
  }

  public var sourceIdentity: String {
    preference.sourceIdentity ?? source.id
  }

  public var isDefault: Bool { identity == sourceIdentity }

  public var displayName: String {
    if let name = preference.displayName, !name.isEmpty { return name }
    return isDefault ? "標準設定" : source.displayName
  }

  public var candidate: RielaAppDaemonWorkflowCandidate {
    guard isConfigured else {
      return source
    }
    return source.managedInstance(identity: identity, displayName: preference.displayName)
  }
}

public extension RielaAppDaemonWorkflowState {
  func workflowInstances(from sourceCandidates: [RielaAppDaemonWorkflowCandidate]) -> [WorkflowInstance] {
    let sourcesByIdentity = Dictionary(uniqueKeysWithValues: sourceCandidates.map { ($0.id, $0) })
    let configuredInstances = preferences
      .sorted { lhs, rhs in lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending }
      .compactMap { identity, preference -> WorkflowInstance? in
        let sourceIdentity = preference.sourceIdentity ?? identity
        guard let source = sourcesByIdentity[sourceIdentity] else {
          return nil
        }
        return .configured(identity: identity, source: source, preference: preference)
      }
    // A named configuration must never replace the stable source-id default.
    let configuredIdentities = Set(preferences.keys)
    let unconfiguredInstances = sourceCandidates
      .filter { !configuredIdentities.contains($0.id) }
      .map(WorkflowInstance.unconfigured(source:))
    return configuredInstances + unconfiguredInstances
  }
}
