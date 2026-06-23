import SQLite3
import XCTest
@testable import RielaMemory

final class RielaMemoryTests: XCTestCase {
  func testSaveLoadAndSearchUseOneSQLiteFilePerMemoryId() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "chat-memory",
      workflowId: "telegram-sdk-trio-chat",
      nodeId: "save-chat-event",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("hello yui"), "kind": .string("chat")])
    )
    try store.save(
      memoryId: "chat-memory",
      workflowId: "telegram-sdk-trio-chat",
      nodeId: "save-chat-event",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["text": .string("hello rina"), "kind": .string("chat")])
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: try store.databasePath(memoryId: "chat-memory")))
    XCTAssertEqual(try store.load(memoryId: "chat-memory", workflowId: "telegram-sdk-trio-chat").map(\.registeredAt), [
      "2026-06-20T10:01:00Z",
      "2026-06-20T10:00:00Z"
    ])
    XCTAssertEqual(
      try store.search(
        memoryId: "chat-memory",
        options: MemorySearchOptions(workflowId: "telegram-sdk-trio-chat", matchPatterns: ["rina"])
      ).map(\.payload),
      [.object(["kind": .string("chat"), "text": .string("hello rina")])]
    )
  }

  func testMultipleMatchPatternsMatchAnyPattern() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("memory about yui and mika")])
    )
    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["text": .string("memory about yui only")])
    )
    try store.save(
      memoryId: "persona-1",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:02:00Z",
      payload: .object(["text": .string("memory about rina only")])
    )

    let records = try store.search(
      memoryId: "persona-1",
      options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["mika", "rina"])
    )

    XCTAssertEqual(records.map(\.registeredAt), [
      "2026-06-20T10:02:00Z",
      "2026-06-20T10:00:00Z"
    ])
  }

  func testOpeningLegacyDatabaseMigratesWithoutDeletingRecords() throws {
    let root = temporaryDirectory()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = root.appendingPathComponent("legacy-memory.sqlite")
    try createLegacyMemoryDatabase(at: databaseURL)

    let store = RielaMemoryStore(rootDirectory: root.path)
    let records = try store.load(memoryId: "legacy-memory", workflowId: "wf", limit: 10)

    XCTAssertEqual(records.map(\.recordId), [1])
    XCTAssertEqual(records[0].tags, [])
    XCTAssertEqual(records[0].relatedRecordIds, [])
    XCTAssertEqual(records[0].files, [])
    XCTAssertEqual(records[0].payload, .object(["text": .string("legacy survives")]))

    let saved = try store.save(
      memoryId: "legacy-memory",
      workflowId: "wf",
      tags: ["new"],
      relatedRecordIds: [records[0].recordId],
      payload: .object(["text": .string("new record")])
    )
    XCTAssertEqual(saved.recordId, 2)
  }

  func testMetadataCanDescribeMemoryPurposeAndDataSchema() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    let metadata = try store.registerMetadata(
      memoryId: "persona-summary",
      description: "summaries for each persona",
      purpose: "help nodes decide when persona history should be searched",
      dataSchema: .object([
        "type": .string("object"),
        "required": .array([.string("text")])
      ]),
      updatedAt: "2026-06-20T10:00:00Z"
    )

    XCTAssertEqual(metadata.memoryId, "persona-summary")
    XCTAssertEqual(try store.metadata(memoryId: "persona-summary"), metadata)
  }

  func testUpdateReplacesPayloadTagsAndRelatedIdsForRecord() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    let base = try store.save(
      memoryId: "daily-summary",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      tags: ["date:2026-06-20"],
      payload: .object(["summary": .string("old")])
    )
    let related = try store.save(
      memoryId: "daily-summary",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["summary": .string("source")])
    )

    let updated = try store.update(
      memoryId: "daily-summary",
      recordId: base.recordId,
      workflowId: "wf",
      tags: ["date:2026-06-20", "updated"],
      relatedRecordIds: [related.recordId],
      payload: .object(["summary": .string("new")])
    )

    XCTAssertEqual(updated.recordId, base.recordId)
    XCTAssertEqual(updated.registeredAt, "2026-06-20T10:00:00Z")
    XCTAssertEqual(updated.tags, ["date:2026-06-20", "updated"])
    XCTAssertEqual(updated.relatedRecordIds, [related.recordId])
    XCTAssertEqual(updated.payload, .object(["summary": .string("new")]))
    XCTAssertEqual(
      try store.search(memoryId: "daily-summary", options: MemorySearchOptions(workflowId: "wf", tags: ["updated"]))
        .map(\.recordId),
      [base.recordId]
    )
  }

  func testSaveCopiesFilesAndReturnsFileReferencesFromSearch() throws {
    let root = temporaryDirectory()
    let sourceDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let sourceFile = sourceDirectory.appendingPathComponent("yui.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sourceFile)
    let store = RielaMemoryStore(rootDirectory: root.path)

    let saved = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      files: [MemoryFileReference(path: sourceFile.path, mediaType: "image/png", kind: "image")],
      payload: .object(["text": .string("image memory")])
    )

    XCTAssertEqual(saved.files.count, 1)
    XCTAssertNotEqual(saved.files[0].path, sourceFile.path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved.files[0].path))
    XCTAssertTrue(saved.files[0].path.contains("/files/chat-memory/\(saved.recordId)/"))
    XCTAssertEqual(saved.files[0].mediaType, "image/png")
    XCTAssertEqual(saved.files[0].kind, "image")
    XCTAssertEqual(saved.files[0].name, "yui.png")
    XCTAssertEqual(saved.files[0].sizeBytes, 4)

    let records = try store.search(memoryId: "chat-memory", options: MemorySearchOptions(workflowId: "wf"))
    XCTAssertEqual(records.map(\.files), [saved.files])
  }

  func testSaveInfersCanonicalKindsForCommonFileFamilies() throws {
    let root = temporaryDirectory()
    let sourceDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let image = sourceDirectory.appendingPathComponent("portrait.jpeg")
    let video = sourceDirectory.appendingPathComponent("clip.mp4")
    let audio = sourceDirectory.appendingPathComponent("voice.m4a")
    let pdf = sourceDirectory.appendingPathComponent("brief.pdf")
    try Data([1]).write(to: image)
    try Data([2]).write(to: video)
    try Data([3]).write(to: audio)
    try Data([4]).write(to: pdf)
    let store = RielaMemoryStore(rootDirectory: root.path)

    let saved = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: [
        MemoryFileReference(path: image.path, kind: "photo"),
        MemoryFileReference(path: video.path),
        MemoryFileReference(path: audio.path),
        MemoryFileReference(path: pdf.path, mediaType: " APPLICATION/PDF ", kind: "document")
      ],
      payload: .object(["text": .string("mixed files")])
    )

    XCTAssertEqual(saved.files.map(\.mediaType), ["image/jpeg", "video/mp4", "audio/mp4", "application/pdf"])
    XCTAssertEqual(saved.files.map(\.kind), ["image", "video", "audio", "pdf"])
  }

  func testUpdatePreservesReplacesAndClearsFilesExplicitly() throws {
    let root = temporaryDirectory()
    let sourceDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let firstFile = sourceDirectory.appendingPathComponent("first.png")
    let secondFile = sourceDirectory.appendingPathComponent("second.pdf")
    try Data([1, 2, 3]).write(to: firstFile)
    try Data([4, 5]).write(to: secondFile)
    let store = RielaMemoryStore(rootDirectory: root.path)

    let saved = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: [MemoryFileReference(path: firstFile.path)],
      payload: .object(["text": .string("with first file")])
    )
    let originalStoredPath = try XCTUnwrap(saved.files.first?.path)

    let preserved = try store.update(
      memoryId: "chat-memory",
      recordId: saved.recordId,
      workflowId: "wf",
      payload: .object(["text": .string("preserve file")])
    )
    XCTAssertEqual(preserved.files.map(\.path), [originalStoredPath])
    XCTAssertTrue(FileManager.default.fileExists(atPath: originalStoredPath))

    let replaced = try store.update(
      memoryId: "chat-memory",
      recordId: saved.recordId,
      workflowId: "wf",
      files: [MemoryFileReference(path: secondFile.path)],
      payload: .object(["text": .string("replace file")])
    )
    let replacementStoredPath = try XCTUnwrap(replaced.files.first?.path)
    XCTAssertEqual(replaced.files.map(\.kind), ["pdf"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: replacementStoredPath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: originalStoredPath))

    let cleared = try store.update(
      memoryId: "chat-memory",
      recordId: saved.recordId,
      workflowId: "wf",
      files: [],
      payload: .object(["text": .string("clear file")])
    )
    XCTAssertEqual(cleared.files, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: replacementStoredPath))
  }

  func testFilesMustBeUniqueExistingAndLimited() throws {
    let root = temporaryDirectory()
    let sourceDirectory = temporaryDirectory()
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    let sourceFile = sourceDirectory.appendingPathComponent("voice.mp3")
    try Data([1, 2, 3]).write(to: sourceFile)
    let store = RielaMemoryStore(rootDirectory: root.path)

    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: [
        MemoryFileReference(path: sourceFile.path),
        MemoryFileReference(path: sourceFile.path)
      ],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .duplicateFilePath(sourceFile.path))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: [
        MemoryFileReference(path: sourceFile.path),
        MemoryFileReference(path: sourceDirectory.appendingPathComponent("./voice.mp3").path)
      ],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .duplicateFilePath(sourceFile.path))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: (0..<11).map { MemoryFileReference(path: "\(sourceFile.path)-\($0)") },
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .tooManyFiles(11))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      files: [MemoryFileReference(path: sourceDirectory.appendingPathComponent("missing.pdf").path)],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .invalidFilePath(sourceDirectory.appendingPathComponent("missing.pdf").path))
    }
  }

  func testUpdateRequiresExistingRecord() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    XCTAssertThrowsError(try store.update(
      memoryId: "daily-summary",
      recordId: 999,
      workflowId: "wf",
      payload: .object(["summary": .string("missing")])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .missingRecordId(999))
    }
  }

  func testTagsAndRelatedRecordIdsAreStoredSearchableAndPageableAsUniqueValues() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    let base = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      tags: ["chat", "yui"],
      payload: .object(["text": .string("base memory")])
    )
    try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:01:00Z",
      tags: ["chat", "rina"],
      relatedRecordIds: [base.recordId],
      payload: .object(["text": .string("related memory")])
    )
    try store.save(
      memoryId: "chat-memory",
      workflowId: "other-wf",
      registeredAt: "2026-06-20T10:02:00Z",
      tags: ["other"],
      relatedRecordIds: [base.recordId],
      payload: .object(["text": .string("other workflow memory")])
    )

    XCTAssertEqual(
      try store.search(memoryId: "chat-memory", options: MemorySearchOptions(workflowId: "wf", tags: ["rina"]))
        .map(\.payload),
      [.object(["text": .string("related memory")])]
    )
    XCTAssertEqual(
      try store.search(
        memoryId: "chat-memory",
        options: MemorySearchOptions(workflowId: "wf", relatedRecordIds: [base.recordId])
      ).map(\.tags),
      [["chat", "rina"]]
    )
    XCTAssertEqual(
      try store.uniqueTags(memoryId: "chat-memory", options: MemoryValueListOptions(workflowId: "wf", limit: 2)),
      ["chat", "rina"]
    )
    XCTAssertEqual(
      try store.uniqueTags(
        memoryId: "chat-memory",
        options: MemoryValueListOptions(workflowId: "wf", sortOrder: .valueDesc, limit: 1, offset: 1)
      ),
      ["rina"]
    )
    XCTAssertEqual(
      try store.uniqueRelatedRecordIds(memoryId: "chat-memory", options: MemoryValueListOptions()),
      [base.recordId]
    )
  }

  func testTagsAndRelatedRecordIdsMustBeUniqueAndLimited() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      tags: ["chat", "chat"],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .duplicateTag("chat"))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      tags: (0..<11).map { "tag-\($0)" },
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .tooManyTags(11))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      relatedRecordIds: [1, 1],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .duplicateRelatedRecordId(1))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      relatedRecordIds: Array(1...11).map(Int64.init),
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .tooManyRelatedRecordIds(11))
    }
    XCTAssertThrowsError(try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      relatedRecordIds: [999],
      payload: .object([:])
    )) { error in
      XCTAssertEqual(error as? RielaMemoryError, .missingRelatedRecordId(999))
    }
  }

  func testLoadAndSearchMissingMemoryReturnEmptyResults() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    XCTAssertEqual(try store.load(memoryId: "new-memory", workflowId: "wf"), [])
    XCTAssertEqual(
      try store.search(
        memoryId: "new-memory",
        options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["anything"])
      ),
      []
    )
  }

  func testSearchCanIncludeAllWorkflowsForSharedPersonaMemory() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "rina-shared",
      workflowId: "discord-rina",
      nodeId: "rina",
      payload: .object(["text": .string("discord memory")])
    )
    try store.save(
      memoryId: "rina-shared",
      workflowId: "telegram-rina",
      nodeId: "rina",
      payload: .object(["text": .string("telegram memory")])
    )

    let scoped = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "telegram-rina")
    )
    let shared = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "telegram-rina", includeAllWorkflows: true)
    )

    XCTAssertEqual(scoped.map(\.workflowId), ["telegram-rina"])
    XCTAssertEqual(Set(shared.map(\.workflowId)), ["discord-rina", "telegram-rina"])
  }

  func testConcurrentSavesWaitForSharedMemoryDatabaseLock() async throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          try store.save(
            memoryId: "rina-shared",
            workflowId: "workflow-\(index)",
            nodeId: "rina",
            payload: .object(["index": .number(Double(index))])
          )
        }
      }
      try await group.waitForAll()
    }

    let records = try store.search(
      memoryId: "rina-shared",
      options: MemorySearchOptions(workflowId: "workflow-0", includeAllWorkflows: true, limit: 20)
    )
    XCTAssertEqual(records.count, 8)
  }

  func testLoadAndSearchRecordReturnedMemoryReferences() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    let saved = try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string("remember this")])
    )

    XCTAssertEqual(try store.referenceHistory(memoryId: "chat-memory"), [])

    _ = try store.load(memoryId: "chat-memory", workflowId: "wf")
    _ = try store.search(
      memoryId: "chat-memory",
      options: MemorySearchOptions(workflowId: "wf", matchPatterns: ["remember"])
    )

    let references = try store.referenceHistory(memoryId: "chat-memory", recordId: saved.recordId)
    XCTAssertEqual(references.map(\.recordId), [saved.recordId, saved.recordId])
    XCTAssertTrue(references.allSatisfy { !$0.referencedAt.isEmpty })
  }

  func testSearchSkipsPayloadsAboveConfiguredSizeBeforeDecoding() throws {
    let root = temporaryDirectory()
    let store = RielaMemoryStore(rootDirectory: root.path)

    try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:00:00Z",
      payload: .object(["text": .string(String(repeating: "x", count: 2_000))])
    )
    try store.save(
      memoryId: "chat-memory",
      workflowId: "wf",
      registeredAt: "2026-06-20T10:01:00Z",
      payload: .object(["text": .string("small memory")])
    )

    let records = try store.search(
      memoryId: "chat-memory",
      options: MemorySearchOptions(workflowId: "wf", limit: 10, maxPayloadBytes: 500)
    )

    XCTAssertEqual(records.map(\.payload), [.object(["text": .string("small memory")])])
  }

  private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-memory-tests-\(UUID().uuidString)", isDirectory: true)
  }

  private func createLegacyMemoryDatabase(at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
      throw RielaMemoryError.openFailed("failed to create legacy test database")
    }
    defer {
      sqlite3_close(db)
    }
    try executeLegacySQL(
      db,
      """
      CREATE TABLE memory_entries (
        record_id INTEGER PRIMARY KEY AUTOINCREMENT,
        workflow_id TEXT NOT NULL,
        node_id TEXT,
        registered_at TEXT NOT NULL,
        payload_json BLOB NOT NULL CHECK (json_valid(payload_json, 8))
      )
      """
    )
    try executeLegacySQL(
      db,
      """
      INSERT INTO memory_entries (workflow_id, node_id, registered_at, payload_json)
      VALUES ('wf', 'node', '2026-06-20T10:00:00Z', jsonb('{"text":"legacy survives"}'))
      """
    )
  }

  private func executeLegacySQL(_ db: OpaquePointer?, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw RielaMemoryError.sqliteFailed(String(cString: sqlite3_errmsg(db)))
    }
  }
}
