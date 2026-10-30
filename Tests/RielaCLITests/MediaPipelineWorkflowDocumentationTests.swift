import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

final class MediaPipelineWorkflowDocumentationTests: XCTestCase {
  func testDocumentedWorkflowsPassTheProductionWorkflowValidator() async throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let document = try String(
      contentsOf: repositoryRoot.appendingPathComponent("docs/workflows/video-pipeline.md"),
      encoding: .utf8)
    let blocks = try jsonBlocks(in: document)
    XCTAssertEqual(blocks.count, 3)
    XCTAssertFalse(document.contains("riela/media-download"))

    let root = try makeRielaCLITestTemporaryDirectory("media-pipeline-doc-workflows")
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let project = root.appendingPathComponent("project", isDirectory: true)
    // The parent vendors the media/yt-dlp-download package add-on, as the guide describes.
    let package = project.appendingPathComponent(".riela/packages/video-pipeline", isDirectory: true)
    let example = repositoryRoot.appendingPathComponent("examples/video-pipeline-yt-dlp")
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("workflow", isDirectory: true), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: example.appendingPathComponent("addons"), to: package.appendingPathComponent("addons"))
    try blocks[0].write(
      to: package.appendingPathComponent("workflow/workflow.json"), atomically: true, encoding: .utf8)
    var manifest = try XCTUnwrap(JSONSerialization.jsonObject(
      with: Data(contentsOf: example.appendingPathComponent("riela-package.json"))) as? [String: Any])
    manifest["name"] = "video-pipeline"
    manifest["checksum"] = try WorkflowPackageChecksum.md5(packageRoot: package)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: package.appendingPathComponent("riela-package.json"))

    let segment = project.appendingPathComponent(".riela/workflows/video-pipeline-segment", isDirectory: true)
    try FileManager.default.createDirectory(
      at: segment.appendingPathComponent("nodes", isDirectory: true), withIntermediateDirectories: true)
    try blocks[1].write(to: segment.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try blocks[2].write(
      to: segment.appendingPathComponent("nodes/describe-segment.json"), atomically: true, encoding: .utf8)

    try await CLIRuntimeEnvironment.$overrides.withValue([
      "HOME": home.path, "RIELA_WORKFLOW_HOME": home.appendingPathComponent(".riela").path
    ]) {
      let app = RielaCLIApplication()
      for name in ["video-pipeline", "video-pipeline-segment"] {
        let result = await app.run([
          "workflow", "validate", name, "--working-dir", project.path, "--output", "json"
        ])
        XCTAssertEqual(result.exitCode, .success, "\(name): \(result.stderr)\n\(result.stdout)")
        XCTAssertFalse(result.stdout.contains("unresolvedAddonExecutable"), result.stdout)
      }
    }
  }

  private func jsonBlocks(in document: String) throws -> [String] {
    let expression = try NSRegularExpression(pattern: "```json\\s*([\\s\\S]*?)\\s*```")
    let range = NSRange(document.startIndex..., in: document)
    return expression.matches(in: document, range: range).compactMap { match in
      guard let range = Range(match.range(at: 1), in: document) else { return nil }
      return String(document[range])
    }
  }
}
