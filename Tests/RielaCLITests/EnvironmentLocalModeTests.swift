#if os(macOS)
import Foundation
import XCTest
import RielaAppSupport
import RielaCore
@testable import RielaCLI

final class EnvironmentLocalModeTests: XCTestCase {
  private func root() -> URL {
    URL(fileURLWithPath: "/tmp/rac-\(UUID().uuidString.prefix(8))", isDirectory: true)
  }

  private func command(_ root: URL) -> EnvironmentCommand {
    var command = EnvironmentCommand()
    command.environment = ["RIELA_APP_ROOT": root.path, "HOME": root.path]
    return command
  }

  private func arguments(_ action: String) -> [String] {
    [action, "--instance", "i", "--profile", "default"]
  }

  private func server(_ root: URL, script: EnvironmentLocalScript) throws -> RielaAppControlChannelServer {
    let run = RielaAppRunDirectory(appRoot: root)
    try run.prepare()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, _ in
      await script.handle(operation)
    })
    try server.bind(socketURL: run.socketURL)
    return server
  }

  func testStatusUsesChannelAndRendersOnlyClosedFields() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let script = EnvironmentLocalScript()
    let listener = try server(base, script: script)
    defer { listener.stop() }
    let result = await command(base).run(arguments("status"))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertFalse(result.stdout.contains("DO_NOT_FORWARD"))
    let output = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(Set(output.keys), Set(["names", "configuredNames", "missingNames", "sourceIDs", "generation", "readiness"]))
    XCTAssertEqual(output["names"] as? [String], ["API_KEY"])
    let operations = await script.operations
    XCTAssertEqual(operations, [.bootstrap, .environmentStatus(identity: "i")])
  }

  func testReloadUsesBootstrapRevisionAndThenStatus() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let script = EnvironmentLocalScript()
    let listener = try server(base, script: script)
    defer { listener.stop() }
    let result = await command(base).run(arguments("reload"))
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let operations = await script.operations
    XCTAssertEqual(operations.count, 3)
    guard operations.count == 3, case let .environmentReload(identity, body) = operations[1] else {
      return XCTFail("missing reload operation")
    }
    XCTAssertEqual(operations[0], .bootstrap)
    XCTAssertEqual(operations[2], .environmentStatus(identity: "i"))
    XCTAssertEqual(identity, "i")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["action", "expectedProfile", "expectedRevision"]))
    XCTAssertEqual(object["action"] as? String, "reloadEnvironment")
    XCTAssertEqual(object["expectedProfile"] as? String, "default")
    XCTAssertEqual(object["expectedRevision"] as? Int, 7)
  }

  func testProfileConflictStopsBeforeReload() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let script = EnvironmentLocalScript(profile: "other")
    let listener = try server(base, script: script)
    defer { listener.stop() }
    let result = await command(base).run(arguments("reload"))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(result.stderr, "environment_profile_conflict\n")
    let operations = await script.operations
    XCTAssertEqual(operations, [.bootstrap])
  }

  func testReload422RendersLastError() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let script = EnvironmentLocalScript(reloadFails: true)
    let listener = try server(base, script: script)
    defer { listener.stop() }
    let result = await command(base).run(arguments("reload"))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(result.stderr, "environment_source_failed\n")
    XCTAssertTrue(result.stdout.contains("environment_source_failed"))
    XCTAssertFalse(result.stdout.contains("DO_NOT_FORWARD"))
    let operations = await script.operations
    XCTAssertEqual(operations.count, 2)
  }

  func testNoAppReleasesLock() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let result = await command(base).run(arguments("status"))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("app_not_running"))
    let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(RielaAppRunDirectory(appRoot: base)))
    lock.release()
  }

  func testBusyLockReportsChannelUnavailable() async throws {
    let base = root()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = RielaAppRunDirectory(appRoot: base)
    try run.prepare()
    let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(run))
    defer { lock.release() }
    let result = await command(base).run(arguments("status"))
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stderr.contains("app_channel_unavailable"))
  }

  func testExplicitServerDoesNotProbe() async {
    let base = root()
    var client = command(base)
    client.probe = { _ in throw CLIUsageError("unexpected_probe") }
    client.transport = { request in
      if request.url?.path == "/api/v1/bootstrap" {
        return (Data(#"{"profile":"default","revision":7,"csrfToken":"token"}"#.utf8), 200)
      }
      return (Data(#"{"names":[],"configuredNames":[],"missingNames":[],"sourceIDs":[],"generation":1,"readiness":"ready"}"#.utf8), 200)
    }
    let result = await client.run(arguments("status") + ["--server", "http://127.0.0.1:8787"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
  }
}

private actor EnvironmentLocalScript {
  private(set) var operations: [RielaAppControlOperation] = []
  let profile: String
  let reloadFails: Bool

  init(profile: String = "default", reloadFails: Bool = false) {
    self.profile = profile
    self.reloadFails = reloadFails
  }

  func handle(_ operation: RielaAppControlOperation) -> RielaAppControlResult {
    operations.append(operation)
    switch operation {
    case .bootstrap:
      return .init(status: 200, body: .object(["profile": .string(profile), "revision": .integer(7)]))
    case .environmentReload where reloadFails:
      return .init(status: 422, body: status(lastError: true))
    case .environmentStatus:
      return .init(status: 200, body: status(lastError: false))
    default:
      return .init(status: 200, body: .object([:]))
    }
  }

  private func status(lastError: Bool) -> JSONValue {
    var body: JSONObject = ["names": .array([.string("API_KEY")]), "configuredNames": .array([]),
      "missingNames": .array([]), "sourceIDs": .array([]), "generation": .integer(3),
      "readiness": .string("ready"), "unexpectedSecret": .string("DO_NOT_FORWARD")]
    if lastError { body["lastError"] = .string("environment_source_failed") }
    return .object(body)
  }
}
#endif
