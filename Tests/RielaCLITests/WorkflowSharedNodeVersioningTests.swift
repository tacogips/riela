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
    let successful = try commitMutableTransaction(
      fixture: fixture,
      coordinator: WorkflowDirectoryTransactionCoordinator(),
      beforeDigest: inventory.bundleDigest,
      afterDigest: inventory.bundleDigest,
      snapshotId: snapshot.snapshotId
    )
    XCTAssertTrue(successful.verification.contains { $0.id == "workflow-validate" })

    let current = try WorkflowHistoryIdentityResolver.inventory(for: fixture.resolved.identity)
    let currentSnapshot = try WorkflowHistoryStore(root: fixture.resolved.historyRoot).createSnapshot(inventory: current)
    try Data("drifted after snapshot".utf8).write(to: fixture.prompt)
    XCTAssertThrowsError(try commitMutableTransaction(
      fixture: fixture,
      coordinator: WorkflowDirectoryTransactionCoordinator(),
      beforeDigest: current.bundleDigest,
      afterDigest: current.bundleDigest,
      snapshotId: currentSnapshot.snapshotId
    )) { error in
      XCTAssertTrue(String(describing: error).contains("changed since review"))
    }
  }

  func testDeactivatedMutableSharedNodeIsRejectedButRemainsInspectable() async throws {
    let fixture = try await makeSharedNodeFixture()
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      _ = try WorkflowRegistryService().setActivation(
        .deactivated,
        target: WorkflowRegistryTarget(workflowId: "shared-personas", scope: .user),
        workingDirectory: fixture.root.path
      )
      let resolution = WorkflowResolutionOptions(
        workflowName: "versioned-flow",
        scope: .user,
        workingDirectory: fixture.root.path
      )
      XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(resolution)) { error in
        guard let registryError = error as? WorkflowRegistryError else {
          return XCTFail("expected typed registry error, got \(error)")
        }
        XCTAssertEqual(registryError.code, .workflowDeactivated)
        XCTAssertEqual(registryError.workflowId, "shared-personas")
      }

      var inspection = resolution
      inspection.includeDeactivated = true
      let inspectable = try FileSystemWorkflowBundleResolver().resolve(inspection)
      XCTAssertEqual(inspectable.nodePayloads.values.first?.systemPromptTemplate, "shared persona")
    }
  }

  func testNestedDeactivatedMutableSharedNodeIsRejectedBeforeMaterialization() async throws {
    let fixture = try await makeSharedNodeFixture()
    try configureNestedSharedNodeFixture(fixture)
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      _ = try WorkflowRegistryService().setActivation(
        .deactivated,
        target: WorkflowRegistryTarget(workflowId: "leaf-personas", scope: .user),
        workingDirectory: fixture.root.path
      )
      let resolution = WorkflowResolutionOptions(
        workflowName: "versioned-flow",
        scope: .user,
        workingDirectory: fixture.root.path
      )
      XCTAssertThrowsError(try FileSystemWorkflowBundleResolver().resolve(resolution)) { error in
        guard let registryError = error as? WorkflowRegistryError else {
          return XCTFail("expected typed registry error, got \(error)")
        }
        XCTAssertEqual(registryError.code, .workflowDeactivated)
        XCTAssertEqual(registryError.workflowId, "leaf-personas")
      }

      var inspection = resolution
      inspection.includeDeactivated = true
      let inspectable = try FileSystemWorkflowBundleResolver().resolve(inspection)
      XCTAssertEqual(inspectable.nodePayloads.values.first?.systemPromptTemplate, "nested persona")
    }
  }

  private func makeSharedNodeFixture() async throws -> MutableSharedNodeFixture {
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
    let environment = mutableWorkflowVersioningEnvironment(root: root)
    let home = URL(
      fileURLWithPath: try XCTUnwrap(environment["HOME"]),
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let resolved = try CLIRuntimeEnvironment.$overrides.withValue(environment) {
      let registry = WorkflowMutableRegistry()
      _ = try registry.register(input: shared, overwrite: false)
      _ = try registry.register(
        input: URL(fileURLWithPath: created.workflowDirectory, isDirectory: true),
        overwrite: false
      )
      let bundle = try FileSystemWorkflowBundleResolver().resolve(WorkflowResolutionOptions(
        workflowName: "versioned-flow",
        scope: .user,
        workingDirectory: root.path
      ))
      let target = try WorkflowHistoryIdentityResolver.identity(for: bundle)
      let historyRoot = try WorkflowHistoryIdentityResolver.historyRoot(
        for: target,
        workingDirectory: root
      )
      return WorkflowVersioningResolvedTarget(
        bundle: bundle,
        identity: target,
        historyRoot: historyRoot
      )
    }
    let registeredPrompt = home.appendingPathComponent(
      ".riela/temporary-workflows/shared-personas/prompts/mika-system.md"
    )
    return MutableSharedNodeFixture(
      root: root,
      resolved: resolved,
      prompt: registeredPrompt,
      environment: environment
    )
  }

  private func configureNestedSharedNodeFixture(_ fixture: MutableSharedNodeFixture) throws {
    let workflows = fixture.root.appendingPathComponent(".riela/workflows", isDirectory: true)
    let leaf = workflows.appendingPathComponent("leaf-personas", isDirectory: true)
    try FileManager.default.createDirectory(at: leaf.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: leaf.appendingPathComponent("prompts"), withIntermediateDirectories: true)
    try Data("""
    {"workflowId":"leaf-personas","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"mika",
    "nodes":[{"id":"mika","nodeFile":"nodes/mika.json"}],"steps":[{"id":"mika","nodeId":"mika","role":"worker"}]}
    """.utf8).write(to: leaf.appendingPathComponent("workflow.json"))
    try Data("""
    {"id":"mika","executionBackend":"codex-agent","model":"gpt-5.5","modelFreeze":false,
    "systemPromptTemplateFile":"prompts/mika-system.md","promptTemplate":"nested","variables":{}}
    """.utf8).write(to: leaf.appendingPathComponent("nodes/mika.json"))
    try Data("nested persona".utf8).write(to: leaf.appendingPathComponent("prompts/mika-system.md"))

    let shared = workflows.appendingPathComponent("shared-personas", isDirectory: true)
    try Data("""
    {"workflowId":"shared-personas","defaults":{"maxLoopIterations":3,"nodeTimeoutMs":120000},"entryStepId":"mika",
    "nodes":[{"id":"mika","nodeRef":{"workflowId":"leaf-personas","nodeId":"mika"}}],
    "steps":[{"id":"mika","nodeId":"mika","role":"worker"}]}
    """.utf8).write(to: shared.appendingPathComponent("workflow.json"))
    try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let registry = WorkflowMutableRegistry()
      _ = try registry.register(input: leaf, overwrite: false)
      _ = try registry.update(workflowId: "shared-personas", input: shared)
    }
  }

  private func commitMutableTransaction(
    fixture: MutableSharedNodeFixture,
    coordinator: WorkflowDirectoryTransactionCoordinator,
    beforeDigest: String,
    afterDigest: String,
    snapshotId: String
  ) throws -> WorkflowDirectoryTransactionResult {
    let registryDigest = try XCTUnwrap(fixture.resolved.bundle.mutableRegistryDigest)
    return try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      try WorkflowMutableRegistry().withWorkflowMutationAccess(
        workflowId: fixture.resolved.identity.workflowId,
        expectedDigest: registryDigest
      ) { detachedWorkflowDirectory, publish in
        try coordinator.commit(
          target: fixture.resolved.identity,
          historyRoot: fixture.resolved.historyRoot,
          kind: .apply,
          expectedBeforeBundleDigest: beforeDigest,
          expectedAfterBundleDigest: afterDigest,
          preOperationSnapshotId: snapshotId,
          physicalOwnershipRoot: detachedWorkflowDirectory,
          postCommitPublication: publish
        ) { _ in }
      }
    }
  }
}

private struct MutableSharedNodeFixture {
  var root: URL
  var resolved: WorkflowVersioningResolvedTarget
  var prompt: URL
  var environment: [String: String]
}
