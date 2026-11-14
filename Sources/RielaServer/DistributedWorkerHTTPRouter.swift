import Foundation
import RielaCore

/// Shared by the app-owned listener and `riela serve`. This endpoint grants
/// only worker operations, never enqueue, manager control, or arbitrary reads.
public struct DistributedWorkerHTTPRouter: RielaHTTPRouteHandling {
  public static let path = "/distributed/v1/worker"
  public static let maximumBodyBytes = 2 * 1024 * 1024
  public static let leaseDurationSeconds: Double = 30

  private let controller: DistributedJobController
  private let credentials: [DistributedWorkerCredential]
  private let clock: any WorkflowRuntimeClock
  private let leaseDuration: Double
  private let capabilitySnapshotSink: @Sendable (HostCapabilitySnapshot) async throws -> Void

  public init(
    controller: DistributedJobController, credentials: [DistributedWorkerCredential],
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    leaseDurationSeconds: Double = Self.leaseDurationSeconds,
    capabilitySnapshotSink: @escaping @Sendable (HostCapabilitySnapshot) async throws -> Void = { _ in }
  ) throws {
    guard leaseDurationSeconds.isFinite, (3...3600).contains(leaseDurationSeconds), !credentials.isEmpty,
      Set(credentials.map(\.workerId)).count == credentials.count,
      Set(credentials.map(\.token)).count == credentials.count,
      credentials.allSatisfy({ credential in
        !credential.workerId.isEmpty && credential.token.utf8.count >= 32
          && credential.token.utf8.count <= 256
          && credential.token.utf8.allSatisfy { (33...126).contains($0) }
          && (1...1024).contains(credential.maxCapacity)
      }) else { throw DistributedWorkerTransportError.invalidConfiguration }
    self.controller = controller
    self.credentials = credentials
    self.clock = clock
    self.leaseDuration = leaseDurationSeconds
    self.capabilitySnapshotSink = capabilitySnapshotSink
  }

  public func response(for request: RielaHTTPRequest) async -> RielaHTTPResponse {
    guard request.path == Self.path, request.percentEncodedPath == Self.path, request.query == nil else {
      return failure(404, "not_found")
    }
    guard request.method == "POST" else { return failure(405, "post_required") }
    // Native worker credentials have no browser authority or CORS bootstrap.
    guard request.headers["origin"] == nil,
      let authorization = request.headers["authorization"],
      let credential = credentials.first(where: { constantTimeEqual(authorization, "Bearer " + $0.token) }) else {
      return failure(403, "unauthorized_worker")
    }
    guard request.body.count <= Self.maximumBodyBytes else { return failure(413, "message_too_large") }
    guard request.headers["content-type"]?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
      return failure(415, "json_required")
    }
    do {
      let message = try JSONDecoder().decode(DistributedWorkerRequest.self, from: request.body)
      guard message.operation == .events || message.events == nil else {
        return failure(400, "unexpected_events")
      }
      let reply = try await dispatch(message, credential: credential)
      let bytes = try JSONEncoder().encode(reply)
      guard bytes.count <= Self.maximumBodyBytes else { return failure(413, "message_too_large") }
      return RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: bytes)
    } catch is DecodingError {
      return failure(400, "invalid_request")
    } catch is AdapterExecutionError {
      return failure(400, "invalid_artifact_result")
    } catch let error as DistributedWorkerError {
      switch error {
      case .staleWorker, .staleLease, .conflictingResult, .conflictingJob, .staleControllerConfiguration:
        return failure(409, "execution_conflict")
      case .unknownJob:
        return failure(404, "unknown_job")
      default:
        return failure(400, "invalid_request")
      }
    } catch is DistributedWorkerTransportError {
      return failure(403, "invalid_worker_request")
    } catch {
      // Do not return filesystem paths, invocation payloads or credentials.
      return failure(503, "controller_unavailable")
    }
  }

  private func dispatch(
    _ message: DistributedWorkerRequest, credential: DistributedWorkerCredential
  ) async throws -> DistributedWorkerResponse {
    if message.operation == .register {
      guard let capacity = message.capacity, (1...credential.maxCapacity).contains(capacity),
        message.registration == nil, message.jobId == nil, message.leaseToken == nil,
        message.result == nil, message.capabilitiesObservedAt == nil else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      let registration = try await controller.register(
        workerId: credential.workerId,
        groups: credential.groups,
        capacity: capacity,
        capabilities: message.capabilities ?? [],
        environment: message.environment ?? [:],
        addonExecutables: message.addonExecutables ?? [:],
        now: clock.now()
      )
      try await publishCapabilities(registration)
      return reply(registration: registration)
    }
    guard message.capacity == nil, let registration = message.registration,
      registration.workerId == credential.workerId, registration.groups == credential.groups,
      registration.capacity <= credential.maxCapacity else { throw DistributedWorkerTransportError.invalidConfiguration }
    switch message.operation {
    case .claim:
      guard message.jobId == nil, message.leaseToken == nil, message.result == nil else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      let observation = try refreshObservation(message, now: clock.now())
      let job = try await controller.claim(worker: registration, now: clock.now(), leaseDuration: leaseDuration)
      try await publishCapabilities(registration, observation: observation)
      return reply(job: job)
    case .renew, .complete, .events, .stopped:
      let observation = message.operation == .renew ? try refreshObservation(message, now: clock.now()) : nil
      guard message.operation == .renew || (
        message.capabilities == nil && message.environment == nil
          && message.addonExecutables == nil && message.capabilitiesObservedAt == nil
      ) else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      guard let jobId = message.jobId, let token = message.leaseToken else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      if message.operation == .complete {
        guard let result = message.result else { throw DistributedWorkerTransportError.invalidConfiguration }
        let completed = try await controller.complete(jobId: jobId, worker: registration, token: token, result: result, now: clock.now())
        try await publishCapabilities(registration)
        // A completion acknowledgement must not retransmit a possibly large
        // invocation, result and event history in the same bounded HTTP body.
        return reply(job: DistributedJob(id: completed.id, target: completed.target, payload: [:], status: completed.status, lease: completed.lease))
      }
      guard message.result == nil else { throw DistributedWorkerTransportError.invalidConfiguration }
      if message.operation == .stopped {
        guard message.events == nil else { throw DistributedWorkerTransportError.invalidConfiguration }
        _ = try await controller.acknowledgeStopped(
          jobId: jobId, worker: registration, token: token, now: clock.now()
        )
        return reply()
      }
      if message.operation == .events {
        guard let events = message.events else { throw DistributedWorkerTransportError.invalidConfiguration }
        try await controller.appendEvents(jobId: jobId, worker: registration, token: token, events: events, now: clock.now())
        try await publishCapabilities(registration)
        return reply()
      }
      try await controller.renew(jobId: jobId, worker: registration, token: token, now: clock.now(), leaseDuration: leaseDuration)
      try await publishCapabilities(registration, observation: observation)
      return reply()
    case .register:
      throw DistributedWorkerTransportError.invalidConfiguration
    }
  }

  private func refreshObservation(
    _ message: DistributedWorkerRequest,
    now: Date
  ) throws -> DistributedWorkerCapabilityObservation? {
    let hasRefresh = message.capabilities != nil || message.environment != nil
      || message.addonExecutables != nil || message.capabilitiesObservedAt != nil
    guard hasRefresh else { return nil }
    guard let capabilities = message.capabilities,
      let environment = message.environment,
      let addonExecutables = message.addonExecutables,
      let observedAt = message.capabilitiesObservedAt,
      capabilities.count <= NodeExecutionBackend.allCases.count,
      Set(capabilities.map(\.backend)).count == capabilities.count,
      environment.count <= 512, addonExecutables.count <= 512,
      environment.keys.allSatisfy(isValidEnvironmentVariableName),
      addonExecutables.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
      throw DistributedWorkerTransportError.invalidConfiguration
    }
    let lead = observedAt.timeIntervalSince(now)
    // An out-of-range worker clock must not prevent a valid claim or lease renewal.
    guard lead <= 30 else { return nil }
    let adjustment = max(0, lead)
    return DistributedWorkerCapabilityObservation(
      capabilities: capabilities.map { shiftedCapability($0, by: adjustment) },
      environment: environment,
      addonExecutables: addonExecutables,
      observedAt: observedAt.addingTimeInterval(-adjustment)
    )
  }

  private func publishCapabilities(
    _ registration: DistributedWorkerRegistration,
    observation: DistributedWorkerCapabilityObservation? = nil
  ) async throws {
    let now = clock.now()
    let backends = observation?.capabilities ?? registration.capabilities.map { capability in
      let lead = capability.observedAt?.timeIntervalSince(now) ?? 0
      return shiftedCapability(capability, by: lead > 0 && lead <= 30 ? lead : 0)
    }
    try await capabilitySnapshotSink(HostCapabilitySnapshot(
      hostId: registration.workerId,
      groups: registration.groups,
      capacity: registration.capacity,
      live: true,
      backends: backends,
      addonExecutables: observation?.addonExecutables ?? registration.addonExecutables,
      environment: observation?.environment ?? registration.environment,
      capabilitiesObservedAt: observation?.observedAt ?? registration.capabilitiesObservedAt,
      refreshedAt: now
    ))
  }

  private func shiftedCapability(_ capability: BackendCapability, by adjustment: TimeInterval) -> BackendCapability {
    BackendCapability(
      backend: capability.backend,
      source: capability.source,
      observedAt: capability.observedAt?.addingTimeInterval(-adjustment),
      availability: capability.availability,
      authentication: capability.authentication,
      version: capability.version,
      models: capability.models,
      requiredEnvironment: capability.requiredEnvironment,
      requiredEnvironmentAlternatives: capability.requiredEnvironmentAlternatives,
      executableAvailable: capability.executableAvailable,
      failures: capability.failures
    )
  }

  private func reply(registration: DistributedWorkerRegistration? = nil, job: DistributedJob? = nil) -> DistributedWorkerResponse {
    DistributedWorkerResponse(registration: registration, job: job, leaseDurationSeconds: leaseDuration)
  }

  private func failure(_ status: Int, _ code: String) -> RielaHTTPResponse {
    var response = RielaHTTPResponse.json(status: status, .object(["error": .string(code)]))
    response.headers["Cache-Control"] = "no-store"
    return response
  }

  private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }
}
