import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters

final class NativeProcessSandboxTests: XCTestCase {
  func testDirectGatewayNeverIgnoresSandboxSelection() async throws {
    do {
      _ = try await AgentGatewayNodeAdapter().execute(.init(node: .init(id: "vendor", executionBackend: .officialOpenAISDK,
        model: "fixture", sandbox: .init()), promptText: "must not execute"), context: .init())
      XCTFail("direct gateway must reject sandboxed input before invoking a vendor")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }
  func testSeatbeltEnforcesChildFilesystemCredentialAndEnvironmentBoundary() async throws {
    try XCTSkipUnless(RielaHostPlatform.current == .darwin, "macOS Seatbelt integration")
    let root = try rootDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let state = root.appendingPathComponent("state")
    let credential = root.appendingPathComponent("credential")
    let secret = root.appendingPathComponent("unshared")
    try "credential".write(to: credential, atomically: true, encoding: .utf8)
    try "secret".write(to: secret, atomically: true, encoding: .utf8)
    let script = """
    set -eu
    [ "$HOME" = "$1/home" ]
    [ -z "${USER:-}" ]
    [ "$(/bin/cat "$2")" = credential ]
    if /bin/cat "$3" 2>/dev/null; then exit 11; fi
    if /bin/sh -c 'echo overwrite > "$1"' child "$2" 2>/dev/null; then exit 12; fi
    if /bin/ln "$2" "$HOME/hardlink" 2>/dev/null; then exit 14; fi
    if /bin/sh -c 'echo escape > "$1"' child "$4" 2>/dev/null; then exit 13; fi
    /bin/sh -c 'echo allowed > child-output'
    echo isolated
    """
    let invocation = try NativeProcessSandbox().invocation(for: .init(executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", script, "fixture", state.path, credential.path, secret.path, root.appendingPathComponent("escape").path],
      environment: [:], workingDirectoryURL: workspace),
      options: .init(backend: .seatbelt, credentialPaths: [credential.path]), stateDirectory: state)
    let output = try await FoundationLocalProcessRunner().run(configuration: invocation, stdin: "", deadline: Date().addingTimeInterval(15))
    XCTAssertEqual(output.terminationStatus, 0, output.stderr)
    XCTAssertEqual(output.stdout, "isolated\n")
    XCTAssertEqual(try String(contentsOf: credential, encoding: .utf8), "credential")
    XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("child-output").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
  }

  func testSelectedBackendNeverFallsBackAndCredentialsCannotBeWritable() throws {
    let root = try rootDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let configuration = LocalProcessConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectoryURL: workspace)
    for backend in [WorkflowSandboxBackend.auto, .seatbelt, .bubblewrap, .container] {
      XCTAssertThrowsError(try NativeProcessSandbox(isExecutable: { _ in false }).invocation(for: configuration,
        options: .init(backend: backend), stateDirectory: root.appendingPathComponent("state")))
    }
    let credentials = workspace.appendingPathComponent("auth")
    try "credential".write(to: credentials, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try NativeProcessSandbox().invocation(for: configuration,
      options: .init(credentialPaths: [credentials.path]), stateDirectory: root.appendingPathComponent("state")))
  }

  func testBubblewrapPlanUsesEmptyRootNamespacesAndSocketPolicy() throws {
    let root = try rootDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = LocalProcessConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"),
      environment: ["EXPLICIT": "allowed"], workingDirectoryURL: root.appendingPathComponent("workspace"))
    let invocation = try NativeProcessSandbox(hostPlatform: .linux, isExecutable: { _ in true }).invocation(for: configuration,
      options: .init(backend: .bubblewrap), stateDirectory: root.appendingPathComponent("state"))
    XCTAssertFalse(invocation.inheritEnvironment)
    XCTAssertTrue(invocation.arguments.contains("--unshare-all"))
    XCTAssertFalse(invocation.arguments.contains("--share-net"))
    XCTAssertTrue(invocation.arguments.contains("--seccomp"))
    XCTAssertFalse(invocation.arguments.contains("/run"))
    XCTAssertEqual(invocation.environment["EXPLICIT"], "allowed")
    let filter = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("state"),
      includingPropertiesForKeys: nil).first { $0.pathExtension == "bpf" })
    XCTAssertEqual(try Data(contentsOf: filter).count, 168)
  }

  func testGuestSymlinkCannotExpandNextInvocationPermissions() throws {
    let root = try rootDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    let link = workspace.appendingPathComponent("planted-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let configuration = LocalProcessConfiguration(executableURL: URL(fileURLWithPath: "/bin/sh"), workingDirectoryURL: workspace)
    for options in [WorkflowExecutionSandbox(readPaths: [link.path]), .init(writePaths: [link.path]),
      .init(credentialPaths: [link.path])] {
      XCTAssertThrowsError(try NativeProcessSandbox().invocation(for: configuration, options: options,
        stateDirectory: root.appendingPathComponent("state")))
    }
  }

  private func rootDirectory() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/execution-sandbox/tests/" + UUID().uuidString)
    for path in ["workspace", "state/home", "state/tmp"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    }
    return root
  }
}
