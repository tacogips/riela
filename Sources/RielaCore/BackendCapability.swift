import Foundation

/// A bounded observation of one execution backend. Concrete executable and
/// credential probing belongs to RielaAdapters; this value is deliberately
/// neutral so workflow validation and placement can share it.
public struct BackendCapability: Codable, Equatable, Sendable {
  public enum Source: String, Codable, Sendable {
    case declared
    case observed
    case merged
  }

  public enum Availability: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
  }

  public enum Authentication: String, Codable, Sendable {
    case available
    case failed
    case unknown
  }

  public let backend: NodeExecutionBackend
  public let source: Source
  public let observedAt: Date?
  public let availability: Availability
  public let authentication: Authentication
  public let version: String?
  public let models: [String]?
  public let requiredEnvironment: [String: Bool]
  public let requiredEnvironmentAlternatives: [[String]]?
  public let executableAvailable: Bool?
  public let failures: [String]

  public init(
    backend: NodeExecutionBackend,
    source: Source,
    observedAt: Date? = nil,
    availability: Availability = .unknown,
    authentication: Authentication = .unknown,
    version: String? = nil,
    models: [String]? = nil,
    requiredEnvironment: [String: Bool] = [:],
    requiredEnvironmentAlternatives: [[String]]? = nil,
    executableAvailable: Bool? = nil,
    failures: [String] = []
  ) {
    self.backend = backend
    self.source = source
    self.observedAt = observedAt
    self.availability = availability
    self.authentication = authentication
    self.version = version
    self.models = models
    self.requiredEnvironment = requiredEnvironment
    self.requiredEnvironmentAlternatives = requiredEnvironmentAlternatives
    self.executableAvailable = executableAvailable
    self.failures = failures
  }

  /// The freshness boundary is intentionally strict: equality is stale so a
  /// dispatcher cannot reuse an observation at its advertised expiry.
  public func isFresh(at date: Date, maximumAge: TimeInterval) -> Bool {
    guard maximumAge.isFinite, maximumAge >= 0, let observedAt else {
      return false
    }
    let age = date.timeIntervalSince(observedAt)
    return age >= 0 && age < maximumAge
  }
}

/// Operator-owned backend policy for one host. Declarations supplement probe
/// observations; they never imply worker liveness or capacity.
public struct BackendCapabilityDeclaration: Codable, Equatable, Sendable {
  public var enabled: Bool
  public var models: [String]?
  public var reason: String?

  public init(enabled: Bool, models: [String]? = nil, reason: String? = nil) {
    self.enabled = enabled
    self.models = models
    self.reason = reason
  }
}

public struct HostCapabilitySnapshot: Codable, Equatable, Sendable {
  public var hostId: String
  public var groups: Set<String>
  public var capacity: Int?
  public var live: Bool
  public var backends: [BackendCapability]
  public var addonExecutables: [String: Bool]
  public var environment: [String: Bool]
  public var capabilitiesObservedAt: Date?
  public var refreshedAt: Date

  public init(
    hostId: String,
    groups: Set<String> = [],
    capacity: Int? = nil,
    live: Bool = true,
    backends: [BackendCapability],
    addonExecutables: [String: Bool] = [:],
    environment: [String: Bool] = [:],
    capabilitiesObservedAt: Date? = nil,
    refreshedAt: Date
  ) {
    self.hostId = hostId
    self.groups = groups
    self.capacity = capacity
    self.live = live
    self.backends = backends
    self.addonExecutables = addonExecutables
    self.environment = environment
    self.capabilitiesObservedAt = capabilitiesObservedAt ?? refreshedAt
    self.refreshedAt = refreshedAt
  }

  public func capability(for backend: NodeExecutionBackend) -> BackendCapability? {
    backends.first { $0.backend == backend }
  }
}

public enum BackendCapabilityMerger {
  public static func merge(
    observations: [BackendCapability],
    declarations: [NodeExecutionBackend: BackendCapabilityDeclaration]
  ) -> [BackendCapability] {
    let observed = Dictionary(observations.map { ($0.backend, $0) }, uniquingKeysWith: { _, latest in latest })
    return NodeExecutionBackend.allCases.compactMap { backend in
      let observation = observed[backend]
      guard let declaration = declarations[backend] else { return observation }
      let declaredFailure = declaration.reason.map { [$0] } ?? []
      guard declaration.enabled else {
        return BackendCapability(
          backend: backend,
          source: .declared,
          observedAt: observation?.observedAt,
          availability: .unavailable,
          authentication: observation?.authentication ?? .unknown,
          version: observation?.version,
          models: declaration.models ?? observation?.models,
          requiredEnvironment: observation?.requiredEnvironment ?? [:],
          requiredEnvironmentAlternatives: observation?.requiredEnvironmentAlternatives,
          executableAvailable: observation?.executableAvailable,
          failures: stableUnique(declaredFailure + (observation?.failures ?? []))
        )
      }
      return BackendCapability(
        backend: backend,
        source: observation == nil ? .declared : .merged,
        observedAt: observation?.observedAt,
        availability: .available,
        authentication: observation?.authentication ?? .unknown,
        version: observation?.version,
        models: declaration.models ?? observation?.models,
        requiredEnvironment: observation?.requiredEnvironment ?? [:],
        requiredEnvironmentAlternatives: observation?.requiredEnvironmentAlternatives,
        executableAvailable: observation?.executableAvailable,
        failures: stableUnique((observation?.failures ?? []) + declaredFailure)
      )
    }
  }

  private static func stableUnique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    return values.filter { seen.insert($0).inserted }
  }
}
