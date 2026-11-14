import Foundation
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageSummaryCarriesTagsAndSearchMatchesTags() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-package-tags-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: packageSource, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/workflow.json"),
      to: packageSource.appendingPathComponent("workflow.json")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/nodes"),
      to: packageSource.appendingPathComponent("nodes")
    )
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step/prompts"),
      to: packageSource.appendingPathComponent("prompts")
    )
    let packageSourceChecksum = try packageChecksum(packageRoot: packageSource)
    try """
    {
      "name": "tagged-package",
      "version": "1.0.0",
      "description": "Tagged package",
      "tags": ["review", "utility"],
      "registry": "local",
      "checksum": "\(packageSourceChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "tagged-package",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    XCTAssertEqual(installed.packages.first?.tags, ["review", "utility"])

    let list = await app.run([
      "package", "list",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeJSON(WorkflowPackageCommandResult.self, from: list.stdout)
    XCTAssertEqual(listed.packages.first?.tags, ["review", "utility"])

    let tagSearch = await app.run([
      "package", "search", "utility",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(tagSearch.exitCode, .success, tagSearch.stderr)
    let tagSearchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: tagSearch.stdout)
    XCTAssertEqual(tagSearchResult.packages.map(\.name), ["tagged-package"])
    XCTAssertEqual(tagSearchResult.packages.first?.tags, ["review", "utility"])
  }
}
