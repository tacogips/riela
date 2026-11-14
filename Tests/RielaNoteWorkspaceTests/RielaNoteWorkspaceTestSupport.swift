import Foundation
import RielaNote
@testable import RielaNoteWorkspace

func makeService(function: String = #function) throws -> NoteService {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteWorkspaceTests", isDirectory: true)
    .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
}

enum LegacyRielaNoteUIClientError: Error {
  case unsupported
}

/// A client that implements only the pre-capability subset of `RielaNoteUIClient`,
/// so the protocol's default implementations supply everything else. Tests use it
/// to prove those defaults fail closed rather than silently returning wrong data.
final class LegacyRielaNoteUIClient: RielaNoteUIClient, @unchecked Sendable {
  let notebook: Notebook
  let firstPageNote: Note
  let laterNote: Note

  init() {
    notebook = Notebook(
      notebookId: "notebook-1",
      title: "Imported Book",
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
    firstPageNote = Note(
      noteId: "note-1",
      notebookId: "notebook-1",
      noteNumber: 1,
      title: "Page One",
      bodyMarkdown: "# Page One\n\nBody",
      readOnly: true,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
    laterNote = Note(
      noteId: "note-2",
      notebookId: "notebook-1",
      noteNumber: 2,
      title: "Ontology",
      bodyMarkdown: "# Ontology\n\nSearch body",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }

  var defaultConfigWorkflowRoot: String {
    "tmp/RielaNoteWorkspaceTests/default-config-workflows"
  }

  func listNotebooks(limit: Int, offset: Int) async throws -> [Notebook] {
    [notebook]
  }

  func listNotes(notebookId: String, limit: Int, offset: Int) async throws -> [Note] {
    Array([firstPageNote, laterNote].dropFirst(offset).prefix(limit))
  }

  func listTags() async throws -> [Tag] {
    []
  }

  func createUserMemo(bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
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
    RielaNoteDetail(note: noteId == firstPageNote.noteId ? firstPageNote : laterNote)
  }

  func firstNote(inNotebook notebookId: String) async throws -> RielaNoteDetail? {
    RielaNoteDetail(note: firstPageNote)
  }

  func resolveFile(fileId: String) async throws -> RielaNoteResolvedFile {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func updateNoteBody(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func applyTag(noteId: String, tagName: String, classId: String?) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func removeTag(noteId: String, tagName: String) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func addComment(noteId: String, bodyMarkdown: String) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func linkNote(noteId: String, targetNoteId: String, linkKind: String) async throws -> RielaNoteDetail {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func answerNoteAgentTurn(message: String, limit: Int) async throws -> RielaNoteAgentTurn {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func saveNoteAgentConversation(
    title: String,
    turns: [RielaNoteAgentTurn]
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func appendNoteAgentTurn(
    notebookId: String,
    turn: RielaNoteAgentTurn
  ) async throws -> RielaNoteAgentConversationSaveResult {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func proposeNoteConfigAgentChange(message: String) async throws -> RielaNoteConfigAgentProposal {
    throw LegacyRielaNoteUIClientError.unsupported
  }

  func applyNoteConfigAgentProposal(
    _ proposal: RielaNoteConfigAgentProposal,
    workflowRoot: String
  ) async throws -> RielaNoteConfigAgentApplyResult {
    throw LegacyRielaNoteUIClientError.unsupported
  }
}
