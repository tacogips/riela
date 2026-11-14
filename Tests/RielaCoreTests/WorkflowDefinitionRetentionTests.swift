import Foundation
import RielaSQLite
import XCTest
@testable import RielaCore

final class WorkflowDefinitionRetentionTests: XCTestCase {
  func testPruneKeepsNewestAndProtectedVersionsAndRecordsTheRemoval() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let versions = try commitChain(store, count: 5)
    try saveSession(root, id: "active", status: .running, pinned: versions[1])
    try saveSession(root, id: "done", status: .completed, pinned: versions[2])
    let before = try rawCounts(root)

    let preview = try store.prune(workflowName: "workflow", keepVersions: 2, reason: "", actor: actor, dryRun: true)
    XCTAssertEqual(preview.removedVersionIds, [versions[2]])
    XCTAssertNil(preview.audit)
    XCTAssertEqual(try rawCounts(root), before, "a dry run must not change rows")

    let result = try store.prune(workflowName: "workflow", keepVersions: 2, reason: "trim history", actor: actor)
    XCTAssertEqual(result.removedVersionIds, [versions[2]])
    XCTAssertEqual(Set(result.keptVersionIds), Set([versions[0], versions[1], versions[3], versions[4]]))
    XCTAssertEqual(result.protectedVersions.map(\.reason), ["current", "lastFileImport", "activeSession"])
    XCTAssertEqual(result.removedAuditCount, 1)
    XCTAssertEqual(result.removedBlobCount, 1)
    XCTAssertGreaterThan(result.removedBlobBytes, 0)
    XCTAssertNil(try store.version(versionId: versions[2]))
    XCTAssertNotNil(try store.version(versionId: versions[1]))

    let history = try store.history(workflowName: "workflow")
    XCTAssertEqual(history.first?.operation, .prune)
    XCTAssertEqual(history.first?.reason, "trim history")
    XCTAssertEqual(history.first?.versionId, versions[4])
    XCTAssertTrue(history.first?.diff.contains { $0.path == "/versions/\(versions[2])" && $0.op == .remove } == true)
    XCTAssertEqual(history.count, 5)

    XCTAssertEqual(try rawCounts(root), [4, 4, 1, 5])
    let database = try rawDatabase(root)
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_versions WHERE version_id = '\(versions[3])'"))
    XCTAssertThrowsError(try database.execute("DELETE FROM definition_change_audit"))

    let noop = try store.prune(workflowName: "workflow", keepVersions: 2, reason: "again", actor: actor)
    XCTAssertTrue(noop.removedVersionIds.isEmpty)
    XCTAssertNil(noop.audit, "a prune with nothing to remove leaves no audit record")
    XCTAssertEqual(try store.history(workflowName: "workflow").count, 5)
  }

  func testPruneRejectsInvalidInputWithoutWritingRows() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    _ = try commitChain(store, count: 3)
    let before = try rawCounts(root)
    XCTAssertThrowsError(try store.prune(workflowName: "workflow", keepVersions: 0, reason: "x", actor: actor)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .invalidRetention)
    }
    XCTAssertThrowsError(try store.prune(workflowName: "workflow", keepVersions: 1, reason: " ", actor: actor)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .missingReason)
    }
    XCTAssertThrowsError(try store.purgeHistory(workflowName: "missing", reason: "x", actor: actor)) {
      XCTAssertEqual(($0 as? WorkflowDefinitionStoreError)?.code, .headMissing)
    }
    XCTAssertEqual(try rawCounts(root), before)
  }

  func testPurgeHistoryKeepsOnlyProtectedVersionsAndOneAuditRecord() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let versions = try commitChain(store, count: 4)
    XCTAssertNotNil(try store.prune(workflowName: "workflow", keepVersions: 2, reason: "earlier prune", actor: actor).audit)

    let result = try store.purgeHistory(workflowName: "workflow", reason: "start over", actor: actor)
    XCTAssertEqual(Set(result.keptVersionIds), Set([versions[0], versions[3]]))
    XCTAssertEqual(result.removedVersionIds, [versions[2]])
    let history = try store.history(workflowName: "workflow")
    XCTAssertEqual(history.map(\.operation), [.purgeHistory])
    XCTAssertEqual(history.first?.reason, "start over")
    XCTAssertEqual(try store.current(workflowName: "workflow")?.version.versionId, versions[3])
    XCTAssertEqual(try store.head(workflowName: "workflow")?.revision, 4, "retention never moves the head")
    XCTAssertThrowsError(try rawDatabase(root).execute("DELETE FROM definition_change_audit"))
  }

  func testOverwrittenChangeLookupIgnoresRetentionRecords() throws {
    let root = try makeRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkflowDefinitionStore(rootDirectory: root.path)
    let versions = try commitChain(store, count: 4)
    _ = try store.prune(workflowName: "workflow", keepVersions: 2, reason: "trim", actor: actor)
    // the prune record shares the current version id; it must not act as an origin or a change
    let changes = try store.auditRecords(workflowName: "workflow", afterVersionId: versions[0])
    XCTAssertEqual(changes.map(\.versionId), [versions[2], versions[3]])
    XCTAssertTrue(try store.auditRecords(workflowName: "workflow", afterVersionId: versions[3]).isEmpty)
  }

  func testRetentionConfigurationParsesDefinitionKeepVersions() throws {
    let home = try makeRoot()
    defer { try? FileManager.default.removeItem(at: home) }
    let configured = try RielaRetentionConfiguration.load(
      homeDirectory: home, projectDirectory: nil,
      environment: ["RIELA_RETENTION": #"{"definitions":{"keepVersions":20}}"#]
    )
    XCTAssertEqual(configured.userPolicy?.definitions.keepVersions, 20)
    XCTAssertThrowsError(try RielaRetentionConfiguration.load(
      homeDirectory: home, projectDirectory: nil,
      environment: ["RIELA_RETENTION": #"{"definitions":{"keepVersions":0}}"#]
    ))
    XCTAssertThrowsError(try RielaRetentionConfiguration.load(
      homeDirectory: home, projectDirectory: nil,
      environment: ["RIELA_RETENTION": #"{"definitions":{"maxAgeDays":3}}"#]
    ))
  }

  private let actor = WorkflowDefinitionActor(kind: .user, id: "tester")

  /// Seeds then updates the workflow so every version has a distinct blob.
  private func commitChain(_ store: WorkflowDefinitionStore, count: Int) throws -> [String] {
    var ids: [String] = []
    for index in 0..<count {
      let document = Data(#"{"runtime":{"workflow":"example","revision":\#(index)}}"#.utf8)
      let write = WorkflowDefinitionWrite(
        workflowName: "workflow", operation: index == 0 ? .seed : .update, documentData: document,
        documentDigest: JSONCanonical.sha256Hex(document), sourceDirectory: "/workflow", sourceScope: "project",
        provenance: "test", actor: actor, reason: "change \(index)", expectedCurrentVersionId: ids.last
      )
      guard case let .created(version, _) = try store.commit(write) else {
        throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "expected a new version")
      }
      ids.append(version.versionId)
    }
    return ids
  }

  private func saveSession(_ root: URL, id: String, status: WorkflowSessionStatus, pinned versionId: String) throws {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let session = WorkflowSession(
      workflowId: "workflow", sessionId: id, status: status, entryStepId: "entry", createdAt: date, updatedAt: date,
      definitionSource: WorkflowDefinitionSource(kind: .store, workflowName: "workflow", versionId: versionId, digest: "digest")
    )
    try SQLiteWorkflowRuntimePersistenceStore(rootDirectory: root.path).save(WorkflowRuntimePersistenceSnapshot(session: session))
  }

  private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("definition-retention-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func rawDatabase(_ root: URL) throws -> SQLiteDatabase {
    try SQLiteDatabase.open(path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: root.path))
  }

  private func rawCounts(_ root: URL) throws -> [Int] {
    let database = try rawDatabase(root)
    return try ["definition_blobs", "definition_versions", "definition_heads", "definition_change_audit"].map {
      try Int(database.query("SELECT COUNT(*) AS count FROM \($0)").first?.string("count") ?? "0") ?? 0
    }
  }
}
