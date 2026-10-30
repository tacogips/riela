import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

/// `riela/media-download` was removed; downloading is supplied by package add-ons such as
/// `media/yt-dlp-download`, so the old name must fail like any other unknown `riela/` add-on.
final class RemovedMediaDownloadAddonTests: XCTestCase {
  func testWorkflowNamingRemovedMediaDownloadFailsValidationAsUnknownAddon() async throws {
    let root = try makeRielaCLITestTemporaryDirectory("removed-media-download")
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

    XCTAssertEqual(result.exitCode, .failure, result.stdout)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(json["valid"] as? Bool, false)
    let diagnostics = try XCTUnwrap(json["diagnostics"] as? [[String: Any]])
    XCTAssertTrue(diagnostics.contains {
      $0["severity"] as? String == "error"
        && ($0["message"] as? String)?.contains("unresolvedAddonExecutable") == true
        && ($0["message"] as? String)?.contains("\"download\"") == true
    }, result.stdout)
    XCTAssertFalse(result.stdout.contains("is deprecated"), result.stdout)
    XCTAssertNil(RielaBuiltinAddonCatalog.descriptor(named: "riela/media-download"))
    XCTAssertFalse(BuiltinStatefulAddonRegistry.registrations.contains { $0.name == "riela/media-download" })
  }
}
