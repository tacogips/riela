import Foundation

/// Both constraints apply when supplied. An empty target means any remote worker.
public struct DistributedWorkerTarget: Codable, Equatable, Sendable {
  public let workerId: String?
  public let group: String?

  public init(workerId: String? = nil, group: String? = nil) {
    self.workerId = workerId
    self.group = group
  }

  func matches(_ worker: DistributedWorkerRegistration) -> Bool {
    (workerId == nil || workerId == worker.workerId)
      && (group == nil || worker.groups.contains(group ?? ""))
  }
}

public struct DistributedWorkerRegistration: Codable, Equatable, Sendable {
  public let workerId: String
  public let incarnation: String
  public let groups: Set<String>
  public let capacity: Int
}

public struct DistributedWorkerStatus: Codable, Equatable, Sendable {
  public let workerId: String
  public let groups: Set<String>
  public let capacity: Int
  public let activeJobIds: [String]
  public let lastSeenAt: Date?
  public let online: Bool
}

public enum DistributedJobStatus: String, Codable, Sendable {
  case queued, leased, succeeded, failed, cancelled, lost
}

public struct DistributedJobLease: Codable, Equatable, Sendable {
  public let workerId: String
  public let incarnation: String
  public let token: String
  public var expiresAt: Date
}

public struct DistributedJobResult: Codable, Equatable, Sendable {
  public static let maximumEncodedBytes = 1024 * 1024

  public enum Outcome: String, Codable, Sendable {
    case succeeded, failed
  }

  public let outcome: Outcome
  public let payload: JSONObject
  public let failure: DistributedJobFailure?
  public let artifacts: [DistributedArtifact]?

  public init(outcome: Outcome, payload: JSONObject, failure: DistributedJobFailure? = nil, artifacts: [DistributedArtifact]? = nil) {
    self.outcome = outcome
    self.payload = payload
    self.failure = failure
    self.artifacts = artifacts
  }
}

public struct DistributedJobFailure: Codable, Equatable, Sendable {
  public let code: AdapterExecutionErrorCode
  public let message: String

  public init(code: AdapterExecutionErrorCode) {
    self.code = code
    switch code {
    case .invalidInput:
      message = "Worker rejected the invocation; check workspace mappings, node configuration and required worker environment."
    case .policyBlocked:
      message = "Worker policy denied execution; check workspace boundaries, add-on authorization and node policy."
    case .timeout:
      message = "Worker execution exceeded its deadline."
    case .invalidOutput:
      message = "Worker returned an invalid node output."
    case .templateResolutionFailed:
      message = "Worker could not resolve a required upstream payload template."
    case .providerError:
      message = "Worker node execution failed; check the worker's executable and provider configuration."
    }
  }
}

public struct DistributedJob: Codable, Equatable, Sendable {
  public let id: String
  public let target: DistributedWorkerTarget
  public let payload: JSONObject
  public var status: DistributedJobStatus
  public var lease: DistributedJobLease?
  public var result: DistributedJobResult?
  public var events: [DistributedJobEvent]?
  public var eventCount: Int?
  public var archived: Bool?

  public init(
    id: String, target: DistributedWorkerTarget, payload: JSONObject, status: DistributedJobStatus,
    lease: DistributedJobLease? = nil, result: DistributedJobResult? = nil,
    events: [DistributedJobEvent]? = nil, eventCount: Int? = nil
  ) {
    self.id = id
    self.target = target
    self.payload = payload
    self.status = status
    self.lease = lease
    self.result = result
    self.events = events
    self.eventCount = eventCount
  }
}

public struct DistributedJobEvent: Codable, Equatable, Sendable {
  public let sequence: Int
  public let event: AdapterBackendEvent

  public init(sequence: Int, event: AdapterBackendEvent) {
    self.sequence = sequence
    self.event = event
  }
}

public enum DistributedWorkerError: Error, Equatable {
  case invalidRegistration
  case invalidJob
  case conflictingJob
  case unknownJob
  case staleWorker
  case staleLease
  case conflictingResult
  case invalidLeaseDuration
  case unsupportedStoreVersion
  case storeUnavailable
  case controllerBusy
  case staleControllerConfiguration
  case storeCapacityExceeded
}

extension DistributedWorkerError: LocalizedError {
  public var errorDescription: String? {
    if self == .storeCapacityExceeded {
      return "Controller storage capacity reached. Finish active jobs or archive the idle controller data root before selecting a new store."
    }
    return nil
  }
}
