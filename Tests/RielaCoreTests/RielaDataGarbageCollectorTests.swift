import Foundation
import XCTest
@testable import RielaCore

final class RielaDataGarbageCollectorTests: XCTestCase {
  func testConfigurationDefaultsToDisabledAndSupportsEnvironmentOverride() throws {
    let home = try makeRoot()

    XCTAssertNil(try RielaGarbageCollectionConfiguration.load(
      homeDirectory: home,
      environment: [:]
    ).gc.retentionDays)
    XCTAssertEqual(try RielaGarbageCollectionConfiguration.load(
      homeDirectory: home,
      environment: ["RIELA_GC_RETENTION_DAYS": "14"]
    ).gc.retentionDays, 14)
  }

  func testConfigurationFileEnablesRetention() throws {
    let home = try makeRoot()
    let configurationURL = home.appendingPathComponent(".riela/config.json")
    try FileManager.default.createDirectory(
      at: configurationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(#"{"gc":{"retentionDays":30}}"#.utf8).write(to: configurationURL)

    let configuration = try RielaGarbageCollectionConfiguration.load(
      homeDirectory: home,
      environment: [:]
    )

    XCTAssertEqual(configuration.gc.retentionDays, 30)
  }

  func testCollectRemovesOnlyGeneratedEntriesOlderThanCutoff() throws {
    let home = try makeRoot()
    let rielaRoot = home.appendingPathComponent(".riela", isDirectory: true)
    let sessions = rielaRoot.appendingPathComponent("sessions", isDirectory: true)
    let oldSession = sessions.appendingPathComponent("old-session.json")
    let newSession = sessions.appendingPathComponent("new-session.json")
    let oldRuntime = sessions.appendingPathComponent("runtime-records/old-session", isDirectory: true)
    let oldSnapshot = rielaRoot.appendingPathComponent(
      "workflow-history/demo/snapshots/snapshot-old",
      isDirectory: true
    )
    let oldReceipt = rielaRoot.appendingPathComponent("events/receipts/receipt-old.json")
    let oldArtifact = rielaRoot.appendingPathComponent("artifacts/old-run/output.txt")
    let oldLog = rielaRoot.appendingPathComponent("logs/old-run.jsonl")
    let workflow = rielaRoot.appendingPathComponent("workflows/demo/workflow.json")
    let generatedFiles = [
      oldRuntime.appendingPathComponent("log.txt"),
      oldSnapshot.appendingPathComponent("manifest.json"),
      oldReceipt,
      oldArtifact,
      oldLog
    ]
    for file in [oldSession, newSession, workflow] + generatedFiles {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("test".utf8).write(to: file)
    }
    let oldDate = Date(timeIntervalSince1970: 1_000)
    try setModificationDate(oldDate, for: oldSession)
    for file in generatedFiles {
      try setModificationDate(oldDate, for: file)
    }
    try setModificationDate(oldDate, for: oldRuntime)
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
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldSession.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldRuntime.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldSnapshot.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldReceipt.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldArtifact.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: oldLog.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: newSession.path))
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

  func testCollectRemovesExpiredSQLiteRuntimeSnapshots() throws {
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

    XCTAssertEqual(report.removedSessionCount, 1)
    XCTAssertThrowsError(try store.load(sessionId: oldSession.sessionId))
    XCTAssertEqual(try store.load(sessionId: newSession.sessionId).session, newSession)
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
