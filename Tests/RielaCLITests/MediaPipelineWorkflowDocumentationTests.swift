import Foundation
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

    let root = try makeRielaCLITestTemporaryDirectory("media-pipeline-doc-workflows")
    defer { try? FileManager.default.removeItem(at: root) }
    let workflowNames = ["video-pipeline", "video-pipeline-segment"]
    for (name, block) in zip(workflowNames, blocks.prefix(2)) {
      let directory = root.appendingPathComponent(name, isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory.appendingPathComponent("nodes", isDirectory: true),
        withIntermediateDirectories: true)
      try block.write(
        to: directory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    }
    try blocks[2].write(
      to: root.appendingPathComponent("video-pipeline-segment/nodes/describe-segment.json"),
      atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    for name in workflowNames {
      let result = await app.run([
        "workflow", "validate", name,
        "--workflow-definition-dir", root.path,
        "--output", "json"
      ])
      XCTAssertEqual(result.exitCode, .success, "\(name): \(result.stderr)\n\(result.stdout)")
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
