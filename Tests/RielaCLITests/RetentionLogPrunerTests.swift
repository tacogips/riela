import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class RetentionLogPrunerTests: XCTestCase {
  func testAgePolicyRemovesOldFilesAndKeepsRecentFiles() throws {
    let (root, now) = try fixture()
    let old = try file("old.jsonl", bytes: 10, age: 20 * 86_400, root: root, now: now)
    let recent = try file("recent.jsonl", bytes: 20, age: 86_400, root: root, now: now)
    let grace = try file("grace.jsonl", bytes: 30, age: 7_200, root: root, now: now)
    let result = pruner(now).run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: 14, maxTotalBytes: nil), dryRun: false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: grace.path))
    XCTAssertEqual(result.report.removedCount, 1)
    XCTAssertEqual(result.report.protected["withinGraceWindow"], 1)
  }

  func testByteCapRemovesOldestUntilUnderCap() throws {
    let (root, now) = try fixture()
    let oldest = try file("a", bytes: 20, age: 10 * 86_400, root: root, now: now)
    let newer = try file("b", bytes: 20, age: 9 * 86_400, root: root, now: now)
    _ = try file("c", bytes: 20, age: 8 * 86_400, root: root, now: now)
    let result = pruner(now).run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: nil, maxTotalBytes: 30), dryRun: false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldest.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: newer.path))
    XCTAssertEqual(result.report.remainingBytes, 20)
    XCTAssertEqual(result.report.capAchieved, true)
  }

  func testSymlinkDirectoryAndHiddenFileAreProtected() throws {
    let (root, now) = try fixture()
    let external = root.deletingLastPathComponent().appendingPathComponent("external-\(UUID().uuidString)")
    try Data(repeating: 1, count: 10).write(to: external)
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
    let hidden = try file(".hidden", bytes: 10, age: 20 * 86_400, root: root, now: now)
    let directory = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let result = pruner(now).run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: 14, maxTotalBytes: nil), dryRun: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: external.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: hidden.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    XCTAssertEqual(result.report.protected["symlink"], 1)
    XCTAssertEqual(result.report.protected["notRegularFile"], 1)
    XCTAssertEqual(result.report.protected["hidden"], 1)
  }

  func testDryRunReportsSelectionWithoutDeleting() throws {
    let (root, now) = try fixture()
    let old = try file("old", bytes: 10, age: 20 * 86_400, root: root, now: now)
    let result = pruner(now).run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: 14, maxTotalBytes: nil), dryRun: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    XCTAssertEqual(result.report.selectedCount, 1)
    XCTAssertEqual(result.report.removedCount, 0)
  }

  func testKeepForeverIsInactive() throws {
    let (root, now) = try fixture()
    let old = try file("old", bytes: 10, age: 20 * 86_400, root: root, now: now)
    let result = pruner(now).run(logsRoot: root.path, state: .keepForever,
      policy: nil, dryRun: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    XCTAssertEqual(result.report.state, .keepForever)
    XCTAssertEqual(result.report.removedCount, 0)
  }

  func testChangedFileIsNotUnlinked() throws {
    let (root, now) = try fixture()
    let old = try file("old", bytes: 10, age: 20 * 86_400, root: root, now: now)
    var changed = false
    let pruner = RetentionLogPruner(now: { now }, beforeUnlink: { path in
      guard !changed else { return }
      changed = true
      try? Data(repeating: 2, count: 11).write(to: URL(fileURLWithPath: path))
      try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-20 * 86_400)],
        ofItemAtPath: path)
    })
    let result = pruner.run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: 14, maxTotalBytes: nil), dryRun: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
    XCTAssertEqual(result.report.protected["changedDuringAdmission"], 1)
    XCTAssertEqual(result.report.removedCount, 0)
  }

  func testRemovalLimitIsReported() throws {
    let (root, now) = try fixture()
    _ = try file("a", bytes: 10, age: 20 * 86_400, root: root, now: now)
    _ = try file("b", bytes: 10, age: 19 * 86_400, root: root, now: now)
    let result = pruner(now).run(logsRoot: root.path, state: .active,
      policy: RetentionPolicySnapshot(maxAgeDays: 14, maxTotalBytes: nil), dryRun: true, removalLimit: 1)
    XCTAssertEqual(result.report.selectedCount, 1)
    XCTAssertTrue(result.report.workLimitReached)
  }

  private func fixture() throws -> (URL, Date) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/automatic-retention-log-tests/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (root, Date(timeIntervalSince1970: 1_800_000_000))
  }

  private func file(_ name: String, bytes: Int, age: TimeInterval, root: URL, now: Date) throws -> URL {
    let url = root.appendingPathComponent(name)
    try Data(repeating: 1, count: bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
    return url
  }

  private func pruner(_ now: Date) -> RetentionLogPruner { RetentionLogPruner(now: { now }) }
}
