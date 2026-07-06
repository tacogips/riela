import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

final class WorkflowPackageRegistryIndexTests: XCTestCase {
  func testPackageRegistryIndexCommandGeneratesDeterministicSearchableIndex() async throws {
    let root = repositoryRoot()
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-registry-index")
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let workflowPackage = registry.appendingPathComponent("packages/goal-package", isDirectory: true)
    let addonPackage = registry.appendingPathComponent("packages/youtube-downloader-addon", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: workflowPackage.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(root)/examples/worker-only-single-step"),
      to: workflowPackage
    )
    try FileManager.default.createDirectory(
      at: addonPackage.appendingPathComponent("containers/youtube", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "FROM scratch\n".write(
      to: addonPackage.appendingPathComponent("containers/youtube/Containerfile"),
      atomically: true,
      encoding: .utf8
    )

    let workflowChecksum = try WorkflowPackageChecksum.md5(packageRoot: workflowPackage)
    let addonChecksum = try WorkflowPackageChecksum.md5(packageRoot: addonPackage)
    try """
    {
      "name": "goal-package",
      "version": "1.0.0",
      "title": "Goal Package",
      "description": "Goal workflow package for registry index generation",
      "tags": ["goal", "planning"],
      "backends": ["codex-agent"],
      "environmentVariables": [
        {"name": "GOAL_TOKEN", "description": "Goal API token", "required": true, "secret": true},
        {"name": "OPTIONAL_GOAL_MODE", "required": false}
      ],
      "dependencies": ["youtube-downloader-addon"],
      "registry": "local",
      "checksum": "\(workflowChecksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: workflowPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
    try """
    {
      "name": "youtube-downloader-addon",
      "version": "1.0.0",
      "kind": "node-addon",
      "title": "YouTube Downloader Add-on",
      "description": "Containerized downloader with yt-dlp and ffmpeg",
      "tags": ["container", "youtube"],
      "registry": "local",
      "checksum": "\(addonChecksum)",
      "checksumAlgorithm": "md5",
      "addons": [
        {
          "name": "youtube-download-worker",
          "version": "1",
          "sourcePath": "containers/youtube",
          "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "execution": {
            "kind": "container",
            "image": "ghcr.io/example/youtube-downloader",
            "imageDigest": "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "containerfilePath": "containers/youtube/Containerfile",
            "runtimeHints": ["yt-dlp", "ffmpeg"]
          },
          "capabilities": [
            {"name": "network.egress", "reason": "Download media metadata", "defaultPolicy": "prompt"},
            {"name": "filesystem.write", "scope": "downloads", "reason": "Write downloaded media", "defaultPolicy": "prompt"}
          ]
        }
      ]
    }
    """.write(to: addonPackage.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let app = RielaCLIApplication()
    let generated = await app.run([
      "package", "registry", "index", registry.path,
      "--registry", "local",
      "--registry-url", "https://github.com/example/registry",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(generated.exitCode, .success, generated.stderr)
    let result = try decodeJSON(PackageRegistryIndexResult.self, from: generated.stdout)
    XCTAssertEqual(result.index.schemaVersion, 1)
    XCTAssertEqual(result.index.registry.id, "local")
    XCTAssertEqual(result.index.registry.url, "https://github.com/example/registry")
    XCTAssertEqual(result.index.packages.map(\.name), ["goal-package", "youtube-downloader-addon"])
    XCTAssertEqual(result.index.packages.first?.directory, "packages/goal-package")
    XCTAssertEqual(
      result.index.packages.first?.archiveURL,
      "https://github.com/example/registry/releases/download/1.0.0/goal-package-1.0.0.rielapkg"
    )
    XCTAssertEqual(result.index.packages.first?.requiredEnvironment.map(\.name), ["GOAL_TOKEN"])
    XCTAssertEqual(result.index.packages.first?.dependencies.map(\.packageId), ["youtube-downloader-addon"])
    let addon = try XCTUnwrap(result.index.packages.first { $0.name == "youtube-downloader-addon" }?.addons.first)
    XCTAssertEqual(addon.execution?.kind, .container)
    XCTAssertEqual(addon.execution?.image, "ghcr.io/example/youtube-downloader")
    XCTAssertEqual(addon.execution?.imageDigest, "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")
    XCTAssertEqual(addon.execution?.containerfilePath, "containers/youtube/Containerfile")
    XCTAssertEqual(addon.execution?.runtimeHints, ["yt-dlp", "ffmpeg"])
    XCTAssertEqual(addon.capabilities.map(\.name), ["network.egress", "filesystem.write"])
    let firstIndexData = try Data(contentsOf: registry.appendingPathComponent("registry-index.json"))

    let regenerated = await app.run([
      "package", "registry", "index", registry.path,
      "--registry", "local",
      "--registry-url", "https://github.com/example/registry",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(regenerated.exitCode, .success, regenerated.stderr)
    XCTAssertEqual(try Data(contentsOf: registry.appendingPathComponent("registry-index.json")), firstIndexData)

    let checked = await app.run([
      "package", "registry", "index", registry.path,
      "--registry", "local",
      "--registry-url", "https://github.com/example/registry",
      "--check",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(checked.exitCode, .success, checked.stderr)
    let checkedResult = try decodeJSON(PackageRegistryIndexResult.self, from: checked.stdout)
    XCTAssertTrue(checkedResult.checked)
    XCTAssertTrue(checkedResult.upToDate)
    XCTAssertEqual(try Data(contentsOf: registry.appendingPathComponent("registry-index.json")), firstIndexData)

    let staleCheck = await app.run([
      "package", "registry", "index", registry.path,
      "--registry", "local",
      "--registry-url", "https://github.com/example/registry-renamed",
      "--check",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(staleCheck.exitCode, .failure, staleCheck.stderr)
    let staleFailure = try decodeJSON(PackageRegistryIndexFailure.self, from: staleCheck.stdout)
    XCTAssertTrue(staleFailure.error.contains("registry index is stale"), staleFailure.error)
    XCTAssertEqual(try Data(contentsOf: registry.appendingPathComponent("registry-index.json")), firstIndexData)

    try FileManager.default.removeItem(at: registry.appendingPathComponent("packages", isDirectory: true))
    let search = await app.run([
      "package", "search", "downloader",
      "--local-path", registry.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(search.exitCode, .success, search.stderr)
    let searchResult = try decodeJSON(WorkflowPackageCommandResult.self, from: search.stdout)
    XCTAssertEqual(searchResult.packages.map(\.name), ["youtube-downloader-addon"])
    XCTAssertEqual(searchResult.packages.first?.cacheMetadata?.source, "flag")
  }

  private func repositoryRoot() -> String {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .path
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(stdout.utf8))
  }
}

private struct PackageRegistryIndexFailure: Decodable {
  var error: String
}
