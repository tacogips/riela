import Foundation
import XCTest
@testable import RielaCLI
@testable import RielaCore

final class WorkflowVersionContentDiffTests: XCTestCase {
  func testUnifiedTextAndMissingSides() {
    let diff = WorkflowUnifiedDiff.render(path: "prompt.txt", before: Data("one\ntwo\nthree\n".utf8),
      after: Data("one\nchanged\nthree\n".utf8))
    XCTAssertEqual(diff.unified, "--- a/prompt.txt\n+++ b/prompt.txt\n@@ -1,3 +1,3 @@\n one\n-two\n+changed\n three\n")
    XCTAssertEqual(WorkflowUnifiedDiff.render(path: "x", before: nil, after: Data("added\n".utf8)).unified,
      "--- a/x\n+++ b/x\n@@ -0,0 +1,1 @@\n+added\n")
    XCTAssertEqual(WorkflowUnifiedDiff.render(path: "x", before: Data("removed\n".utf8), after: nil).unified,
      "--- a/x\n+++ b/x\n@@ -1,1 +0,0 @@\n-removed\n")
    XCTAssertNil(WorkflowUnifiedDiff.render(path: "x", before: Data("same".utf8), after: Data("same".utf8)).unified)
    XCTAssertTrue(WorkflowUnifiedDiff.render(path: "x", before: Data("a".utf8), after: Data("a\n".utf8))
      .unified?.contains("\\ No newline at end of file") == true)
    XCTAssertTrue(WorkflowUnifiedDiff.render(path: "x", before: Data("é\n".utf8), after: Data("e\u{301}\n".utf8))
      .unified?.contains("-é") == true)
    let before = (0..<12).map(String.init).joined(separator: "\n") + "\n"
    var lines = (0..<12).map(String.init)
    lines[0] = "first"
    lines[11] = "last"
    let separated = WorkflowUnifiedDiff.render(path: "x", before: Data(before.utf8),
      after: Data((lines.joined(separator: "\n") + "\n").utf8)).unified ?? ""
    XCTAssertEqual(separated.components(separatedBy: "@@ -").count - 1, 2)
  }

  func testBinaryLargeAndWireShapes() throws {
    let binary = WorkflowUnifiedDiff.render(path: "x", before: Data([0]), after: nil)
    XCTAssertTrue(binary.binary)
    XCTAssertNil(binary.unified)
    let large = WorkflowUnifiedDiff.render(path: "x", before: Data(repeating: 65, count: 300 * 1_024), after: nil)
    XCTAssertTrue(large.tooLarge)
    XCTAssertEqual(large.limitBytes, 262_144)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    XCTAssertEqual(String(data: try encoder.encode(binary), encoding: .utf8), "{\"binary\":true}")
    XCTAssertEqual(String(data: try encoder.encode(large), encoding: .utf8), "{\"limitBytes\":262144,\"tooLarge\":true}")
  }

  func testSnapshotParentSkipsForeignOwner() async throws {
    let (root, _) = try await makeWorkflowVersioningFixture(self)
    let target = try resolveVersioningTarget(root: root).identity
    let store = WorkflowHistoryStore(root: root.appendingPathComponent("mixed-history"))
    let original = try WorkflowHistoryIdentityResolver.inventory(for: target)
    _ = try store.createSnapshot(inventory: original, snapshotId: "owner-a", now: Date(timeIntervalSince1970: 1))
    try FileManager.default.createDirectory(at: store.root.appendingPathComponent("snapshots/broken"),
      withIntermediateDirectories: true)
    var other = original
    other.target.workflowDirectory = root.appendingPathComponent("other").path
    other.target.ownershipRoot = other.target.workflowDirectory
    other.bundleDigest = try WorkflowHistoryCanonicalCoding.bundleDigest(target: other.target, files: other.files.map(\.metadata))
    let first = try store.createSnapshot(inventory: other, snapshotId: "owner-b-1", now: Date(timeIntervalSince1970: 2))
    XCTAssertNil(first.parentSnapshotId)
    let second = try store.createSnapshot(inventory: other, snapshotId: "owner-b-2", now: Date(timeIntervalSince1970: 3))
    XCTAssertEqual(second.parentSnapshotId, first.snapshotId)
    let tied = try store.createSnapshot(inventory: other, snapshotId: "owner-b-3", now: Date(timeIntervalSince1970: 3))
    XCTAssertEqual(tied.parentSnapshotId, second.snapshotId)
    let afterTie = try store.createSnapshot(inventory: other, snapshotId: "owner-b-4", now: Date(timeIntervalSince1970: 4))
    XCTAssertEqual(afterTie.parentSnapshotId, tied.snapshotId)
    XCTAssertThrowsError(try store.list(expectedIdentity: other.target))
  }

  func testSnapshotsAndCLIContentAndReason() async throws {
    let fixture = try await makeMutableWorkflowVersioningFixture(self)
    let store = WorkflowHistoryStore(root: fixture.resolved.historyRoot)
    let target = fixture.resolved.identity
    let inventory = try WorkflowHistoryIdentityResolver.inventory(for: target)
    let isolated = WorkflowHistoryStore(root: fixture.root.appendingPathComponent("isolated-history"))
    XCTAssertNil(try isolated.createSnapshot(inventory: inventory, snapshotId: "only").parentSnapshotId)
    let first = try store.createSnapshot(inventory: inventory,
      snapshotId: "first", now: Date(timeIntervalSince1970: 4_000_000_000))
    let node = try fixture.registeredURL(for: fixture.created.files[1])
    let original = try Data(contentsOf: node)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    let modeDiff = await RielaCLIApplication().run(["workflow", "version", "diff", "versioned-flow", "first", "current",
      "--scope", "user", "--working-dir", fixture.root.path, "--content", "--output", "json"], environment: fixture.environment)
    XCTAssertEqual(modeDiff.exitCode, .success, modeDiff.stderr)
    let modeResult = try decodeVersionJSON(WorkflowVersionDiffCommandResult.self, modeDiff.stdout)
    XCTAssertEqual(modeResult.differences.first?.kind, .executableBitOnly)
    XCTAssertNil(modeResult.differences.first?.content)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: node.path)
    var modified = original
    modified.append(Data("\n".utf8))
    try modified.write(to: node)
    let second = try store.createSnapshot(inventory: WorkflowHistoryIdentityResolver.inventory(for: target),
      snapshotId: "second", now: Date(timeIntervalSince1970: 4_000_000_001))
    XCTAssertEqual(second.parentSnapshotId, first.snapshotId)
    XCTAssertEqual(try store.list(expectedIdentity: target).first?.parentSnapshotId, first.snapshotId)
    let file = try XCTUnwrap(first.files.first { $0.relativePath.hasSuffix(node.lastPathComponent) })
    XCTAssertEqual(try store.objectBytes(snapshot: first, relativePath: file.relativePath), original)
    XCTAssertThrowsError(try store.objectBytes(snapshot: first, relativePath: "missing"))
    let app = RielaCLIApplication()
    let base = ["workflow", "version", "diff", "versioned-flow", "first", "second", "--scope", "user",
      "--working-dir", fixture.root.path, "--output", "json"]
    let plain = await app.run(base, environment: fixture.environment)
    XCTAssertEqual(plain.exitCode, .success, plain.stderr)
    XCTAssertFalse(plain.stdout.contains("\"content\""))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let golden = WorkflowVersionDifference(relativePath: "x", kind: .added, from: nil, to: nil)
    XCTAssertEqual(String(data: try encoder.encode(golden), encoding: .utf8), "{\"kind\":\"added\",\"relativePath\":\"x\"}")
    let content = await app.run(base + ["--content"], environment: fixture.environment)
    XCTAssertEqual(content.exitCode, .success, content.stderr)
    let result = try decodeVersionJSON(WorkflowVersionDiffCommandResult.self, content.stdout)
    XCTAssertNotNil(result.differences.first?.content?.unified)
    let text = await app.run(Array(base.dropLast(2)) + ["--content", "--output", "text"], environment: fixture.environment)
    XCTAssertEqual(text.exitCode, .success, text.stderr)
    XCTAssertTrue(text.stdout.contains("--- a/"))
    let restore = await app.run(["workflow", "restore", "versioned-flow", "first", "--scope", "user",
      "--working-dir", fixture.root.path, "--yes", "--reason", "restore test", "--output", "json"],
      environment: fixture.environment)
    XCTAssertEqual(restore.exitCode, .success, restore.stderr)
    XCTAssertEqual(try decodeVersionJSON(WorkflowRestoreCommandResult.self, restore.stdout).reason, "restore test")
    let blank = await app.run(["workflow", "restore", "versioned-flow", "first", "--scope", "user",
      "--working-dir", fixture.root.path, "--reason", "  "], environment: fixture.environment)
    XCTAssertEqual(blank.exitCode, .usage)
  }
}
