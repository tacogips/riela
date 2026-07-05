import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

@MainActor
final class RielaNoteLibraryImagePrefetchTests: XCTestCase {
  func testSelectingNotebookPrefetchesCurrentAndAdjacentSourceImages() async throws {
    let client = PrefetchNoteUIClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-prefetch")
    await Task.yield()

    XCTAssertEqual(viewModel.contentMode, .text)
    XCTAssertNil(viewModel.resolvedSourceImage)
    XCTAssertFalse(client.resolvedFileIds.contains("file-page-1"))

    await viewModel.setContentMode(.sourceImage)

    XCTAssertEqual(viewModel.contentMode, .sourceImage)
    XCTAssertEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page-1")
    XCTAssertEqual(viewModel.decodedSourceImage?.fileId, "file-page-1")
    XCTAssertEqual(viewModel.decodedSourceImage?.pixelWidth, 1)
    XCTAssertEqual(viewModel.decodedSourceImage?.pixelHeight, 1)
    XCTAssertEqual(client.resolvedFileIds.sorted(), ["file-page-1", "file-page-2"])
  }

  func testImageModePersistsWhilePagingWithinNotebookAndUsesPrefetchCache() async throws {
    let client = PrefetchNoteUIClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-prefetch")
    await Task.yield()
    await viewModel.setContentMode(.sourceImage)
    await viewModel.selectNextNote()

    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-prefetch-2")
    XCTAssertEqual(viewModel.contentMode, .sourceImage)
    XCTAssertEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page-2")
    XCTAssertEqual(viewModel.decodedSourceImage?.fileId, "file-page-2")
    XCTAssertEqual(client.resolvedFileIds.sorted(), ["file-page-1", "file-page-2"])
  }

  func testRetrySourceImageEvictsPrefetchCacheAndResolvesAgain() async throws {
    let client = PrefetchNoteUIClient()
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-prefetch")
    await Task.yield()
    await viewModel.setContentMode(.sourceImage)
    await viewModel.retrySourceImage()

    XCTAssertEqual(viewModel.resolvedSourceImage?.file.fileId, "file-page-1")
    XCTAssertEqual(viewModel.decodedSourceImage?.fileId, "file-page-1")
    XCTAssertEqual(client.resolvedFileIds.filter { $0 == "file-page-1" }.count, 2)
  }

  func testSourceImageLoadingStateIsExposedDuringExplicitFetch() async throws {
    let client = PrefetchNoteUIClient(resolveDelayNanoseconds: 50_000_000)
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-prefetch")
    await viewModel.setContentMode(.sourceImage)

    let retryTask = Task {
      await viewModel.retrySourceImage()
    }
    try await Task.sleep(nanoseconds: 10_000_000)

    XCTAssertTrue(viewModel.isSourceImageLoading)
    await retryTask.value
    XCTAssertFalse(viewModel.isSourceImageLoading)
    XCTAssertEqual(viewModel.decodedSourceImage?.fileId, "file-page-1")
  }

  func testTextModeSelectionDoesNotWaitForDelayedPrefetch() async throws {
    let client = PrefetchNoteUIClient(resolveDelayNanoseconds: 50_000_000)
    let viewModel = RielaNoteLibraryViewModel(client: client)

    await viewModel.selectNotebook("notebook-prefetch")

    XCTAssertEqual(viewModel.state, .loaded)
    XCTAssertEqual(viewModel.selectedNote?.noteId, "note-prefetch-1")
    XCTAssertEqual(client.resolvedFileIds, [])

    try await Task.sleep(nanoseconds: 70_000_000)
    XCTAssertEqual(client.resolvedFileIds, ["file-page-2"])
  }

  func testSourceImageZoomControlsClampToSupportedRange() async throws {
    let viewModel = RielaNoteLibraryViewModel(client: PrefetchNoteUIClient())

    XCTAssertEqual(viewModel.sourceImageZoom, 1.0)

    for _ in 0..<20 {
      viewModel.zoomInSourceImage()
    }
    XCTAssertEqual(viewModel.sourceImageZoom, RielaNoteLibraryViewModel.sourceImageMaximumZoom)

    viewModel.resetSourceImageZoom()
    XCTAssertEqual(viewModel.sourceImageZoom, 1.0)

    for _ in 0..<20 {
      viewModel.zoomOutSourceImage()
    }
    XCTAssertEqual(viewModel.sourceImageZoom, RielaNoteLibraryViewModel.sourceImageMinimumZoom)
  }

  func testSourceImageCachesEvictOldEntriesAtConfiguredLimit() async throws {
    let client = PrefetchNoteUIClient(noteCount: 2)
    let viewModel = RielaNoteLibraryViewModel(
      client: client,
      notebookNoteLimit: 1,
      sourceImageCacheLimit: 1
    )

    await viewModel.selectNotebook("notebook-prefetch")
    await viewModel.setContentMode(.sourceImage)
    await viewModel.selectNote("note-prefetch-2")
    await viewModel.selectNote("note-prefetch-1")

    XCTAssertGreaterThanOrEqual(client.resolvedFileIds.filter { $0 == "file-page-1" }.count, 2)
  }
}

private final class PrefetchNoteUIClient: RielaNoteUIClient, @unchecked Sendable {
  private let notebook = Notebook(
    notebookId: "notebook-prefetch",
    title: "Prefetch Notebook",
    createdAt: "2026-07-04T00:00:00Z",
    updatedAt: "2026-07-04T00:00:00Z"
  )
  private let notes: [Note]
  private let attachmentsByNoteId: [String: NoteFileAttachment]
  private let resolveDelayNanoseconds: UInt64
  var resolvedFileIds: [String] = []

  init(resolveDelayNanoseconds: UInt64 = 0, noteCount: Int = 2) {
    self.resolveDelayNanoseconds = resolveDelayNanoseconds
    notes = (1...noteCount).map { number in
      Self.note(noteId: "note-prefetch-\(number)", number: number, title: "Page \(number)")
    }
    attachmentsByNoteId = Dictionary(uniqueKeysWithValues: notes.map { note in
      let fileId = "file-page-\(note.noteNumber)"
      return (
        note.noteId,
        NoteFileAttachment(
          noteId: note.noteId,
          file: FileRecord(
            fileId: fileId,
            storageKind: .local,
            localPath: "pages/\(fileId).png",
            s3Profile: nil,
            s3Bucket: nil,
            s3Key: nil,
            mediaType: "image/png",
            byteSize: 3,
            sha256: "sha-\(fileId)",
            originalFilename: "\(fileId).png",
            createdAt: "2026-07-04T00:00:00Z",
            migratedAt: nil
          ),
          role: .sourcePageImage,
          position: note.noteNumber
        )
      )
    })
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteLibraryImagePrefetchTests/workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    [notebook]
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array(notes.dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func searchNotes(
    query: String,
    tagFilter: [String],
    classFilter: [String],
    limit: Int,
    offset: Int
  ) async throws -> [NoteSearchResult] {
    []
  }

  func noteDetail(noteId: String) async throws -> RielaNoteDetail {
    guard let note = notes.first(where: { $0.noteId == noteId }) else {
      throw PrefetchClientError.missingNote
    }
    return RielaNoteDetail(note: note, files: [attachmentsByNoteId[noteId]].compactMap { $0 })
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    try await noteDetail(noteId: notes[0].noteId)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    if resolveDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: resolveDelayNanoseconds)
    }
    resolvedFileIds.append(fileId)
    let noteId = fileId.replacingOccurrences(of: "file-page-", with: "note-prefetch-")
    guard let attachment = attachmentsByNoteId[noteId] else {
      throw PrefetchClientError.missingFile
    }
    return RielaNoteResolvedFile(file: attachment.file, data: Self.onePixelPNGData)
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw PrefetchClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw PrefetchClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw PrefetchClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw PrefetchClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw PrefetchClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw PrefetchClientError.unsupported
  }

  private static func note(noteId: String, number: Int, title: String) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-prefetch",
      noteNumber: number,
      title: title,
      bodyMarkdown: "# \(title)\n\nBody",
      readOnly: true,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }

  private static var onePixelPNGData: Data {
    guard let data = Data(base64Encoded: onePixelPNGBase64) else {
      fatalError("Invalid one-pixel PNG fixture")
    }
    return data
  }

  private static let onePixelPNGBase64 =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
}

private enum PrefetchClientError: Error {
  case missingFile
  case missingNote
  case unsupported
}
