import Foundation
import RielaAdapters
import XCTest
@testable import RielaCLI

final class SetupContainerCommandTests: XCTestCase {
  func testSetupContainerPrintScriptDoesNotRunProcesses() async throws {
    let runner = RecordingSetupContainerRunner()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(runner: runner))

    let result = await app.run([
      "setup", "container",
      "--print-script",
      "--output", "text"
    ], environment: ["PATH": ""])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.hasPrefix("#!/bin/sh\n"), result.stdout)
    XCTAssertTrue(result.stdout.contains("PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"), result.stdout)
    XCTAssertTrue(result.stdout.contains("https://api.github.com/repos/apple/container/releases/latest"), result.stdout)
    XCTAssertTrue(result.stdout.contains("browser_download_url"), result.stdout)
    XCTAssertTrue(result.stdout.contains("/usr/sbin/spctl --assess --type install \"$pkg\""), result.stdout)
    XCTAssertTrue(result.stdout.contains("sudo /usr/sbin/installer -pkg \"$pkg\" -target /"), result.stdout)
    XCTAssertTrue(result.stdout.contains("container system start"), result.stdout)
    XCTAssertFalse(result.stdout.contains("<downloaded-container.pkg>"), result.stdout)
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.count, 0)
  }

  func testSetupContainerPrintScriptCanOpenSignedInstallerWithoutDeletingPackage() async throws {
    let runner = RecordingSetupContainerRunner()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(runner: runner))

    let result = await app.run([
      "setup", "container",
      "--print-script",
      "--open-installer",
      "--output", "text"
    ], environment: ["PATH": ""])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    XCTAssertTrue(result.stdout.contains("open \"$pkg\""), result.stdout)
    XCTAssertTrue(result.stdout.contains("Installer package left at: $pkg"), result.stdout)
    XCTAssertFalse(result.stdout.contains("trap 'rm -rf \"$tmpdir\"' EXIT"), result.stdout)
    XCTAssertFalse(result.stdout.contains("sudo /usr/sbin/installer -pkg \"$pkg\" -target /"), result.stdout)
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.count, 0)
  }

  func testSetupContainerStartsExistingAppleContainerWhenAccepted() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-setup-container")
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let container = try installExecutable(named: "container", in: bin)
    let runner = RecordingSetupContainerRunner()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(runner: runner))

    let result = await app.run([
      "setup", "container",
      "--yes",
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoded = try decodeJSON(SetupContainerResult.self, from: result.stdout)
    XCTAssertFalse(decoded.dryRun)
    XCTAssertTrue(decoded.accepted)
    XCTAssertEqual(decoded.runtimePath, container.path)
    XCTAssertEqual(decoded.actions.last?.kind, .startService)
    XCTAssertEqual(decoded.actions.last?.status, .ok)
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.map(\.executableURL.path), [container.path])
    XCTAssertEqual(invocations.map(\.arguments), [["system", "start"]])
  }

  func testSetupContainerOpenInstallerRunsOpenCommand() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-setup-container-open")
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let package = tempDir.appendingPathComponent("container-1.0.0.pkg")
    try Data("pkg".utf8).write(to: package)
    let open = try installExecutable(named: "open", in: bin)
    let runner = RecordingSetupContainerRunner()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(
      runner: runner,
      releaseResolver: FakeSetupContainerReleaseResolver(downloadURL: URL(string: "https://example.com/container.pkg")!),
      downloader: FakeSetupContainerDownloader(packageURL: package)
    ))

    let result = await app.run([
      "setup", "container",
      "--open-installer",
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoded = try decodeJSON(SetupContainerResult.self, from: result.stdout)
    XCTAssertFalse(decoded.dryRun)
    XCTAssertFalse(decoded.accepted)
    XCTAssertEqual(decoded.installerAssetName, "container.pkg")
    XCTAssertEqual(decoded.installerDownloadURL, "https://example.com/container.pkg")
    XCTAssertEqual(decoded.installerPath, package.path)
    XCTAssertEqual(decoded.actions.first { $0.kind == .downloadInstaller }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .verifyInstaller }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .openInstaller }?.status, .ok)
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.map(\.executableURL.path), [
      "/usr/sbin/spctl",
      open.path
    ])
    XCTAssertEqual(invocations.map(\.arguments), [
      ["--assess", "--type", "install", package.path],
      [package.path]
    ])
  }

  func testSetupContainerDownloadsInstallerInstallsAndStartsRuntimeWhenMissingAndAccepted() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-setup-container-install")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    let package = tempDir.appendingPathComponent("container-1.0.0.pkg")
    try Data("pkg".utf8).write(to: package)
    let runner = RecordingSetupContainerRunner()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(
      runner: runner,
      releaseResolver: FakeSetupContainerReleaseResolver(downloadURL: URL(string: "https://example.com/container.pkg")!),
      downloader: FakeSetupContainerDownloader(packageURL: package)
    ))

    let result = await app.run([
      "setup", "container",
      "--yes",
      "--output", "json"
    ], environment: ["PATH": ""])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoded = try decodeJSON(SetupContainerResult.self, from: result.stdout)
    XCTAssertFalse(decoded.dryRun)
    XCTAssertEqual(decoded.installerAssetName, "container.pkg")
    XCTAssertEqual(decoded.installerDownloadURL, "https://example.com/container.pkg")
    XCTAssertEqual(decoded.installerPath, package.path)
    XCTAssertEqual(decoded.actions.first { $0.kind == .downloadInstaller }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .verifyInstaller }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .installPackage }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .startService }?.status, .ok)
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.map(\.executableURL.path), [
      "/usr/sbin/spctl",
      "/usr/sbin/installer",
      "/usr/local/bin/container"
    ])
    XCTAssertEqual(invocations.map(\.arguments), [
      ["--assess", "--type", "install", package.path],
      ["-pkg", package.path, "-target", "/"],
      ["system", "start"]
    ])
  }

  func testSetupContainerDoesNotOpenOrInstallWhenSignatureVerificationFails() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-setup-container-verify-fail")
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let package = tempDir.appendingPathComponent("container-1.0.0.pkg")
    try Data("pkg".utf8).write(to: package)
    _ = try installExecutable(named: "open", in: bin)
    let runner = FailingSetupContainerVerifier()
    let app = RielaCLIApplication(setupContainerCommand: SetupContainerCommand(
      runner: runner,
      releaseResolver: FakeSetupContainerReleaseResolver(downloadURL: URL(string: "https://example.com/container.pkg")!),
      downloader: FakeSetupContainerDownloader(packageURL: package)
    ))

    let result = await app.run([
      "setup", "container",
      "--open-installer",
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoded = try decodeJSON(SetupContainerResult.self, from: result.stdout)
    XCTAssertEqual(decoded.actions.first { $0.kind == .downloadInstaller }?.status, .ok)
    XCTAssertEqual(decoded.actions.first { $0.kind == .verifyInstaller }?.status, .warning)
    XCTAssertEqual(decoded.actions.first { $0.kind == .openInstaller }?.status, .unknown)
    XCTAssertTrue(decoded.nextStep?.contains("signature verification failed") == true, decoded.nextStep ?? "")
    let invocations = await runner.invocations()
    XCTAssertEqual(invocations.map(\.executableURL.path), ["/usr/sbin/spctl"])
  }

  private func installExecutable(named name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(stdout.utf8))
  }
}

private struct FakeSetupContainerReleaseResolver: SetupContainerReleaseResolving {
  var downloadURL: URL

  func latestInstallerRelease() async throws -> SetupContainerInstallerRelease {
    SetupContainerInstallerRelease(assetName: "container.pkg", downloadURL: downloadURL)
  }
}

private struct FakeSetupContainerDownloader: SetupContainerDownloading {
  var packageURL: URL

  func downloadInstaller(from url: URL) async throws -> URL {
    packageURL
  }
}

private actor RecordingSetupContainerRunner: LocalAgentProcessRunning {
  private var recorded: [LocalAgentProcessConfiguration] = []

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    recorded.append(configuration)
    return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 0)
  }

  func invocations() -> [LocalAgentProcessConfiguration] {
    recorded
  }
}

private actor FailingSetupContainerVerifier: LocalAgentProcessRunning {
  private var recorded: [LocalAgentProcessConfiguration] = []

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    recorded.append(configuration)
    if configuration.executableURL.path == "/usr/sbin/spctl" {
      return LocalAgentProcessResult(stdout: "", stderr: "signature verification failed", terminationStatus: 1)
    }
    return LocalAgentProcessResult(stdout: "", stderr: "", terminationStatus: 0)
  }

  func invocations() -> [LocalAgentProcessConfiguration] {
    recorded
  }
}
