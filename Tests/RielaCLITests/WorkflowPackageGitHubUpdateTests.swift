import Foundation
import RielaAddons
import XCTest
@testable import RielaCLI

final class WorkflowPackageGitHubUpdateTests: XCTestCase {
  func testGitHubPackageURLRejectsAmbiguousOrUnsafePaths() throws {
    XCTAssertNil(try GitHubPackageReference.parse("demo"))
    XCTAssertThrowsError(try GitHubPackageReference.parse("https://github.com/example/repo/tree/main"))
    XCTAssertThrowsError(try GitHubPackageReference.parse("https://github.com/example/repo/tree/main/../demo"))
    XCTAssertThrowsError(try GitHubPackageReference.parse("https://github.com/example/repo?ref=main"))
    XCTAssertThrowsError(try GitHubPackageReference.parse("https://user@github.com/example/repo"))
    XCTAssertThrowsError(try GitHubPackageReference.parse("https://github.com:8443/example/repo"))
    XCTAssertEqual(try GitHubPackageReference.parse("https://github.com/example/repo.git")?.repository, "repo")
  }

  func testGitHubURLUpdatesOnlyInstalledPackageAndKeepsReusableLockSource() async throws {
    let taskRoot = URL(fileURLWithPath: repositoryRoot(), isDirectory: true)
      .appendingPathComponent("tmp/package-github-update-\(UUID().uuidString)", isDirectory: true)
    let repository = taskRoot.appendingPathComponent("source", isDirectory: true)
    let package = repository.appendingPathComponent("packages/demo", isDirectory: true)
    let workingDirectory = taskRoot.appendingPathComponent("work", isDirectory: true)
    let gitWrapper = taskRoot.appendingPathComponent("git-wrapper.sh")
    defer { try? FileManager.default.removeItem(at: taskRoot) }
    try FileManager.default.createDirectory(at: package.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: "\(repositoryRoot())/examples/worker-only-single-step"),
      to: package
    )
    try writeManifest(version: "1.0.0", package: package)
    try runGit(["-C", repository.path, "init", "-b", "main"])
    try runGit(["-C", repository.path, "config", "user.name", "Riela Test"])
    try runGit(["-C", repository.path, "config", "user.email", "riela-test@example.invalid"])
    try runGit(["-C", repository.path, "add", "."])
    try runGit(["-C", repository.path, "commit", "-qm", "initial"])

    try "#!/bin/sh\nexec git \"$@\"\n".write(to: gitWrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gitWrapper.path)
    let githubURL = "https://github.com/example/riela-update-test/tree/main/packages/demo"
    let gitEnvironment = [
      "RIELA_GIT_EXECUTABLE": gitWrapper.path,
      "GIT_CONFIG_COUNT": "1",
      "GIT_CONFIG_KEY_0": "url.file://\(repository.path).insteadOf",
      "GIT_CONFIG_VALUE_0": "https://github.com/example/riela-update-test.git"
    ]
    let app = RielaCLIApplication()
    let missing = await app.run([
      "package", "update", githubURL,
      "--working-dir", workingDirectory.path, "--output", "json"
    ], environment: gitEnvironment)
    XCTAssertEqual(missing.exitCode, .failure)
    XCTAssertTrue(missing.stdout.contains("installed package not found"), missing.stdout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workingDirectory.appendingPathComponent("riela-lock.json").path))
    let install = await app.run([
      "package", "install", package.path,
      "--working-dir", workingDirectory.path, "--output", "json"
    ])
    XCTAssertEqual(install.exitCode, .success, install.stdout + install.stderr)

    try "new content".write(to: package.appendingPathComponent("release.txt"), atomically: true, encoding: .utf8)
    try writeManifest(version: "1.1.0", package: package)
    try runGit(["-C", repository.path, "add", "."])
    try runGit(["-C", repository.path, "commit", "-qm", "update"])
    let updatedRevision = try runGit(["-C", repository.path, "rev-parse", "HEAD"])

    let dryRun = await app.run([
      "package", "update", githubURL, "--dry-run",
      "--working-dir", workingDirectory.path, "--output", "json"
    ], environment: gitEnvironment)
    XCTAssertEqual(dryRun.exitCode, .success, dryRun.stdout + dryRun.stderr)
    let preview = try decodeJSON(WorkflowPackageCommandResult.self, from: dryRun.stdout)
    XCTAssertEqual(preview.packages.first?.updateState, "would-update")
    XCTAssertEqual(preview.packages.first?.version, "1.1.0")

    let update = await app.run([
      "package", "update", githubURL,
      "--working-dir", workingDirectory.path, "--output", "json"
    ], environment: gitEnvironment)
    XCTAssertEqual(update.exitCode, .success, update.stdout + update.stderr)
    let updated = try decodeJSON(WorkflowPackageCommandResult.self, from: update.stdout)
    XCTAssertEqual(updated.packages.first?.updateState, "updated")
    let installed = workingDirectory.appendingPathComponent(".riela/packages/demo", isDirectory: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("release.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".git").path))

    let lock = try readWorkflowPackageLock(at: workingDirectory.appendingPathComponent("riela-lock.json"))
    XCTAssertEqual(lock.packages["demo"]?.source.kind, "github")
    XCTAssertEqual(lock.packages["demo"]?.source.reference, githubURL)
    XCTAssertEqual(lock.packages["demo"]?.source.gitRevision, updatedRevision)

    // Advancing the source branch must not change what CI installs.
    try writeManifest(version: "1.2.0", package: package)
    try runGit(["-C", repository.path, "add", "."])
    try runGit(["-C", repository.path, "commit", "-qm", "next release"])
    let ci = await app.run([
      "package", "ci", "demo", "--working-dir", workingDirectory.path, "--output", "json"
    ], environment: gitEnvironment)
    XCTAssertEqual(ci.exitCode, .success, ci.stdout + ci.stderr)
    let replay = try decodeJSON(WorkflowPackageCommandResult.self, from: ci.stdout)
    XCTAssertEqual(replay.packages.first?.version, "1.1.0")
    let replayLock = try readWorkflowPackageLock(at: workingDirectory.appendingPathComponent("riela-lock.json"))
    XCTAssertEqual(replayLock.packages["demo"]?.source.gitRevision, updatedRevision)

    let missingGit = await app.run([
      "package", "update", githubURL,
      "--working-dir", workingDirectory.path, "--output", "json"
    ], environment: ["RIELA_GIT_EXECUTABLE": "/missing/riela-git"])
    XCTAssertEqual(missingGit.exitCode, .failure)
    XCTAssertTrue(missingGit.stdout.contains("git executable is not executable"), missingGit.stdout)
  }

  func testRepositoryRootUpdateIncludesNestedFilesWithRelativeNoisyGitExecutable() async throws {
    let root = URL(fileURLWithPath: repositoryRoot()).appendingPathComponent("tmp/root-package-update-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let repository = root.appendingPathComponent("repository")
    let work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "\(repositoryRoot())/examples/worker-only-single-step"), to: source)
    try writeManifest(version: "1.0.0", package: source)
    let app = RielaCLIApplication()
    let install = await app.run(["package", "install", source.path, "--working-dir", work.path, "--output", "json"])
    XCTAssertEqual(install.exitCode, .success, install.stdout + install.stderr)
    try writeManifest(version: "2.0.0", package: source)
    try FileManager.default.copyItem(at: source, to: repository)
    try runGit(["-C", repository.path, "init", "-b", "main"])
    try runGit(["-C", repository.path, "config", "user.name", "Riela Test"])
    try runGit(["-C", repository.path, "config", "user.email", "riela-test@example.invalid"])
    try runGit(["-C", repository.path, "add", "."])
    try runGit(["-C", repository.path, "commit", "-qm", "root package"])
    let wrapper = root.appendingPathComponent("git-wrapper.sh")
    try """
    #!/bin/sh
    if [ "$1" = clone ]; then
      dd if=/dev/zero bs=1024 count=256 >&2 2>/dev/null
    fi
    exec git "$@"
    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let update = await app.run([
      "package", "update", "https://github.com/example/root-package.git",
      "--working-dir", work.path, "--output", "json"
    ], environment: [
      "RIELA_GIT_EXECUTABLE": "../git-wrapper.sh",
      "GIT_CONFIG_COUNT": "1",
      "GIT_CONFIG_KEY_0": "url.file://\(repository.path).insteadOf",
      "GIT_CONFIG_VALUE_0": "https://github.com/example/root-package.git"
    ])
    XCTAssertEqual(update.exitCode, .success, update.stdout + update.stderr)
    let installed = work.appendingPathComponent(".riela/packages/demo")
    XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("nodes").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: installed.appendingPathComponent("prompts").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: installed.appendingPathComponent(".git").path))
    let validation = await app.run(["package", "validate", installed.path, "--working-dir", work.path, "--output", "json"])
    XCTAssertEqual(validation.exitCode, .success, validation.stdout + validation.stderr)
  }

  func testLocalUpdateRejectsDifferentPackageAndCorruptUnchangedSourceWithoutWrites() async throws {
    let root = URL(fileURLWithPath: repositoryRoot()).appendingPathComponent("tmp/local-package-update-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("source")
    let work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "\(repositoryRoot())/examples/worker-only-single-step"), to: source)
    try writeManifest(version: "1.0.0", package: source)
    let app = RielaCLIApplication()
    let install = await app.run(["package", "install", source.path, "--working-dir", work.path, "--output", "json"])
    XCTAssertEqual(install.exitCode, .success, install.stdout + install.stderr)
    let lockURL = work.appendingPathComponent("riela-lock.json")
    let originalLock = try Data(contentsOf: lockURL)
    let installedManifest = work.appendingPathComponent(".riela/packages/demo/riela-package.json")
    let originalManifest = try Data(contentsOf: installedManifest)
    try writeManifest(version: "2.0.0", package: source, name: "other")
    for flags in [[], ["--dry-run"]] {
      let update = await app.run([
        "package", "update", "demo", "--source", source.path,
        "--working-dir", work.path, "--output", "json"
      ] + flags)
      XCTAssertEqual(update.exitCode, .failure)
      XCTAssertTrue(update.stdout.contains("source name mismatch"), update.stdout)
    }
    try writeManifest(version: "1.0.0", package: source)
    try "corrupt".write(to: source.appendingPathComponent("extra.txt"), atomically: true, encoding: .utf8)
    for flags in [[], ["--dry-run"]] {
      let update = await app.run([
        "package", "update", "demo", "--source", source.path,
        "--working-dir", work.path, "--output", "json"
      ] + flags)
      XCTAssertEqual(update.exitCode, .failure)
      XCTAssertTrue(update.stdout.contains("source validation failed"), update.stdout)
    }
    XCTAssertEqual(try Data(contentsOf: lockURL), originalLock)
    XCTAssertEqual(try Data(contentsOf: installedManifest), originalManifest)
    XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent(".riela/packages/other").path))
  }

  private func writeManifest(version: String, package: URL, name: String = "demo") throws {
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: package)
    try """
    {
      "name": "\(name)",
      "version": "\(version)",
      "description": "GitHub update test package",
      "tags": ["test"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": "."
    }
    """.write(to: package.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(output.utf8))
  }

  private func repositoryRoot() -> String {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
        return url.path
      }
      url.deleteLastPathComponent()
    }
    return FileManager.default.currentDirectoryPath
  }

  @discardableResult
  private func runGit(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git"] + arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, message)
    return message.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
