import Foundation
import XCTest
@testable import RielaCLI

final class MediaDownloadDeprecationWarningTests: XCTestCase {
  func testValidationSucceedsWithDeprecationWarning() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("media-download-deprecation")
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("video-pipeline", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let workflow: [String: Any] = [
      "workflowId": "video-pipeline",
      "defaults": ["nodeTimeoutMs": 120_000, "maxLoopIterations": 1],
      "entryStepId": "download",
      "nodes": [["id": "download", "addon": ["name": "riela/media-download", "version": "1",
        "config": ["options": ["url": "https://example.com/video"]]]]],
      "steps": [["id": "download", "nodeId": "download"]]
    ]
    try JSONSerialization.data(withJSONObject: workflow).write(to: directory.appendingPathComponent("workflow.json"))
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "video-pipeline", "--workflow-definition-dir", root.path, "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(json["valid"] as? Bool, true)
    let diagnostics = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
    let message = "riela/media-download is deprecated; install an adaptable downloader add-on such as "
      + "media/yt-dlp-download and wire its mediaDownload.path (see docs/workflows/video-pipeline.md, "
      + "Migrating from riela/media-download)"
    let warnings = diagnostics.filter { $0["message"] as? String == message }
    XCTAssertEqual(warnings.count, 1)
    XCTAssertEqual(warnings.first?["severity"] as? String, "warning")
  }
}
