import Foundation
import RielaCore
@testable import RielaServer
import XCTest

final class DistributedWorkerAPIKeyTests: XCTestCase {
  func testPersistedWorkerKeyEnforcesPurposeIdentityExpiryAndImmediateRevocation() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/api-key-worker/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaAPIKeyStore(root: root.appendingPathComponent("keys"))
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let clock = APIKeyWorkerClock(now)
    let workerKey = try store.issue(name: "worker", purpose: .worker, workerID: "worker", now: now)
    let clientKey = try store.issue(name: "client", now: now)
    let unknownKey = try store.issue(name: "unknown", purpose: .worker, workerID: "unknown", now: now)
    let expiringKey = try store.issue(name: "expiry", purpose: .worker, workerID: "worker",
                                      expiresAt: now.addingTimeInterval(1), now: now)
    let controller = try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, workers: [.init(id: "worker", groups: ["trusted"], maxCapacity: 1)],
      apiKeyStore: RielaAPIKeyStore(root: store.root), clock: clock
    )
    let register = DistributedWorkerRequest(operation: .register, capacity: 1)
    let oversizedBearer = await send(router, String(repeating: "a", count: 257), register)
    XCTAssertEqual(oversizedBearer.status, 403)
    let clientResponse = await send(router, clientKey.token, register)
    let unknownResponse = await send(router, unknownKey.token, register)
    XCTAssertEqual(clientResponse.status, 403)
    XCTAssertEqual(unknownResponse.status, 403)
    try store.setRequireClientKey(false)
    let noToken = await send(router, "", register)
    XCTAssertEqual(noToken.status, 403)
    let accepted = await send(router, workerKey.token, register)
    XCTAssertEqual(accepted.status, 200)
    let reply = try JSONDecoder().decode(DistributedWorkerResponse.self, from: accepted.body)
    let registration = try XCTUnwrap(reply.registration)
    XCTAssertEqual(registration.workerId, "worker")
    XCTAssertEqual(registration.groups, ["trusted"])
    let oversized = await send(router, workerKey.token, .init(operation: .register, capacity: 2))
    XCTAssertEqual(oversized.status, 403)
    let initialExpiry = await send(router, expiringKey.token, register)
    XCTAssertEqual(initialExpiry.status, 200)
    clock.advance()
    let expired = await send(router, expiringKey.token, register)
    XCTAssertEqual(expired.status, 403)
    try store.revoke(id: workerKey.record.id)
    for operation in [DistributedWorkerOperation.claim, .renew, .complete, .events, .stopped, .register] {
      let rejected = await send(router, workerKey.token, .init(operation: operation, registration: registration))
      XCTAssertEqual(rejected.status, 403, "Revocation must be checked for \(operation)")
    }
  }

  func testPersistedWorkerKeyCompletesLiveHTTPExchangeAndStopsAtExpiryAndRevocation() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/api-key-worker/live-http/\(UUID().uuidString)")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let store = RielaAPIKeyStore(root: root.appendingPathComponent("keys"))
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let clock = APIKeyWorkerClock(now)
    let issued = try store.issue(name: "Live worker", purpose: .worker, workerID: "worker",
                                 expiresAt: now.addingTimeInterval(10), now: now)
    let controller = try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, workers: [.init(id: "worker", groups: ["trusted"], maxCapacity: 1)],
      apiKeyStore: RielaAPIKeyStore(root: store.root), clock: clock
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    let client = try DistributedWorkerHTTPClient(controllerURL: endpoint, token: issued.token)
    let registered = try await client.send(.init(operation: .register, capacity: 1))
    let registration = try XCTUnwrap(registered.registration)
    XCTAssertEqual(registration.workerId, "worker")
    XCTAssertEqual(registration.groups, ["trusted"])
    _ = try await controller.enqueue(id: "live-key-job", target: .init(workerId: "worker"), payload: [:])
    let claimed = try await client.send(.init(operation: .claim, registration: registration))
    let job = try XCTUnwrap(claimed.job)
    let leaseToken = try XCTUnwrap(job.lease?.token)
    _ = try await client.send(.init(operation: .renew, registration: registration,
                                    jobId: job.id, leaseToken: leaseToken))
    let event = DistributedJobEvent(sequence: 1, event: .init(
      provider: "test", eventType: "progress", contentSnapshot: "working"
    ))
    _ = try await client.send(.init(operation: .events, registration: registration,
                                    jobId: job.id, leaseToken: leaseToken, events: [event]))
    let result = DistributedJobResult(outcome: .succeeded, payload: ["output": .string("done")])
    let completed = try await client.send(.init(operation: .complete, registration: registration,
                                               jobId: job.id, leaseToken: leaseToken, result: result))
    XCTAssertEqual(completed.job?.status, .succeeded)
    let persisted = try await controller.job(id: job.id, now: now)
    XCTAssertEqual(persisted?.events?.map(\.sequence), [1])
    XCTAssertEqual(persisted?.result, result)
    clock.advance(by: 10)
    do {
      _ = try await client.send(.init(operation: .claim, registration: registration))
      XCTFail("Expired persisted worker key accepted over HTTP")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .rejected(status: 403)) }
    let rotated = try store.issue(name: "Replacement", purpose: .worker, workerID: "worker", now: clock.now())
    let replacement = try DistributedWorkerHTTPClient(controllerURL: endpoint, token: rotated.token)
    _ = try await replacement.send(.init(operation: .register, capacity: 1))
    try RielaAPIKeyStore(root: store.root).revoke(id: rotated.record.id)
    do {
      _ = try await replacement.send(.init(operation: .register, capacity: 1))
      XCTFail("Revoked persisted worker key accepted by existing HTTP router")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .rejected(status: 403)) }
  }

  private func send(
    _ router: DistributedWorkerHTTPRouter, _ token: String, _ message: DistributedWorkerRequest
  ) async -> RielaHTTPResponse {
    await router.response(for: RielaHTTPRequest(
      method: "POST", path: DistributedWorkerHTTPRouter.path,
      headers: ["content-type": "application/json", "authorization": "Bearer " + token],
      body: (try? JSONEncoder().encode(message)) ?? Data()
    ))
  }
}

private final class APIKeyWorkerClock: WorkflowRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func advance(by seconds: TimeInterval = 1) {
    lock.lock()
    defer { lock.unlock() }
    value = value.addingTimeInterval(seconds)
  }
}
