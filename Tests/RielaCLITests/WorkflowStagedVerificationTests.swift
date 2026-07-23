import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowStagedVerificationTests: XCTestCase {
  func testRequiredScenarioExecutesStdioWiringWithoutLaunchingCommand() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowDirectory = URL(fileURLWithPath: created.workflowDirectory, isDirectory: true)
    try requireMockScenario(in: workflowDirectory)
    try """
    {
      "id": "main-worker",
      "nodeType": "command",
      "modelFreeze": false,
      "command": { "executable": "/definitely/not/a/real/executable" }
    }
    """.write(
      to: workflowDirectory.appendingPathComponent("nodes/node-main-worker.json"),
      atomically: true,
      encoding: .utf8
    )
    try writeScenario(["main-worker": ["payload": ["stdio": true]]], in: workflowDirectory)

    let result = try commitUnchanged(root: root)

    XCTAssertTrue(result.verification.contains { $0.id == "mock-scenario-mock-scenario" })
  }

  func testRequiredScenarioExecutesAddonWiringWithoutProductionResolver() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowDirectory = URL(fileURLWithPath: created.workflowDirectory, isDirectory: true)
    let workflowURL = workflowDirectory.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    workflow["nodes"] = [["id": "main-worker", "addon": ["name": "missing-production-addon"]]]
    try requireMockScenario(workflow: &workflow)
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
    try writeScenario(["main-worker": ["payload": ["addon": true]]], in: workflowDirectory)

    let result = try commitUnchanged(root: root)

    XCTAssertTrue(result.verification.contains { $0.id == "mock-scenario-mock-scenario" })
  }

  func testRequiredScenarioFailsClosedWhenExecutedNodeEntryIsMissing() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowDirectory = URL(fileURLWithPath: created.workflowDirectory, isDirectory: true)
    try requireMockScenario(in: workflowDirectory)
    try writeScenario(["unused-node": ["payload": ["unused": true]]], in: workflowDirectory)

    XCTAssertThrowsError(try commitUnchanged(root: root)) { error in
      XCTAssertTrue(String(describing: error).contains("missing a response"))
    }
  }

  func testRequiredScenarioFailsClosedWhenResponsesRemainUnconsumed() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflowDirectory = URL(fileURLWithPath: created.workflowDirectory, isDirectory: true)
    try requireMockScenario(in: workflowDirectory)
    try writeScenario([
      "main-worker": ["payload": ["executed": true]],
      "unused-node": ["payload": ["unused": true]]
    ], in: workflowDirectory)

    XCTAssertThrowsError(try commitUnchanged(root: root)) { error in
      XCTAssertTrue(String(describing: error).contains("unconsumed required responses"))
    }
  }

  private func requireMockScenario(in directory: URL) throws {
    let workflowURL = directory.appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    try requireMockScenario(workflow: &workflow)
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
  }

  private func requireMockScenario(workflow: inout [String: Any]) throws {
    var loop = try XCTUnwrap(workflow["loop"] as? [String: Any])
    var selfEvolution = try XCTUnwrap(loop["selfEvolution"] as? [String: Any])
    selfEvolution["requiredVerification"] = ["workflow validate", "mock-scenario"]
    loop["selfEvolution"] = selfEvolution
    workflow["loop"] = loop
  }

  private func writeScenario(_ scenario: [String: Any], in directory: URL) throws {
    try JSONSerialization.data(withJSONObject: scenario, options: [.prettyPrinted, .sortedKeys])
      .write(to: directory.appendingPathComponent("mock-scenario.json"))
  }

  private func commitUnchanged(root: URL) throws -> WorkflowDirectoryTransactionResult {
    let resolved = try resolveMutableTransactionTarget(root: root)
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(inventory: inventory)
    return try WorkflowDirectoryTransactionCoordinator().commit(
      target: resolved.identity,
      historyRoot: resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }
  }
}
