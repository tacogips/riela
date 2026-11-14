import Foundation
import XCTest
@testable import RielaCLI

/// A workflow outside any package may use a container add-on installed in the shared
/// add-on store, matching how the runtime resolves it.
final class SharedContainerAddonValidationTests: XCTestCase {
  func testDirectWorkflowValidatesWithSharedContainerAddonOnlyWhenInstalled() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let source = root.appendingPathComponent("examples/video-pipeline-yt-dlp")
    let temp = root.appendingPathComponent("tmp/shared-container-addon-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let home = temp.appendingPathComponent("home")
    let project = temp.appendingPathComponent("project")
    let definitions = project.appendingPathComponent("workflows")
    let directory = definitions.appendingPathComponent("download-only", isDirectory: true)
    for path in [home, directory] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let workflow: [String: Any] = [
      "workflowId": "download-only",
      "defaults": ["nodeTimeoutMs": 120_000, "maxLoopIterations": 1],
      "entryStepId": "download",
      "nodes": [["id": "download", "addon": ["name": "media/yt-dlp-download", "version": "1",
        "config": ["options": ["url": "https://www.youtube.com/watch?v=abc"]]]]],
      "steps": [["id": "download", "nodeId": "download"]]
    ]
    try JSONSerialization.data(withJSONObject: workflow).write(to: directory.appendingPathComponent("workflow.json"))
    let validate = [
      "workflow", "validate", "download-only", "--workflow-definition-dir", definitions.path,
      "--working-dir", project.path, "--output", "json"
    ]

    try await CLIRuntimeEnvironment.$overrides.withValue([
      "HOME": home.path, "RIELA_WORKFLOW_HOME": home.appendingPathComponent(".riela").path
    ]) {
      let app = RielaCLIApplication()
      let missing = await app.run(validate)
      XCTAssertEqual(missing.exitCode, .failure, missing.stdout)
      XCTAssertTrue(missing.stdout.contains("unresolvedAddonExecutable"), missing.stdout)

      let install = await app.run(["node", "install", "video-pipeline-yt-dlp", "--source", source.path,
        "--scope", "user", "--working-dir", temp.path, "--output", "json"])
      XCTAssertEqual(install.exitCode, .success, install.stdout + install.stderr)

      let installed = await app.run(validate)
      XCTAssertEqual(installed.exitCode, .success, installed.stdout + installed.stderr)
      XCTAssertFalse(installed.stdout.contains("unresolvedAddonExecutable"), installed.stdout)
    }
  }
}
