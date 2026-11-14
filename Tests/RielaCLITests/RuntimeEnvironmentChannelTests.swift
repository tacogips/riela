import Foundation
import XCTest
import RielaAppSupport
import RielaCore
@testable import RielaCLI
import RielaWorkflowRegistry

final class RuntimeEnvironmentChannelTests: XCTestCase {
  private func frame(_ generation: Int, _ values: [String: String], names: [String] = ["API_KEY", "OPTIONAL"]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["generation": generation, "managedNames": names, "values": values])
  }

  func testAtomicGenerationReplacementRemovesStaleOptionalAndRetainsCapturedRun() async throws {
    let store = EventRuntimeEnvironment(base: ["API_KEY": "stale", "OPTIONAL": "stale", "PATH": "/safe"], requiresBootstrap: true)
    do { _ = try await store.capture(); XCTFail("bootstrap required") } catch {}
    let first = await store.replace(try frame(1, ["API_KEY": "first", "OPTIONAL": "old"]))
    XCTAssertTrue(first.accepted)
    let running = try await store.capture()
    let second = await store.replace(try frame(2, ["API_KEY": "second"]))
    XCTAssertEqual(second.names, ["API_KEY", "OPTIONAL"])
    let next = try await store.capture()
    XCTAssertEqual(running["API_KEY"], "first")
    XCTAssertEqual(next["API_KEY"], "second")
    XCTAssertNil(next["OPTIONAL"])
    XCTAssertEqual(next["PATH"], "/safe")
    let output = (String(data: try JSONEncoder().encode(second), encoding: .utf8) ?? "")
    XCTAssertFalse(output.contains("second"))
    XCTAssertFalse(output.contains("stale"))
  }

  func testInvalidFrameCannotChangeActiveSnapshotOrEchoValue() async throws {
    let store = EventRuntimeEnvironment(base: [:], requiresBootstrap: true)
    _ = await store.replace(try frame(4, ["API_KEY": "valid"]))
    for data in [try frame(4, ["API_KEY": "secret"]), try frame(5, ["UNDECLARED": "secret"]),
                 try frame(5, ["API_KEY": "secret"], names: ["API_KEY"]), Data("malformed-secret".utf8),
                 try frame(5, ["API_KEY": "nul\0secret"])] {
      let ack = await store.replace(data)
      XCTAssertFalse(ack.accepted)
      XCTAssertEqual(ack.error, "environment_channel_invalid")
      XCTAssertFalse((String(data: try JSONEncoder().encode(ack), encoding: .utf8) ?? "").contains("secret"))
      let captured = try await store.capture()
      XCTAssertEqual(captured["API_KEY"], "valid")
    }
  }

  func testPipeBootstrapAndTypedAckNeverPersistOrReturnSecret() async throws {
    let input = Pipe(), output = Pipe()
    let store = EventRuntimeEnvironment(base: [:], requiresBootstrap: true)
    let channel = RuntimeEnvironmentChannel(state: store, input: input.fileHandleForReading, output: output.fileHandleForWriting)
    defer { channel.stop() }
    try input.fileHandleForWriting.write(contentsOf: frame(1, ["API_KEY": "pipe-only-test-value"]) + Data([10]))
    try await store.awaitInitial()
    let data = output.fileHandleForReading.availableData
    let ack = try JSONDecoder().decode(RuntimeEnvironmentAcknowledgement.self, from: data)
    XCTAssertTrue(ack.accepted)
    XCTAssertFalse((String(data: data, encoding: .utf8) ?? "").contains("pipe-only-test-value"))
    let snapshot = try await store.capture()
    XCTAssertEqual(snapshot["API_KEY"], "pipe-only-test-value")
  }

  func testDispatchUsesCapturedGenerationAndDoesNotPutItInVariables() async throws {
    let runner = EnvironmentRecordingEventRunner()
    var server = DefaultEventLiveServer(workflowRunner: runner)
    let environment = EventRuntimeEnvironment(base: [:], requiresBootstrap: true)
    server.runtimeEnvironment = environment
    _ = await environment.replace(try frame(1, ["API_KEY": "first"]))
    let request = EventWorkflowRunRequest(workflowName: "fixture", runtimeVariables: ["public": .bool(true)], parsed: try ParsedParityOptions([]))
    do { _ = try await server.runEventWorkflow(request) } catch {}
    _ = await environment.replace(try frame(2, ["API_KEY": "second"]))
    do { _ = try await server.runEventWorkflow(request) } catch {}
    let observed = await runner.observed
    XCTAssertEqual(observed, ["first", "second"])
    XCTAssertEqual(request.runtimeVariables, ["public": .bool(true)])
  }

  func testEnvironmentHelpIsStaticAndNeverUsesTransportOrEchoesArguments() async {
    let calls = EnvironmentHTTPCalls()
    let command = EnvironmentCommand(transport: { request in
      await calls.append(request.httpMethod ?? "GET", request.url?.path ?? "")
      throw CLIUsageError("unexpected_transport")
    })
    for arguments in [["--help"], ["status", "-h"], ["reload", "--instance", "secret-sentinel", "--help"]] {
      let result = await command.run(arguments)
      XCTAssertEqual(result.exitCode, .success)
      XCTAssertTrue(result.stdout.contains("--instance"))
      XCTAssertTrue(result.stdout.contains("--profile"))
      XCTAssertTrue(result.stderr.isEmpty)
      XCTAssertFalse(result.stdout.contains("secret-sentinel"))
    }
    let requests = await calls.values
    XCTAssertTrue(requests.isEmpty)
  }

  func testEnvironmentClientProfileConflictNeverPostsAndResponseIsTyped() async throws {
    let command = EnvironmentCommand(transport: { request in
      XCTAssertEqual(request.httpMethod, "GET")
      return (Data(#"{"profile":"other","revision":1,"csrfToken":"not-for-output"}"#.utf8), 200)
    })
    let result = await command.run(["reload", "--instance", "fixture", "--profile", "default"])
    XCTAssertEqual(result.exitCode, .failure)
    XCTAssertFalse((result.stdout + result.stderr).contains("not-for-output"))
    XCTAssertTrue(result.stderr.contains("profile_conflict"))
  }

  func testEnvironmentClientReloadUsesResidentCSRFAndReturnsOnlyStatus() async throws {
    let calls = EnvironmentHTTPCalls()
    let command = EnvironmentCommand(transport: { request in
      await calls.append(request.httpMethod ?? "GET", request.url?.path ?? "")
      if request.url?.path == "/api/v1/bootstrap" {
        return (Data(#"{"profile":"default","revision":7,"csrfToken":"fixture-csrf"}"#.utf8), 200)
      }
      if request.httpMethod == "POST" {
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-riela-csrf"), "fixture-csrf")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "http://127.0.0.1:8787")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        XCTAssertEqual(body?["expectedRevision"] as? Int, 7)
        XCTAssertEqual(body?["expectedProfile"] as? String, "default")
        return (Data("{}".utf8), 200)
      }
      return (Data(#"{"names":["API_KEY"],"configuredNames":["API_KEY"],"missingNames":[],"sourceIDs":["fixture"],"generation":2,"readiness":"ready","unexpectedSecret":"DO_NOT_FORWARD"}"#.utf8), 200)
    })
    let result = await command.run(["reload", "--instance", "fixture", "--profile", "default"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertFalse(result.stdout.contains("DO_NOT_FORWARD"))
    let requests = await calls.values
    XCTAssertEqual(requests, ["GET /api/v1/bootstrap", "POST /api/v1/instances/fixture/actions", "GET /api/v1/instances/fixture/environment"])
  }

  /// Transport answering bootstrap with a matching profile, then `reply` for
  /// the reload POST (when non-nil) and the status GET.
  private func environmentCommand(post: (Data, Int)?, status: (Data, Int)) -> EnvironmentCommand {
    EnvironmentCommand(transport: { request in
      if request.url?.path == "/api/v1/bootstrap" {
        return (Data(#"{"profile":"default","revision":1,"csrfToken":"fixture-csrf"}"#.utf8), 200)
      }
      if request.httpMethod == "POST" { return post ?? (Data("{}".utf8), 200) }
      return status
    })
  }

  private func statusBody(lastError: String) -> Data {
    Data(("{\"names\":[\"API_KEY\"],\"configuredNames\":[],\"missingNames\":[\"API_KEY\"],\"sourceIDs\":[\"vault\"],"
      + "\"generation\":3,\"readiness\":\"failed\",\"lastError\":\"" + lastError + "\",\"leak\":\"DO_NOT_FORWARD\"}").utf8)
  }

  func testEnvironmentReload422PrintsStatusLastErrorInsteadOfHTTPCode() async throws {
    for code in ["environment_source_failed", "environment_restart_required", "environment_reload_in_progress",
                 "environment_instance_changed"] {
      let command = environmentCommand(post: (statusBody(lastError: code), 422),
                                       status: (Data(), 500))
      let result = await command.run(["reload", "--instance", "fixture", "--profile", "default"])
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertEqual(result.stderr, code + "\n")
      XCTAssertTrue(result.stdout.contains(#""generation":3"#), result.stdout)
      XCTAssertFalse(result.stdout.contains("DO_NOT_FORWARD"))
    }
  }

  func testEnvironmentErrorEnvelopeCodesAndFallbacks() async throws {
    let conflict = Data(#"{"error":{"code":"configuration_conflict","message":"Configuration changed."}}"#.utf8)
    let notFound = Data(#"{"error":{"code":"instance_not_found","message":"Execution configuration was not found."}}"#.utf8)
    let unsafe = Data(#"{"error":{"code":"Secret Value 123","message":"x"}}"#.utf8)
    let cases: [EnvironmentResponseCase] = [
      EnvironmentResponseCase(post: (conflict, 409), status: (Data(), 500), expected: "configuration_conflict"),
      EnvironmentResponseCase(post: nil, status: (notFound, 404), expected: "instance_not_found"),
      EnvironmentResponseCase(post: nil, status: (Data("not json".utf8), 404), expected: "environment_http_404"),
      EnvironmentResponseCase(post: nil, status: (unsafe, 409), expected: "environment_http_409"),
      EnvironmentResponseCase(post: (statusBody(lastError: "Not A Code!"), 422), status: (Data(), 500),
                              expected: "environment_request_failed")
    ]
    for testCase in cases {
      let command = environmentCommand(post: testCase.post, status: testCase.status)
      let result = await command.run(["reload", "--instance", "fixture", "--profile", "default"])
      XCTAssertEqual(result.exitCode, .failure)
      XCTAssertEqual(result.stderr, testCase.expected + "\n")
      XCTAssertFalse((result.stdout + result.stderr).contains("Secret Value"))
      XCTAssertFalse((result.stdout + result.stderr).contains("Not A Code"))
    }
  }

  func testEnvironmentStatusDecodesUnknownLastErrorTolerantly() async throws {
    let command = environmentCommand(post: nil, status: (statusBody(lastError: "environment_restart_required"), 200))
    let result = await command.run(["status", "--instance", "fixture", "--profile", "default"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains(#""lastError":"environment_restart_required""#), result.stdout)
    XCTAssertFalse(result.stdout.contains("DO_NOT_FORWARD"))
  }
}

private struct EnvironmentResponseCase {
  var post: (Data, Int)?
  var status: (Data, Int)
  var expected: String
}

private actor EnvironmentHTTPCalls {
  var values: [String] = []
  func append(_ method: String, _ path: String) { values.append(method + " " + path) }
}

private actor EnvironmentRecordingEventRunner: EventWorkflowRunning {
  var observed: [String] = []
  func runWorkflow(_ request: EventWorkflowRunRequest) async throws -> WorkflowRunResult {
    observed.append(CLIRuntimeEnvironment.mergedProcessEnvironment()["API_KEY"] ?? "missing")
    throw CLIUsageError("fixture complete")
  }
}
