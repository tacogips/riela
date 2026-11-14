import Foundation
import RielaCore
import RielaNote
import XCTest
@testable import RielaCLI

final class NoteMemoryAddonTests: XCTestCase {
  func testSaveAndLoadUseLockedSystemNotebookWithWorkflowIsolationAndFiles() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appendingPathComponent("source.png")
    let imageData = Data([0x89, 0x50, 0x4E, 0x47])
    try imageData.write(to: image)
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    let save = try await resolver.execute(
      noteMemoryInput(
        workflowId: "telegram-sdk-trio-chat",
        name: "riela/note-memory-save",
        config: [
          "streamId": .string("chat-memory"),
          "nodeId": .string("chat-event"),
          "tags": .array([.string("provider:telegram")]),
          "attachments": .array([.string(image.path)]),
          "payloadTemplate": .object([
            "text": .string("{{event.input.text}}"),
            "conversationId": .string("{{event.conversation.id}}")
          ])
        ],
        variables: [
          "event": .object([
            "input": .object(["text": .string("Remember the Note-backed context")]),
            "conversation": .object(["id": .string("chat-1")])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(save.payload["saved"], .bool(true))
    XCTAssertEqual(save.payload["streamId"], .string("chat-memory"))
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    XCTAssertTrue(try service.systemMemoryNotebook().readOnly)
    XCTAssertEqual(
      try service.listSystemMemoryNotes(
        streamId: "chat-memory",
        workflowId: "telegram-sdk-trio-chat",
        limit: 10
      ).count,
      1
    )

    _ = try await resolver.execute(
      noteMemoryInput(
        workflowId: "other-workflow",
        name: "riela/note-memory-save",
        config: [
          "streamId": .string("chat-memory"),
          "payload": .object(["text": .string("Must remain isolated")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let load = try await resolver.execute(
      noteMemoryInput(
        workflowId: "telegram-sdk-trio-chat",
        name: "riela/note-memory-load",
        config: ["streamId": .string("chat-memory"), "limit": .number(30)]
      ),
      context: AdapterExecutionContext()
    )
    guard case let .array(records)? = load.payload["records"],
          case let .object(record)? = records.first,
          case let .object(payload)? = record["payload"] else {
      return XCTFail("note-memory load did not return the stored record")
    }
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(payload["text"], .string("Remember the Note-backed context"))
    XCTAssertEqual(payload["conversationId"], .string("chat-1"))
    guard case let .string(recordsText)? = load.payload["recordsText"] else {
      return XCTFail("note-memory load did not return recordsText")
    }
    XCTAssertTrue(recordsText.contains("Remember the Note-backed context"))
    guard case let .array(imagePaths)? = load.payload["imagePaths"],
          case let .string(storedImagePath)? = imagePaths.first else {
      return XCTFail("note-memory load did not return a materialized image path")
    }
    XCTAssertTrue(storedImagePath.hasPrefix(root.appendingPathComponent("files").path + "/"))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: storedImagePath)), imageData)
  }

  func testLoadReturnsNewestBoundedRecordsInWorkflowOrder() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])
    let streamId = "ordered-stream"
    let workflowId = "ordered-workflow"
    var orderedNoteIds: [String] = []

    for sequence in 1...3 {
      let save = try await resolver.execute(
        noteMemoryInput(
          workflowId: workflowId,
          name: "riela/note-memory-save",
          config: [
            "streamId": .string(streamId),
            "payload": .object(["sequence": .number(Double(sequence))])
          ]
        ),
        context: AdapterExecutionContext()
      )
      guard case let .string(noteId)? = save.payload["noteId"] else {
        return XCTFail("note-memory save did not return noteId for sequence \(sequence)")
      }
      orderedNoteIds.append(noteId)
    }

    let unrelatedSave = try await resolver.execute(
      noteMemoryInput(
        workflowId: "unrelated-workflow",
        name: "riela/note-memory-save",
        config: [
          "streamId": .string(streamId),
          "payload": .object(["sequence": .number(99)])
        ]
      ),
      context: AdapterExecutionContext()
    )
    guard case let .string(unrelatedNoteId)? = unrelatedSave.payload["noteId"] else {
      return XCTFail("unrelated note-memory save did not return noteId")
    }

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    try service.driver.withDatabase { database in
      for (index, noteId) in orderedNoteIds.enumerated() {
        let timestamp = "2026-08-01T00:00:0\(index + 1)Z"
        try database.execute(
          "UPDATE notes SET created_at = ?, updated_at = ? WHERE note_id = ?",
          bindings: [.text(timestamp), .text(timestamp), .text(noteId)]
        )
      }
      try database.execute(
        "UPDATE notes SET created_at = ?, updated_at = ? WHERE note_id = ?",
        bindings: [
          .text("2026-08-01T00:00:04Z"),
          .text("2026-08-01T00:00:04Z"),
          .text(unrelatedNoteId)
        ]
      )
    }

    let load = try await resolver.execute(
      noteMemoryInput(
        workflowId: workflowId,
        name: "riela/note-memory-load",
        config: ["streamId": .string(streamId), "limit": .number(2)]
      ),
      context: AdapterExecutionContext()
    )
    guard case let .array(records)? = load.payload["records"],
          records.count == 2,
          case let .object(firstRecord) = records[0],
          case let .object(secondRecord) = records[1],
          case let .object(firstPayload)? = firstRecord["payload"],
          case let .object(secondPayload)? = secondRecord["payload"] else {
      return XCTFail("note-memory load did not return two object records")
    }

    XCTAssertEqual(
      [firstRecord["noteId"], secondRecord["noteId"]],
      [.string(orderedNoteIds[2]), .string(orderedNoteIds[1])]
    )
    XCTAssertEqual(
      [firstPayload["sequence"], secondPayload["sequence"]],
      [.number(3), .number(2)]
    )
    XCTAssertFalse(records.contains { record in
      guard case let .object(object) = record else { return false }
      return object["noteId"] == .string(unrelatedNoteId)
    })
    XCTAssertEqual(load.payload["limit"], .number(2))
  }

  func testAddonsRejectLegacyStorageAndUnsupportedVersions() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    do {
      _ = try await resolver.execute(
        noteMemoryInput(
          name: "riela/note-memory-load",
          config: ["streamId": .string("chat-memory"), "legacyStorageRoot": .string("/tmp/legacy")]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected legacy storage rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("legacyStorageRoot"))
    }

    do {
      _ = try await resolver.execute(
        noteMemoryInput(name: "riela/note-memory-save", version: "2"),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected unsupported version rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
  }

  func testLoadRejectsReservedTagsAndMetadataPreventsWorkflowTagSpoofing() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    do {
      _ = try await resolver.execute(
        noteMemoryInput(
          workflowId: "workflow-a",
          name: "riela/note-memory-save",
          config: [
            "streamId": .string("chat-memory"),
            "tags": .array([.string(NoteService.systemMemoryWorkflowTag("workflow-b"))]),
            "payload": .object(["text": .string("must remain isolated")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected reserved tag rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("reserved prefix"))
    }

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    _ = try service.appendSystemMemoryNote(
      bodyMarkdown: "spoofed workflow tag",
      tags: [
        NoteTagInput(name: NoteService.systemMemoryStreamTag("chat-memory")),
        NoteTagInput(name: NoteService.systemMemoryWorkflowTag("workflow-a")),
        NoteTagInput(name: NoteService.systemMemoryWorkflowTag("workflow-b")),
        NoteTagInput(name: NoteService.systemMemoryNodeTag("chat-event"))
      ],
      metaJSON: #"{"entryKind":"workflow-memory","streamId":"chat-memory","workflowId":"workflow-a","nodeId":"chat-event"}"#
    )

    let load = try await resolver.execute(
      noteMemoryInput(
        workflowId: "workflow-b",
        name: "riela/note-memory-load",
        config: ["streamId": .string("chat-memory")]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(load.payload["records"], .array([]))
  }

  func testSaveEnforcesAttachmentCountBeforeReadingOrStaging() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])
    let sourceURLs = try (0...64).map { index -> URL in
      let url = root.appendingPathComponent("source-\(index).txt")
      try Data([UInt8(index)]).write(to: url)
      return url
    }

    _ = try await resolver.execute(
      noteMemoryInput(
        workflowId: "attachment-limit",
        name: "riela/note-memory-save",
        config: [
          "streamId": .string("chat-memory"),
          "attachments": .array(sourceURLs.prefix(64).map { .string($0.path) }),
          "payload": .object(["text": .string("at attachment limit")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let notesAtLimit = try service.listSystemMemoryNotes(
      streamId: "chat-memory",
      workflowId: "attachment-limit",
      limit: 10
    )
    XCTAssertEqual(notesAtLimit.count, 1)
    XCTAssertEqual(try service.listFiles(noteId: notesAtLimit[0].noteId).count, 64)
    let unreadableOverflowRefs = (0...64).map { index in
      root.appendingPathComponent("missing-\(index).txt").path
    }

    do {
      _ = try await resolver.execute(
        noteMemoryInput(
          workflowId: "attachment-limit",
          name: "riela/note-memory-save",
          config: [
            "streamId": .string("chat-memory"),
            "attachments": .array(unreadableOverflowRefs.map(JSONValue.string)),
            "payload": .object(["text": .string("over attachment limit")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected attachment count rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("maximum of 64"))
    }
    XCTAssertEqual(
      try service.listSystemMemoryNotes(
        streamId: "chat-memory",
        workflowId: "attachment-limit",
        limit: 10
      ).count,
      1
    )
  }

  func testSaveRejectsSymlinkEscapeWithoutPersistingMemory() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let allowedRoot = root.appendingPathComponent("allowed", isDirectory: true)
    try FileManager.default.createDirectory(at: allowedRoot, withIntermediateDirectories: true)
    let outsideFile = root.appendingPathComponent("outside-secret.txt")
    try Data("secret".utf8).write(to: outsideFile)
    let symlink = allowedRoot.appendingPathComponent("linked-secret.txt")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideFile)
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    do {
      _ = try await resolver.execute(
        noteMemoryInput(
          workflowId: "attachment-security",
          name: "riela/note-memory-save",
          config: [
            "streamId": .string("chat-memory"),
            "localFileRoot": .string(allowedRoot.path),
            "attachments": .array([.string(symlink.path)]),
            "payload": .object(["text": .string("must not persist")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected symlink escape rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("outside allowed root"))
    }
    try assertNoNoteMemoryRecords(root: root, workflowId: "attachment-security")
  }

  func testSaveRejectsMissingAttachmentAtomically() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let validFile = root.appendingPathComponent("valid.txt")
    try Data("valid".utf8).write(to: validFile)
    let missingFile = root.appendingPathComponent("missing.txt")
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    do {
      _ = try await resolver.execute(
        noteMemoryInput(
          workflowId: "attachment-missing",
          name: "riela/note-memory-save",
          config: [
            "streamId": .string("chat-memory"),
            "attachments": .array([.string(validFile.path), .string(missingFile.path)]),
            "payload": .object(["text": .string("must roll back")])
          ]
        ),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected missing attachment rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("attachment cannot be resolved"))
    }
    try assertNoNoteMemoryRecords(root: root, workflowId: "attachment-missing")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("files").path))
  }

  func testSaveRejectsUnsupportedAndMalformedAttachmentReferences() async throws {
    let root = try makeNoteMemoryAddonRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let resolver = BuiltinWorkflowAddonResolver(environment: ["RIELA_NOTE_ROOT": root.path])

    for (workflowId, reference, expectedMessage) in [
      (
        "attachment-remote",
        JSONValue.string("https://example.invalid/secret.txt"),
        "attachment cannot be resolved"
      ),
      (
        "attachment-malformed",
        JSONValue.object(["unexpected": .string("value")]),
        "does not contain a supported reference"
      )
    ] {
      do {
        _ = try await resolver.execute(
          noteMemoryInput(
            workflowId: workflowId,
            name: "riela/note-memory-save",
            config: [
              "streamId": .string("chat-memory"),
              "attachments": .array([reference]),
              "payload": .object(["text": .string("must not persist")])
            ]
          ),
          context: AdapterExecutionContext()
        )
        XCTFail("Expected unsupported attachment rejection")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .invalidInput)
        XCTAssertTrue(error.message.contains(expectedMessage))
      }
      try assertNoNoteMemoryRecords(root: root, workflowId: workflowId)
    }
  }
}

private func noteMemoryInput(
  workflowId: String = "note-memory-addon-tests",
  name: String,
  version: String = "1",
  config: JSONObject = [
    "streamId": .string("chat-memory"),
    "payload": .object(["text": .string("fixture")])
  ],
  variables: JSONObject = [:]
) -> WorkflowAddonExecutionInput {
  WorkflowAddonExecutionInput(
    workflowId: workflowId,
    stepId: "note-memory-step",
    nodeId: "note-memory-node",
    addon: WorkflowNodeAddonRef(name: name, version: version, config: config),
    variables: variables
  )
}

private func makeNoteMemoryAddonRoot() throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/NoteMemoryAddonTests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func assertNoNoteMemoryRecords(root: URL, workflowId: String) throws {
  let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
  XCTAssertTrue(try service.listSystemMemoryNotes(
    streamId: "chat-memory",
    workflowId: workflowId,
    limit: 10
  ).isEmpty)
}
