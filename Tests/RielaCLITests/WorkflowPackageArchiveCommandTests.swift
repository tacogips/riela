import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackagePackValidateInstallAndRunRielaPackageArchive() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-archive-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "archive-demo")
    let archiveURL = tempDir.appendingPathComponent("archive-demo.rielapkg")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    XCTAssertEqual(packed.destinationDirectory, archiveURL.path)
    XCTAssertEqual(packed.packages.first?.name, "archive-demo")

    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stdout)
    let validated = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(validated.packages.first?.valid, true)

    let install = await app.run([
      "package", "install", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stdout)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/archive-demo", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))

    let run = await app.run([
      "package", "run", "archive-demo",
      "--working-dir", tempDir.path,
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success, run.stdout)
    let runResult = try decodeJSON(WorkflowPackageCommandResult.self, from: run.stdout)
    XCTAssertNotNil(runResult.runSessionId)
  }

  func testPackagePackAndValidateZipArchive() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-zip-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "zip-demo")
    let archiveURL = tempDir.appendingPathComponent("zip-demo.zip")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)

    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success, validate.stdout)
    let validated = try decodeJSON(WorkflowPackageCommandResult.self, from: validate.stdout)
    XCTAssertEqual(validated.packages.first?.name, "zip-demo")
    XCTAssertEqual(validated.packages.first?.valid, true)
  }

  func testPackageInstallSourceArchiveUsesManifestName() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-source-archive-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "source-archive-demo")
    let archiveURL = tempDir.appendingPathComponent("source-archive-demo.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install",
      "--source", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let installed = try decodeJSON(WorkflowPackageCommandResult.self, from: install.stdout)
    let installedDirectory = tempDir.appendingPathComponent(".riela/packages/source-archive-demo", isDirectory: true)
    XCTAssertEqual(installed.destinationDirectory, installedDirectory.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedDirectory.appendingPathComponent("riela-package.json").path))
  }

  func testPackagePackRejectsHiddenSymlink() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-hidden-symlink-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "hidden-link-demo")
    try FileManager.default.createSymbolicLink(
      at: packageSource.appendingPathComponent(".hidden-link"),
      withDestinationURL: tempDir
    )
    let archiveURL = tempDir.appendingPathComponent("hidden-link-demo.rielapkg")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(pack.exitCode, .success)
    XCTAssertTrue((pack.stdout + pack.stderr).contains("unsafeArchiveEntry"), pack.stdout + pack.stderr)
    XCTAssertFalse(FileManager.default.fileExists(atPath: archiveURL.path))
  }

  func testPackageValidateRejectsArchiveTraversalBeforeExtraction() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-traversal-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "traversal-demo")
    try "escape".write(to: tempDir.appendingPathComponent("escape.txt"), atomically: true, encoding: .utf8)
    let archiveURL = tempDir.appendingPathComponent("traversal-demo.zip")
    try runZip(arguments: ["-qry", archiveURL.path, ".", "../escape.txt"], currentDirectory: packageSource)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(validate.exitCode, .success)
    XCTAssertTrue((validate.stdout + validate.stderr).contains("unsafeArchiveEntry"), validate.stdout + validate.stderr)
    let extractionRoot = tempDir.appendingPathComponent(".riela/tmp/rielapkg", isDirectory: true)
    let extractionChildren = (try? FileManager.default.contentsOfDirectory(
      at: extractionRoot,
      includingPropertiesForKeys: nil
    )) ?? []
    XCTAssertEqual(extractionChildren, [])
  }

  func testPackageValidateRejectsSiblingBesideTopLevelPackageDirectory() async throws {
    let root = repositoryRoot()
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-top-level-sibling-package-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("package-dir", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try makeArchivePackageSource(root: root, packageSource: packageSource, packageName: "sibling-demo")
    try "extra".write(to: tempDir.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
    let archiveURL = tempDir.appendingPathComponent("sibling-demo.zip")
    try runZip(arguments: ["-qry", archiveURL.path, "package-dir", "sibling.txt"], currentDirectory: tempDir)

    let app = RielaCLIApplication()
    let validate = await app.run([
      "package", "validate", archiveURL.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertNotEqual(validate.exitCode, .success)
    XCTAssertTrue((validate.stdout + validate.stderr).contains("missingPackageManifest"), validate.stdout + validate.stderr)
  }

  private func makeArchivePackageSource(root: String, packageSource: URL, packageName: String) throws {
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
    try """
    {
      "name": "\(packageName)",
      "version": "1.0.0",
      "description": "Archive package",
      "tags": ["archive"],
      "registry": "local",
      "checksum": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func runZip(arguments: [String], currentDirectory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectory
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}
