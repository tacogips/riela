import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testPackageInstallWritesProjectLockfileAndRemoveUpdatesIt() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-package-lock-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "demo-addon")

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "demo-addon",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])

    XCTAssertEqual(install.exitCode, .success, install.stderr)
    let lockURL = tempDir.appendingPathComponent("riela-lock.json")
    let lock = try decodeJSON(WorkflowPackageLockFile.self, from: String(contentsOf: lockURL))
    let entry = try XCTUnwrap(lock.packages["demo-addon"])
    XCTAssertEqual(lock.lockfileVersion, 1)
    XCTAssertEqual(entry.name, "demo-addon")
    XCTAssertEqual(entry.version, "1.0.0")
    XCTAssertEqual(entry.kind, .nodeAddon)
    XCTAssertEqual(entry.source.kind, "source")
    XCTAssertEqual(entry.source.reference, packageSource.path)
    XCTAssertEqual(entry.addons.map(\.name), ["example/demo"])
    XCTAssertEqual(entry.addons.map(\.contentDigest), ["sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"])

    let remove = await app.run([
      "package", "remove", "demo-addon",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(remove.exitCode, .success, remove.stderr)
    let removedLock = try decodeJSON(WorkflowPackageLockFile.self, from: String(contentsOf: lockURL))
    XCTAssertNil(removedLock.packages["demo-addon"])
  }

  func testPackageInstallFromRielapkgPinsArchiveDigestInLockfile() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-package-lock-archive-\(UUID().uuidString)", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    let installRoot = tempDir.appendingPathComponent("install-root", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "archive-addon")

    let app = RielaCLIApplication()
    let pack = await app.run([
      "package", "pack", packageSource.path,
      "--destination", tempDir.appendingPathComponent("archive-addon.rielapkg").path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(pack.exitCode, .success, pack.stderr)
    let packed = try decodeJSON(WorkflowPackageCommandResult.self, from: pack.stdout)
    let archivePath = try XCTUnwrap(packed.destinationDirectory)

    let install = await app.run([
      "package", "install", archivePath,
      "--working-dir", installRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr)

    let lockURL = installRoot.appendingPathComponent("riela-lock.json")
    let lock = try decodeJSON(WorkflowPackageLockFile.self, from: String(contentsOf: lockURL))
    let entry = try XCTUnwrap(lock.packages["archive-addon"])
    XCTAssertEqual(entry.source.kind, "archive")
    XCTAssertEqual(entry.source.reference, archivePath)
    XCTAssertEqual(entry.source.archiveDigestAlgorithm, "sha256")
    XCTAssertTrue(entry.source.archiveDigest?.hasPrefix("sha256:") == true)
    XCTAssertEqual(entry.source.archiveDigest?.count, "sha256:".count + 64)
  }

  func testPackageCIReplaysLockedSourceInstall() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-ci-source")
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "ci-source-addon")

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "ci-source-addon",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr + install.stdout)
    let installedPackage = tempDir.appendingPathComponent(".riela/packages/ci-source-addon", isDirectory: true)
    try FileManager.default.removeItem(at: installedPackage)

    let ci = await app.run([
      "package", "ci",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(ci.exitCode, .success, ci.stderr + ci.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: ci.stdout)
    XCTAssertEqual(result.command, "ci")
    XCTAssertEqual(result.packages.map(\.name), ["ci-source-addon"])
  }

  func testPackageInstallLockedReplaysLockfileGraph() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-install-locked-source")
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "locked-source-addon")

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "locked-source-addon",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr + install.stdout)
    let installedPackage = tempDir.appendingPathComponent(".riela/packages/locked-source-addon", isDirectory: true)
    try FileManager.default.removeItem(at: installedPackage)

    let locked = await app.run([
      "package", "install",
      "--locked",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(locked.exitCode, .success, locked.stderr + locked.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: locked.stdout)
    XCTAssertEqual(result.command, "install")
    XCTAssertEqual(result.packages.map(\.name), ["locked-source-addon"])
    XCTAssertEqual(result.destinationDirectory, tempDir.appendingPathComponent("riela-lock.json").path)
  }

  func testPackageInstallWithoutTargetReplaysLockfileGraph() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-install-no-target-source")
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "no-target-source-addon")

    let app = RielaCLIApplication()
    let install = await app.run([
      "package", "install", "no-target-source-addon",
      "--source", packageSource.path,
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr + install.stdout)
    let installedPackage = tempDir.appendingPathComponent(".riela/packages/no-target-source-addon", isDirectory: true)
    try FileManager.default.removeItem(at: installedPackage)

    let replay = await app.run([
      "package", "install",
      "--working-dir", tempDir.path,
      "--output", "json"
    ])
    XCTAssertEqual(replay.exitCode, .success, replay.stderr + replay.stdout)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installedPackage.appendingPathComponent("riela-package.json").path))
    let result = try decodeJSON(WorkflowPackageCommandResult.self, from: replay.stdout)
    XCTAssertEqual(result.command, "install")
    XCTAssertEqual(result.packages.map(\.name), ["no-target-source-addon"])
    XCTAssertEqual(result.destinationDirectory, tempDir.appendingPathComponent("riela-lock.json").path)
  }

  func testPackageCIVerifiesLockedArchiveDigestBeforeInstall() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-ci-archive-mismatch")
    let packageSource = tempDir.appendingPathComponent("demo-addon-source", isDirectory: true)
    let installRoot = tempDir.appendingPathComponent("install-root", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "ci-archive-addon")

    let archiveURL = tempDir.appendingPathComponent("ci-archive-addon.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)
    let badLock = WorkflowPackageLockFile(packages: [
      "ci-archive-addon": WorkflowPackageLockEntry(
        name: "ci-archive-addon",
        version: "1.0.0",
        kind: .nodeAddon,
        registry: "local",
        checksumAlgorithm: "md5",
        checksum: "invalid",
        integrity: nil,
        source: WorkflowPackageLockSource(
          kind: "archive",
          reference: archiveURL.path,
          archiveDigestAlgorithm: "sha256",
          archiveDigest: "sha256:\(String(repeating: "0", count: 64))"
        ),
        dependencies: [],
        addons: []
      )
    ])
    try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(badLock).write(to: installRoot.appendingPathComponent("riela-lock.json"))

    let ci = await RielaCLIApplication().run([
      "package", "ci",
      "--working-dir", installRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(ci.exitCode, .failure)
    XCTAssertTrue(ci.stdout.contains("archiveSHA256 mismatch"), ci.stdout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: installRoot.appendingPathComponent(".riela/packages/ci-archive-addon").path))
  }

  func testPackageInstallFromIndexOnlyArchiveVerifiesDigestAndPinsReleaseURL() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-index-archive-lock")
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("archive-addon-source", isDirectory: true)
    let installRoot = tempDir.appendingPathComponent("install-root", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "index-archive-addon")

    let archiveURL = tempDir.appendingPathComponent("index-archive-addon.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)
    try writeIndexOnlyArchiveRegistry(
      registry: registry,
      packageName: "index-archive-addon",
      archiveURL: archiveURL,
      archiveSHA256: sha256Digest(for: archiveURL)
    )

    let install = await RielaCLIApplication().run([
      "package", "install", "index-archive-addon",
      "--local-path", registry.path,
      "--working-dir", installRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stderr + install.stdout)

    let lockURL = installRoot.appendingPathComponent("riela-lock.json")
    let lock = try decodeJSON(WorkflowPackageLockFile.self, from: String(contentsOf: lockURL))
    let entry = try XCTUnwrap(lock.packages["index-archive-addon"])
    XCTAssertEqual(entry.source.kind, "archive")
    XCTAssertEqual(entry.source.reference, archiveURL.absoluteString)
    XCTAssertEqual(entry.source.archiveDigest, try sha256Digest(for: archiveURL))
  }

  func testPackageInstallFromIndexOnlyArchiveDigestMismatchLeavesPriorLockfileIntact() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-package-index-archive-mismatch")
    let registry = tempDir.appendingPathComponent("registry", isDirectory: true)
    let packageSource = tempDir.appendingPathComponent("archive-addon-source", isDirectory: true)
    let installRoot = tempDir.appendingPathComponent("install-root", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installLockfileNodeAddonFixture(at: packageSource, packageName: "index-archive-addon")

    let lockURL = installRoot.appendingPathComponent("riela-lock.json")
    try FileManager.default.createDirectory(at: installRoot, withIntermediateDirectories: true)
    let priorLock = """
    {
      "generatedBy": "riela",
      "lockfileVersion": 1,
      "packages": {
        "existing": {
          "addons": [],
          "dependencies": [],
          "kind": "workflow",
          "name": "existing",
          "source": {"kind": "source", "reference": "/tmp/existing"}
        }
      }
    }
    """
    try priorLock.write(to: lockURL, atomically: true, encoding: .utf8)
    let originalLockData = try Data(contentsOf: lockURL)

    let archiveURL = tempDir.appendingPathComponent("index-archive-addon.rielapkg")
    try WorkflowPackageArchiveManager().createArchive(from: packageSource, to: archiveURL)
    try writeIndexOnlyArchiveRegistry(
      registry: registry,
      packageName: "index-archive-addon",
      archiveURL: archiveURL,
      archiveSHA256: "sha256:\(String(repeating: "0", count: 64))"
    )

    let install = await RielaCLIApplication().run([
      "package", "install", "index-archive-addon",
      "--local-path", registry.path,
      "--working-dir", installRoot.path,
      "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .failure)
    XCTAssertTrue(install.stdout.contains("archiveSHA256 mismatch"), install.stdout)
    XCTAssertEqual(try Data(contentsOf: lockURL), originalLockData)
  }

  private func installLockfileNodeAddonFixture(at packageSource: URL, packageName: String) throws {
    let addonRoot = packageSource.appendingPathComponent("addons/example/demo/1", isDirectory: true)
    try FileManager.default.createDirectory(at: addonRoot, withIntermediateDirectories: true)
    try """
    {
      "name": "example/demo",
      "version": "1",
      "description": "Demo add-on descriptor"
    }
    """.write(to: addonRoot.appendingPathComponent("addon.json"), atomically: true, encoding: .utf8)
    let checksum = try packageChecksum(packageRoot: packageSource)
    try """
    {
      "name": "\(packageName)",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Demo node add-on package",
      "tags": ["demo"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "addons": [
        {
          "name": "example/demo",
          "version": "1",
          "sourcePath": "addons/example/demo/1",
          "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "execution": {"kind": "declarative"}
        }
      ]
    }
    """.write(to: packageSource.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func writeIndexOnlyArchiveRegistry(
    registry: URL,
    packageName: String,
    archiveURL: URL,
    archiveSHA256: String
  ) throws {
    try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
    try """
    {
      "schemaVersion": 1,
      "registry": {"id": "local"},
      "packages": [
        {
          "name": "\(packageName)",
          "directory": "packages/\(packageName)",
          "archiveURL": "\(archiveURL.absoluteString)",
          "archiveSHA256": "\(archiveSHA256)",
          "version": "1.0.0",
          "kind": "node-addon",
          "tags": ["demo"],
          "workflow": {"directory": null},
          "workflowIds": [],
          "backends": [],
          "requiredEnvironment": [],
          "dependencies": [],
          "addons": []
        }
      ]
    }
    """.write(to: registry.appendingPathComponent("registry-index.json"), atomically: true, encoding: .utf8)
  }
}
