import AppCore
import Foundation
import RielaAddonSupport
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaKnowledgeAddonTests: XCTestCase {
  func testTagSearchChainAttachmentsAndMemosExposeKnowledgeContext() async throws {
    let root = scratchNoteRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    let first = try service.createNote(
      bodyMarkdown: "# Source\n\nProject Atlas origin.",
      tags: [NoteTagInput(name: "project-atlas")]
    )
    let second = try service.createNote(bodyMarkdown: "# Target\n\nProject Atlas destination.")
    _ = try service.linkNotes(
      from: first.noteId,
      to: second.noteId,
      linkKind: "related",
      provenance: .ai
    )
    _ = try service.attachFile(
      noteId: first.noteId,
      data: Data("fixture".utf8),
      mediaType: "text/plain",
      originalFilename: "fixture.txt"
    )
    _ = try service.addComment(
      noteId: first.noteId,
      bodyMarkdown: "Agent observation",
      author: "assistant"
    )

    let tagSearch = try await execute(
      "kaiba/note-tag-search",
      root: root,
      inputs: ["tags": .array([.string("project-atlas")])]
    )
    XCTAssertEqual(tagSearch.payload["noteIds"], .array([.string(first.noteId.rawValue)]))

    let chain = try await execute(
      "kaiba/note-chain",
      root: root,
      inputs: ["noteId": .string(first.noteId.rawValue), "depth": .number(1)]
    )
    XCTAssertEqual(chain.payload["resultCount"], .number(1))
    guard case let .array(chains)? = chain.payload["chains"],
          case let .object(firstChain)? = chains.first else {
      return XCTFail("expected one graph chain")
    }
    XCTAssertEqual(firstChain["pathNoteIds"], .array([.string(first.noteId.rawValue), .string(second.noteId.rawValue)]))

    let attachments = try await execute(
      "kaiba/note-attachments",
      root: root,
      inputs: ["noteId": .string(first.noteId.rawValue)]
    )
    XCTAssertEqual(attachments.payload["fileCount"], .number(1))
    guard case let .array(files)? = attachments.payload["files"],
          case let .object(file)? = files.first else {
      return XCTFail("expected one attachment")
    }
    XCTAssertEqual(file["originalFilename"], .string("fixture.txt"))
    XCTAssertEqual(file["s3URL"], .null)

    let memos = try await execute(
      "kaiba/note-memos",
      root: root,
      inputs: ["noteId": .string(first.noteId.rawValue)]
    )
    XCTAssertEqual(memos.payload["memoCount"], .number(1))
    XCTAssertEqual(memos.payload["agentMemoCount"], .number(1))
  }

  func testDocumentImportRejectsAPathOutsideItsConfiguredRoot() async throws {
    let root = scratchNoteRoot()
    let allowed = root.appendingPathComponent("incoming", isDirectory: true)
    let outside = root.appendingPathComponent("outside.pdf")
    try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
    try Data("not really a PDF".utf8).write(to: outside)
    defer { try? FileManager.default.removeItem(at: root) }

    do {
      _ = try await execute(
        "kaiba/document-import",
        root: root,
        config: ["localFileRoot": .string(allowed.path)],
        inputs: ["path": .string(outside.path), "ocr": .bool(false)]
      )
      XCTFail("expected an out-of-root rejection")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("outside allowed root"), error.message)
    }
  }

  func testDocumentImportUsesKaibaAndReturnsTheStoredSourceFile() async throws {
    let root = scratchNoteRoot()
    let incoming = root.appendingPathComponent("incoming", isDirectory: true)
    let source = incoming.appendingPathComponent("inventory.csv")
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try Data("item,count\nwidget,3\n".utf8).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let output = try await execute(
      "kaiba/document-import",
      root: root,
      config: ["localFileRoot": .string(incoming.path)],
      inputs: [
        "path": .string(source.path),
        "title": .string("Inventory"),
        "ocr": .bool(false),
        "translate": .bool(false)
      ]
    )

    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["ocrRequested"], .bool(false))
    XCTAssertEqual(output.payload["translationRequested"], .bool(false))
    XCTAssertNotNil(nonEmptyString(output.payload["notebookId"]))
    XCTAssertNotNil(output.payload["sourceFile"])
    XCTAssertEqual(output.payload["noteCount"], .number(1))
  }

  func testS3LocatorIsStableAndDoesNotExposeAnEndpoint() {
    let record = FileRecord(
      fileId: FileID("file-1"),
      storageKind: .s3,
      localPath: nil,
      s3Profile: "private",
      s3Bucket: "kaiba-files",
      s3Key: "attachments/file-1",
      mediaType: "application/pdf",
      byteSize: 42,
      sha256: String(repeating: "a", count: 64),
      originalFilename: "source.pdf",
      createdAt: "2026-08-12T00:00:00Z",
      migratedAt: "2026-08-12T00:00:01Z"
    )

    XCTAssertEqual(s3Locator(for: record), "s3://kaiba-files/attachments/file-1")
  }

  private func execute(
    _ name: String,
    root: URL,
    config extraConfig: JSONObject = [:],
    inputs: JSONObject
  ) async throws -> AdapterExecutionOutput {
    var config = extraConfig
    config["noteRoot"] = .string(root.path)
    return try await KaibaAddonCatalog.execute(
      WorkflowAddonExecutionInput(
        workflowId: "kaiba-knowledge-test",
        stepId: "knowledge",
        nodeId: "knowledge",
        addon: WorkflowNodeAddonRef(name: name, version: "1", config: config),
        resolvedInputPayload: inputs
      ),
      environment: [:]
    )
  }

  private func scratchNoteRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-kaiba-knowledge-addon-\(UUID().uuidString)", isDirectory: true)
  }
}
