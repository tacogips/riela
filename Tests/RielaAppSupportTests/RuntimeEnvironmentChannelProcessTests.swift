import Foundation
import RielaCore
import RielaServer
@testable import RielaAppSupport
import XCTest

/// Parent-side channel behavior against a real child process (python stand-in
/// for `riela events serve --runtime-environment-channel`).
final class RuntimeEnvironmentChannelProcessTests: XCTestCase {
  private func scriptDirectory() throws -> URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("tmp/runtime-environment-channel-tests/" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }

  private func executableScript(_ body: String, in directory: URL) throws -> String {
    let url = directory.appendingPathComponent("child.py")
    try ("#!/usr/bin/python3 -u\n" + body).write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.path
  }

  private func startRequest(eventRoot: URL, values: [String: String]) -> WorkflowServeStartRequest {
    var configuration = WorkflowServeRuntimeConfiguration(
      workingDirectory: eventRoot.deletingLastPathComponent().path, runtimeEnvironmentGeneration: 1, runtimeEnvironmentNames: ["TOKEN"]
    )
    configuration.runtimeEnvironmentValues = values
    return WorkflowServeStartRequest(
      selection: .directDirectory(eventRoot.deletingLastPathComponent().path, identifier: "fixture"),
      configuration: configuration, eventRoot: eventRoot.path
    )
  }

  /// B7: a managed child that ACKs and then exits surfaces only safe codes from
  /// its stderr in the startup diagnostic.
  func testManagedChildEarlyExitSurfacesOnlySafeStderrCodes() async throws {
    let directory = try scriptDirectory()
    let canary = "early-exit-canary-" + UUID().uuidString
    let executable = try executableScript("""
    import sys, json
    f = json.loads(sys.stdin.readline())
    print(json.dumps({'type': 'runtime-environment-ack', 'generation': f['generation'], 'names': f['managedNames'], 'accepted': True}), flush=True)
    print('leaked ' + f['values'].get('TOKEN', ''), file=sys.stderr, flush=True)
    print('environment_required_missing', file=sys.stderr, flush=True)
    sys.exit(1)
    """, in: directory)
    let factory = RielaAppDaemonProcessEventSourceFactory(executablePath: executable, earlyExitGraceNanoseconds: 600_000_000)
    let eventRoot = directory.appendingPathComponent(".riela-events", isDirectory: true)
    do {
      _ = try await factory.startEventSources(
        for: WorkflowServeResolvedWorkflow(workflowId: "fixture", selectedIdentity: "fixture", workflowDirectory: directory.path),
        request: startRequest(eventRoot: eventRoot, values: ["TOKEN": canary]), generationId: "g1"
      )
      XCTFail("child exited")
    } catch let WorkflowServeError.startupFailed(diagnostic) {
      XCTAssertEqual(diagnostic.code, "event_source_process_exited")
      XCTAssertTrue(diagnostic.message.contains("environment_required_missing"), diagnostic.message)
      XCTAssertFalse(diagnostic.message.contains(canary))
      XCTAssertFalse(diagnostic.message.contains("leaked"))
    }
  }

  /// Parent enforces the child's 1 MiB frame bound before writing, so the child
  /// is neither closed nor reaped and later frames still apply.
  func testOversizedFrameIsRejectedBeforeWriteAndChildKeepsRunning() async throws {
    let directory = try scriptDirectory()
    let executable = try executableScript("""
    import sys, json
    for line in sys.stdin:
        f = json.loads(line)
        print(json.dumps({'type': 'runtime-environment-ack', 'generation': f['generation'], 'names': f['managedNames'], 'accepted': True}), flush=True)
    """, in: directory)
    let factory = RielaAppDaemonProcessEventSourceFactory(executablePath: executable, earlyExitGraceNanoseconds: 50_000_000)
    let eventRoot = directory.appendingPathComponent(".riela-events", isDirectory: true)
    let handles = try await factory.startEventSources(
      for: WorkflowServeResolvedWorkflow(workflowId: "fixture", selectedIdentity: "fixture", workflowDirectory: directory.path),
      request: startRequest(eventRoot: eventRoot, values: ["TOKEN": "first"]), generationId: "g1"
    )
    let handle = try XCTUnwrap(handles.first)
    do {
      let huge = String(repeating: "x", count: RuntimeEnvironmentChannelWire.maxFrameBytes)
      do {
        try await handle.updateRuntimeEnvironment(generation: 2, names: ["TOKEN"], values: ["TOKEN": huge])
        XCTFail("oversized frame")
      } catch { XCTAssertEqual(error as? RuntimeEnvironmentError, .outputTooLarge) }
      XCTAssertEqual(handle.status.status, "running")
      try await handle.updateRuntimeEnvironment(generation: 3, names: ["TOKEN"], values: ["TOKEN": "third"])
      XCTAssertEqual(handle.status.status, "running")
    } catch {
      try? await handle.shutdown()
      throw error
    }
    try await handle.shutdown()
    XCTAssertEqual(handle.status.status, "exited")
  }
}
