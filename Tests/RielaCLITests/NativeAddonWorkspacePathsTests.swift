import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NativeAddonWorkspacePathsTests: XCTestCase {
  func testExplicitMountMappingAndReadOnlyPrecedence() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-workspace-paths")
    defer { try? FileManager.default.removeItem(at: root) }
    let privateData = root.appendingPathComponent("fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: privateData, withIntermediateDirectories: true)
    let paths = NativeAddonWorkspacePaths(workingDirectory: root, mounts: [
      .init(source: privateData.path, target: "/input"),
      .init(source: privateData.path, target: root.appendingPathComponent("readonly").path)
    ])
    XCTAssertEqual(try paths.hostPath("/input/config.json", writing: false), privateData.appendingPathComponent("config.json").path)
    XCTAssertThrowsError(try paths.hostPath("/input/result", writing: true))
    XCTAssertThrowsError(try paths.hostPath("readonly/result", writing: true))
    XCTAssertThrowsError(try paths.hostPath("../../outside", writing: false))
    XCTAssertEqual(try paths.hostPath("result", writing: true), root.appendingPathComponent("result").path)
    let arguments = try paths.nativeArguments(["--config", "/input/config.json", "graphql", "--query", "--output-dir"])
    XCTAssertEqual(arguments, ["--config", privateData.appendingPathComponent("config.json").path, "graphql", "--query", "--output-dir"])
  }

  func testWorkspaceSymlinkCannotExposeAnOutsideFile() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-path-symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("escape"), withDestinationURL: root)
    let paths = NativeAddonWorkspacePaths(workingDirectory: workspace, mounts: [])
    XCTAssertThrowsError(try paths.hostPath("escape/private.json", writing: false))
  }

  func testAdminGrantBindsCommandToOriginalInputs() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-admin-scope")
    defer { try? FileManager.default.removeItem(at: root) }
    let input = WorkflowAddonExecutionInput(workflowId: "w", stepId: "s", nodeId: "n",
      addon: .init(name: "riela/apple-gateway-permissions-request", config: ["domain": .string("notes")]))
    let capability = try AppleGatewayContainerCapability(input: input, workingDirectory: root, mounts: [])
    try capability.validate(arguments: ["permissions", "request", "--domain", "notes"])
    XCTAssertThrowsError(try capability.validate(arguments: ["permissions", "request", "--domain", "calendar"]))
    XCTAssertThrowsError(try capability.validate(arguments: ["cache", "prune", "--all"]))
    XCTAssertEqual(capability.maximumNativeCalls, 1)
  }
}
