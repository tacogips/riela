import Foundation
import RielaCore
import RielaSQLite
import XCTest
@testable import RielaCLI

final class RuntimeStoreFirstOpenerAutoVacuumTests: XCTestCase {
  func testCLISessionStoreAsFirstOpenerEnablesIncrementalAutoVacuum() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = makeSession(id: "cli-first-open")
    let record = makeRecord(session: session, root: root)

    try CLIWorkflowSessionStore(rootDirectory: root.path).save(
      record,
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session)
    )

    let canonicalRuntimeRoot = root.resolvingSymlinksInPath()
      .appendingPathComponent("runtime-records", isDirectory: true).path
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: canonicalRuntimeRoot)
    let database = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try database.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "2")
    XCTAssertEqual(try database.query("PRAGMA journal_mode").first?["journal_mode"], "wal")
  }

  func testCLISessionStoreLeavesExistingNoneDatabaseUnchanged() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let canonicalRuntimeRoot = root.resolvingSymlinksInPath()
      .appendingPathComponent("runtime-records", isDirectory: true).path
    let path = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: canonicalRuntimeRoot)
    let existing = try SQLiteDatabase.open(path: path, options: .writableDefault)
    try existing.execute("CREATE TABLE preexisting (id INTEGER PRIMARY KEY)")
    let session = makeSession(id: "cli-existing")

    try CLIWorkflowSessionStore(rootDirectory: root.path).save(
      makeRecord(session: session, root: root),
      runtimeSnapshot: WorkflowRuntimePersistenceSnapshot(session: session)
    )

    let reopened = try SQLiteDatabase.open(path: path, mode: .readOnly, options: .readOnlyDefault)
    XCTAssertEqual(try reopened.query("PRAGMA auto_vacuum").first?["auto_vacuum"], "0")
  }

  private func makeRecord(session: WorkflowSession, root: URL) -> PersistedCLIWorkflowSession {
    PersistedCLIWorkflowSession(
      workflowName: session.workflowId,
      session: session,
      resolution: WorkflowResolutionOptions(workflowName: session.workflowId, workingDirectory: root.path)
    )
  }

  private func makeSession(id: String) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return WorkflowSession(
      workflowId: "first-opener", sessionId: id, status: .completed,
      entryStepId: "entry", createdAt: date, updatedAt: date
    )
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-first-opener-\(UUID().uuidString)", isDirectory: true)
  }
}
