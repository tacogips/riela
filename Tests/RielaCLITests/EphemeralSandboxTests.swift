import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class EphemeralSandboxTests: XCTestCase {
  func testActualContainerKeepsCredentialsAndModelStateInGuestTmpfs() async throws {
    let image = ProcessInfo.processInfo.environment["RIELA_EPHEMERAL_CONTAINER_IMAGE"]
    try XCTSkipUnless(image != nil, "opt-in native worker image required")
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-container")
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = root.appendingPathComponent("tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    let sentinel = root.appendingPathComponent("unshared-host")
    try "host-sentinel".write(to: sentinel, atomically: true, encoding: .utf8)
    let fixture = tools.appendingPathComponent("codex-fixture")
    try """
    #!/bin/sh
    set -eu
    if [ "${1:-}" = --version ]; then echo codex-fixture; exit 0; fi
    case "$HOME" in /tmp/riela-private-*/home) ;; *) exit 10 ;; esac
    [ "$(cat "$HOME/.vendor/auth.json")" = synthetic-private-credential ]
    [ ! -e "$FIXTURE_HOST_SENTINEL" ]
    grep -q ' /tmp tmpfs ' /proc/mounts
    printf 'guest-refresh' > "$HOME/.vendor/auth.json"
    cat >/dev/null
    printf '%s\\n' \
      '{"type":"thread.started","thread_id":"ephemeral-fixture"}' \
      '{"type":"item.completed","item":{"type":"agent_message","text":"isolated ephemeral fixture"}}' \
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """.write(to: fixture, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
      "VENDOR_AUTH_JSON": "synthetic-private-credential"
    ], workingDirectory: root.path, directoryParent: root)
    let options = WorkflowExecutionSandbox(backend: .container, readPaths: [tools.path],
      container: .init(image: image!, runtime: .appleContainer), ephemeralHome: true,
      credentialEnvironment: ["VENDOR_AUTH_JSON": ".vendor/auth.json"])
    let output = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
      model: "fixture", sandbox: options, agentSandbox: .readOnly,
      variables: ["codexExecutable": .string(fixture.path)]), promptText: "synthetic public input",
      agentEnvironment: ["FIXTURE_HOST_SENTINEL": sentinel.path]), context: .init(deadline: Date().addingTimeInterval(120)))
    XCTAssertEqual(output.payload["text"], .string("isolated ephemeral fixture"))
    XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "host-sentinel")
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["tools", "unshared-host"])
  }

  func testCredentialsTravelOnlyOnWorkerStdinWithoutWritableHostShares() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-sandbox")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker",
      "VENDOR_AUTH_JSON": "synthetic-private-credential", "UNSELECTED_SECRET": "must-not-forward"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    let sandbox = WorkflowExecutionSandbox(backend: .container, networkPolicy: .egressAllowed,
      container: .init(image: "fixture:local"), ephemeralHome: true,
      credentialEnvironment: ["VENDOR_AUTH_JSON": ".vendor/auth.json"])
    let output = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
      model: "fixture", sandbox: sandbox), promptText: "inspected input"), context: .init())
    XCTAssertEqual(output.payload["status"], .string("ok"))
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    let initialize = calls[0]
    let call = calls[1]
    XCTAssertFalse(call.0.arguments.joined().contains("synthetic-private-credential"))
    XCTAssertFalse(call.0.environment.values.contains("synthetic-private-credential"))
    XCTAssertEqual(initialize.1, "")
    XCTAssertTrue(initialize.0.arguments.contains("--read-only"))
    XCTAssertTrue(initialize.0.arguments.contains("--log-driver"))
    XCTAssertTrue(call.0.arguments.contains("exec"))
    XCTAssertTrue(calls[2].0.arguments.contains("--force"))
    XCTAssertFalse(call.0.arguments.contains("-v"))
    XCTAssertFalse(call.0.arguments.contains("--mount"))
    let request = try JSONDecoder().decode(SandboxNodeRequest.self, from: Data(try XCTUnwrap(call.1).utf8))
    XCTAssertEqual(request.credentials?.count, 1)
    XCTAssertEqual(request.credentials?.first?.homePath, ".vendor/auth.json")
    XCTAssertEqual(request.credentials?.first?.value, "synthetic-private-credential")
    XCTAssertEqual(request.input.node.workingDirectory, "/tmp")
    XCTAssertFalse(try XCTUnwrap(call.1).contains("must-not-forward"))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty,
      "ephemeral invocation must leave no host files or credential projection")
  }

  func testEphemeralPolicyRejectsUnsafeCredentialTargetsAndWritableShares() throws {
    let invalid: [WorkflowExecutionSandbox] = [
      .init(backend: .seatbelt, ephemeralHome: true),
      .init(backend: .container, writePaths: ["/host/work"], ephemeralHome: true),
      .init(backend: .container, container: .init(mounts: [.init(source: "/host/work", target: "/work", readOnly: false)]), ephemeralHome: true),
      .init(backend: .container, credentialEnvironment: ["AUTH": ".vendor/auth"]),
      .init(backend: .container, environment: ["AUTH"], ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor/auth"]),
      .init(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": "../escape"]),
      .init(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor", "SECOND": ".vendor/auth"])
    ]
    for options in invalid { XCTAssertThrowsError(try options.validate()) }
    let valid = WorkflowExecutionSandbox(backend: .container, ephemeralHome: true,
      credentialEnvironment: ["AUTH": ".vendor/auth"])
    XCTAssertEqual(try JSONDecoder().decode(WorkflowExecutionSandbox.self, from: JSONEncoder().encode(valid)), valid)
  }

  func testMissingCredentialAndSessionReuseFailBeforeStartingContainer() async throws {
    let runner = EphemeralFixtureRunner()
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(),
      environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath], workingDirectory: nil, runner: runner)
    let options = WorkflowExecutionSandbox(backend: .container, ephemeralHome: true, credentialEnvironment: ["AUTH": ".vendor/auth"])
    for policy: WorkflowStepSessionPolicy? in [nil, .init(mode: .reuse)] {
      do {
        _ = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent, model: "fixture", sandbox: options),
          promptText: "fixture", sessionPolicy: policy), context: .init())
        XCTFail("Unavailable credential or session reuse must not start a container")
      } catch { XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    }
    let calls = await runner.calls
    XCTAssertTrue(calls.isEmpty)
  }

  func testCancelledWorkerStillRemovesOnlyItsOwnedContainer() async throws {
    let runner = EphemeralFixtureRunner(failExec: true)
    let root = try makeRielaCLITestTemporaryDirectory("ephemeral-cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = SandboxingNodeAdapter(primary: EphemeralForbiddenHost(), environment: [
      "RIELA_SANDBOX_WORKER_EXECUTABLE": workerPath, "RIELA_CONTAINER_RUNTIME": "docker"
    ], workingDirectory: root.path, runner: runner, directoryParent: root)
    do {
      _ = try await adapter.execute(.init(node: .init(id: "edit", executionBackend: .codexAgent,
        model: "fixture", sandbox: .init(backend: .container, ephemeralHome: true)), promptText: "fixture"), context: .init())
      XCTFail("cancelled worker must fail")
    } catch { XCTAssertTrue(error is CancellationError) }
    let calls = await runner.calls
    XCTAssertEqual(calls.count, 3)
    let initialize = calls[0].0.arguments
    let name = initialize[try XCTUnwrap(initialize.firstIndex(of: "--name")) + 1]
    XCTAssertTrue(name.hasPrefix("riela-agent-"))
    XCTAssertEqual(calls[2].0.arguments.suffix(3), ["rm", "--force", name])
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  private var workerPath: String {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath().path
  }
}

private actor EphemeralFixtureRunner: LocalProcessRunning {
  var calls: [(LocalProcessConfiguration, String?)] = []
  var failExec: Bool
  init(failExec: Bool = false) { self.failExec = failExec }
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    calls.append((configuration, stdin))
    if failExec, configuration.arguments.contains("exec") { throw CancellationError() }
    let record = SandboxNodeRecord(kind: .result, output: .init(provider: "fixture", model: "fixture", promptText: "",
      completionPassed: true, payload: ["status": .string("ok")]))
    return .init(stdout: String(decoding: try JSONEncoder().encode(record), as: UTF8.self) + "\n", stderr: "", terminationStatus: 0)
  }
}

private struct EphemeralForbiddenHost: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("ephemeral sandbox must not fall back to host execution")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}
