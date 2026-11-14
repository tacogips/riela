import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowVersionCommandsTests: XCTestCase {
  func testListShowDiffDryRunAndApprovedRestorePreserveExecutableBits() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let root = fixture.root
    let resolved = fixture.resolved
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let script = fixture.workflowDirectory.appendingPathComponent("verify.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let node = try fixture.registeredURL(for: fixture.created.files[1])
    var nodeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: node)) as? [String: Any])
    nodeObject["promptTemplateFile"] = "verify.sh"
    try JSONSerialization.data(withJSONObject: nodeObject, options: [.prettyPrinted, .sortedKeys]).write(to: node)
    let store = WorkflowHistoryStore(root: historyRoot)
    let snapshot = try store.createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: target),
      snapshotId: "snapshot-executable",
      now: Date(timeIntervalSince1970: 1)
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
    let app = RielaCLIApplication()

    let list = await app.run([
      "workflow", "versions", "versioned-flow", "--scope", "user",
      "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeVersionJSON(WorkflowVersionsCommandResult.self, list.stdout).snapshots.first
    XCTAssertEqual(listed?.snapshotId, snapshot.snapshotId)
    XCTAssertEqual(listed?.sourceKind, .authoredWorkflow)
    XCTAssertEqual(listed?.retentionClass, "standard")
    XCTAssertEqual(listed?.redactionStatus, "not-required")
    XCTAssertEqual(listed?.integrityAlgorithm, "sha256")
    XCTAssertTrue(listed?.integrityVerified == true)

    let show = await app.run([
      "workflow", "version", "show", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(show.exitCode, .success, show.stderr)
    XCTAssertTrue(try decodeVersionJSON(WorkflowVersionShowCommandResult.self, show.stdout).integrityVerified)

    let diff = await app.run([
      "workflow", "version", "diff", "versioned-flow", snapshot.snapshotId, "current",
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(diff.exitCode, .success, diff.stderr)
    XCTAssertEqual(try decodeVersionJSON(WorkflowVersionDiffCommandResult.self, diff.stdout).differences.first?.kind, .executableBitOnly)

    let dryRun = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(dryRun.exitCode, .success, dryRun.stderr)
    let dryResult = try decodeVersionJSON(WorkflowRestoreCommandResult.self, dryRun.stdout)
    XCTAssertTrue(dryResult.dryRun)
    XCTAssertFalse(dryResult.restored)
    XCTAssertNil(dryResult.preRestoreSnapshotId)

    let restore = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--yes", "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(restore.exitCode, .success, restore.stdout + restore.stderr)
    let restoreResult = try decodeVersionJSON(WorkflowRestoreCommandResult.self, restore.stdout)
    XCTAssertTrue(restoreResult.restored)
    let transactionId = try XCTUnwrap(restoreResult.transactionId)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: historyRoot.appendingPathComponent("transactions/active.json").path
    ))
    let transaction = try XCTUnwrap(WorkflowTransactionGenerationStore.readLatest(
      logicalURL: historyRoot.appendingPathComponent("transactions/\(transactionId).json"),
      historyRoot: historyRoot
    ))
    XCTAssertEqual(transaction.phase, .committed)
    let transactionEntries = try FileManager.default.contentsOfDirectory(
      at: historyRoot.appendingPathComponent("transactions", isDirectory: true),
      includingPropertiesForKeys: nil
    ).map(\.lastPathComponent).sorted()
    XCTAssertEqual(
      transactionEntries.filter { $0.hasSuffix(".json.generations") },
      ["\(transactionId).json.generations"],
      "\(transactionEntries)"
    )
    let recovered = try WorkflowDirectoryTransactionCoordinator().recover(
      historyRoot: historyRoot,
      target: target,
      authoritativeBundleDigest: transaction.expectedAfterBundleDigest
    )
    XCTAssertNil(recovered)
    let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
    XCTAssertNotEqual((mode?.intValue ?? 0) & 0o111, 0)
    let postRestoreShow = await app.run([
      "workflow", "version", "show", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(
      postRestoreShow.exitCode,
      .success,
      postRestoreShow.stdout + postRestoreShow.stderr
    )
    let shown = try decodeVersionJSON(WorkflowVersionShowCommandResult.self, postRestoreShow.stdout)
    XCTAssertEqual(shown.restoreReferences.count, 2)
  }

  func testRestoreRejectsUnsafeSnapshotIdAndPreservesUnownedRegularFile() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let root = fixture.root
    let resolved = fixture.resolved
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let store = WorkflowHistoryStore(root: historyRoot)
    let snapshot = try store.createSnapshot(inventory: WorkflowHistoryIdentityResolver.inventory(for: target))
    let unreviewed = fixture.workflowDirectory.appendingPathComponent("unreviewed.txt")
    try Data("dirty".utf8).write(to: unreviewed)
    let app = RielaCLIApplication()
    let restore = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--yes", "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(restore.exitCode, .success, restore.stdout + restore.stderr)
    XCTAssertEqual(try String(contentsOf: unreviewed), "dirty")

    let unsafe = await app.run([
      "workflow", "version", "show", "versioned-flow", "../escape",
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertNotEqual(unsafe.exitCode, .success)
  }

  func testRestoreRejectsGenericOverwriteAndForceAliases() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    )
    let app = RielaCLIApplication()
    for alias in ["--overwrite", "--force", "-f"] {
      let response = await app.run([
        "workflow", "restore", "versioned-flow", snapshot.snapshotId,
        "--working-dir", root.path, alias, "--output", "json"
      ])
      XCTAssertEqual(response.exitCode, .success, response.stderr)
      let result = try decodeVersionJSON(WorkflowRestoreCommandResult.self, response.stdout)
      XCTAssertTrue(result.dryRun)
      XCTAssertFalse(result.approved)
      XCTAssertFalse(result.restored)
    }
  }

  func testApprovedRestoreRejectsImmutableProjectWorkflow() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let snapshot = try WorkflowHistoryStore(root: resolved.historyRoot).createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: resolved.identity)
    )
    let response = await RielaCLIApplication().run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--working-dir", root.path, "--yes", "--output", "json"
    ])
    XCTAssertEqual(response.exitCode, .failure)
    XCTAssertTrue(
      (response.stdout + response.stderr).contains(WorkflowRegistryErrorCode.immutableWorkflow.rawValue)
    )
  }

  func testRestoreReportsAndRejectsUnownedPathCollision() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let root = fixture.root
    let resolved = fixture.resolved
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let script = fixture.workflowDirectory.appendingPathComponent("verify.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    let node = try fixture.registeredURL(for: fixture.created.files[1])
    var nodeObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: node)) as? [String: Any])
    nodeObject["promptTemplateFile"] = "verify.sh"
    try JSONSerialization.data(withJSONObject: nodeObject, options: [.prettyPrinted, .sortedKeys]).write(to: node)
    let snapshot = try WorkflowHistoryStore(root: historyRoot).createSnapshot(
      inventory: WorkflowHistoryIdentityResolver.inventory(for: target)
    )
    nodeObject.removeValue(forKey: "promptTemplateFile")
    try JSONSerialization.data(withJSONObject: nodeObject, options: [.prettyPrinted, .sortedKeys]).write(to: node)
    try Data("local-unowned-change".utf8).write(to: script)
    let app = RielaCLIApplication()

    let dryRun = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--output", "json"
    ], environment: fixture.environment)
    XCTAssertEqual(dryRun.exitCode, .success, dryRun.stderr)
    XCTAssertEqual(
      try decodeVersionJSON(WorkflowRestoreCommandResult.self, dryRun.stdout).dirtyConflicts,
      ["verify.sh"]
    )

    let approved = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--scope", "user", "--working-dir", root.path, "--yes", "--output", "json"
    ], environment: fixture.environment)
    XCTAssertNotEqual(approved.exitCode, .success)
    XCTAssertEqual(try String(contentsOf: script), "local-unowned-change")
  }
}
