import Foundation
import XCTest
@testable import RielaCLI

final class InstanceAppCancelCommandTests: XCTestCase {
  private let bootstrap = #"{"profile":"default","revision":1,"csrfToken":"secret"}"#
  private let accepted = #"{"identity":"ID","profile":"default","sessionId":"s1","owner":"app","outcome":"requested"}"#

  func testRequestAndClosedOutput() async throws {
    for session in [true, false] {
      let fake = CancelTransport([(200, bootstrap), (202, accepted)])
      let result = await invoke(session ? ["--session", "s/1", "--reason", " fix "] : ["--reason", "fix"], fake)
      XCTAssertEqual(result.exitCode, .success)
      let requests = await fake.requests
      XCTAssertEqual(requests.count, 2)
      let post = try XCTUnwrap(requests.last)
      XCTAssertEqual(post.url?.absoluteString, "http://127.0.0.1:19091/api/v1/instances/ID/" +
        (session ? "executions/s%2F1/cancel" : "cancel"))
      XCTAssertEqual(post.httpMethod, "POST")
      for (header, value) in [("Origin", "http://127.0.0.1:19091"), ("x-riela-csrf", "secret"),
                              ("x-riela-profile", "default"), ("Content-Type", "application/json")] {
        XCTAssertEqual(post.value(forHTTPHeaderField: header), value)
      }
      let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: String])
      XCTAssertEqual(body, ["expectedProfile": "default", "reason": "fix"])
      let output = try object(result.stdout)
      XCTAssertEqual(Set(output.keys), Set(["identity", "profile", "sessionId", "owner", "outcome", "status"]))
      XCTAssertTrue(output["status"] is NSNull)
    }
  }

  func testErrorsAndAmbiguity() async throws {
    let cases: [(Int, (String, String))] = [
      (409, ("no_running_execution", "no_running_execution")), (409, ("not_running", "not_running")),
      (404, ("not_found", "app_cancel_unsupported")), (405, ("not_found", "app_cancel_unsupported")),
      (404, ("session_not_found", "session_not_found")), (404, ("instance_not_found", "instance_not_found"))
    ]
    for (status, codes) in cases {
      let (code, expected) = codes
      for session in [true, false] {
        let fake = CancelTransport([(200, bootstrap), (status, "{\"error\":{\"code\":\"\(code)\"}}")])
        let result = await invoke((session ? ["--session", "s1"] : []) + ["--reason", "fix"], fake)
        XCTAssertEqual(result.exitCode, .failure)
        XCTAssertTrue(result.stderr.contains(expected))
      }
    }
    let fake = CancelTransport([(200, bootstrap), (409,
      #"{"error":{"code":"ambiguous_running_sessions"},"sessionIds":["a","b"],"pendingRunCount":1,"secret":"discard"}"#)])
    let result = await invoke(["--reason", "fix"], fake)
    let output = try object(result.stdout)
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertEqual(output["sessionIds"] as? [String], ["a", "b"])
    XCTAssertEqual(output["pendingRunCount"] as? Int, 1)
    XCTAssertEqual(Set(output.keys), Set(["error", "exitCode", "sessionIds", "pendingRunCount"]))
    let malformed = CancelTransport([(200, bootstrap), (409, #"{"error":{"code":"ambiguous_running_sessions"}}"#)])
    let fallback = try object(await invoke(["--reason", "fix"], malformed).stdout)
    XCTAssertEqual(fallback["sessionIds"] as? [String], [])
    XCTAssertEqual(fallback["pendingRunCount"] as? Int, 0)
  }

  func testWaitOutcomes() async throws {
    let running = #"{"session":{"status":"running"}}"#
    let cases: [([(Int, String)], (String, Bool))] = [
      ([(200, running), (200, #"{"session":{"status":"cancelled"}}"#)], ("cancelled", true)),
      ([(200, #"{"session":{"status":"completed"}}"#)], ("cancel_not_effective", false)),
      ([(200, running), (200, running), (200, running)], ("cancel_wait_timeout", false))
    ]
    for (replies, expectation) in cases {
      let (expected, success) = expectation
      let fake = CancelTransport([(200, bootstrap), (202, accepted)] + replies)
      let result = await invoke(["--reason", "fix", "--wait", "--timeout-seconds", "2"], fake)
      XCTAssertEqual(result.exitCode, success ? .success : .failure)
      XCTAssertTrue((result.stdout + result.stderr).contains(expected))
    }
  }

  func testUsageErrors() async {
    let cases: [([String], String)] = [([], "instance_reason_required"),
      (["--reason", " "], "instance_reason_required"), (["--reason", "fix", "--timeout-seconds", "5"], "instance_invalid_options"),
      (["--reason", "fix", "--session", ""], "instance_invalid_options"),
      (["--reason", "fix", "--session", String(repeating: "x", count: 1025)], "instance_invalid_options")]
    for (args, code) in cases {
      let fake = CancelTransport([])
      let result = await invoke(args, fake)
      XCTAssertEqual(result.exitCode, .usage)
      XCTAssertTrue(result.stderr.contains(code))
      let requests = await fake.requests
      XCTAssertTrue(requests.isEmpty)
    }
  }

  private func object(_ string: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
  }
  private func invoke(_ args: [String], _ fake: CancelTransport) async -> CLICommandResult {
    await InstanceAppCommands(transport: { request in await fake.send(request) }, sleep: { _ in }).run(
      CLICommandOptions(scope: "instance", command: "cancel", target: "ID",
                        arguments: args + ["--server", "http://127.0.0.1:19091", "--profile", "default"]))
  }
}

private actor CancelTransport {
  private var responses: [(Int, String)]
  private(set) var requests: [URLRequest] = []
  init(_ responses: [(Int, String)]) { self.responses = responses }
  func send(_ request: URLRequest) -> (Data, Int) {
    requests.append(request)
    guard !responses.isEmpty else { return (Data(), 500) }
    let (status, body) = responses.removeFirst()
    return (Data(body.utf8), status)
  }
}
