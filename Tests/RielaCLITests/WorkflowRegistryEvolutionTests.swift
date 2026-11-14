import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

final class WorkflowRegistryEvolutionTests: XCTestCase {
  func testRegistryUpdatesCapturePromptsAndContractVersionRestoration() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    try await CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
      let store = WorkflowHistoryStore(root: fixture.resolved.historyRoot)
      let initial = try store.list(expectedIdentity: fixture.resolved.identity)
      let baseline = try XCTUnwrap(initial.first)
      XCTAssertTrue(baseline.snapshotId.hasPrefix("registry-after-"))
      let candidate = fixture.root.appendingPathComponent("candidate")
      try FileManager.default.copyItem(at: fixture.workflowDirectory, to: candidate)
      let workflowURL = candidate.appendingPathComponent("workflow.json")
      var definition = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workflowURL)) as? [String: Any])
      definition["workflowContractVersion"] = "2"
      definition["description"] = "evolved definition"
      var loop = try XCTUnwrap(definition["loop"] as? [String: Any])
      var evolution = try XCTUnwrap(loop["selfEvolution"] as? [String: Any])
      evolution["historyRoot"] = ".riela/new-history-location"
      loop["selfEvolution"] = evolution
      definition["loop"] = loop
      try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys]).write(to: workflowURL)
      let registeredNode = try fixture.registeredURL(for: fixture.created.files[1])
      let nodePath = String(registeredNode.path.dropFirst(fixture.workflowDirectory.path.count + 1))
      let nodeURL = candidate.appendingPathComponent(nodePath)
      var node = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: nodeURL)) as? [String: Any])
      let priorPromptPath = try XCTUnwrap(node["promptTemplateFile"] as? String)
      let priorPromptBytes = try Data(contentsOf: candidate.appendingPathComponent(priorPromptPath))
      node["promptTemplateFile"] = "prompt-history.txt"
      try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys]).write(to: nodeURL)
      // Remove the replaced owned prompt. Leaving an unreferenced file at the
      // old path intentionally invokes restore's existing unowned-file guard.
      try FileManager.default.removeItem(at: candidate.appendingPathComponent(priorPromptPath))
      let prompt = Data("進化した指示\n".utf8)
      try prompt.write(to: candidate.appendingPathComponent("prompt-history.txt"))
      _ = try WorkflowRegistryService().update(target: .init(workflowId: "versioned-flow", scope: .user), input: candidate,
        workingDirectory: fixture.root.path)
      let resolved = try resolveMutableTransactionTarget(root: fixture.root)
      XCTAssertEqual(resolved.identity.workflowContractVersion, "2")
      XCTAssertEqual(try WorkflowHistoryIdentityResolver.historyRoot(for: resolved.identity,
        workingDirectory: fixture.root, configuredRoot: ".riela/new-history-location"), fixture.resolved.historyRoot)
      let versions = try store.list(expectedIdentity: resolved.identity)
      XCTAssertEqual(versions.count, initial.count + 2)
      XCTAssertTrue(versions.contains { $0.snapshotId.hasPrefix("registry-before-") })
      let currentSnapshot = try XCTUnwrap(versions.first { $0.workflowContractVersion == "2" })
      let currentManifest = try store.loadSnapshot(currentSnapshot.snapshotId, expectedIdentity: resolved.identity)
      let promptFile = try XCTUnwrap(currentManifest.files.first { $0.relativePath == "prompt-history.txt" })
      XCTAssertEqual(try store.objectBytes(digest: promptFile.contentDigest, snapshotId: currentSnapshot.snapshotId), prompt)
      let old = try store.loadSnapshot(baseline.snapshotId, expectedIdentity: resolved.identity)
      XCTAssertNotEqual(old.target.workflowContractVersion, resolved.identity.workflowContractVersion)
      let restored = await RielaCLIApplication().run([
        "workflow", "restore", "versioned-flow", baseline.snapshotId, "--yes", "--scope", "user",
        "--working-dir", fixture.root.path, "--output", "json"
      ], environment: fixture.environment)
      XCTAssertEqual(restored.exitCode, .success, restored.stdout + restored.stderr)
      let after = try resolveMutableTransactionTarget(root: fixture.root)
      XCTAssertEqual(after.identity.workflowContractVersion, old.target.workflowContractVersion)
      XCTAssertEqual(try Data(contentsOf: fixture.workflowDirectory.appendingPathComponent(priorPromptPath)), priorPromptBytes)
      XCTAssertGreaterThan(try store.list(expectedIdentity: after.identity).count, versions.count)
    }
  }
}
