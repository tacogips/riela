import Foundation
import RielaAdapters
import RielaAddons
import RielaCore
@testable import RielaServer
import RielaWork
@testable import RielaCLI
import XCTest

final class DistributedWorkerConfigurationTests: XCTestCase {
  func testWorkspaceEnvironmentAllowsProviderCredentialsButNeverTransportToken() throws {
    let config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN"}"#)
    var workspace = try XCTUnwrap(config.workspaces["project"])
    workspace.allowedEnvironment = ["PROVIDER_KEY", "WORKER_TOKEN"]
    let filtered = try config.executionEnvironment(for: workspace, from: [
      "PATH": "/usr/bin", "PROVIDER_KEY": "provider-sentinel", "WORKER_TOKEN": "transport-sentinel", "UNRELATED_KEY": "private-sentinel"
    ])
    XCTAssertNil(filtered["WORKER_TOKEN"])
    XCTAssertNil(filtered["UNRELATED_KEY"])
    XCTAssertEqual(filtered["PATH"], "/usr/bin")
    for source in ["WORKER_TOKEN", "UNRELATED_KEY"] {
      XCTAssertThrowsError(try resolveAgentEnvironment(["KEY": .init(fromEnv: source, required: true)], variables: [:], runtimeEnvironment: filtered))
      XCTAssertThrowsError(try resolveAddonEnvironment(["KEY": .object(["fromEnv": .string(source)])], runtimeEnvironment: filtered))
    }
    let allowed = try resolveAgentEnvironment(["KEY": .init(fromEnv: "PROVIDER_KEY", required: true)], variables: [:], runtimeEnvironment: filtered)
    XCTAssertEqual(allowed["KEY"], "provider-sentinel")
    let addon = try resolveAddonEnvironment(["KEY": .object(["fromEnv": .string("PROVIDER_KEY")])], runtimeEnvironment: filtered)
    XCTAssertEqual(addon["KEY"], "provider-sentinel")
  }

  func testWorkerSubprocessDoesNotReinheritAmbientEnvironment() async throws {
    let runner = DistributedWorkerProcessRunner(environment: ["WORKER_ALLOWED": "allowed-sentinel"])
    let result = try await runner.run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env")),
      stdin: "", deadline: Date().addingTimeInterval(5))
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "WORKER_ALLOWED=allowed-sentinel")
  }

  func testTokenFileResolvesBesideConfigurationAndAcceptsLineEndings() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/distributed-workers/config-test/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = String(repeating: "a", count: 40)
    let config = try decode(#"{"tokenFile":"worker.token"}"#)
    for ending in ["", "\n", "\r\n"] {
      try Data((token + ending).utf8).write(to: root.appendingPathComponent("worker.token"))
      XCTAssertEqual(try config.resolveToken(relativeTo: root.appendingPathComponent("worker.json"), environment: [:]), token)
    }
    try Data(repeating: 97, count: 300).write(to: root.appendingPathComponent("worker.token"))
    XCTAssertThrowsError(try config.resolveToken(relativeTo: root.appendingPathComponent("worker.json"), environment: [:]))
  }

  func testEnvironmentCompatibilityAndAmbiguousCredentialsRejected() throws {
    let url = URL(fileURLWithPath: "/unused/worker.json")
    let config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN"}"#)
    XCTAssertEqual(try config.resolveToken(relativeTo: url, environment: ["WORKER_TOKEN": "value"]), "value")
    XCTAssertThrowsError(try config.resolveToken(relativeTo: url, environment: [:]))
    for json in [#"{}"#, #"{"tokenFile":"x","tokenEnvironment":"WORKER_TOKEN"}"#] {
      let invalid = try decode(json)
      XCTAssertThrowsError(try invalid.resolveToken(relativeTo: url, environment: ["WORKER_TOKEN": "value"]))
    }
  }

  func testRegistrationMetadataUsesFilteredEnvironmentAndInstalledAllowedAddon() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let configURL = root.appendingPathComponent("worker.json")
    let packageRoot = root.appendingPathComponent(".riela/packages/demo-package", isDirectory: true)
    let addonRoot = packageRoot.appendingPathComponent("addons/demo", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let executableURL = addonRoot.appendingPathComponent("bin/tool")
    try Data("#!/bin/sh\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
    let manifest = WorkflowPackageManifest(
      name: "demo-package",
      kind: .nodeAddon,
      nodeAddons: [WorkflowPackageNodeAddon(
        name: "demo-addon",
        version: "1.0.0",
        sourcePath: "addons/demo",
        execution: .init(kind: .localCommand, entrypoint: "bin/tool")
      )]
    )
    try JSONEncoder().encode(manifest).write(to: packageRoot.appendingPathComponent("riela-package.json"))

    var config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN"}"#)
    var workspace = try XCTUnwrap(config.workspaces["project"])
    workspace.path = root.path
    workspace.allowedEnvironment = ["PROVIDER_KEY", "MISSING_KEY", "WORKER_TOKEN"]
    workspace.allowedAddons = ["demo-addon"]
    config.workspaces["project"] = workspace
    let metadata = try await config.registrationCapabilityMetadata(
      relativeTo: configURL,
      inheritedEnvironment: [
        "PATH": "/usr/bin",
        "PROVIDER_KEY": "secret-provider",
        "WORKER_TOKEN": "secret-transport",
        "UNRELATED_KEY": "secret-unrelated"
      ]
    )

    XCTAssertEqual(metadata.environment["PROVIDER_KEY"], true)
    XCTAssertEqual(metadata.environment["MISSING_KEY"], false)
    XCTAssertNil(metadata.environment["WORKER_TOKEN"])
    XCTAssertNil(metadata.environment["UNRELATED_KEY"])
    XCTAssertEqual(metadata.addonExecutables, ["bin/tool": true])

    var restrictedWorkspace = workspace
    restrictedWorkspace.path = root.appendingPathComponent("restricted").path
    restrictedWorkspace.allowedEnvironment = []
    restrictedWorkspace.allowedAddons = []
    config.workspaces["restricted"] = restrictedWorkspace
    let multiWorkspaceMetadata = try await config.registrationCapabilityMetadata(
      relativeTo: configURL,
      inheritedEnvironment: ["PATH": "/usr/bin", "PROVIDER_KEY": "secret-provider"]
    )
    XCTAssertEqual(multiWorkspaceMetadata.environment["PROVIDER_KEY"], false)
    XCTAssertEqual(multiWorkspaceMetadata.addonExecutables["bin/tool"], false)
  }

  func testWorkerBackendDeclarationsDecodeAndRegistrationDefaultsRemainCompatible() throws {
    let config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN","backends":{"codex-agent":{"enabled":true,"models":["gpt"]},"claude-code-agent":{"enabled":false,"reason":"disabled"}}}"#)
    XCTAssertEqual(config.backends?["codex-agent"]?.models, ["gpt"])
    XCTAssertEqual(config.backends?["claude-code-agent"]?.enabled, false)

    let legacy = try JSONDecoder().decode(
      DistributedWorkerRegistration.self,
      from: Data(#"{"workerId":"worker","incarnation":"one","groups":[],"capacity":1}"#.utf8)
    )
    XCTAssertEqual(legacy.capabilities, [])
    XCTAssertEqual(legacy.environment, [:])
    XCTAssertEqual(legacy.addonExecutables, [:])

    let capability = BackendCapability(
      backend: .codexAgent,
      source: .observed,
      availability: .available,
      authentication: .available
    )
    let request = DistributedWorkerRequest(
      operation: .register,
      capacity: 1,
      capabilities: [capability],
      environment: ["CUSTOM_KEY": true],
      addonExecutables: ["tool-cli": true]
    )
    let roundTripped = try JSONDecoder().decode(
      DistributedWorkerRequest.self,
      from: JSONEncoder().encode(request)
    )
    XCTAssertEqual(roundTripped.capabilities, [capability])
    XCTAssertEqual(roundTripped.environment, ["CUSTOM_KEY": true])
    XCTAssertEqual(roundTripped.addonExecutables, ["tool-cli": true])
  }

  func testLongLivedWorkerRefreshesObservedBackendWithoutLosingLease() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkStore(rootDirectory: root.path)
    let controller = try DistributedJobController(fileURL: root.appendingPathComponent("jobs.json"))
    let controllerClock = WorkerCapabilityTestClock(Date(timeIntervalSince1970: 1_800_000_000))
    let workerClock = WorkerCapabilityTestClock(controllerClock.now().addingTimeInterval(1))
    let token = String(repeating: "a", count: 40)
    let router = try DistributedWorkerHTTPRouter(
      controller: controller,
      credentials: [.init(workerId: "worker", groups: [], token: token, maxCapacity: 1)],
      clock: controllerClock,
      leaseDurationSeconds: 3600,
      capabilitySnapshotSink: { snapshot in try store.saveHostSnapshot(snapshot) }
    )
    let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1"))
    let initial = workerClock.now()
    let capability = BackendCapability(
      backend: .codexAgent,
      source: .observed,
      observedAt: initial,
      availability: .available,
      authentication: .available,
      executableAvailable: true
    )
    let client = try DistributedWorkerHTTPClient(
      controllerURL: endpoint,
      token: token,
      initialCapabilities: .init(
        capabilities: [capability], environment: [:], addonExecutables: [:], observedAt: initial
      ),
      clock: { workerClock.now() },
      capabilityProvider: {
        let now = workerClock.now()
        let refreshed = BackendCapability(
          backend: .codexAgent,
          source: .observed,
          observedAt: now,
          availability: .available,
          authentication: .available,
          executableAvailable: true
        )
        return .init(capabilities: [refreshed], environment: [:], addonExecutables: [:], observedAt: now)
      }
    )
    func send(_ message: DistributedWorkerRequest) async throws -> DistributedWorkerResponse {
      let prepared = await client.preparedRequest(message)
      let response = await router.response(for: RielaHTTPRequest(
        method: "POST",
        path: DistributedWorkerHTTPRouter.path,
        headers: ["content-type": "application/json", "authorization": "Bearer " + token],
        body: try JSONEncoder().encode(prepared)
      ))
      XCTAssertEqual(response.status, 200)
      return try JSONDecoder().decode(DistributedWorkerResponse.self, from: response.body)
    }
    let reply = try await send(.init(
      operation: .register, capacity: 1, capabilities: [capability], environment: [:], addonExecutables: [:]
    ))
    let registration = try XCTUnwrap(reply.registration)
    _ = try await controller.enqueue(id: "leased", target: .init(workerId: "worker"), payload: [:])
    let claim = try await send(.init(operation: .claim, registration: registration))
    let job = try XCTUnwrap(claim.job)
    let leaseToken = try XCTUnwrap(job.lease?.token)
    let claimedSnapshot = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertEqual(claimedSnapshot.capabilitiesObservedAt, controllerClock.now())
    XCTAssertEqual(claimedSnapshot.backends.first?.observedAt, controllerClock.now())

    controllerClock.advance(by: 301)
    workerClock.advance(by: 301)
    let stale = try XCTUnwrap(store.loadHostSnapshots().first)
    let provenance = WorkflowRequirementProvenance(workflowId: "flow", stepId: "agent", nodeId: "agent")
    let requirement = WorkflowBackendRequirement(pin: .codexAgent, provenance: [provenance])
    let local = HostCapabilitySnapshot(hostId: "local", backends: [], refreshedAt: controllerClock.now())
    let resolver = BackendCapabilityPlacementResolver()
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: local, workers: [stale],
      assignments: [provenance: .init(workerId: "worker")], now: controllerClock.now()
    ).complete)

    let failedProbe = try DistributedWorkerHTTPClient(
      controllerURL: endpoint,
      token: token,
      initialCapabilities: .init(
        capabilities: [capability], environment: [:], addonExecutables: [:], observedAt: initial
      ),
      clock: { workerClock.now() },
      capabilityProvider: { throw DistributedWorkerTransportError.invalidConfiguration }
    )
    let staleRenewal = await failedProbe.preparedRequest(.init(
      operation: .renew, registration: registration, jobId: job.id, leaseToken: leaseToken
    ))
    XCTAssertEqual(staleRenewal.capabilitiesObservedAt, initial)
    XCTAssertEqual(staleRenewal.capabilities?.first?.observedAt, initial)
    let staleResponse = await router.response(for: RielaHTTPRequest(
      method: "POST",
      path: DistributedWorkerHTTPRouter.path,
      headers: ["content-type": "application/json", "authorization": "Bearer " + token],
      body: try JSONEncoder().encode(staleRenewal)
    ))
    XCTAssertEqual(staleResponse.status, 200)
    let afterFailedProbe = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: local, workers: [afterFailedProbe],
      assignments: [provenance: .init(workerId: "worker")], now: controllerClock.now()
    ).complete)

    _ = try await send(.init(
      operation: .renew, registration: registration, jobId: job.id, leaseToken: leaseToken
    ))
    let refreshed = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertEqual(refreshed.capabilitiesObservedAt, controllerClock.now())
    XCTAssertEqual(refreshed.backends.first?.observedAt, controllerClock.now())
    XCTAssertTrue(resolver.resolve(
      requirements: [requirement], local: local, workers: [refreshed],
      assignments: [provenance: .init(workerId: "worker")], now: controllerClock.now()
    ).complete)
    let activeJob = try await controller.job(id: job.id, now: controllerClock.now())
    XCTAssertEqual(activeJob?.status, .leased)
    XCTAssertEqual(activeJob?.lease?.incarnation, registration.incarnation)
    XCTAssertEqual(activeJob?.lease?.token, leaseToken)

    controllerClock.advance(by: 301)
    let excessiveFuture = controllerClock.now().addingTimeInterval(31)
    let futureRenewal = DistributedWorkerRequest(
      operation: .renew, registration: registration, jobId: job.id, leaseToken: leaseToken,
      capabilities: [BackendCapability(
        backend: .codexAgent, source: .observed, observedAt: excessiveFuture,
        availability: .available, authentication: .available
      )],
      environment: [:], addonExecutables: [:], capabilitiesObservedAt: excessiveFuture
    )
    let futureResponse = await router.response(for: RielaHTTPRequest(
      method: "POST",
      path: DistributedWorkerHTTPRouter.path,
      headers: ["content-type": "application/json", "authorization": "Bearer " + token],
      body: try JSONEncoder().encode(futureRenewal)
    ))
    XCTAssertEqual(futureResponse.status, 200)
    let afterExcessiveSkew = try XCTUnwrap(store.loadHostSnapshots().first)
    XCTAssertEqual(afterExcessiveSkew.capabilitiesObservedAt, refreshed.capabilitiesObservedAt)
    XCTAssertFalse(resolver.resolve(
      requirements: [requirement], local: local, workers: [afterExcessiveSkew],
      assignments: [provenance: .init(workerId: "worker")], now: controllerClock.now()
    ).complete)
    let stillActive = try await controller.job(id: job.id, now: controllerClock.now())
    XCTAssertEqual(stillActive?.lease?.token, leaseToken)
  }

  private func decode(_ credentials: String) throws -> DistributedWorkerCommand.Configuration {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credentials.utf8)) as? [String: Any])
    object["controllerURL"] = "https://controller.example.com"
    object["capacity"] = 2
    object["workspaces"] = ["project": ["path": "."]]
    return try JSONDecoder().decode(DistributedWorkerCommand.Configuration.self, from: JSONSerialization.data(withJSONObject: object))
  }
}

private final class WorkerCapabilityTestClock: WorkflowRuntimeClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ date: Date) { value = date }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }
}
