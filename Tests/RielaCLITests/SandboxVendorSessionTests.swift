import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

final class SandboxVendorSessionTests: XCTestCase {
  func testEveryVendorCLIReusesPrivateHomeWithReadOnlyCredentialProjection() async throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "macOS native CLI session gate")
    try await verifyVendorSessions(containerImage: nil)
  }

  func testEveryVendorCLIUsesContainerWithReadOnlyCredentialProjection() async throws {
    let image = ProcessInfo.processInfo.environment["RIELA_TEST_SANDBOX_CONTAINER_IMAGE"]
    try XCTSkipUnless(image != nil, "opt-in source-matching container worker gate")
    try await verifyVendorSessions(containerImage: image)
  }

  private func verifyVendorSessions(containerImage: String?) async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-vendor-sessions")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let worker = repository.appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
    let tools = root.appendingPathComponent("tools")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    let cases: [(NodeExecutionBackend, String)] = [(.codexAgent, "codexExecutable"), (.claudeCodeAgent, "claudeExecutable"),
      (.cursorCliAgent, "cursorExecutable")]
    for (backend, variable) in cases {
      let workspace = root.appendingPathComponent(backend.rawValue)
      try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
      let source = root.appendingPathComponent(backend.rawValue + "-auth")
      try "fixture-key".write(to: source, atomically: true, encoding: .utf8)
      let executable = tools.appendingPathComponent(backend.rawValue + "-fixture")
      try fixtureScript.write(to: executable, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
      let events = SandboxSessionEventStore()
      let adapter = SandboxingNodeAdapter(primary: SessionHostFallback(),
        environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path, "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"],
        workingDirectory: workspace.path, directoryParent: root)
      var input = AdapterExecutionInput(node: .init(id: "vendor", executionBackend: backend, model: "fixture-model",
        sandbox: .init(backend: containerImage == nil ? .seatbelt : .container, readPaths: [tools.path],
          container: containerImage.map { .init(image: $0, runtime: .appleContainer) },
          credentials: [.init(source: source.path, homePath: ".vendor/auth.json")]),
        agentSandbox: .workspaceWrite, variables: [variable: .string(executable.path)]), promptText: "fixture",
        sessionPolicy: .init(mode: .reuse),
        executionIdentity: .init(workflowRunId: "runtime-run", workflowSessionId: "runtime-session", stepId: "first"),
        agentEnvironment: ["FIXTURE_VENDOR": backend.rawValue, "FIXTURE_RECEIPT": workspace.appendingPathComponent("receipt").path,
          "FIXTURE_HOST_SOURCE": source.path])
      let context = AdapterExecutionContext(deadline: Date().addingTimeInterval(containerImage == nil ? 30 : 120), backendEventHandler: { event in await events.append(event) })
      let first = try await adapter.execute(input, context: context)
      XCTAssertEqual(first.payload["text"], .string("session fixture"))
      input.executionIdentity?.stepId = "second"
      input.sessionPolicy = .init(mode: .reuse, inheritFromStepId: "first")
      let second = try await adapter.execute(input, context: context)
      XCTAssertEqual(second.payload["text"], .string("session fixture"))
      let receipts = try String(contentsOf: workspace.appendingPathComponent("receipt"), encoding: .utf8).split(separator: "\n").map(String.init)
      XCTAssertEqual(receipts.count, 2)
      XCTAssertTrue(receipts[0].hasSuffix("|0"))
      XCTAssertTrue(receipts[1].hasSuffix("|1"))
      let homes = receipts.map { String($0.dropLast(2)) }
      XCTAssertEqual(homes[0], homes[1], backend.rawValue)
      XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "fixture-key")
      let streamed = await events.values
      XCTAssertTrue(streamed.contains { $0.contentDelta == "session fixture" || $0.contentSnapshot == "session fixture" })
      input.node.sandbox?.networkPolicy = .egressAllowed
      do {
        _ = try await adapter.execute(input, context: context)
        XCTFail("reuse must refuse a changed isolation boundary")
      } catch let error as AdapterExecutionError { XCTAssertEqual(error.code, .policyBlocked) }
      await adapter.workflowRunDidEnd(.init(workflowRunId: "runtime-run"))
      XCTAssertFalse(FileManager.default.fileExists(atPath: homes[0]), "private session HOME must be cleaned at workflow end")
    }
  }

  private var fixtureScript: String {
    """
    #!/bin/sh
    set -eu
    if [ "${1:-}" = --version ]; then echo vendor-fixture; exit 0; fi
    [ "$(/bin/cat "$HOME/.vendor/auth.json")" = fixture-key ]
    if /bin/cat "$FIXTURE_HOST_SOURCE" >/dev/null 2>&1; then exit 11; fi
    if /bin/sh -c 'echo bad > "$HOME/.vendor/auth.json"' 2>/dev/null; then exit 12; fi
    resumed=0
    for argument in "$@"; do [ "$argument" != fixture-thread ] || resumed=1; done
    if [ "$resumed" = 1 ]; then [ "$(/bin/cat "$HOME/session-state")" = saved ]; else echo saved > "$HOME/session-state"; fi
    printf '%s|%s\\n' "$HOME" "$resumed" >> "$FIXTURE_RECEIPT"
    /bin/cat >/dev/null
    case "$FIXTURE_VENDOR" in
      codex-agent)
        printf '%s\\n' '{"type":"thread.started","thread_id":"fixture-thread"}' \
          '{"type":"item.completed","item":{"type":"agent_message","text":"session fixture"}}' \
          '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}' ;;
      *) printf '%s\\n' '{"type":"result","subtype":"success","result":"session fixture","session_id":"fixture-thread","usage":{"input_tokens":1,"output_tokens":1}}' ;;
    esac
    """
  }
}

private struct SessionHostFallback: NodeAdapter {
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("host fallback forbidden")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}

private actor SandboxSessionEventStore {
  var values: [AdapterBackendEvent] = []
  func append(_ event: AdapterBackendEvent) { values.append(event) }
}
