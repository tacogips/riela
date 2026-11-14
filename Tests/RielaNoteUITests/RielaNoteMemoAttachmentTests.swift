import Foundation
import RielaNote
@testable import RielaNoteUI
import UniformTypeIdentifiers
import XCTest

@MainActor
final class RielaNoteMemoAttachmentTests: XCTestCase {
  func testCreateUserMemoAppliesSystemNonDeletableKindTag() async throws {
    let service = try makeMemoTestService()
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.createUserMemo(bodyMarkdown: "# Memo\nBody")

    let notebook = try service.getNotebook(detail.note.notebookId)
    let kindTag = notebook.tags.first { $0.tag.name == "notebook-kind:user-memo" }
    XCTAssertNotNil(kindTag, "createUserMemo must seed the user-memo notebook kind tag")
    XCTAssertEqual(kindTag?.provenance, .system)
    XCTAssertFalse(kindTag?.deletable ?? true)

    let filtered = try service.listNotebooks(tagFilter: ["notebook-kind:user-memo"])
    XCTAssertEqual(filtered.map(\.notebookId), [detail.note.notebookId])
  }

  func testWriteResolvedFileToScratchWritesBytesUnderOriginalFilename() throws {
    let scratch = uniqueScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bytes = Data("hello pdf".utf8)
    let resolved = RielaNoteResolvedFile(
      file: makeFileRecord(fileId: "file-1", mediaType: "application/pdf", originalFilename: "report.pdf"),
      data: bytes
    )

    let url = try rielaNoteWriteResolvedFileToScratch(resolved, directory: scratch)

    XCTAssertEqual(url.lastPathComponent, "report.pdf")
    XCTAssertEqual(try Data(contentsOf: url), bytes)
  }

  func testWriteResolvedFileStripsPathComponentsFromOriginalFilename() throws {
    let scratch = uniqueScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let resolved = RielaNoteResolvedFile(
      file: makeFileRecord(
        fileId: "file-2",
        mediaType: "application/pdf",
        originalFilename: "../../escape.pdf"
      ),
      data: Data("x".utf8)
    )

    let url = try rielaNoteWriteResolvedFileToScratch(resolved, directory: scratch)

    XCTAssertEqual(url.lastPathComponent, "escape.pdf")
    XCTAssertTrue(url.path.hasPrefix(scratch.path), "the write must stay inside the scratch directory")
  }

  func testResolvedFileNameFallsBackToFileIdWithMediaTypeExtension() {
    let record = makeFileRecord(fileId: "file-3", mediaType: "application/pdf", originalFilename: nil)

    XCTAssertEqual(rielaNoteResolvedFileName(for: record), "file-3.pdf")
  }

  func testOpenFileActionInvokesInjectedCallbackWithScratchURL() throws {
    let scratch = uniqueScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let bytes = Data("video bytes".utf8)
    let resolved = RielaNoteResolvedFile(
      file: makeFileRecord(fileId: "file-4", mediaType: "video/mp4", originalFilename: "clip.mp4"),
      data: bytes
    )

    var openedURL: URL?
    let action = RielaNoteOpenFileAction { openedURL = $0 }

    let url = try rielaNoteWriteResolvedFileToScratch(resolved, directory: scratch)
    action(url)

    XCTAssertEqual(openedURL, url)
    XCTAssertEqual(openedURL?.lastPathComponent, "clip.mp4")
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(openedURL)), bytes)
  }

  func testBinaryFileDocumentHoldsBytesAndContentTypeForExport() {
    let bytes = Data([0x00, 0x01, 0x02, 0xFF])
    let document = RielaNoteBinaryFileDocument(data: bytes, contentType: .pdf)

    XCTAssertEqual(document.data, bytes)
    XCTAssertEqual(document.contentType, .pdf)
    XCTAssertTrue(RielaNoteBinaryFileDocument.readableContentTypes.contains(.data))
  }

  private func makeFileRecord(fileId: String, mediaType: String, originalFilename: String?) -> FileRecord {
    FileRecord(
      fileId: fileId,
      storageKind: .local,
      localPath: "files/\(fileId)",
      s3Profile: nil,
      s3Bucket: nil,
      s3Key: nil,
      mediaType: mediaType,
      byteSize: 4,
      sha256: "sha-\(fileId)",
      originalFilename: originalFilename,
      createdAt: "2026-07-12T00:00:00Z",
      migratedAt: nil
    )
  }

  private func uniqueScratchDirectory() -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaNoteMemoAttachmentTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}

private func makeMemoTestService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteMemoAttachmentTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}
