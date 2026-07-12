import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowVersionCommandsTests: XCTestCase {
  func testListShowDiffDryRunAndApprovedRestorePreserveExecutableBits() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let script = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("verify.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let node = URL(fileURLWithPath: created.files[1])
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

    let list = await app.run(["workflow", "versions", "versioned-flow", "--working-dir", root.path, "--output", "json"])
    XCTAssertEqual(list.exitCode, .success, list.stderr)
    let listed = try decodeVersionJSON(WorkflowVersionsCommandResult.self, list.stdout).snapshots.first
    XCTAssertEqual(listed?.snapshotId, snapshot.snapshotId)
    XCTAssertEqual(listed?.sourceKind, .authoredWorkflow)
    XCTAssertEqual(listed?.retentionClass, "standard")
    XCTAssertEqual(listed?.redactionStatus, "not-required")
    XCTAssertEqual(listed?.integrityAlgorithm, "sha256")
    XCTAssertTrue(listed?.integrityVerified == true)

    let show = await app.run(["workflow", "version", "show", "versioned-flow", snapshot.snapshotId, "--working-dir", root.path, "--output", "json"])
    XCTAssertEqual(show.exitCode, .success, show.stderr)
    XCTAssertTrue(try decodeVersionJSON(WorkflowVersionShowCommandResult.self, show.stdout).integrityVerified)

    let diff = await app.run(["workflow", "version", "diff", "versioned-flow", snapshot.snapshotId, "current", "--working-dir", root.path, "--output", "json"])
    XCTAssertEqual(diff.exitCode, .success, diff.stderr)
    XCTAssertEqual(try decodeVersionJSON(WorkflowVersionDiffCommandResult.self, diff.stdout).differences.first?.kind, .executableBitOnly)

    let dryRun = await app.run(["workflow", "restore", "versioned-flow", snapshot.snapshotId, "--working-dir", root.path, "--output", "json"])
    XCTAssertEqual(dryRun.exitCode, .success, dryRun.stderr)
    let dryResult = try decodeVersionJSON(WorkflowRestoreCommandResult.self, dryRun.stdout)
    XCTAssertTrue(dryResult.dryRun)
    XCTAssertFalse(dryResult.restored)
    XCTAssertNil(dryResult.preRestoreSnapshotId)

    let restore = await app.run(["workflow", "restore", "versioned-flow", snapshot.snapshotId, "--working-dir", root.path, "--yes", "--output", "json"])
    XCTAssertEqual(restore.exitCode, .success, restore.stderr)
    XCTAssertTrue(try decodeVersionJSON(WorkflowRestoreCommandResult.self, restore.stdout).restored)
    let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? NSNumber
    XCTAssertNotEqual((mode?.intValue ?? 0) & 0o111, 0)
    let postRestoreShow = await app.run([
      "workflow", "version", "show", "versioned-flow", snapshot.snapshotId,
      "--working-dir", root.path, "--output", "json"
    ])
    let shown = try decodeVersionJSON(WorkflowVersionShowCommandResult.self, postRestoreShow.stdout)
    XCTAssertEqual(shown.restoreReferences.count, 2)
  }

  func testRestoreRejectsUnsafeSnapshotIdAndPreservesUnownedRegularFile() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let store = WorkflowHistoryStore(root: historyRoot)
    let snapshot = try store.createSnapshot(inventory: WorkflowHistoryIdentityResolver.inventory(for: target))
    try Data("dirty".utf8).write(to: URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("unreviewed.txt"))
    let app = RielaCLIApplication()
    let restore = await app.run(["workflow", "restore", "versioned-flow", snapshot.snapshotId, "--working-dir", root.path, "--yes", "--output", "json"])
    XCTAssertEqual(restore.exitCode, .success, restore.stderr)
    XCTAssertEqual(
      try String(contentsOf: URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("unreviewed.txt")),
      "dirty"
    )

    let unsafe = await app.run(["workflow", "version", "show", "versioned-flow", "../escape", "--working-dir", root.path, "--output", "json"])
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

  func testRestoreReportsAndRejectsUnownedPathCollision() async throws {
    let (root, created) = try await makeWorkflowVersioningFixture(self)
    let resolved = try resolveVersioningTarget(root: root)
    let (target, historyRoot) = (resolved.identity, resolved.historyRoot)
    let script = URL(fileURLWithPath: created.workflowDirectory).appendingPathComponent("verify.sh")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
    let node = URL(fileURLWithPath: created.files[1])
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
      "--working-dir", root.path, "--output", "json"
    ])
    XCTAssertEqual(dryRun.exitCode, .success, dryRun.stderr)
    XCTAssertEqual(
      try decodeVersionJSON(WorkflowRestoreCommandResult.self, dryRun.stdout).dirtyConflicts,
      ["verify.sh"]
    )

    let approved = await app.run([
      "workflow", "restore", "versioned-flow", snapshot.snapshotId,
      "--working-dir", root.path, "--yes", "--output", "json"
    ])
    XCTAssertNotEqual(approved.exitCode, .success)
    XCTAssertEqual(try String(contentsOf: script), "local-unowned-change")
  }
}
