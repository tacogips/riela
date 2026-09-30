import Foundation
import RielaAdapters
import RielaAppSupport
import RielaCore
import RielaWork
import XCTest
@testable import RielaCLI

final class HostTraitsResolverTests: XCTestCase {
  func testProfileHostTraitsDefaultAndMergeWithLocalOverride() async throws {
    let missing = try JSONDecoder().decode(
      RielaAppDaemonWorkflowState.self, from: Data(#"{"version":1}"#.utf8)
    )
    XCTAssertEqual(missing.hostTraits, [])
    let encoded = try JSONEncoder().encode(missing)
    XCTAssertNotNil((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["hostTraits"])

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let profileURL = root.appendingPathComponent("profile.json")
    try JSONEncoder().encode(RielaAppDaemonWorkflowState(hostTraits: [.userReachable])).write(to: profileURL)
    let resolver = HostCapabilityResolver(
      profileStore: RielaAppDaemonWorkflowStore(stateURL: profileURL),
      runner: HostTraitsNoopRunner(), environment: [:], localTraitOverride: [.gui, .userReachable]
    )
    let snapshots = try await resolver.resolve(
      host: "local", scope: .project, workingDirectory: root.path,
      readOnly: true, localAddonExecutables: [:]
    )
    XCTAssertEqual(snapshots.first?.traits, [.gui, .userReachable])
    let topology = try await resolver.taskTopology(
      store: WorkStore(rootDirectory: root.appendingPathComponent("work").path),
      scope: .project, workingDirectory: root.path, localAddonExecutables: [:]
    )
    XCTAssertEqual(topology.local.traits, [.gui, .userReachable])
  }

  func testWorkerConfigurationDecodesDeclaredTraitsStrictly() throws {
    let valid = try workerConfiguration(#"{"traits":["userReachable","gui"]}"#)
    XCTAssertEqual(valid.traits, [.userReachable, .gui])
    XCTAssertThrowsError(try workerConfiguration(#"{"traits":["made-up-trait"]}"#)) { error in
      XCTAssertTrue(String(describing: error).contains("made-up-trait"))
    }
    let absent = try workerConfiguration("{}")
    XCTAssertNil(absent.traits)
  }

  func testDoctorReportsDeclaredHostTraitsInJSONAndText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = HostCapabilitySnapshot(
      hostId: "local", backends: [], refreshedAt: Date(), traits: [.userReachable, .gui]
    )
    let command = DoctorCommand(
      runner: HostTraitsNoopRunner(), hostResolver: HostTraitsSnapshotResolver(snapshot: snapshot)
    )
    let json = await command.run(CLICommandOptions(
      scope: "doctor", arguments: ["--working-dir", root.path, "--output", "json"], output: .json
    ))
    XCTAssertEqual(json.exitCode, .success)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(payload["hostTraits"] as? [String], ["gui", "userReachable"])

    let text = await command.run(CLICommandOptions(
      scope: "doctor", arguments: ["--working-dir", root.path, "--output", "text"], output: .text
    ))
    XCTAssertTrue(text.stdout.contains("host traits: gui,userReachable"))
  }

  private func workerConfiguration(_ fields: String) throws -> DistributedWorkerCommand.Configuration {
    let extra = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
    var object: [String: Any] = [
      "controllerURL": "https://controller.example.com", "capacity": 1,
      "workspaces": ["project": ["path": "."]]
    ]
    object.merge(extra) { _, new in new }
    return try JSONDecoder().decode(
      DistributedWorkerCommand.Configuration.self,
      from: JSONSerialization.data(withJSONObject: object)
    )
  }
}

private struct HostTraitsSnapshotResolver: HostCapabilityResolving {
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

private struct HostTraitsNoopRunner: LocalProcessRunning {
  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalProcessResult {
    LocalProcessResult(stdout: "", stderr: "", terminationStatus: 1)
  }
}
