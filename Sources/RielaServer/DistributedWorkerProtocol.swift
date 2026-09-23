import Foundation
import RielaCore

public enum DistributedWorkerOperation: String, Codable, Sendable {
  case register, claim, renew, complete, events
}

public struct DistributedWorkerCapabilityObservation: Sendable {
  public var capabilities: [BackendCapability]
  public var environment: [String: Bool]
  public var addonExecutables: [String: Bool]
  public var observedAt: Date

  public init(
    capabilities: [BackendCapability], environment: [String: Bool],
    addonExecutables: [String: Bool], observedAt: Date
  ) {
    self.capabilities = capabilities
    self.environment = environment
    self.addonExecutables = addonExecutables
    self.observedAt = observedAt
  }
}

public struct DistributedWorkerRequest: Codable, Sendable {
  public var operation: DistributedWorkerOperation
  public var capacity: Int?
  public var registration: DistributedWorkerRegistration?
  public var jobId: String?
  public var leaseToken: String?
  public var result: DistributedJobResult?
  public var events: [DistributedJobEvent]?
  public var capabilities: [BackendCapability]?
  public var environment: [String: Bool]?
  public var addonExecutables: [String: Bool]?
  public var capabilitiesObservedAt: Date?

  public init(
    operation: DistributedWorkerOperation, capacity: Int? = nil,
    registration: DistributedWorkerRegistration? = nil, jobId: String? = nil,
    leaseToken: String? = nil, result: DistributedJobResult? = nil, events: [DistributedJobEvent]? = nil,
    capabilities: [BackendCapability]? = nil, environment: [String: Bool]? = nil,
    addonExecutables: [String: Bool]? = nil, capabilitiesObservedAt: Date? = nil
  ) {
    self.operation = operation
    self.capacity = capacity
    self.registration = registration
    self.jobId = jobId
    self.leaseToken = leaseToken
    self.result = result
    self.events = events
    self.capabilities = capabilities
    self.environment = environment
    self.addonExecutables = addonExecutables
    self.capabilitiesObservedAt = capabilitiesObservedAt
  }
}

public struct DistributedWorkerResponse: Codable, Sendable {
  public let registration: DistributedWorkerRegistration?
  public let job: DistributedJob?
  public let leaseDurationSeconds: Double
}

/// Kept in controller configuration, never sent to workers or status endpoints.
public struct DistributedWorkerCredential: Sendable {
  public let workerId: String
  public let groups: Set<String>
  public let token: String
  public let maxCapacity: Int

  public init(workerId: String, groups: Set<String>, token: String, maxCapacity: Int = 4) {
    self.workerId = workerId
    self.groups = groups
    self.token = token
    self.maxCapacity = maxCapacity
  }
}

public enum DistributedWorkerTransportError: Error, Equatable, Sendable {
  case invalidConfiguration
  case invalidEndpoint
  case insecureEndpoint
  case oversizedMessage
  case rejected(status: Int)
  case invalidResponse
  case networkFailure
}
