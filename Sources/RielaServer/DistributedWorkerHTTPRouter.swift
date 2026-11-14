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

  public init(
    controller: DistributedJobController, credentials: [DistributedWorkerCredential],
    clock: any WorkflowRuntimeClock = SystemWorkflowRuntimeClock(),
    leaseDurationSeconds: Double = Self.leaseDurationSeconds
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
        message.registration == nil, message.jobId == nil, message.leaseToken == nil, message.result == nil else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      let registration = try await controller.register(workerId: credential.workerId, groups: credential.groups, capacity: capacity, now: clock.now())
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
      return try await reply(job: controller.claim(worker: registration, now: clock.now(), leaseDuration: leaseDuration))
    case .renew, .complete, .events:
      guard let jobId = message.jobId, let token = message.leaseToken else {
        throw DistributedWorkerTransportError.invalidConfiguration
      }
      if message.operation == .complete {
        guard let result = message.result else { throw DistributedWorkerTransportError.invalidConfiguration }
        let completed = try await controller.complete(jobId: jobId, worker: registration, token: token, result: result, now: clock.now())
        // A completion acknowledgement must not retransmit a possibly large
        // invocation, result and event history in the same bounded HTTP body.
        return reply(job: DistributedJob(id: completed.id, target: completed.target, payload: [:], status: completed.status, lease: completed.lease))
      }
      guard message.result == nil else { throw DistributedWorkerTransportError.invalidConfiguration }
      if message.operation == .events {
        guard let events = message.events else { throw DistributedWorkerTransportError.invalidConfiguration }
        try await controller.appendEvents(jobId: jobId, worker: registration, token: token, events: events, now: clock.now())
        return reply()
      }
      try await controller.renew(jobId: jobId, worker: registration, token: token, now: clock.now(), leaseDuration: leaseDuration)
      return reply()
    case .register:
      throw DistributedWorkerTransportError.invalidConfiguration
    }
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
