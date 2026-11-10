import Foundation
import XCTest
@testable import RielaCLI

final class InstanceAppCommandsTests: XCTestCase {
  func testDiscoveryIsReadOnlyAndValidatesServer() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/instance-app-client-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let settings = root.appendingPathComponent("web-server.json")
    let invalid = Data("not-json".utf8)
    try invalid.write(to: settings)
    XCTAssertEqual(try RielaAppAPIClient.resolveEndpoint(server: nil, appRoot: root, environment: [:]).port, 19091)
    XCTAssertEqual(try Data(contentsOf: settings), invalid)
    try Data(#"{"isEnabled":true,"port":19555}"#.utf8).write(to: settings)
    XCTAssertEqual(try RielaAppAPIClient.resolveEndpoint(server: nil, appRoot: root, environment: [:]).port, 19555)
    XCTAssertThrowsError(try RielaAppAPIClient.resolveEndpoint(server: "http://10.0.0.1:1", appRoot: root, environment: [:]))
    try Data(#"{"version":1,"activeProfile":"b"}"#.utf8).write(to: root.appendingPathComponent("active-profile.json"))
    XCTAssertEqual(try RielaAppAPIClient.expectedProfile(explicit: nil, appRoot: root), "b")
  }

  func testBootstrapRejectsMismatchedProfile() async throws {
    let client = RielaAppAPIClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:19091")), profile: "b") { _ in
      (Data(#"{"profile":"a","revision":1,"csrfToken":"secret"}"#.utf8), 200)
    }
    do {
      _ = try await client.bootstrap()
      XCTFail("expected profile conflict")
    } catch let failure as RielaAppAPIFailure {
      XCTAssertEqual(failure.code, "app_profile_conflict")
    }
  }

  func testPostHeadersAndEncodedPath() async throws {
    let recorder = AppRequestRecorder()
    let client = RielaAppAPIClient(endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:19091")), profile: "default") { request in
      await recorder.record(request)
      return (Data("{}".utf8), 200)
    }
    let bootstrap = RielaAppAPIClient.Bootstrap(profile: "default", revision: 4, csrfToken: "secret")
    _ = try await client.post("/api/v1/instances/a%2Fb/reload", body: ["expectedRevision": 4], bootstrap: bootstrap)
    let recorded = await recorder.lastRequest()
    let request = try XCTUnwrap(recorded)
    XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:19091/api/v1/instances/a%2Fb/reload")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:19091")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-riela-csrf"), "secret")
    XCTAssertEqual(request.value(forHTTPHeaderField: "x-riela-profile"), "default")
    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
  }

  func testErrorCodesAndSizeLimit() async throws {
    let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:19091"))
    let unsafe = RielaAppAPIClient(endpoint: endpoint, profile: "default") { _ in
      (Data(#"{"error":{"code":"Bad Code!"}}"#.utf8), 422)
    }
    do {
      _ = try await unsafe.get("/test")
      XCTFail("expected error")
    } catch let failure as RielaAppAPIFailure {
      XCTAssertEqual(failure.code, "app_http_422")
    }
    let safe = RielaAppAPIClient(endpoint: endpoint, profile: "default") { _ in
      (Data(#"{"error":{"code":"instance_not_found"}}"#.utf8), 404)
    }
    do {
      _ = try await safe.get("/test")
      XCTFail("expected error")
    } catch let failure as RielaAppAPIFailure {
      XCTAssertEqual(failure.code, "instance_not_found")
    }
    let oversized = RielaAppAPIClient(endpoint: endpoint, profile: "default") { _ in
      (Data(repeating: 65, count: 1_048_577), 200)
    }
    do {
      _ = try await oversized.get("/test")
      XCTFail("expected error")
    } catch let failure as RielaAppAPIFailure {
      XCTAssertEqual(failure.code, "app_response_too_large")
    }
  }

  func testInvalidArgumentsDoNotSendRequests() async {
    let recorder = AppRequestRecorder()
    let runner = InstanceAppCommands(transport: { request in
      await recorder.record(request)
      return (Data(), 500)
    })
    let cases: [(String, [String])] = [
      ("reload", []), ("executions", ["--limit", "0"]), ("executions", ["--limit", "101"]),
      ("run", ["--variables", "[1]"]), ("run", ["--timeout-seconds", "0"])
    ]
    for (command, arguments) in cases {
      let result = await runner.run(CLICommandOptions(
        scope: "instance", command: command, target: "instance",
        arguments: arguments + ["--server", "http://127.0.0.1:19091"]
      ))
      XCTAssertEqual(result.exitCode, .usage, "\(command): \(result.stdout) \(result.stderr)")
    }
    let recorded = await recorder.lastRequest()
    XCTAssertNil(recorded)
  }

  func testReloadRetryAndMappings() async throws {
    let busy = reply(409, #"{"error":{"code":"instance_run_in_flight"}}"#)
    let success = reply(200, reloadJSON("none"))
    let fake = ScriptedAppTransport([bootstrap, busy, bootstrap, busy, bootstrap, success])
    let result = await invoke("reload", ["--reason", "fix", "--wait-idle", "--timeout-seconds", "30"], fake)
    XCTAssertEqual(result.exitCode, .success)
    let requests = await fake.requests
    XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 3)
    for request in requests where request.httpMethod == "POST" {
      XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:19091")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-riela-csrf"), "secret-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-riela-profile"), "default")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }
    XCTAssertFalse((result.stdout + result.stderr).contains("secret-token"))
    let cases: [(Int, (String, String))] = [
      (409, ("definition_conflict", "definition_conflict")), (404, ("app_http_404", "app_reload_unsupported")),
      (405, ("app_http_405", "app_reload_unsupported")), (404, ("instance_not_found", "instance_not_found"))
    ]
    for (status, codes) in cases {
      let (code, expected) = codes
      let fake = ScriptedAppTransport([bootstrap, reply(status, "{\"error\":{\"code\":\"\(code)\"}}")])
      let result = await invoke("reload", ["--reason", "fix", "--wait-idle"], fake)
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertTrue(result.stderr.contains(expected))
      let requests = await fake.requests
      XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }
    let timeout = ScriptedAppTransport([bootstrap, busy, bootstrap, busy])
    let timed = await invoke("reload", ["--reason", "fix", "--wait-idle", "--timeout-seconds", "1"], timeout)
    XCTAssertTrue(timed.stderr.contains("instance_run_in_flight"))
    let lost = ScriptedAppTransport([bootstrap, reply(200, reloadJSON("lost"))])
    let lostResult = await invoke("reload", ["--reason", "fix"], lost)
    XCTAssertEqual(lostResult.exitCode, .failure)
    XCTAssertTrue(lostResult.stderr.contains("reload_handoff_lost"))
    XCTAssertTrue(lostResult.stdout.contains("lost"))
  }

  func testRunPollingAndFallback() async throws {
    let started = reply(202, #"{"id":"launch","status":"running","sessionId":null}"#)
    let running = reply(200, #"{"id":"launch","status":"running","sessionId":"session"}"#)
    let completed = reply(200, #"{"id":"launch","status":"completed","sessionId":"session"}"#)
    let basic = ScriptedAppTransport([bootstrap, started, running])
    let result = await invoke("run", [], basic)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["launchId", "sessionId", "status"]))
    XCTAssertEqual(result.exitCode, .success)
    let requests = await basic.requests
    XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Origin"))
    XCTAssertFalse((result.stdout + result.stderr).contains("secret-token"))
    let wait = ScriptedAppTransport([bootstrap, started, running, completed])
    let waitResult = await invoke("run", ["--wait"], wait)
    XCTAssertEqual(waitResult.exitCode, .success)
    let failed = ScriptedAppTransport([bootstrap, reply(202, #"{"id":"launch","status":"failed","sessionId":null}"#)])
    let failedResult = await invoke("run", ["--wait"], failed)
    XCTAssertTrue(failedResult.stderr.contains("run_failed"))
    let timeout = ScriptedAppTransport([bootstrap, started, started])
    let timed = await invoke("run", ["--wait", "--timeout-seconds", "1"], timeout)
    XCTAssertTrue(timed.stderr.contains("run_wait_timeout"))
    let fallback = ScriptedAppTransport([bootstrap, started, running, reply(404, "{}"),
                                         reply(200, #"{"session":{"status":"completed"}}"#)])
    let fallbackResult = await invoke("run", ["--wait"], fallback)
    XCTAssertEqual(fallbackResult.exitCode, .success)
    let paths = await fallback.requests.map { $0.url?.path ?? "" }
    XCTAssertTrue(paths.contains("/api/v1/instances/instance/executions/session"))
  }

  func testExecutionsClosedFieldsAndFailures() async throws {
    let fake = ScriptedAppTransport([bootstrap, reply(200, #"{"items":[{"sessionId":"s","status":"completed","extra":"discard"}],"truncated":false}"#)])
    let result = await invoke("executions", ["--limit", "1"], fake)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    let items = try XCTUnwrap(object["items"] as? [[String: Any]])
    let item = try XCTUnwrap(items.first)
    XCTAssertEqual(Set(item.keys), Set(["sessionId", "status", "startedAt", "endedAt", "updatedAt", "currentStepId"]))
    XCTAssertTrue(item["startedAt"] is NSNull)
    let conflict = ScriptedAppTransport([reply(200, #"{"profile":"other","revision":1,"csrfToken":"secret-token"}"#)])
    let conflictResult = await invoke("run", [], conflict)
    XCTAssertTrue(conflictResult.stderr.contains("app_profile_conflict"))
    let conflictRequests = await conflict.requests
    XCTAssertFalse(conflictRequests.contains { $0.httpMethod == "POST" })
    let oversized = ScriptedAppTransport([(Data(repeating: 65, count: 1_048_577), 200)])
    let oversizedResult = await invoke("executions", [], oversized)
    XCTAssertTrue(oversizedResult.stderr.contains("app_response_too_large"))
    let unreachable = InstanceAppCommands(transport: { _ in throw URLError(.cannotConnectToHost) })
    let unreachableResult = await unreachable.run(options("executions", []))
    XCTAssertTrue(unreachableResult.stderr.contains("app_unreachable"))
  }

  private var bootstrap: (Data, Int) { reply(200, #"{"profile":"default","revision":1,"csrfToken":"secret-token"}"#) }
  private func reply(_ status: Int, _ body: String) -> (Data, Int) { (Data(body.utf8), status) }
  private func reloadJSON(_ handoff: String) -> String {
    #"{"profile":"default","revision":1,"identity":"instance","workflowId":"w","workflowDirectory":"/tmp/w","sourceChanged":false,"#
      + #""definition":{"outcome":"unchanged"},"eventBindings":{"respawnRequired":false,"respawned":false},"handoff":"\#(handoff)","runtimeStatus":"running","committed":true}"#
  }
  private func options(_ command: String, _ args: [String]) -> CLICommandOptions {
    CLICommandOptions(scope: "instance", command: command, target: "instance",
                      arguments: args + ["--server", "http://127.0.0.1:19091", "--profile", "default"])
  }
  private func invoke(_ command: String, _ args: [String], _ fake: ScriptedAppTransport) async -> CLICommandResult {
    await InstanceAppCommands(transport: { request in await fake.send(request) }, sleep: { _ in }).run(options(command, args))
  }

}

private actor AppRequestRecorder {
  private var request: URLRequest?
  func record(_ request: URLRequest) { self.request = request }
  func lastRequest() -> URLRequest? { request }
}

private actor ScriptedAppTransport {
  private var responses: [(Data, Int)]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [(Data, Int)]) { self.responses = responses }
  func send(_ request: URLRequest) -> (Data, Int) {
    requests.append(request)
    return responses.isEmpty ? (Data(), 500) : responses.removeFirst()
  }
}
