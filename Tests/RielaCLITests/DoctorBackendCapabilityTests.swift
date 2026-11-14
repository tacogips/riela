import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

private struct DoctorCapabilityHostResolver: HostCapabilityResolving {
  var snapshot: HostCapabilitySnapshot

  func resolve(
    host: String,
    scope: WorkflowScope,
    workingDirectory: String,
    readOnly: Bool,
    localAddonExecutables: [String: Bool]
  ) async throws -> [HostCapabilitySnapshot] {
    [snapshot]
  }
}

private struct DoctorCapabilityProcessRunner: LocalProcessRunning {
  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalProcessResult {
    LocalProcessResult(stdout: "", stderr: "", terminationStatus: 1)
  }
}

final class DoctorBackendCapabilityTests: XCTestCase {
  func testDoctorJSONAndTextExposeBackendStatusWithoutSecrets() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = HostCapabilitySnapshot(
      hostId: "local",
      backends: [BackendCapability(
        backend: .codexAgent,
        source: .declared,
        observedAt: Date(),
        availability: .available,
        authentication: .failed,
        version: "1.2.3",
        models: ["gpt"],
        failures: ["authentication probe failed"]
      )],
      refreshedAt: Date(timeIntervalSinceReferenceDate: 10)
    )
    let command = DoctorCommand(
      runner: DoctorCapabilityProcessRunner(),
      hostResolver: DoctorCapabilityHostResolver(snapshot: snapshot)
    )
    let json = await command.run(CLICommandOptions(
      scope: "doctor",
      arguments: ["--working-dir", root.path, "--output", "json"],
      output: .json
    ))
    XCTAssertEqual(json.exitCode, .success)
    XCTAssertTrue(json.stdout.contains("codex-agent"))
    XCTAssertTrue(json.stdout.contains("authentication probe failed"))

    let text = await command.run(CLICommandOptions(
      scope: "doctor",
      arguments: ["--working-dir", root.path, "--output", "text"],
      output: .text
    ))
    XCTAssertTrue(text.stdout.contains("auth=failed"))
    XCTAssertTrue(text.stdout.contains("source=declared"))
    XCTAssertTrue(text.stdout.contains("version=1.2.3"))
    XCTAssertTrue(text.stdout.contains("models=gpt"))
    XCTAssertTrue(text.stdout.contains("failures=authentication probe failed"))
    XCTAssertTrue(text.stdout.contains("fresh"))
  }

  func testWritableLocalRefreshPersistsSnapshotButReadOnlyRefreshDoesNot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionRoot = root.appendingPathComponent("sessions")
    let resolver = HostCapabilityResolver(
      profileStore: RielaAppDaemonWorkflowStore(stateURL: root.appendingPathComponent("profile.json")),
      runner: DoctorCapabilityProcessRunner(),
      environment: ["RIELA_SESSION_STORE": sessionRoot.path]
    )
    _ = try await resolver.resolve(
      host: "local", scope: .project, workingDirectory: root.path, readOnly: true
    )
    let store = WorkStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot.path))
    XCTAssertTrue(try store.loadHostSnapshots().isEmpty)

    _ = try await resolver.resolve(
      host: "local", scope: .project, workingDirectory: root.path, readOnly: false
    )
    XCTAssertEqual(try store.loadHostSnapshots().map(\.hostId), ["local"])
  }
}
