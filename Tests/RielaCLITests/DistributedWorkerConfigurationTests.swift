import Foundation
import RielaAdapters
import RielaCore
@testable import RielaCLI
import XCTest

final class DistributedWorkerConfigurationTests: XCTestCase {
  func testWorkspaceEnvironmentAllowsProviderCredentialsButNeverTransportToken() throws {
    let config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN"}"#)
    var workspace = try XCTUnwrap(config.workspaces["project"])
    workspace.allowedEnvironment = ["PROVIDER_KEY", "WORKER_TOKEN"]
    let filtered = try config.executionEnvironment(for: workspace, from: [
      "PATH": "/usr/bin", "PROVIDER_KEY": "provider-sentinel", "WORKER_TOKEN": "transport-sentinel", "UNRELATED_KEY": "private-sentinel"
    ])
    XCTAssertNil(filtered["WORKER_TOKEN"])
    XCTAssertNil(filtered["UNRELATED_KEY"])
    XCTAssertEqual(filtered["PATH"], "/usr/bin")
    for source in ["WORKER_TOKEN", "UNRELATED_KEY"] {
      XCTAssertThrowsError(try resolveAgentEnvironment(["KEY": .init(fromEnv: source, required: true)], variables: [:], runtimeEnvironment: filtered))
      XCTAssertThrowsError(try resolveAddonEnvironment(["KEY": .object(["fromEnv": .string(source)])], runtimeEnvironment: filtered))
    }
    let allowed = try resolveAgentEnvironment(["KEY": .init(fromEnv: "PROVIDER_KEY", required: true)], variables: [:], runtimeEnvironment: filtered)
    XCTAssertEqual(allowed["KEY"], "provider-sentinel")
    let addon = try resolveAddonEnvironment(["KEY": .object(["fromEnv": .string("PROVIDER_KEY")])], runtimeEnvironment: filtered)
    XCTAssertEqual(addon["KEY"], "provider-sentinel")
  }

  func testWorkerSubprocessDoesNotReinheritAmbientEnvironment() async throws {
    let runner = DistributedWorkerProcessRunner(environment: ["WORKER_ALLOWED": "allowed-sentinel"])
    let result = try await runner.run(configuration: .init(executableURL: URL(fileURLWithPath: "/usr/bin/env")),
      stdin: "", deadline: Date().addingTimeInterval(5))
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "WORKER_ALLOWED=allowed-sentinel")
  }

  func testTokenFileResolvesBesideConfigurationAndAcceptsLineEndings() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/distributed-workers/config-test/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let token = String(repeating: "a", count: 40)
    let config = try decode(#"{"tokenFile":"worker.token"}"#)
    for ending in ["", "\n", "\r\n"] {
      try Data((token + ending).utf8).write(to: root.appendingPathComponent("worker.token"))
      XCTAssertEqual(try config.resolveToken(relativeTo: root.appendingPathComponent("worker.json"), environment: [:]), token)
    }
    try Data(repeating: 97, count: 300).write(to: root.appendingPathComponent("worker.token"))
    XCTAssertThrowsError(try config.resolveToken(relativeTo: root.appendingPathComponent("worker.json"), environment: [:]))
  }

  func testEnvironmentCompatibilityAndAmbiguousCredentialsRejected() throws {
    let url = URL(fileURLWithPath: "/unused/worker.json")
    let config = try decode(#"{"tokenEnvironment":"WORKER_TOKEN"}"#)
    XCTAssertEqual(try config.resolveToken(relativeTo: url, environment: ["WORKER_TOKEN": "value"]), "value")
    XCTAssertThrowsError(try config.resolveToken(relativeTo: url, environment: [:]))
    for json in [#"{}"#, #"{"tokenFile":"x","tokenEnvironment":"WORKER_TOKEN"}"#] {
      let invalid = try decode(json)
      XCTAssertThrowsError(try invalid.resolveToken(relativeTo: url, environment: ["WORKER_TOKEN": "value"]))
    }
  }

  private func decode(_ credentials: String) throws -> DistributedWorkerCommand.Configuration {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(credentials.utf8)) as? [String: Any])
    object["controllerURL"] = "https://controller.example.com"
    object["capacity"] = 2
    object["workspaces"] = ["project": ["path": "."]]
    return try JSONDecoder().decode(DistributedWorkerCommand.Configuration.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
