import Foundation
import RielaCore
import RielaWork
@testable import RielaServer
import XCTest

final class DistributedWorkerHTTPTests: XCTestCase {
  private let tokenA = String(repeating: "a", count: 40)
  private let tokenB = String(repeating: "b", count: 40)

  private func controller() throws -> DistributedJobController {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/http-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
  }

  private func router(_ controller: DistributedJobController) throws -> DistributedWorkerHTTPRouter {
    try DistributedWorkerHTTPRouter(controller: controller, credentials: [
      .init(workerId: "mac", groups: ["apple"], token: tokenA, maxCapacity: 2),
      .init(workerId: "linux", groups: ["linux"], token: tokenB, maxCapacity: 1)
    ])
  }

  func testTwoLiveHTTPWorkersRouteAndPublishResults() async throws {
    let controller = try controller()
    let server = RielaLocalHTTPServer(routeHandler: try router(controller))
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
    let mac = try DistributedWorkerHTTPClient(controllerURL: url, token: tokenA)
    let linux = try DistributedWorkerHTTPClient(controllerURL: url, token: tokenB)
    let macReply = try await mac.send(.init(operation: .register, capacity: 2))
    let linuxReply = try await linux.send(.init(operation: .register, capacity: 1))
    let macRegistration = try XCTUnwrap(macReply.registration)
    let linuxRegistration = try XCTUnwrap(linuxReply.registration)
    XCTAssertEqual(macRegistration.groups, ["apple"])
    XCTAssertEqual(linuxRegistration.workerId, "linux")
    _ = try await controller.enqueue(id: "linux-only", target: .init(workerId: "linux"), payload: ["command": .string("test")])
    let noJob = try await mac.send(.init(operation: .claim, registration: macRegistration))
    XCTAssertNil(noJob.job)
    let claimed = try await linux.send(.init(operation: .claim, registration: linuxRegistration))
    let job = try XCTUnwrap(claimed.job)
    XCTAssertEqual(job.id, "linux-only")
    let token = try XCTUnwrap(job.lease?.token)
    _ = try await linux.send(.init(operation: .renew, registration: linuxRegistration, jobId: job.id, leaseToken: token))
    do {
      _ = try await linux.send(.init(
        operation: .complete, registration: linuxRegistration, jobId: job.id, leaseToken: token,
        result: .init(outcome: .succeeded, payload: [:], artifacts: [.init(path: "unsolicited", data: Data())])
      ))
      XCTFail("Unrequested artifact accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .rejected(status: 400)) }
    let result = DistributedJobResult(outcome: .succeeded, payload: ["output": .string("done")])
    let completed = try await linux.send(.init(operation: .complete, registration: linuxRegistration, jobId: job.id, leaseToken: token, result: result))
    XCTAssertEqual(completed.job?.status, .succeeded)
    let duplicate = try await linux.send(.init(operation: .complete, registration: linuxRegistration, jobId: job.id, leaseToken: token, result: result))
    XCTAssertEqual(duplicate.job, completed.job)
    do {
      _ = try await mac.send(.init(operation: .claim, registration: linuxRegistration))
      XCTFail("Credential impersonation accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .rejected(status: 403)) }
  }

  func testRegistrationPublishesCapabilitiesToWorkHostStore() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/capability-store/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let controller = try controller()
    let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let clock = MutableDistributedWorkerClock(observedAt)
    let router = try DistributedWorkerHTTPRouter(
      controller: controller,
      credentials: [.init(workerId: "mac", groups: ["apple"], token: tokenA, maxCapacity: 2)],
      clock: clock,
      capabilitySnapshotSink: { snapshot in try store.saveHostSnapshot(snapshot) }
    )
    let body = try JSONEncoder().encode(DistributedWorkerRequest(
      operation: .register,
      capacity: 2,
      capabilities: [
        BackendCapability(
          backend: .codexAgent,
          source: .observed,
          observedAt: observedAt,
          availability: .available,
          authentication: .available,
          requiredEnvironment: ["CODEX_TOKEN": true],
          executableAvailable: true
        ),
        BackendCapability(
          backend: .claudeCodeAgent,
          source: .observed,
          observedAt: observedAt,
          availability: .available,
          authentication: .available,
          executableAvailable: true
        )
      ],
      environment: ["CODEX_TOKEN": false, "CUSTOM_ENV": true],
      addonExecutables: ["tool-cli": true]
    ))
    let response = await router.response(for: RielaHTTPRequest(
      method: "POST",
      path: DistributedWorkerHTTPRouter.path,
      headers: ["content-type": "application/json", "authorization": "Bearer " + tokenA],
      body: body
    ))
    XCTAssertEqual(response.status, 200)
    let registrationReply = try JSONDecoder().decode(DistributedWorkerResponse.self, from: response.body)
    let registration = try XCTUnwrap(registrationReply.registration)
    let snapshot = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertEqual(snapshot.hostId, "mac")
    XCTAssertEqual(snapshot.groups, ["apple"])
    XCTAssertEqual(snapshot.capacity, 2)
    XCTAssertTrue(snapshot.live)
    XCTAssertEqual(snapshot.backends.first?.backend, .codexAgent)
    XCTAssertEqual(snapshot.environment, ["CODEX_TOKEN": false, "CUSTOM_ENV": true])
    XCTAssertEqual(snapshot.addonExecutables, ["tool-cli": true])
    XCTAssertEqual(snapshot.capabilitiesObservedAt, observedAt)

    let backendProvenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "agent", nodeId: "agent")
    let addonProvenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "addon", nodeId: "addon")
    let placement = BackendCapabilityPlacementResolver().resolve(
      requirements: [
        WorkflowBackendRequirement(
          pin: .claudeCodeAgent,
          requiredEnvironment: ["CUSTOM_ENV"],
          provenance: [backendProvenance]
        ),
        WorkflowBackendRequirement(addonExecutable: "tool-cli", provenance: [addonProvenance])
      ],
      local: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: Date()),
      workers: [snapshot],
      assignments: [
        backendProvenance: DistributedWorkerTarget(workerId: "mac"),
        addonProvenance: DistributedWorkerTarget(workerId: "mac")
      ],
      now: observedAt
    )
    XCTAssertTrue(placement.complete)
    XCTAssertEqual(placement.choices.map(\.hostId), ["mac", "mac"])
    let workspaceFilteredPlacement = BackendCapabilityPlacementResolver().resolve(
      requirements: [WorkflowBackendRequirement(
        pin: .codexAgent,
        provenance: [backendProvenance]
      )],
      local: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: observedAt),
      workers: [snapshot],
      assignments: [backendProvenance: DistributedWorkerTarget(workerId: "mac")],
      now: observedAt
    )
    XCTAssertFalse(workspaceFilteredPlacement.complete, "A positive backend probe cannot override a workspace-filtered environment fact.")

    clock.advance(by: 20)
    let claimResponse = await router.response(for: RielaHTTPRequest(
      method: "POST",
      path: DistributedWorkerHTTPRouter.path,
      headers: ["content-type": "application/json", "authorization": "Bearer " + tokenA],
      body: try JSONEncoder().encode(DistributedWorkerRequest(operation: .claim, registration: registration))
    ))
    XCTAssertEqual(claimResponse.status, 200)
    let refreshedSnapshot = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertEqual(refreshedSnapshot.refreshedAt, observedAt.addingTimeInterval(20))
    XCTAssertEqual(refreshedSnapshot.capabilitiesObservedAt, observedAt)
    let stalePlacement = BackendCapabilityPlacementResolver(maximumAge: 300).resolve(
      requirements: [
        WorkflowBackendRequirement(
          requiredEnvironment: ["CUSTOM_ENV"],
          provenance: [backendProvenance]
        ),
        WorkflowBackendRequirement(addonExecutable: "tool-cli", provenance: [addonProvenance])
      ],
      local: HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: observedAt),
      workers: [refreshedSnapshot],
      assignments: [
        backendProvenance: DistributedWorkerTarget(workerId: "mac"),
        addonProvenance: DistributedWorkerTarget(workerId: "mac")
      ],
      now: observedAt.addingTimeInterval(300)
    )
    XCTAssertFalse(stalePlacement.complete, "Capability equality at maximum age is stale even after a liveness refresh.")
  }

  func testAuthenticationContentTypeAndBrowserRequestsFailClosed() async throws {
    let router = try router(controller())
    let body = try JSONEncoder().encode(DistributedWorkerRequest(operation: .register, capacity: 1))
    var request = RielaHTTPRequest(method: "POST", path: DistributedWorkerHTTPRouter.path, headers: ["content-type": "application/json"], body: body)
    let unauthenticated = await router.response(for: request)
    XCTAssertEqual(unauthenticated.status, 403)
    request.headers["authorization"] = "Bearer " + tokenA
    request.headers["origin"] = "https://untrusted.example"
    let browser = await router.response(for: request)
    XCTAssertEqual(browser.status, 403)
    request.headers.removeValue(forKey: "origin")
    request.headers["content-type"] = "text/plain"
    let invalidType = await router.response(for: request)
    XCTAssertEqual(invalidType.status, 415)
    request.headers["content-type"] = "application/json"
    request.body = Data(repeating: 0, count: DistributedWorkerHTTPRouter.maximumBodyBytes + 1)
    let oversized = await router.response(for: request)
    XCTAssertEqual(oversized.status, 413)
  }

  func testEndpointAndCredentialConfigurationValidation() throws {
    let remote = try XCTUnwrap(URL(string: "http://192.0.2.1:8787"))
    XCTAssertThrowsError(try DistributedWorkerHTTPClient(controllerURL: remote, token: tokenA)) {
      XCTAssertEqual($0 as? DistributedWorkerTransportError, .insecureEndpoint)
    }
    _ = try DistributedWorkerHTTPClient(controllerURL: remote, token: tokenA, allowInsecureHTTP: true)
    for endpoint in ["https://user:password@example.com", "https://example.com?token=secret", "https://example.com/other"] {
      XCTAssertThrowsError(try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: endpoint)), token: tokenA))
    }
    XCTAssertThrowsError(try DistributedWorkerHTTPRouter(controller: controller(), credentials: [
      .init(workerId: "one", groups: [], token: tokenA), .init(workerId: "two", groups: [], token: tokenA)
    ]))
  }

  func testClientRejectsRedirectAndLargeResponse() async throws {
    let server = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in
      RielaHTTPResponse(status: 302, headers: ["Location": "http://127.0.0.1:1/steal"])
    })
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    do {
      _ = try await client.send(.init(operation: .register, capacity: 1))
      XCTFail("Redirect accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .rejected(status: 302)) }
    let largeServer = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in
      RielaHTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: Data(repeating: 32, count: DistributedWorkerHTTPRouter.maximumBodyBytes + 1))
    })
    let largePort = try await largeServer.startForTesting()
    addTeardownBlock { await largeServer.stop() }
    let largeClient = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(largePort)")), token: tokenA)
    do {
      _ = try await largeClient.send(.init(operation: .register, capacity: 1))
      XCTFail("Oversized response accepted")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .oversizedMessage) }
  }

  func testWorkerLoopRenewsDuringExecutionAndStopsWhenCancelled() async throws {
    let controller = try controller()
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "mac", groups: [], token: tokenA)], leaseDurationSeconds: 3
    )
    let server = RielaLocalHTTPServer(routeHandler: router)
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    _ = try await controller.enqueue(id: "slow", target: .init(workerId: "mac"), payload: [:])
    let loop = try DistributedWorkerLoop(client: client, capacity: 1) { _ in
      try await Task.sleep(for: .seconds(4))
      return DistributedJobResult(outcome: .succeeded, payload: ["finished": .bool(true)])
    }
    let worker = Task { try await loop.run() }
    defer { worker.cancel() }
    let deadline = ContinuousClock().now.advanced(by: .seconds(8))
    var completed: DistributedJob?
    while ContinuousClock().now < deadline {
      completed = try await controller.jobs(now: Date()).first
      if completed?.status == .succeeded || completed?.status == .lost { break }
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertEqual(completed?.status, .succeeded, "Execution exceeds initial lease and requires renewal")
    worker.cancel()
    do {
      try await worker.value
      XCTFail("Loop should report cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testRejectedRenewalCancelsRunningExecutor() async throws {
    let controller = try controller()
    let router = try DistributedWorkerHTTPRouter(
      controller: controller, credentials: [.init(workerId: "mac", groups: [], token: tokenA)], leaseDurationSeconds: 3
    )
    let server = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { request in
      let message = try? JSONDecoder().decode(DistributedWorkerRequest.self, from: request.body)
      if message?.operation == .renew { return .json(status: 409, .object([:])) }
      return await router.response(for: request)
    })
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    _ = try await controller.enqueue(id: "cancel-on-lease-loss", target: .init(), payload: [:])
    let stopped = expectation(description: "Executor observes cancellation")
    let loop = try DistributedWorkerLoop(client: client, capacity: 2) { job in
      if job.id == "after-lease-loss" { return .init(outcome: .succeeded, payload: [:]) }
      do {
        try await Task.sleep(for: .seconds(20))
        XCTFail("Lost lease executor continued")
        return .init(outcome: .succeeded, payload: [:])
      } catch {
        stopped.fulfill()
        throw error
      }
    }
    let worker = Task { try await loop.run() }
    defer { worker.cancel() }
    await fulfillment(of: [stopped], timeout: 5)
    _ = try await controller.enqueue(id: "after-lease-loss", target: .init(), payload: [:])
    let deadline = Date().addingTimeInterval(5)
    var completed = false
    while Date() < deadline {
      completed = try await controller.jobs(now: Date()).contains { $0.id == "after-lease-loss" && $0.status == .succeeded }
      if completed { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertTrue(completed, "A rejected job lease must not stop the worker")
    worker.cancel()
    do {
      try await worker.value
      XCTFail("Worker cancellation ignored")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

  func testWorkerFailurePreservesCodeWithoutLeakingArbitraryDiagnostics() async throws {
    let controller = try controller()
    let server = RielaLocalHTTPServer(routeHandler: try router(controller))
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    _ = try await controller.enqueue(id: "failure", target: .init(), payload: [:])
    let loop = try DistributedWorkerLoop(client: client, capacity: 1) { _ in
      throw AdapterExecutionError(.policyBlocked, "SECRET_FROM_PROVIDER_DIAGNOSTIC")
    }
    let worker = Task { try await loop.run() }
    defer { worker.cancel() }
    let deadline = ContinuousClock().now.advanced(by: .seconds(5))
    var result: DistributedJobResult?
    while ContinuousClock().now < deadline {
      result = try await controller.jobs(now: Date()).first?.result
      if result != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(result?.failure?.code, .policyBlocked)
    let bytes = try JSONEncoder().encode(result)
    XCTAssertFalse(try XCTUnwrap(String(data: bytes, encoding: .utf8)).contains("SECRET_FROM_PROVIDER_DIAGNOSTIC"))
    worker.cancel()
    _ = try? await worker.value
  }

  func testRemoteEventsAreOrderedAndReplayIsIdempotentAfterLostAcknowledgement() async throws {
    let controller = try controller()
    let router = try router(controller)
    let fault = DistributedEventTestFault()
    let server = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { request in
      let response = await router.response(for: request)
      if let message = try? JSONDecoder().decode(DistributedWorkerRequest.self, from: request.body),
        message.operation == .events, await fault.consume() {
        return .json(status: 503, .object([:]))
      }
      return response
    })
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    let loop = try DistributedWorkerLoop(client: client, capacity: 1, contextualExecutor: { job, registration in
      let sender = DistributedWorkerEventSender(client: client, registration: registration, job: job)
      for index in 1...3 {
        await sender.record(AdapterBackendEvent(provider: "test", eventType: "progress", contentSnapshot: "event-\(index)"))
      }
      try await sender.finish()
      let output = DistributedNodeOutput.adapter(AdapterExecutionOutput(provider: "test", model: "test", promptText: "", completionPassed: true, payload: [:]))
      return .init(
        outcome: .succeeded, payload: try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(output)),
        artifacts: [.init(path: "report.txt", data: Data("report".utf8))]
      )
    })
    let worker = Task { try await loop.run() }
    defer { worker.cancel() }
    let observed = DistributedEventTestObservation()
    let executor = QueuedDistributedNodeExecutor(controller: controller)
    _ = try await executor.execute(
      .adapter(.init(node: .init(id: "node", model: "test"), promptText: "")), executionId: "event-test",
      placement: .init(target: .init(workerId: "mac"), workspace: "project", exports: ["report.txt"]),
      context: .init(deadline: Date().addingTimeInterval(5), backendEventHandler: { await observed.append($0) })
    )
    let jobs = try await controller.jobs(now: Date())
    XCTAssertEqual(jobs.first?.events?.map(\.sequence), [1, 2, 3])
    let events = await observed.events
    XCTAssertEqual(events.filter { $0.eventType == "progress" }.compactMap(\.contentSnapshot), ["event-1", "event-2", "event-3"])
    XCTAssertEqual(events.first?.metadata?["workerId"], .string("mac"))
    let artifactEvent = try XCTUnwrap(events.first { $0.eventType == "remote.artifact" })
    XCTAssertEqual(artifactEvent.metadata?["path"], .string("report.txt"))
    XCTAssertEqual(artifactEvent.metadata?["size"], .integer(6))
    worker.cancel()
    _ = try? await worker.value
  }

  func testOversizedUnicodeEventsRemainDeliverable() async throws {
    let controller = try controller()
    let server = RielaLocalHTTPServer(routeHandler: try router(controller))
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    let reply = try await client.send(.init(operation: .register, capacity: 1))
    let registration = try XCTUnwrap(reply.registration)
    _ = try await controller.enqueue(id: "unicode", target: .init(), payload: [:])
    let claim = try await client.send(.init(operation: .claim, registration: registration))
    let job = try XCTUnwrap(claim.job)
    let sender = DistributedWorkerEventSender(client: client, registration: registration, job: job)
    let grapheme = "a" + String(repeating: "\u{301}", count: 20_000)
    for text in [grapheme, String(repeating: "\u{0}", count: 20_000)] {
      await sender.record(.init(provider: grapheme, eventType: grapheme, contentSnapshot: text))
    }
    try await sender.finish()
    let jobs = try await controller.jobs(now: Date())
    let events = try XCTUnwrap(jobs.first?.events)
    XCTAssertEqual(events.count, 2)
    for event in events {
      XCTAssertEqual(event.event.eventType, "remote.event_truncated")
      XCTAssertLessThanOrEqual(try JSONEncoder().encode(event.event).count, 15 * 1024)
    }
  }

  func testOversizedResultFailsOnlyItsJobAndWorkerContinues() async throws {
    let controller = try controller()
    let server = RielaLocalHTTPServer(routeHandler: try router(controller))
    let port = try await server.startForTesting()
    addTeardownBlock { await server.stop() }
    let client = try DistributedWorkerHTTPClient(controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(port)")), token: tokenA)
    _ = try await controller.enqueue(id: "oversized", target: .init(), payload: [:])
    _ = try await controller.enqueue(id: "next", target: .init(), payload: [:])
    let loop = try DistributedWorkerLoop(client: client, capacity: 1) { job in
      .init(outcome: .succeeded, payload: job.id == "oversized"
        ? ["text": .string(String(repeating: "x", count: DistributedJobResult.maximumEncodedBytes))] : [:])
    }
    let worker = Task { try await loop.run() }
    defer { worker.cancel() }
    let deadline = Date().addingTimeInterval(5)
    var jobs: [DistributedJob] = []
    while Date() < deadline {
      jobs = try await controller.jobs(now: Date())
      if jobs.allSatisfy({ $0.result != nil }) { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(jobs.first { $0.id == "oversized" }?.result?.failure?.code, .invalidOutput)
    XCTAssertEqual(jobs.first { $0.id == "next" }?.status, .succeeded)
    worker.cancel()
    _ = try? await worker.value
  }
}

private actor DistributedEventTestFault {
  private var pending = true
  func consume() -> Bool {
    defer { pending = false }
    return pending
  }
}

private final class MutableDistributedWorkerClock: WorkflowRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(interval)
    lock.unlock()
  }
}

private actor DistributedEventTestObservation {
  var events: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { events.append(event) }
}
