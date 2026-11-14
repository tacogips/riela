#if os(macOS)
import AppKit
@testable import RielaServer
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class DistributedControllerSettingsTests: XCTestCase {
  func testWorkerSettingsAPIRejectsStaleProfileAndConfiguration() async throws {
    let app = RielaApp()
    let root = try scratch()
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    guard app.distributedControllerConfigurationURL.path.hasPrefix(root.path) else {
      throw XCTSkip("Controller environment override is active")
    }
    let read = await app.workerSettingsResponse(for: .init(method: "GET", path: "/api/v1/settings/workers"))
    XCTAssertEqual(read?.status, 200)
    let data = try XCTUnwrap(read?.body)
    var body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertNil(body["token"])
    body["expectedProfile"] = "other-profile"
    body["expectedConfiguration"] = NSNull()
    let wrongProfile = await app.workerSettingsResponse(for: .init(
      method: "PUT", path: "/api/v1/settings/workers", body: try JSONSerialization.data(withJSONObject: body)
    ))
    XCTAssertEqual(wrongProfile?.status, 409)
    body["expectedProfile"] = "default"
    body["expectedConfiguration"] = body["configuration"]
    let stale = await app.workerSettingsResponse(for: .init(
      method: "PUT", path: "/api/v1/settings/workers", body: try JSONSerialization.data(withJSONObject: body)
    ))
    XCTAssertEqual(stale?.status, 409)
    XCTAssertFalse(FileManager.default.fileExists(atPath: app.distributedControllerConfigurationURL.path))
  }

  func testProfileSwitchStopsOldListenerAndUsesNewCredentials() async throws {
    let root = try scratch()
    let app = RielaApp()
    addTeardownBlock { @MainActor in await app.stopDistributedController() }
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    app.appHomeDirectory = root.appendingPathComponent("home")
    let firstURL = app.distributedControllerConfigurationURL
    guard firstURL.path.hasPrefix(root.path) else { throw XCTSkip("Controller environment override is active") }
    let config = try await availableConfiguration()
    try writeProfile(config: config, url: firstURL, token: String(repeating: "a", count: 40))
    let secondURL = firstURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("second/controller.json")
    try writeProfile(config: try await availableConfiguration(), url: secondURL, token: String(repeating: "b", count: 40))
    await app.startDistributedController()
    let oldHost = try XCTUnwrap(app.distributedController)
    let oldPort = try XCTUnwrap(Int(app.distributedControllerStatus.split(separator: ":").last.map(String.init) ?? ""))
    let oldClient = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(oldPort)")), token: String(repeating: "a", count: 40)
    )
    _ = try await oldClient.send(.init(operation: .register, capacity: 1))
    await app.switchDaemonProfileAndWait(to: "second")
    XCTAssertEqual(app.daemonProfileName.rawValue, "second")
    XCTAssertEqual(app.distributedControllerConfigurationURL, secondURL)
    XCTAssertFalse(app.distributedController === oldHost)
    do {
      _ = try await oldClient.send(.init(operation: .register, capacity: 1))
      XCTFail("Previous profile listener is still accepting work")
    } catch { XCTAssertEqual(error as? DistributedWorkerTransportError, .networkFailure) }
    let newHost = try XCTUnwrap(app.distributedController)
    let newWorkers = try await newHost.controller.workers(now: Date())
    XCTAssertTrue(newWorkers.isEmpty, "Profiles must not share registrations")
    let newPort = try XCTUnwrap(Int(app.distributedControllerStatus.split(separator: ":").last.map(String.init) ?? ""))
    let newClient = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(newPort)")), token: String(repeating: "b", count: 40)
    )
    _ = try await newClient.send(.init(operation: .register, capacity: 1))
    let staleSave = await app.saveDistributedControllerConfiguration(configuration(), at: firstURL)
    XCTAssertTrue(staleSave.contains("active profile changed"))
    await app.stopDistributedController()
    XCTAssertNil(app.distributedController)
  }

  func testSettingsSavePreservesRunningJobsAndPersistsIdleConfiguration() async throws {
    let root = try scratch()
    let app = RielaApp()
    addTeardownBlock { @MainActor in await app.stopDistributedController() }
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    let url = app.distributedControllerConfigurationURL
    guard url.path.hasPrefix(root.path) else { throw XCTSkip("Controller environment override is active") }
    let config = try await availableConfiguration()
    try writeProfile(config: config, url: url, token: String(repeating: "c", count: 40))
    await app.startDistributedController()
    let host = try XCTUnwrap(app.distributedController)
    _ = try await host.controller.enqueue(id: "queued", target: .init(), payload: [:])
    let refused = await app.saveDistributedControllerConfiguration(config, at: url)
    XCTAssertTrue(refused.contains("Finish or cancel"))
    XCTAssertTrue(app.distributedController === host)
    await app.stopDistributedController()
    let originalBytes = try Data(contentsOf: url)
    var alternateStore = config
    alternateStore.storePath = "other-jobs.json"
    let stoppedRefusal = await app.saveDistributedControllerConfiguration(alternateStore, at: url)
    XCTAssertTrue(stoppedRefusal.contains("Finish or cancel"))
    XCTAssertNil(app.distributedController)
    XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    try await host.controller.cancel(jobId: "queued")
    var updated = config
    updated.workers[0].groups = ["build", "linux"]
    let encoder = JSONEncoder()
    let updateBody: [String: Any] = [
      "expectedProfile": "default",
      "expectedConfiguration": try JSONSerialization.jsonObject(with: encoder.encode(config)),
      "configuration": try JSONSerialization.jsonObject(with: encoder.encode(updated))
    ]
    let saved = await app.workerSettingsResponse(for: .init(
      method: "PUT", path: "/api/v1/settings/workers", body: try JSONSerialization.data(withJSONObject: updateBody)
    ))
    XCTAssertEqual(saved?.status, 200)
    let savedMessage = try XCTUnwrap(String(bytes: try XCTUnwrap(saved?.body), encoding: .utf8))
    XCTAssertTrue(savedMessage.contains("Settings saved"))
    XCTAssertEqual(try DistributedControllerConfiguration.load(from: url).workers[0].groups, ["build", "linux"])
    XCTAssertNotNil(app.distributedController)
    await app.stopDistributedController()
  }

  func testSaveAndProfileSwitchWaitForSuspendedControllerTransition() async throws {
    let root = try scratch()
    let app = RielaApp()
    addTeardownBlock { @MainActor in await app.stopDistributedController() }
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    app.appHomeDirectory = root.appendingPathComponent("home")
    let firstURL = app.distributedControllerConfigurationURL
    guard firstURL.path.hasPrefix(root.path) else { throw XCTSkip("Controller environment override is active") }
    let config = try await availableConfiguration()
    try writeProfile(config: config, url: firstURL, token: String(repeating: "a", count: 40))
    let secondURL = firstURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("second/controller.json")
    let second = try await availableConfiguration()
    try writeProfile(config: second, url: secondURL, token: String(repeating: "b", count: 40))
    await app.startDistributedController()
    let suspended = expectation(description: "controller transition suspended after stop")
    let gate = ControllerTransitionTestGate()
    let transition = Task { @MainActor in
      await app.distributedControllerOperations.run {
        await app.performDistributedControllerStop()
        await withCheckedContinuation { continuation in
          gate.continuation = continuation
          suspended.fulfill()
        }
      }
    }
    await fulfillment(of: [suspended], timeout: 3)
    let save = Task { @MainActor in await app.saveDistributedControllerConfiguration(config, at: firstURL) }
    let change = Task { @MainActor in await app.switchDaemonProfileAndWait(to: "second") }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(app.daemonProfileName.rawValue, "default")
    XCTAssertNil(app.distributedController, "No operation may restart a host inside a suspended transition")
    gate.continuation?.resume()
    await transition.value
    _ = await save.value
    await change.value
    XCTAssertEqual(app.daemonProfileName.rawValue, "second")
    XCTAssertEqual(app.distributedController?.configuration.port, second.port)
    let client = try DistributedWorkerHTTPClient(
      controllerURL: XCTUnwrap(URL(string: "http://127.0.0.1:\(second.port)")), token: String(repeating: "b", count: 40)
    )
    _ = try await client.send(.init(operation: .register, capacity: 1))
    let stale = await app.saveDistributedControllerConfiguration(config, at: firstURL)
    XCTAssertTrue(stale.contains("active profile changed"))
    await app.stopDistributedController()
  }

  private func configuration() -> DistributedControllerConfiguration {
    .init(host: "127.0.0.1", port: 8788, storePath: "jobs.json", workers: [
      .init(id: "worker", groups: ["linux"], tokenEnvironment: "RIELA_TEST_WORKER_TOKEN", maxCapacity: 1)
    ])
  }

  private func availableConfiguration() async throws -> DistributedControllerConfiguration {
    let server = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .json(status: 200, .object([:])) })
    let port = try await server.startForTesting()
    await server.stop()
    var config = configuration()
    config.port = port
    return config
  }

  private func writeProfile(config: DistributedControllerConfiguration, url: URL, token: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(config).write(to: url)
    try Data("RIELA_TEST_WORKER_TOKEN=\(token)\n".utf8).write(to: url.deletingLastPathComponent().appendingPathComponent("controller.env"))
  }

  private func scratch() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/distributed-workers/settings-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}

@MainActor
private final class ControllerTransitionTestGate {
  var continuation: CheckedContinuation<Void, Never>?
}
#endif
