import Foundation
import RielaAdapters
import XCTest
@testable import RielaCLI

final class DoctorCommandTests: XCTestCase {
  func testDoctorReportsMissingContainerRuntimeForContainerAddons() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-container")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)

    let result = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": ""])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .warning)
    XCTAssertEqual(report.summary.missingContainerRequirements, 1)
    XCTAssertEqual(report.summary.availableContainerRuntimes, 0)
    XCTAssertEqual(report.containerRequirements.map(\.package), ["container-addon-package"])
    XCTAssertEqual(report.containerRequirements.map(\.addon), ["youtube-download-worker"])
    XCTAssertEqual(report.containerRequirements.map(\.containerfilePath), ["containers/youtube/Containerfile"])
    XCTAssertEqual(report.containerRequirements.map(\.status), [.missing])
    XCTAssertTrue(report.containerRequirements.first?.installHint?.contains("riela setup container") == true)
  }

  func testDoctorMarksContainerRequirementOkWhenRuntimeIsAvailable() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-container-ok")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeContainer = bin.appendingPathComponent("container")
    try "#!/bin/sh\nexit 0\n".write(to: fakeContainer, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeContainer.path)

    let result = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .ok)
    XCTAssertEqual(report.summary.missingContainerRequirements, 0)
    XCTAssertEqual(report.summary.availableContainerRuntimes, 1)
    XCTAssertEqual(report.containerRequirements.map(\.status), [.ok])
    XCTAssertEqual(report.containerRuntimes.first { $0.kind == .appleContainer }?.resolvedPath, fakeContainer.path)
  }

  func testDoctorMarksAppleContainerWarningWhenServiceIsNotRunning() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-container-stopped")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeContainer = bin.appendingPathComponent("container")
    try """
    #!/bin/sh
    if [ "$1" = "system" ] && [ "$2" = "status" ]; then
      echo '{"status":"stopped"}'
      exit 1
    fi
    exit 0
    """.write(to: fakeContainer, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeContainer.path)

    let result = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .warning)
    XCTAssertEqual(report.summary.availableContainerRuntimes, 0)
    XCTAssertEqual(report.summary.missingContainerRequirements, 1)
    XCTAssertEqual(report.containerRuntimes.first { $0.kind == .appleContainer }?.status, .warning)
    XCTAssertEqual(report.containerRequirements.map(\.status), [.missing])
  }

  func testDoctorMarksDockerWarningWhenDaemonIsNotReady() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-docker-stopped")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeDocker = bin.appendingPathComponent("docker")
    try """
    #!/bin/sh
    if [ "$1" = "info" ]; then
      echo 'Cannot connect to the Docker daemon' >&2
      exit 1
    fi
    exit 0
    """.write(to: fakeDocker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)

    let result = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .warning)
    XCTAssertEqual(report.summary.availableContainerRuntimes, 0)
    XCTAssertEqual(report.summary.missingContainerRequirements, 1)
    XCTAssertEqual(report.containerRuntimes.first { $0.kind == .docker }?.status, .warning)
    XCTAssertEqual(report.containerRequirements.map(\.status), [.missing])
  }

  func testDoctorMarksDockerRuntimeOkWhenDaemonIsReady() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-docker-ok")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeDocker = bin.appendingPathComponent("docker")
    try """
    #!/bin/sh
    if [ "$1" = "info" ]; then
      echo 'Server Version: test'
      exit 0
    fi
    exit 0
    """.write(to: fakeDocker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)

    let result = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": bin.path])

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .ok)
    XCTAssertEqual(report.summary.availableContainerRuntimes, 1)
    XCTAssertEqual(report.summary.missingContainerRequirements, 0)
    XCTAssertEqual(report.containerRuntimes.first { $0.kind == .docker }?.status, .ok)
    XCTAssertEqual(report.containerRequirements.map(\.status), [.ok])
  }

  func testDoctorTreatsRuntimeReadinessErrorsAsWarnings() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-runtime-error")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installContainerAddonPackage(workingDirectory: tempDir)
    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeDocker = bin.appendingPathComponent("docker")
    try "#!/bin/sh\nexit 0\n".write(to: fakeDocker, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDocker.path)

    let result = await CLIRuntimeEnvironment.$overrides.withValue(["PATH": bin.path]) {
      await DoctorCommand(runner: ThrowingDoctorRuntimeRunner()).run(CLICommandOptions(
        scope: "doctor",
        command: "doctor",
        arguments: ["--scope", "project", "--working-dir", tempDir.path],
        output: .json
      ))
    }

    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let report = try decodeJSON(DoctorCommandResult.self, from: result.stdout)
    XCTAssertEqual(report.summary.status, .warning)
    XCTAssertEqual(report.containerRuntimes.first { $0.kind == .docker }?.status, .warning)
    XCTAssertEqual(report.summary.missingContainerRequirements, 1)
  }

  func testDoctorReportsRequiredEnvironmentAndRuntimeHints() async throws {
    let tempDir = try makeRielaCLITestTemporaryDirectory("riela-doctor-env-runtime")
    defer { try? FileManager.default.removeItem(at: tempDir) }
    try installDiagnosticAddonPackage(workingDirectory: tempDir)

    let missing = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: ["PATH": ""])

    XCTAssertEqual(missing.exitCode, .success, missing.stderr)
    let missingReport = try decodeJSON(DoctorCommandResult.self, from: missing.stdout)
    XCTAssertEqual(missingReport.summary.status, .warning)
    XCTAssertEqual(missingReport.summary.missingEnvironment, 1)
    XCTAssertEqual(missingReport.summary.missingRuntimeHints, 1)
    XCTAssertEqual(missingReport.requiredEnvironment.map(\.name), ["RIELA_DOCTOR_REQUIRED_TOKEN"])
    XCTAssertEqual(missingReport.requiredEnvironment.map(\.status), [.missing])
    XCTAssertEqual(missingReport.runtimeHints.map(\.hint), ["pdfinfo"])
    XCTAssertEqual(missingReport.runtimeHints.map(\.status), [.missing])
    XCTAssertEqual(missingReport.runtimeHints.first?.installHint, "Install pdfinfo and ensure it is on PATH")

    let bin = tempDir.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let fakeRuntime = bin.appendingPathComponent("pdfinfo")
    try "#!/bin/sh\nexit 0\n".write(to: fakeRuntime, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeRuntime.path)

    let ok = await RielaCLIApplication().run([
      "doctor",
      "--scope", "project",
      "--working-dir", tempDir.path,
      "--output", "json"
    ], environment: [
      "PATH": bin.path,
      "RIELA_DOCTOR_REQUIRED_TOKEN": "set"
    ])

    XCTAssertEqual(ok.exitCode, .success, ok.stderr)
    let okReport = try decodeJSON(DoctorCommandResult.self, from: ok.stdout)
    XCTAssertEqual(okReport.summary.missingEnvironment, 0)
    XCTAssertEqual(okReport.summary.missingRuntimeHints, 0)
    XCTAssertEqual(okReport.requiredEnvironment.map(\.status), [.ok])
    XCTAssertEqual(okReport.runtimeHints.map(\.status), [.ok])
    XCTAssertEqual(okReport.runtimeHints.first?.resolvedPath, fakeRuntime.path)
  }

  private func installContainerAddonPackage(workingDirectory: URL) throws {
    let package = workingDirectory
      .appendingPathComponent(".riela/packages/container-addon-package", isDirectory: true)
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("containers/youtube", isDirectory: true),
      withIntermediateDirectories: true
    )
    try "FROM scratch\n".write(
      to: package.appendingPathComponent("containers/youtube/Containerfile"),
      atomically: true,
      encoding: .utf8
    )
    try """
    {
      "name": "container-addon-package",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Containerized YouTube downloader add-on",
      "tags": ["container", "youtube"],
      "addons": [
        {
          "name": "youtube-download-worker",
          "version": "1",
          "sourcePath": "containers/youtube",
          "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "execution": {
            "kind": "container",
            "containerfilePath": "containers/youtube/Containerfile"
          },
          "capabilities": [
            {"name": "network.egress", "reason": "Download media metadata", "defaultPolicy": "prompt"},
            {"name": "filesystem.write", "scope": "downloads", "reason": "Write downloaded media", "defaultPolicy": "prompt"}
          ]
        }
      ]
    }
    """.write(to: package.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func installDiagnosticAddonPackage(workingDirectory: URL) throws {
    let package = workingDirectory
      .appendingPathComponent(".riela/packages/diagnostic-addon-package", isDirectory: true)
    try FileManager.default.createDirectory(
      at: package.appendingPathComponent("addons/diagnostic", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    {
      "name": "diagnostic-addon-package",
      "version": "1.0.0",
      "kind": "node-addon",
      "description": "Diagnostic add-on package",
      "environmentVariables": [
        {
          "name": "RIELA_DOCTOR_REQUIRED_TOKEN",
          "description": "Required doctor test token",
          "required": true,
          "secret": true
        }
      ],
      "addons": [
        {
          "name": "diagnostic/pdfinfo",
          "version": "1",
          "sourcePath": "addons/diagnostic",
          "contentDigest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
          "execution": {
            "kind": "local-command",
            "entrypoint": "run.sh",
            "runtimeHints": ["pdfinfo"]
          }
        }
      ]
    }
    """.write(to: package.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(stdout.utf8))
  }
}

private struct DoctorRuntimeReadinessError: Error {}

private actor ThrowingDoctorRuntimeRunner: LocalAgentProcessRunning {
  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    throw DoctorRuntimeReadinessError()
  }
}
