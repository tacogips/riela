import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class SandboxedVendorNodeTests: XCTestCase {
  func testSandboxCommandSeparatesOptionsAndChildArguments() async throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "macOS sandbox command integration")
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-command")
    defer { try? FileManager.default.removeItem(at: root) }
    let command = SandboxCommand(environment: ["PATH": "/usr/bin:/bin"], directoryParent: root)
    let result = await command.run(["run", "--backend", "seatbelt", "--working-dir", root.path,
      "--", "/bin/sh", "-c", "printf '%s' \"$1\"", "fixture", "--backend-is-a-child-argument"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(result.stdout, "--backend-is-a-child-argument")
    let failed = await command.run(["run", "--backend", "bubblewrap", "--working-dir", root.path, "--", "/bin/echo", "must-not-run"])
    XCTAssertEqual(failed.exitCode, .failure)
    XCTAssertEqual(failed.stdout, "")
  }

  func testCodexNodeRunsInSeatbeltWorkerAndSharesCredentialReadOnly() async throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "macOS Seatbelt vendor integration")
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-vendor")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let credential = root.appendingPathComponent("auth")
    let unshared = root.appendingPathComponent("private")
    try "fixture-credential".write(to: credential, atomically: true, encoding: .utf8)
    try "private".write(to: unshared, atomically: true, encoding: .utf8)
    let cli = root.appendingPathComponent("codex-fixture")
    try """
    #!/bin/sh
    set -eu
    if [ "${1:-}" = --version ]; then echo codex-cli-fixture; exit 0; fi
    [ "$(/bin/cat "$FIXTURE_CREDENTIAL")" = fixture-credential ]
    if /bin/cat "$FIXTURE_UNSHARED" >/dev/null 2>&1; then exit 11; fi
    if /bin/sh -c 'echo changed > "$1"' child "$FIXTURE_CREDENTIAL" 2>/dev/null; then exit 12; fi
    printf '%s' "$HOME" > "$FIXTURE_RECEIPT"
    /bin/cat >/dev/null
    printf '%s\\n' \
      '{"type":"thread.started","thread_id":"fixture-thread"}' \
      '{"type":"item.completed","item":{"type":"agent_message","text":"isolated fixture"}}' \
      '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """.write(to: cli, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let worker = repository.appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
    let environment = ["RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path, "PATH": "/usr/bin:/bin"]
    let adapter = SandboxingNodeAdapter(primary: ForbiddenHostNodeAdapter(), environment: environment,
      workingDirectory: workspace.path, directoryParent: root)
    let input = AdapterExecutionInput(node: .init(id: "vendor", executionBackend: .codexAgent, model: "fixture-model",
      sandbox: .init(backend: .seatbelt, readPaths: [cli.path], credentialPaths: [credential.path]),
      agentSandbox: .workspaceWrite, variables: ["codexExecutable": .string(cli.path)]), promptText: "fixture",
      executionIdentity: .init(workflowRunId: "runtime-run", workflowSessionId: "runtime-session", stepId: "vendor"),
      agentEnvironment: ["FIXTURE_CREDENTIAL": credential.path, "FIXTURE_UNSHARED": unshared.path,
        "FIXTURE_RECEIPT": workspace.appendingPathComponent("receipt").path])
    let output = try await adapter.execute(input, context: .init(deadline: Date().addingTimeInterval(30)))
    XCTAssertEqual(output.payload["text"], .string("isolated fixture"))
    XCTAssertEqual(output.usage?.totalTokens, 2)
    XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), "fixture-credential")
    let home = try String(contentsOf: workspace.appendingPathComponent("receipt"), encoding: .utf8)
    XCTAssertTrue(home.hasPrefix(root.path + "/riela-sandbox-"), home)
    XCTAssertTrue(home.hasSuffix("/home"))
  }
}

private struct ForbiddenHostNodeAdapter: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("selected sandbox must never execute the host adapter")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}
