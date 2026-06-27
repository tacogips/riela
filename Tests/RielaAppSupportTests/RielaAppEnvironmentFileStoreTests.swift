#if os(macOS)
import Foundation
import RielaAddons
@testable import RielaAppSupport
import XCTest

final class RielaAppEnvironmentFileStoreTests: XCTestCase {
  func testPackageDiscoveryReportsRequiredEnvironmentVariables() throws {
    let root = try temporaryHome()
    let packageDirectory = root.appendingPathComponent(".riela/packages/env-package", isDirectory: true)
    try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
    try """
    {"workflowId":"env-workflow","steps":[],"nodes":[]}
    """.write(to: packageDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    let checksum = try WorkflowPackageChecksum.md5(packageRoot: packageDirectory)
    try """
    {
      "kind": "workflow",
      "name": "env-package",
      "version": "1.0.0",
      "description": "Environment package",
      "tags": ["env"],
      "registry": "local",
      "checksum": "\(checksum)",
      "checksumAlgorithm": "md5",
      "workflowDirectory": ".",
      "environmentVariables": [
        {"name": "RIELA_REQUIRED_TOKEN", "description": "Required token", "secret": true},
        {"name": "RIELA_OPTIONAL_MODE", "required": false}
      ]
    }
    """.write(to: packageDirectory.appendingPathComponent("riela-package.json"), atomically: true, encoding: .utf8)

    let candidate = try XCTUnwrap(RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows().first)

    XCTAssertEqual(candidate.requiredEnvironment.map(\.name), ["RIELA_REQUIRED_TOKEN"])
    XCTAssertEqual(candidate.requiredEnvironment.first?.description, "Required token")
    XCTAssertEqual(candidate.requiredEnvironment.first?.secret, true)
  }

  func testEnvironmentFileStoreReportsSelectedFileAndProcessValues() throws {
    let root = try temporaryHome()
    let envURL = root.appendingPathComponent("workflow.env")
    try """
    RIELA_TOKEN='abc'\\''123'
    RIELA_FILE_ONLY=present
    """.write(to: envURL, atomically: true, encoding: .utf8)
    let store = RielaAppEnvironmentFileStore(
      environmentFileURL: envURL,
      processEnvironment: [
        "RIELA_FROM_PROCESS": "present",
        "RIELA_TOKEN": "process-token"
      ]
    )

    XCTAssertEqual(store.mergedEnvironment()["RIELA_TOKEN"], "abc'123")
    XCTAssertEqual(store.mergedEnvironment()["RIELA_FROM_PROCESS"], "present")
    XCTAssertEqual(store.statuses(for: ["RIELA_TOKEN", "RIELA_FROM_PROCESS", "RIELA_MISSING"]).map(\.configured), [
      true,
      true,
      false
    ])
  }

  func testWorkflowDiscoveryReportsWorkflowRequiredEnvironmentVariables() throws {
    let root = try temporaryHome()
    let workflowDirectory = root.appendingPathComponent(".riela/workflows/env-workflow", isDirectory: true)
    try FileManager.default.createDirectory(
      at: workflowDirectory.appendingPathComponent("nodes", isDirectory: true),
      withIntermediateDirectories: true
    )
    try """
    {
      "workflowId": "env-workflow",
      "nodes": [
        {
          "id": "inline-addon",
          "addon": {
            "name": "riela/demo",
            "env": {
              "TOKEN": {"fromEnv": "RIELA_ADDON_TOKEN"},
              "OPTIONAL": {"fromEnv": "RIELA_OPTIONAL_TOKEN", "required": false}
            }
          }
        },
        {"id": "agent", "nodeFile": "nodes/agent.json"}
      ],
      "steps": []
    }
    """.write(to: workflowDirectory.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "agent",
      "model": "test",
      "agentEnvironment": {
        "OPENAI_API_KEY": {"fromEnv": "RIELA_AGENT_TOKEN", "required": true},
        "OPTIONAL": {"fromEnv": "RIELA_AGENT_OPTIONAL"}
      }
    }
    """.write(to: workflowDirectory.appendingPathComponent("nodes/agent.json"), atomically: true, encoding: .utf8)

    let candidate = try XCTUnwrap(RielaAppDaemonWorkflowDiscovery(homeDirectory: root).discoverUserDaemonWorkflows().first)

    XCTAssertEqual(candidate.requiredEnvironment.map(\.name), ["RIELA_ADDON_TOKEN", "RIELA_AGENT_TOKEN"])
  }

  private func temporaryHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-app-env-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return root
  }
}
#endif
