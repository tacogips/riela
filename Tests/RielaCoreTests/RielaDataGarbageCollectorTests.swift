import Foundation
import XCTest
@testable import RielaCore

final class RielaDataGarbageCollectorTests: XCTestCase {
  func testCollectRemovesOnlyGeneratedEntriesOlderThanCutoff() throws {
    let home = try makeRoot()
    let rielaRoot = home.appendingPathComponent(".riela", isDirectory: true)
    let oldSnapshot = rielaRoot.appendingPathComponent(
      "workflow-history/demo/snapshots/snapshot-old",
      isDirectory: true
    )
    let oldReceipt = rielaRoot.appendingPathComponent("events/receipts/receipt-old.json")
    let oldArtifact = rielaRoot.appendingPathComponent("artifacts/old-run/output.txt")
    let oldLog = rielaRoot.appendingPathComponent("logs/old-run.jsonl")
    let workflow = rielaRoot.appendingPathComponent("workflows/demo/workflow.json")
    let generatedFiles = [
      oldSnapshot.appendingPathComponent("manifest.json"),
      oldReceipt,
      oldArtifact,
      oldLog
    ]
    for file in [workflow] + generatedFiles {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("test".utf8).write(to: file)
    }
    let oldDate = Date(timeIntervalSince1970: 1_000)
    for file in generatedFiles {
      try setModificationDate(oldDate, for: file)
    }
    try setModificationDate(oldDate, for: oldSnapshot)
    try setModificationDate(oldDate, for: oldArtifact.deletingLastPathComponent())
    try setModificationDate(oldDate, for: oldReceipt)

    let report = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home,
      now: Date(timeIntervalSince1970: 2_000_000)
    )

    XCTAssertTrue(report.enabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldSnapshot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldReceipt.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldArtifact.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: oldLog.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: workflow.path))
  }

  func testCollectPreservesOldDirectoryContainingRecentlyUpdatedRuntimeData() throws {
    let home = try makeRoot()
    let runtimeDirectory = home.appendingPathComponent(".riela/sessions/runtime-records/active-session")
    let recentLog = runtimeDirectory.appendingPathComponent("log.jsonl")
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
    try Data("recent".utf8).write(to: recentLog)
    try setModificationDate(Date(timeIntervalSince1970: 1_000), for: runtimeDirectory)

    _ = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home,
      now: Date()
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: recentLog.path))
  }

  func testDisabledCollectionDoesNotChangeStorage() throws {
    let home = try makeRoot()
    let session = home.appendingPathComponent(".riela/sessions/old-session.json")
    try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("test".utf8).write(to: session)
    try setModificationDate(Date(timeIntervalSince1970: 1_000), for: session)

    let report = RielaDataGarbageCollector().collect(
      retentionDays: nil,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home,
      now: Date(timeIntervalSince1970: 2_000_000)
    )

    XCTAssertFalse(report.enabled)
    XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
  }

  func testAgeOnlyCollectionPreservesRuntimeSnapshotsForScopedRetention() throws {
    let home = try makeRoot()
    let runtimeRoot = home.appendingPathComponent(".riela/sessions/runtime-records", isDirectory: true)
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
    let oldDate = Date(timeIntervalSince1970: 1_000)
    let newDate = Date(timeIntervalSince1970: 2_000_000)
    let oldSession = WorkflowSession(
      workflowId: "demo",
      sessionId: "old-session",
      status: .completed,
      entryStepId: "start",
      createdAt: oldDate,
      updatedAt: oldDate
    )
    let newSession = WorkflowSession(
      workflowId: "demo",
      sessionId: "new-session",
      status: .completed,
      entryStepId: "start",
      createdAt: newDate,
      updatedAt: newDate
    )
    try store.save(WorkflowRuntimePersistenceSnapshot(session: oldSession))
    try store.save(WorkflowRuntimePersistenceSnapshot(session: newSession))

    let report = RielaDataGarbageCollector().collect(
      retentionDays: 7,
      scope: .user,
      homeDirectory: home,
      projectDirectory: home,
      now: newDate
    )

    XCTAssertEqual(report.removedSessionCount, 0)
    XCTAssertEqual(try store.load(sessionId: oldSession.sessionId).session, oldSession)
    XCTAssertEqual(try store.load(sessionId: newSession.sessionId).session, newSession)
  }

  func testReadOnlySnapshotAndExternalSymlink() throws {
    let home = try makeRoot()
    let snapshot = home.appendingPathComponent(".riela/workflow-history/demo/snapshots/registry-before-x")
    let subdirectory = snapshot.appendingPathComponent("nested")
    let outside = home.appendingPathComponent("outside")
    let manager = FileManager.default
    try manager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
    try manager.createDirectory(at: outside, withIntermediateDirectories: true)
    let file = subdirectory.appendingPathComponent("file")
    let outsideFile = outside.appendingPathComponent("keep")
    try Data("test".utf8).write(to: file)
    try Data("keep".utf8).write(to: outsideFile)
    try manager.createSymbolicLink(at: snapshot.appendingPathComponent("link"), withDestinationURL: outside)
    for url in [file, subdirectory, snapshot] { try setModificationDate(Date(timeIntervalSince1970: 1_000), for: url) }
    for url in [snapshot, subdirectory, outside] { try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path) }
    try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path) }
    let collector = RielaDataGarbageCollector()
    let dry = collector.collect(retentionDays: 1, scope: .user, homeDirectory: home, projectDirectory: home,
      dryRun: true, now: Date(timeIntervalSince1970: 2_000_000))
    XCTAssertTrue(dry.warnings.isEmpty)
    XCTAssertEqual((try manager.attributesOfItem(atPath: snapshot.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
    let report = collector.collect(retentionDays: 1, scope: .user, homeDirectory: home, projectDirectory: home,
      now: Date(timeIntervalSince1970: 2_000_000))
    XCTAssertTrue(report.warnings.isEmpty)
    XCTAssertTrue(report.diagnostics.isEmpty)
    XCTAssertFalse(manager.fileExists(atPath: snapshot.path))
    XCTAssertTrue(manager.fileExists(atPath: outsideFile.path))
    XCTAssertEqual((try manager.attributesOfItem(atPath: outside.path)[.posixPermissions] as? NSNumber)?.intValue, 0o555)
  }

  func testUnremovableSnapshotIsWarningAndOtherEntriesAreRemoved() throws {
    let home = try makeRoot()
    let manager = FileManager.default
    let parent = home.appendingPathComponent(".riela/workflow-history/one/snapshots")
    let blocked = parent.appendingPathComponent("old")
    let other = home.appendingPathComponent(".riela/workflow-history/two/snapshots/old")
    for url in [blocked, other] {
      try manager.createDirectory(at: url, withIntermediateDirectories: true)
      try setModificationDate(Date(timeIntervalSince1970: 1_000), for: url)
    }
    try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
    defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
    let report = RielaDataGarbageCollector().collect(retentionDays: 1, scope: .user, homeDirectory: home,
      projectDirectory: home, now: Date(timeIntervalSince1970: 2_000_000))
    XCTAssertEqual(report.warnings.count, 1)
    XCTAssertTrue(report.warnings.first?.contains(blocked.path) == true)
    XCTAssertTrue(report.diagnostics.isEmpty)
    XCTAssertFalse(manager.fileExists(atPath: other.path))
  }

  private var roots: [URL] = []

  override func tearDown() {
    for root in roots.reversed() {
      try? FileManager.default.removeItem(at: root)
    }
    roots = []
    super.tearDown()
  }

  private func makeRoot() throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/riela-gc-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    roots.append(root)
    return root
  }

  private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }
}
