import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class NativeAddonSandboxIntegrationTests: XCTestCase {
  func testNodeCLIExecutesTimeSignalInSeatbeltWorker() async throws {
    #if os(macOS)
    try await verifyTimeSignalCLI(backend: .seatbelt)
    #else
    throw XCTSkip("macOS Seatbelt gate")
    #endif
  }

  func testNodeCLIExecutesTimeSignalInContainerWorker() async throws {
    guard let image = ProcessInfo.processInfo.environment["RIELA_TEST_SANDBOX_CONTAINER_IMAGE"] else {
      throw XCTSkip("opt-in container addon.sandbox gate")
    }
    try await verifyTimeSignalCLI(backend: .container, image: image)
  }

  private func verifyTimeSignalCLI(backend: WorkflowSandboxBackend, image: String? = nil) async throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-addon-cli")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let home = root.appendingPathComponent("host-home")
    for directory in [workspace, home] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
    let settings = WorkflowExecutionSandbox(backend: backend,
      container: image.map { .init(image: $0, runtime: .appleContainer) })
    let options = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
    let result = await CLIRuntimeEnvironment.$overrides.withValue([
      "HOME": home.path, "RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path
    ]) {
      await NodeCommandRunner().run(.init(kind: .run, options: .init(scope: "node", command: "run", target: "riela/time-signal",
        arguments: ["--working-dir", workspace.path, "--sandbox", backend.rawValue, "--sandbox-options", options,
          "--config", #"{"intervalMinutes":60}"#, "--variables", #"{"scheduledAt":"2026-10-15T00:30:00Z","timezone":"UTC"}"#],
        output: .json)))
    }
    XCTAssertEqual(result.exitCode, .success, result.stdout + result.stderr)
    guard result.exitCode == .success else { return }
    let output = try JSONDecoder().decode(NodeRunCommandResult.self, from: Data(result.stdout.utf8))
    XCTAssertEqual(output.payload["intervalMinutes"], .number(60))
    XCTAssertEqual(output.payload["shouldAnnounce"], .bool(false))
  }

  func testScopedAppleBridgePreservesMailPermissionDenialInNativeWorker() async throws {
    #if os(macOS)
    let root = try makeRielaCLITestTemporaryDirectory("native-mail-bridge")
    defer { try? FileManager.default.removeItem(at: root) }
    let worker = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent(".build/debug/riela").resolvingSymlinksInPath()
    for authorized in [true, false] {
      let resolver = BuiltinAddonContainerResolver(transportRootDirectory: builtinContainerTransportRoot(for: root, testCase: self),
        primary: NativeAddonHostFallback(), environment: ["RIELA_SANDBOX_WORKER_EXECUTABLE": worker.path], workingDirectory: root,
        nativeAppleGatewayRunner: { _, _, _ in
          let data: JSONObject = ["data": .object([
            "permissions": .object(["mailFullDiskAccess": .string(authorized ? "AUTHORIZED" : "DENIED")]),
            "mailAccounts": .array([]), "mailboxes": .array([]),
            "mailMessages": .object(["totalCount": .integer(0), "edges": .array([]),
              "pageInfo": .object(["hasNextPage": .bool(false), "endCursor": .null])])])]
          return .init(stdout: try XCTUnwrap(String(data: JSONEncoder().encode(data), encoding: .utf8)), stderr: "")
        })
      do {
        let output = try await resolver.execute(.init(workflowId: "fixture", stepId: "mail", nodeId: "mail",
          addon: .init(name: "riela/apple-mail-list", version: "1", sandbox: .init(backend: .seatbelt))),
          context: .init(deadline: Date().addingTimeInterval(30)))
        XCTAssertTrue(authorized)
        XCTAssertEqual(output.payload["messageCount"], .integer(0))
      } catch let error as AdapterExecutionError {
        XCTAssertFalse(authorized, error.message)
        XCTAssertEqual(error.code, .policyBlocked)
        XCTAssertTrue(error.message.contains("Full Disk Access"), error.message)
      }
    }
    #else
    throw XCTSkip("macOS native Apple bridge gate")
    #endif
  }

}

private struct NativeAddonHostFallback: WorkflowAddonResolving {
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    XCTFail("selected sandbox must not execute the host resolver")
    throw AdapterExecutionError(.policyBlocked, "host fallback forbidden")
  }
}
