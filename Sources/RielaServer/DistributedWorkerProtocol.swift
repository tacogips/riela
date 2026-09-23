import Foundation
import RielaCore

public enum DistributedWorkerOperation: String, Codable, Sendable {
  case register, claim, renew, complete, events
}

public struct DistributedWorkerRequest: Codable, Sendable {
  public var operation: DistributedWorkerOperation
  public var capacity: Int?
  public var registration: DistributedWorkerRegistration?
  public var jobId: String?
  public var leaseToken: String?
  public var result: DistributedJobResult?
  public var events: [DistributedJobEvent]?

  public init(
    operation: DistributedWorkerOperation, capacity: Int? = nil,
    registration: DistributedWorkerRegistration? = nil, jobId: String? = nil,
    leaseToken: String? = nil, result: DistributedJobResult? = nil, events: [DistributedJobEvent]? = nil
  ) {
    self.operation = operation
    self.capacity = capacity
    self.registration = registration
    self.jobId = jobId
    self.leaseToken = leaseToken
    self.result = result
    self.events = events
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
