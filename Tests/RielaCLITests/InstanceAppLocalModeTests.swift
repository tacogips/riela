#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import XCTest
@testable import RielaCLI

final class InstanceAppLocalModeTests: XCTestCase {
  private func fixture(profile: String = "default", source: String? = nil) throws -> URL {
    let root = URL(fileURLWithPath: "/tmp/rac-\(UUID().uuidString.prefix(8))", isDirectory: true)
    XCTAssertTrue(root.path.hasPrefix("/tmp/rac-"))
    let stateURL = root.appendingPathComponent("profiles/\(profile)/daemon-workflows.json")
    let store = RielaAppDaemonWorkflowStore(stateURL: stateURL)
    try store.save(.init(preferences: ["instance": .init(identity: "instance", sourceIdentity: source)]))
    try Data("{\"version\":1,\"activeProfile\":\"\(profile)\"}".utf8)
      .write(to: root.appendingPathComponent("active-profile.json"))
    return root
  }

  private func invoke(_ root: URL, _ action: String, _ args: [String] = []) async -> CLICommandResult {
    let runner = InstanceAppCommands(sleep: { _ in }, environment: ["HOME": root.path, "RIELA_APP_ROOT": root.path])
    return await runner.run(.init(scope: "instance", command: action, target: "instance", arguments: args))
  }

  private func server(_ root: URL, _ script: InstanceLocalScript) throws -> RielaAppControlChannelServer {
    let run = RielaAppRunDirectory(appRoot: root)
    try run.prepare()
    let server = RielaAppControlChannelServer(run: run, handler: { operation, profile in
      await script.handle(operation, profile: profile)
    })
    try server.bind(socketURL: run.socketURL)
    return server
  }

  func testRunAndCancelUseChannelAndActiveProfile() async throws {
    let root = try fixture(profile: "work")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = InstanceLocalScript()
    let listener = try server(root, script)
    defer { listener.stop() }
    let result = await invoke(root, "run", ["--variables", #"{"a":1}"#])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let cancel = await invoke(root, "cancel", ["--reason", "fix"])
    XCTAssertEqual(cancel.exitCode, .success, cancel.stderr)
    let operations = await script.operations
    let profiles = await script.profiles
    XCTAssertEqual(profiles, ["work", "work", "work", "work"])
    XCTAssertEqual(operations.count, 4)
    guard operations.count == 4, case let .run(identity, body) = operations[1],
      case let .cancel(cancelIdentity, session, _) = operations[3] else { return XCTFail("missing operations") }
    XCTAssertEqual(operations[0], .bootstrap)
    XCTAssertEqual(operations[2], .bootstrap)
    XCTAssertEqual(identity, "instance")
    XCTAssertEqual(cancelIdentity, "instance")
    XCTAssertNil(session)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["expectedProfile", "expectedRevision", "variables"]))
    XCTAssertEqual(object["expectedProfile"] as? String, "work")
    XCTAssertEqual(object["expectedRevision"] as? Int, 7)
  }

  func testRunWaitAndReloadRetry() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = InstanceLocalScript()
    let listener = try server(root, script)
    defer { listener.stop() }
    let run = await invoke(root, "run", ["--wait"])
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    XCTAssertTrue(run.stdout.contains("completed"))
    let reload = await invoke(root, "reload", ["--reason", "fix", "--wait-idle"])
    XCTAssertEqual(reload.exitCode, .success, reload.stderr)
    let operations = await script.operations
    XCTAssertEqual(operations.filter { $0 == .bootstrap }.count, 3)
    XCTAssertEqual(operations.filter { if case .reload = $0 { return true }; return false }.count, 2)
  }

  func testNoAppRunAndCancelReleaseLock() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    for (action, args) in [("run", [String]()), ("cancel", ["--reason", "fix"])] {
      let result = await invoke(root, action, args)
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertTrue(result.stdout.contains("app_not_running"), result.stdout)
      XCTAssertTrue(result.stderr.contains("start RielaApp"), result.stderr)
      let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(RielaAppRunDirectory(appRoot: root)))
      lock.release()
    }
  }

  func testBusyLockReportsUnavailable() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let run = RielaAppRunDirectory(appRoot: root)
    try run.prepare()
    let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(run))
    defer { lock.release() }
    let result = await invoke(root, "run")
    XCTAssertTrue(result.stderr.contains("app_channel_unavailable"), result.stderr)
  }

  func testUnresolvableSourceReportsError() async throws {
    let root = try fixture(source: "selected-workflow:/tmp/rac-missing")
    defer { try? FileManager.default.removeItem(at: root) }
    let result = await invoke(root, "executions")
    XCTAssertTrue(result.stderr.contains("invalid_workflow_source"), result.stderr)
  }

  private func workflow(_ root: URL, name: String) throws -> URL {
    let directory = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try Data(#"""
      {"workflowId":"flow","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},
       "entryStepId":"first","nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],
       "steps":[{"id":"first","nodeId":"worker","role":"worker"}],"nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}]}
      """#.utf8)
      .write(to: directory.appendingPathComponent("workflow.json"))
    try Data(#"{"id":"worker","executionBackend":"codex-agent","model":"model","promptTemplate":"first","variables":{}}"#.utf8)
      .write(to: directory.appendingPathComponent("nodes/worker.json"))
    return directory
  }

  private func setSource(_ root: URL, _ directory: URL) throws -> URL {
    let url = root.appendingPathComponent("profiles/default/daemon-workflows.json")
    try RielaAppDaemonWorkflowStore(stateURL: url).save(.init(preferences: [
      "instance": .init(identity: "instance", sourceIdentity: "selected-workflow:" + directory.path)
    ]))
    return url
  }

  func testLocalReloadSeedsAndRelinksWithoutRevision() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try workflow(root, name: "old")
    let new = try workflow(root, name: "new")
    let stateURL = try setSource(root, old)
    let empty = await invoke(root, "executions")
    XCTAssertEqual(empty.exitCode, .success, empty.stderr)
    XCTAssertTrue(empty.stdout.contains(#""items":[]"#), empty.stdout)
    let result = await invoke(root, "reload", ["--reason", "fix", "--workflow-definition-dir", new.path])
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertNil(object["revision"])
    XCTAssertEqual(object["runtimeStatus"] as? String, "stopped")
    XCTAssertEqual(object["handoff"] as? String, "none")
    XCTAssertEqual((object["definition"] as? [String: Any])?["outcome"] as? String, "seeded")
    let state = RielaAppDaemonWorkflowStore(stateURL: stateURL).load()
    XCTAssertEqual(state.preferences["instance"]?.sourceIdentity, "selected-workflow:" + new.path)
    XCTAssertTrue(state.workflowDirectories.contains(new.path))
    let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(RielaAppRunDirectory(appRoot: root)))
    lock.release()
  }

  func testInvalidLocalReloadDoesNotChangeState() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try workflow(root, name: "old")
    let invalid = try workflow(root, name: "invalid")
    try Data("{".utf8).write(to: invalid.appendingPathComponent("workflow.json"))
    let stateURL = try setSource(root, old)
    let before = try Data(contentsOf: stateURL)
    let result = await invoke(root, "reload", ["--reason", "fix", "--workflow-definition-dir", invalid.path])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertTrue(result.stdout.contains("invalid_workflow_definition"), result.stdout + result.stderr)
    XCTAssertEqual(try Data(contentsOf: stateURL), before)
  }

  func testExpiredReloadDeadlineDoesNotCommit() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = try workflow(root, name: "old")
    let new = try workflow(root, name: "new")
    let stateURL = try setSource(root, old)
    let before = try Data(contentsOf: stateURL)
    let client = RielaAppLocalInstanceControlClient(appRoot: root, homeDirectory: root, profile: "default",
      deadline: { .distantPast })
    do {
      _ = try await client.reload(identity: "instance", body: ["expectedProfile": "default", "expectedRevision": 0,
        "reason": "fix", "workflowDirectory": new.path, "interruptRunning": false])
      XCTFail("expected timeout")
    } catch let failure as RielaAppAPIFailure {
      XCTAssertEqual(failure.code, "app_channel_timeout")
    }
    XCTAssertEqual(try Data(contentsOf: stateURL), before)
    let lock = try XCTUnwrap(RielaAppOwnerLock.tryAcquire(RielaAppRunDirectory(appRoot: root)))
    lock.release()
  }

  func testInsecureSocketIsRejected() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let listener = try server(root, InstanceLocalScript())
    defer { listener.stop() }
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: RielaAppRunDirectory(appRoot: root).socketURL.path)
    let result = await invoke(root, "run")
    XCTAssertTrue(result.stderr.contains("app_channel_insecure"), result.stderr)
  }

  func testExplicitHTTPMatchesLocalRunAndCancel() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let listener = try server(root, InstanceLocalScript())
    defer { listener.stop() }
    let runner = InstanceAppCommands(transport: { request in
      if request.url?.path == "/api/v1/bootstrap" {
        return (Data(#"{"profile":"default","revision":7,"csrfToken":"token"}"#.utf8), 200)
      }
      if request.url?.path.hasSuffix("/cancel") == true {
        return (Data(#"{"identity":"instance","profile":"default","sessionId":"session","owner":"app","outcome":"cancelled"}"#.utf8), 202)
      }
      return (Data(#"{"id":"launch","status":"running","sessionId":"session"}"#.utf8), 202)
    }, sleep: { _ in }, environment: ["HOME": root.path, "RIELA_APP_ROOT": root.path],
      probe: { _ in throw CLIUsageError("unexpected_probe") })
    for (action, args) in [("run", [String]()), ("cancel", ["--reason", "fix"])] {
      let local = await invoke(root, action, args)
      let http = await runner.run(.init(scope: "instance", command: action, target: "instance",
        arguments: args + ["--server", "http://127.0.0.1:19091"]))
      XCTAssertEqual(local.exitCode, http.exitCode)
      let localObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(local.stdout.utf8)) as? NSDictionary)
      let httpObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(http.stdout.utf8)) as? NSDictionary)
      XCTAssertEqual(localObject, httpObject)
    }
  }
}

private actor InstanceLocalScript {
  private(set) var operations: [RielaAppControlOperation] = []
  private(set) var profiles: [String] = []
  private var reloadCount = 0

  func handle(_ operation: RielaAppControlOperation, profile: String) -> RielaAppControlResult {
    operations.append(operation)
    profiles.append(profile)
    switch operation {
    case .bootstrap:
      return .init(status: 200, body: .object(["profile": .string(profile), "revision": .integer(7)]))
    case .run:
      return .init(status: 202, body: .object(["id": .string("launch"), "status": .string("running"), "sessionId": .string("session")]))
    case .launchStatus:
      return .init(status: 200, body: .object(["id": .string("launch"), "status": .string("completed"), "sessionId": .string("session")]))
    case .cancel:
      return .init(status: 202, body: .object(["identity": .string("instance"), "profile": .string(profile),
        "sessionId": .string("session"), "owner": .string("app"), "outcome": .string("cancelled")]))
    case .reload:
      reloadCount += 1
      if reloadCount == 1 { return .error(status: 409, code: "instance_run_in_flight") }
      return .init(status: 200, body: .object(["profile": .string(profile), "revision": .integer(7),
        "identity": .string("instance"), "workflowId": .string("flow"), "workflowDirectory": .string("/tmp/flow"),
        "sourceChanged": .bool(false), "definition": .object(["outcome": .string("seeded")]),
        "eventBindings": .object(["respawnRequired": .bool(false), "respawned": .bool(false)]),
        "handoff": .string("none"), "runtimeStatus": .string("stopped"), "committed": .bool(true)]))
    default:
      return .error(status: 404, code: "not_found")
    }
  }
}
#endif
