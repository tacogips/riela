import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowSharedNodeVersioningTests: XCTestCase {
  func testSharedNodeGraphIsPinnedIntoDigestAndSnapshot() async throws {
    let fixture = try await makeSharedNodeFixture()
    let first = try WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity)
    let dependencyPaths = first.files.map(\.metadata.relativePath).filter {
      WorkflowSharedNodeDependencyInventory.isDependencyPath($0)
    }
    XCTAssertEqual(dependencyPaths, [
      ".riela-shared-nodes/shared-personas/nodes/mika.json",
      ".riela-shared-nodes/shared-personas/prompts/mika-system.md",
      ".riela-shared-nodes/shared-personas/workflow.json"
    ])

    let manifest = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(inventory: first)
    XCTAssertEqual(manifest.files.filter { $0.artifactKind == .sharedNode }.map(\.relativePath), dependencyPaths)
    for file in manifest.files where file.artifactKind == .sharedNode {
      let bytes = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).objectBytes(
        digest: file.contentDigest,
        snapshotId: manifest.snapshotId
      )
      XCTAssertEqual(WorkflowHistoryCanonicalCoding.sha256(bytes), file.contentDigest)
    }

    try Data("mutated shared persona".utf8).write(to: fixture.prompt)
    let changed = try WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity)
    XCTAssertNotEqual(changed.bundleDigest, first.bundleDigest)
  }

  func testSharedNodeDriftBlocksTransactionAndStagedVerificationResolvesPinnedLayout() async throws {
    let fixture = try await makeSharedNodeFixture()
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity)
    let snapshot = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(inventory: inventory)
    let successful = try WorkflowDirectoryTransactionCoordinator().commit(
      target: fixture.resolved.identity,
      historyRoot: fixture.resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: inventory.bundleDigest,
      expectedAfterBundleDigest: inventory.bundleDigest,
      preOperationSnapshotId: snapshot.snapshotId
    ) { _ in }
    XCTAssertTrue(successful.verification.contains { $0.id == "workflow-validate" })

    let current = try WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity)
    let currentSnapshot = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(inventory: current)
    try Data("drifted after snapshot".utf8).write(to: fixture.prompt)
    XCTAssertThrowsError(try WorkflowDirectoryTransactionCoordinator().commit(
      target: fixture.resolved.identity,
      historyRoot: fixture.resolved.historyRoot,
      kind: .apply,
      expectedBeforeBundleDigest: current.bundleDigest,
      expectedAfterBundleDigest: current.bundleDigest,
      preOperationSnapshotId: currentSnapshot.snapshotId
    ) { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("changed since review"))
    }
  }

  private func makeSharedNodeFixture() async throws -> (
    resolved: WorkflowVersioningResolvedTarget,
    prompt: URL
  ) {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let workflows = URL(fileURLWithPath: created.workflowDirectory).deletingLastPathComponent()
    let shared = workflows.appendingPathComponent("shared-personas", isDirectory: true)
    try FileManager.default.createDirectory(at: shared.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: shared.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try Data("""
    {"workflowId":"shared-personas","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"mika",
    "nodes":[{"id":"mika","nodeFile":"nodes/mika.json"}],"steps":[{"id":"mika","nodeId":"mika","role":"worker"}]}
    """.utf8).write(to: shared.appendingPathComponent("workflow.json"))
    try Data("""
    {"id":"mika","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,"systemPromptTemplateFile":"prompts/mika-system.md","promptTemplate":"shared","variables":{}}
    """.utf8).write(to: shared.appendingPathComponent("nodes/mika.json"))
    let prompt = shared.appendingPathComponent("prompts/mika-system.md")
    try Data("shared persona".utf8).write(to: prompt)

    let workflowURL = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("workflow.json")
    var workflow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
    var nodes = try XCTUnwrap(workflow["nodes"] as? [[String: Any]])
    let localId = try XCTUnwrap(nodes.first?["id"] as? String)
    nodes[0] = [
      "id": localId,
      "nodeRef": ["workflowId": "shared-personas", "nodeId": "mika"]
    ]
    workflow["nodes"] = nodes
    try JSONSerialization.data(withJSONObject: workflow, options: [.prettyPrinted, .sortedKeys]).write(to: workflowURL)
    return (try resolveVersioningTarget(root: root), prompt)
  }
}
