import Foundation
import RielaCore
import RielaAdapters
import XCTest
@testable import RielaCLI

final class SandboxContainerShareValidationTests: XCTestCase {
  func testRootWorkspaceIsRefusedBeforeRuntimeDiscovery() throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-root-guard")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try SandboxExecutionDirectory(parent: root)
    let launcher = ExecutionSandboxLauncher(environment: [:])
    XCTAssertThrowsError(try launcher.process(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
      workspace: URL(fileURLWithPath: "/"), options: .init(backend: .container), directory: directory)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.message, "sandbox workspace cannot be the filesystem root")
    }
  }

  func testRelativeWritableMountCannotAliasReadOnlyHostCredentials() throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-relative-credential-alias")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let credentials = root.appendingPathComponent("credentials")
    for path in [workspace, credentials] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
    let directory = try SandboxExecutionDirectory(parent: root)
    let launcher = ExecutionSandboxLauncher(environment: ["RIELA_CONTAINER_RUNTIME": "/fixture/docker"])
    let options = WorkflowExecutionSandbox(backend: .container, credentialPaths: [credentials.path],
      container: .init(runtime: .docker, mounts: [.init(source: "../credentials", target: "/writable-alias", readOnly: false)]))
    XCTAssertThrowsError(try launcher.process(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
      workspace: workspace, options: options, directory: directory)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.message, "host credentials overlap writable container storage")
    }
  }

  func testRootAliasMountSourceIsRefused() throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-root-mount-alias")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try SandboxExecutionDirectory(parent: root)
    let launcher = ExecutionSandboxLauncher(environment: ["RIELA_CONTAINER_RUNTIME": "/fixture/docker"])
    let options = WorkflowExecutionSandbox(backend: .container,
      container: .init(runtime: .docker, mounts: [.init(source: "/.", target: "/host-root")]))
    XCTAssertThrowsError(try launcher.process(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
      workspace: root, options: options, directory: directory)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
  }

  func testContainerPreservesImagePATHUnlessHostPATHIsExplicitlyShared() throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-image-path")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = try SandboxExecutionDirectory(parent: root)
    let launcher = ExecutionSandboxLauncher(environment: ["RIELA_CONTAINER_RUNTIME": "/fixture/docker", "PATH": "/host-only"])
    var options = WorkflowExecutionSandbox(backend: .container)
    let inherited = try launcher.process(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
      workspace: root, options: options, directory: directory)
    XCTAssertFalse(inherited.arguments.contains { $0.hasPrefix("PATH=") })
    options.environment = ["PATH"]
    let explicit = try launcher.process(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
      workspace: root, options: options, directory: directory)
    XCTAssertTrue(explicit.arguments.contains("PATH=/host-only"))
  }

  func testContainerCommandDoesNotRequireExecutableOnCoordinatorHost() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("sandbox-image-only-program")
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = ImageOnlyCommandRunner()
    let command = SandboxCommand(environment: ["RIELA_CONTAINER_RUNTIME": "/fixture/docker", "PATH": "/host-only"],
      runner: runner, directoryParent: root)
    let result = await command.run(["run", "--backend", "container", "--working-dir", root.path, "--", "image-only-program", "--help"])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertEqual(result.stdout, "image-only-ran")
    let configurations = await runner.configurations
    XCTAssertTrue(try XCTUnwrap(configurations.first).arguments.contains("image-only-program"))
  }

}

private actor ImageOnlyCommandRunner: LocalProcessRunning {
  var configurations: [LocalProcessConfiguration] = []

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    configurations.append(configuration)
    return .init(stdout: "image-only-ran", stderr: "", terminationStatus: 0)
  }
}
