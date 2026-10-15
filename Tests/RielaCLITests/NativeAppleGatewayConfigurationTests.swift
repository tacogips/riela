import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class NativeAppleGatewayConfigurationTests: XCTestCase {
  func testGuestConfigurationCannotSelectHostStorageOrExecutables() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-config-authority")
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let environment = ["HOME": root.appendingPathComponent("host-home").path]
    let config = workspace.appendingPathComponent("gateway.toml")
    let outside = root.appendingPathComponent("outside/downloads/sentinel")
    try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "preserve".write(to: outside, atomically: true, encoding: .utf8)
    for contents in [
      "[storage]\ncache_dir = \"\(root.appendingPathComponent("outside").path)\"\n",
      "[notifications]\nhelper_app_path = \"/bin/sh\"\n",
      "[mail]\nmail_root = \"\(root.appendingPathComponent("outside").path)\"\n"
    ] {
      try contents.write(to: config, atomically: true, encoding: .utf8)
      let paths = NativeAddonWorkspacePaths(workingDirectory: workspace, mounts: [])
      XCTAssertThrowsError(try paths.withGatewayArguments(["--config", config.path, "graphql", "--query", "query { notes { id } }"]) { arguments in
        try NativeAppleGatewayConfiguration.validate(arguments: arguments, environment: environment, exposedRoots: [workspace])
        XCTFail("untrusted configuration must not reach the native SDK")
        return .init(stdout: "", stderr: "")
      }) { error in XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked) }
    }
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "preserve")
    try "[limits]\ndefault_page_size = 10\n".write(to: config, atomically: true, encoding: .utf8)
    try NativeAppleGatewayConfiguration.validate(arguments: ["--config", config.path, "graphql"], environment: environment, exposedRoots: [workspace])
  }

  func testHostStorageAndConfigurationCannotOverlapGuestShares() throws {
    let root = try makeRielaCLITestTemporaryDirectory("native-config-overlap")
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = ["HOME": root.path]
    for share in [root, root.appendingPathComponent(".cache/apple-gateway/downloads")] {
      XCTAssertThrowsError(try NativeAppleGatewayConfiguration.validate(arguments: ["cache", "prune", "--all"],
        environment: environment, exposedRoots: [share])) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
      }
    }
  }
}
