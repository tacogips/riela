import Foundation
import RielaMemory
import RielaSQLite
import XCTest
@testable import RielaCore

private protocol VersionedHistoryAdapterProtocol {
  func write(_ value: Int) throws
  func undo() throws -> Int
  func redo() throws -> Int
  func diff(fromStored: Int, toStored: Int) throws -> [String]
  func retainedVersions() throws -> [Int]
  func rowCount() throws -> Int
  func errorCode() -> String
  func normalizedRetainedVersions() throws -> [Int]
}

private struct VersionedHistoryAdapter: VersionedHistoryAdapterProtocol {
  var writeBody: (Int) throws -> Void
  var undoBody: () throws -> Int
  var redoBody: () throws -> Int
  var diffBody: (Int, Int) throws -> [String]
  var retainedVersionsBody: () throws -> [Int]
  var rowCountBody: () throws -> Int
  var errorCodeBody: () -> String
  var fileVersionPin: Int?

  init(
    write: @escaping (Int) throws -> Void,
    undo: @escaping () throws -> Int,
    redo: @escaping () throws -> Int,
    diff: @escaping (Int, Int) throws -> [String],
    retainedVersions: @escaping () throws -> [Int],
    rowCount: @escaping () throws -> Int,
    errorCode: @escaping () -> String,
    fileVersionPin: Int? = nil
  ) {
    writeBody = write; undoBody = undo; redoBody = redo; diffBody = diff
    retainedVersionsBody = retainedVersions; rowCountBody = rowCount
    errorCodeBody = errorCode; self.fileVersionPin = fileVersionPin
  }

  func write(_ value: Int) throws { try writeBody(value) }
  func undo() throws -> Int { try undoBody() }
  func redo() throws -> Int { try redoBody() }
  func diff(fromStored: Int, toStored: Int) throws -> [String] { try diffBody(fromStored, toStored) }
  func retainedVersions() throws -> [Int] { try retainedVersionsBody() }
  func rowCount() throws -> Int { try rowCountBody() }
  func errorCode() -> String { errorCodeBody() }
  func normalizedRetainedVersions() throws -> [Int] {
    try retainedVersions().filter { $0 != fileVersionPin }.sorted()
  }
}

final class VersionedHistoryConformanceTests: XCTestCase {
  private final class Clock: @unchecked Sendable { var now: Date; init(_ now: Date) { self.now = now } }

  func testMemoryAndDefinitionStoresConformForDiffUndoRedoRetentionAndBranching() throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/efficient-history/conformance-\(UUID().uuidString)", isDirectory: true)
    let memoryRoot = root.appendingPathComponent("memory", isDirectory: true)
    let definitionRoot = root.appendingPathComponent("definitions", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let memory = RielaMemoryStore(rootDirectory: memoryRoot.path)
    var memoryRecord = try memory.save(memoryId: "conformance", workflowId: "flow", payload: .object(["value": .number(1)]), historyRetention: 3)
    let clock = Clock(Date(timeIntervalSince1970: 1_700_000_000))
    let definitions = WorkflowDefinitionStore(rootDirectory: definitionRoot.path, defaultHistoryRetention: 3, now: { clock.now })
    var definitionIds: [String] = []
    var memoryBytes: [Data] = []

    for value in 1...6 {
      if value > 1 {
        clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
        memoryRecord = try memory.update(memoryId: "conformance", recordId: memoryRecord.recordId,
          payload: .object(["value": .number(Double(value))]), historyRetention: 3)
      }
      let bytes = try encodedMemoryRecord(memoryRecord)
      memoryBytes.append(bytes)
      let operation: WorkflowDefinitionOperation = .update
      let previous = definitionIds.last
      let write = WorkflowDefinitionWrite(workflowName: "flow", operation: operation, documentData: bytes,
        documentDigest: JSONCanonical.sha256Hex(bytes), sourceDirectory: root.path, sourceScope: "project",
        provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "version \(value)",
        expectedCurrentVersionId: previous, historyRetention: 3, defaultHistoryRetention: 3)
      guard case let .created(version, _) = try definitions.commit(write) else { return XCTFail("expected definition commit") }
      definitionIds.append(version.versionId)
    }

    let memoryHistory = try memory.evolutionHistory(memoryId: "conformance", recordId: memoryRecord.recordId)
    XCTAssertEqual(memoryHistory.map(\.version), [6, 5, 4])
    XCTAssertEqual(try count("memory_history_versions", database: try memory.databasePath(memoryId: "conformance")), 3)
    let definitionDatabase = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: definitionRoot.path)
    XCTAssertEqual(try count("definition_history_versions", database: definitionDatabase), 4)
    let retainedDefinitionIds = Set(try definitions.history(workflowName: "flow").filter(\.retained).map(\.versionId))
    let definitionRetained = try historyVersions(database: definitionDatabase, retainedVersionIds: retainedDefinitionIds)
    XCTAssertEqual(definitionRetained, [1, 4, 5, 6])
    XCTAssertEqual(try count("memory_history_versions", database: try memory.databasePath(memoryId: "conformance")), memoryHistory.map(\.version).count)
    XCTAssertEqual(try count("definition_history_versions", database: definitionDatabase), definitionRetained.count)
    XCTAssertNotNil(try definitions.document(versionId: definitionIds[0])) // the file-version pin survives outside the R=3 window
    XCTAssertThrowsError(try definitions.document(versionId: definitionIds[1]))

    let memoryDiff = try memory.recordDiff(memoryId: "conformance", recordId: memoryRecord.recordId, fromVersion: 4, toVersion: 6)
    let storedBefore = try XCTUnwrap(definitions.document(versionId: definitionIds[3]))
    let storedAfter = try XCTUnwrap(definitions.document(versionId: definitionIds[5]))
    let definitionDiff = WorkflowDefinitionDiff.compute(beforeJSON: storedBefore, afterJSON: storedAfter)
    XCTAssertEqual(Set(memoryDiff.map { "\($0.op) \($0.path)" }), Set(definitionDiff.map { "\($0.op.rawValue) \($0.path)" }))
    XCTAssertEqual(memoryDiff.map { "\($0.op) \($0.path)" }, ["replace /payload/value"])
    XCTAssertEqual(definitionDiff.map(\.op.rawValue), memoryDiff.map(\.op))
    XCTAssertEqual(normalizedDiffKeys(memoryDiff.first), normalizedDiffKeys(definitionDiff.first))
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(memoryDiff.first?.beforeJSON)), definitionDiff.first?.before)
    XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(memoryDiff.first?.afterJSON)), definitionDiff.first?.after)

    var memoryHeadRevision: Int64 = 6
    let memoryAdapter = VersionedHistoryAdapter(
      write: { value in
        memoryRecord = try memory.update(memoryId: "conformance", recordId: memoryRecord.recordId,
          payload: .object(["value": .number(Double(value))]), historyRetention: 3)
        memoryHeadRevision += 1
      },
      undo: {
        let moved = try memory.undoRecord(memoryId: "conformance", recordId: memoryRecord.recordId, expectedHeadVersion: memoryHeadRevision)
        memoryHeadRevision += 1
        return self.memoryValue(moved.record)
      },
      redo: {
        let moved = try memory.redoRecord(memoryId: "conformance", recordId: memoryRecord.recordId, expectedHeadVersion: memoryHeadRevision)
        memoryHeadRevision += 1
        return self.memoryValue(moved.record)
      },
      diff: { from, to in
        try memory.recordDiff(memoryId: "conformance", recordId: memoryRecord.recordId, fromVersion: Int64(from), toVersion: Int64(to))
          .map { "\($0.op) \($0.path)" }
      },
      retainedVersions: { try memory.evolutionHistory(memoryId: "conformance", recordId: memoryRecord.recordId).map { Int($0.version) } },
      rowCount: { try self.count("memory_history_versions", database: memory.databasePath(memoryId: "conformance")) },
      errorCode: {
        do {
          _ = try memory.redoRecord(memoryId: "conformance", recordId: memoryRecord.recordId, expectedHeadVersion: memoryHeadRevision)
          return "unexpected_success"
        } catch let error as VersionedHistoryError { return error == .nothingToRedo ? "nothing_to_redo" : "\(error)" } catch {
          return "unexpected_error: \(error)"
        }
      },
    )
    let definitionAdapter = VersionedHistoryAdapter(
      write: { value in
        clock.now = clock.now.addingTimeInterval(25 * 60 * 60)
        var branchRecord = memoryRecord
        branchRecord.payload = .object(["value": .number(Double(value))])
        let data = try self.encodedMemoryRecord(branchRecord)
        let head = try XCTUnwrap(definitions.head(workflowName: "flow"))
        guard case .created = try definitions.commit(WorkflowDefinitionWrite(workflowName: "flow", operation: .update,
          documentData: data, documentDigest: JSONCanonical.sha256Hex(data), sourceDirectory: root.path,
          sourceScope: "project", provenance: "test", actor: WorkflowDefinitionActor(kind: .user), reason: "branch write",
          expectedCurrentVersionId: head.currentVersionId, historyRetention: 3, defaultHistoryRetention: 3)) else {
          throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "expected branch commit")
        }
      },
      undo: {
        let head = try XCTUnwrap(definitions.head(workflowName: "flow"))
        guard case let .created(version, _) = try definitions.moveHead(workflowName: "flow", direction: .undo,
          reason: "undo", expectedRevision: Int64(head.revision), expectedVersionId: head.currentVersionId,
          evidence: [], actorKind: "user", actorId: nil),
          let data = try definitions.document(versionId: version.versionId) else { throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "undo failed") }
        return self.memoryValue(try JSONDecoder().decode(MemoryRecord.self, from: data))
      },
      redo: {
        let head = try XCTUnwrap(definitions.head(workflowName: "flow"))
        guard case let .created(version, _) = try definitions.moveHead(workflowName: "flow", direction: .redo,
          reason: "redo", expectedRevision: Int64(head.revision), expectedVersionId: head.currentVersionId,
          evidence: [], actorKind: "user", actorId: nil),
          let data = try definitions.document(versionId: version.versionId) else { throw WorkflowDefinitionStoreError(code: .storeUnavailable, message: "redo failed") }
        return self.memoryValue(try JSONDecoder().decode(MemoryRecord.self, from: data))
      },
      diff: { from, to in
        let before = try XCTUnwrap(definitions.document(versionId: definitionIds[from - 1]))
        let after = try XCTUnwrap(definitions.document(versionId: definitionIds[to - 1]))
        return WorkflowDefinitionDiff.compute(beforeJSON: before, afterJSON: after).map { "\($0.op.rawValue) \($0.path)" }
      },
      retainedVersions: {
        let retainedIds = Set(try definitions.history(workflowName: "flow").filter(\.retained).map(\.versionId))
        return try self.historyVersions(database: definitionDatabase, retainedVersionIds: retainedIds)
      },
      rowCount: { try self.count("definition_history_versions", database: definitionDatabase) },
      errorCode: {
        do {
          let head = try XCTUnwrap(definitions.head(workflowName: "flow"))
          _ = try definitions.moveHead(workflowName: "flow", direction: .redo, reason: "redo dropped branch",
            expectedRevision: Int64(head.revision), expectedVersionId: head.currentVersionId,
            evidence: [], actorKind: "user", actorId: nil)
          return "unexpected_success"
        } catch let error as WorkflowDefinitionStoreError { return error.code.rawValue } catch {
          return "unexpected_error: \(error)"
        }
      },
      fileVersionPin: 1
    )
    for adapter in [memoryAdapter, definitionAdapter] {
      XCTAssertEqual(try adapter.diff(fromStored: 4, toStored: 6), ["replace /payload/value"])
      XCTAssertEqual(try adapter.undo(), 5)
      XCTAssertEqual(try adapter.redo(), 6)
      XCTAssertEqual(try adapter.undo(), 5)
      try adapter.write(99)
      XCTAssertEqual(adapter.errorCode(), "nothing_to_redo")
      XCTAssertEqual(try adapter.normalizedRetainedVersions(), [4, 5, 10])
      XCTAssertEqual(try adapter.rowCount(), try adapter.retainedVersions().count)
    }
  }

  private func encodedMemoryRecord(_ record: MemoryRecord) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(record)
  }

  private func memoryValue(_ record: MemoryRecord) -> Int {
    guard case let .object(payload) = record.payload, case let .number(value)? = payload["value"] else { return -1 }
    return Int(value)
  }

  private func count(_ table: String, database path: String) throws -> Int {
    let db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    return Int(try XCTUnwrap(db.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
  }

  private func historyVersions(database path: String, retainedVersionIds: Set<String>) throws -> [Int] {
    let db = try SQLiteDatabase.open(path: path, mode: .strictReadOnly, options: .readOnlyDefault)
    guard !retainedVersionIds.isEmpty else { return [] }
    return try db.query("SELECT version_id, history_version FROM definition_versions ORDER BY history_version")
      .compactMap { row in
        guard let versionId = row["version_id"], retainedVersionIds.contains(versionId) else { return nil }
        return row["history_version"].flatMap(Int.init)
      }
  }

  private func normalizedDiffKeys(_ entry: VersionedHistoryDiffEntry?) -> Set<String> {
    guard let entry else { return [] }
    var keys: Set<String> = ["path", "op"]
    if entry.beforeJSON != nil { keys.insert("before") }
    if entry.afterJSON != nil { keys.insert("after") }
    return keys
  }

  private func normalizedDiffKeys(_ entry: WorkflowDefinitionDiffEntry?) -> Set<String> {
    guard let entry else { return [] }
    var keys: Set<String> = ["path", "op"]
    if entry.before != nil { keys.insert("before") }
    if entry.after != nil { keys.insert("after") }
    return keys
  }
}
