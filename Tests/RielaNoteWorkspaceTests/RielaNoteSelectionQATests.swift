import Foundation
import RielaNote
@testable import RielaNoteWorkspace
import XCTest

@MainActor
final class RielaNoteSelectionQATests: XCTestCase {
  // MARK: - Client round-trips against a real service

  func testNoteServiceClientSelectionQuestionProviderRoundTrip() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let provider = CapturingSelectionQuestionProvider(
      draft: RielaNoteSelectionAnswerDraft(answerMarkdown: "Answer", summary: "Sum")
    )
    let client = NoteServiceRielaNoteUIClient(service: service, selectionQuestionProvider: provider)

    let answer = try await client.answerNoteSelectionQuestion(
      noteId: note.noteId,
      question: "What?",
      bodyMarkdown: "# Draft\n\nBody",
      selectedText: "Body",
      selectionStart: 9,
      selectionEnd: 13
    )

    XCTAssertEqual(answer.answerMarkdown, "Answer")
    XCTAssertEqual(provider.requests.first?.noteId, note.noteId)
    XCTAssertEqual(provider.requests.first?.noteRoot, service.noteRootPath())
    XCTAssertEqual(provider.requests.first?.selectedText, "Body")
    XCTAssertEqual(provider.requests.first?.selectionStart, 9)
  }

  func testNoteServiceClientSelectionQuestionWithoutProviderThrowsNotConfigured() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    do {
      _ = try await client.answerNoteSelectionQuestion(
        noteId: note.noteId,
        question: "What?",
        bodyMarkdown: note.bodyMarkdown,
        selectedText: "Body",
        selectionStart: 9,
        selectionEnd: 13
      )
      XCTFail("Expected notConfigured")
    } catch RielaNoteSelectionQuestionError.notConfigured {
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testNoteServiceClientAddCommentPassesAuthorThrough() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.addComment(noteId: note.noteId, bodyMarkdown: "Agent note", author: "note-agent")

    XCTAssertEqual(detail.comments.count, 1)
    XCTAssertEqual(detail.comments.first?.author, "note-agent")
    XCTAssertEqual(detail.comments.first?.bodyMarkdown, "Agent note")
  }

  func testNoteServiceClientPromoteCommentReturnsDetailWithLink() async throws {
    let service = try makeService()
    let note = try service.createNote(bodyMarkdown: "# Draft\n\nBody")
    let comment = try service.addComment(noteId: note.noteId, bodyMarkdown: "# Promote\n\nBody", author: "note-agent")
    let client = NoteServiceRielaNoteUIClient(service: service)

    let detail = try await client.promoteCommentToNotebook(noteId: note.noteId, commentId: comment.commentId)

    XCTAssertEqual(detail.links.count, 1)
    XCTAssertEqual(detail.links.first?.fromNoteId, note.noteId)
    XCTAssertEqual(detail.links.first?.linkKind, "related")
    let linkedNoteId = try XCTUnwrap(detail.links.first?.toNoteId)
    XCTAssertEqual(detail.linkedNotesById[linkedNoteId]?.bodyMarkdown, "# Promote\n\nBody")
  }

  // MARK: - Workflow provider

  #if os(macOS)
  func testWorkflowSelectionQuestionVariablesIncludeSelectionFields() throws {
    let variables = noteSelectionQuestionVariables(
      noteId: "note-1",
      noteRoot: "/tmp/notes",
      question: "What is this?",
      bodyMarkdown: "# Draft",
      selectedText: "Draft",
      selectionStart: 2,
      selectionEnd: 7
    )

    let workflowInput = try XCTUnwrap(variables["workflowInput"] as? [String: Any])
    XCTAssertEqual(variables["noteRoot"] as? String, "/tmp/notes")
    XCTAssertEqual(workflowInput["noteId"] as? String, "note-1")
    XCTAssertEqual(workflowInput["question"] as? String, "What is this?")
    XCTAssertEqual(workflowInput["selectedText"] as? String, "Draft")
    XCTAssertEqual(workflowInput["selectionStart"] as? Int, 2)
    XCTAssertEqual(workflowInput["selectionEnd"] as? Int, 7)
  }

  func testWorkflowSelectionQuestionRunArgumentsUseVariablesFile() {
    let arguments = rielaWorkflowRunArguments(
      workflowName: "note-selection-question",
      workflowDefinitionDirectory: "/tmp/examples",
      variablesFilePath: "/tmp/riela-note-workflow/variables.json"
    )

    XCTAssertEqual(arguments, [
      "workflow",
      "run",
      "note-selection-question",
      "--workflow-definition-dir",
      "/tmp/examples",
      "--variables-file",
      "/tmp/riela-note-workflow/variables.json",
      "--output",
      "jsonl"
    ])
    XCTAssertFalse(arguments.contains("--variables"))
  }

  func testWorkflowSelectionAnswerParserReadsLastDecodableRootOutputLine() {
    let output = """
    {"event":"progress"}
    {"result":{"rootOutput":{"answerMarkdown":"first","summary":"ignored"}}}
    {"result":{"rootOutput":{"answerMarkdown":"second","summary":"used"}}}
    """

    let draft = parseNoteSelectionAnswerDraft(from: output)

    XCTAssertEqual(draft, RielaNoteSelectionAnswerDraft(answerMarkdown: "second", summary: "used"))
  }
  #endif
}

// MARK: - Test doubles

private final class CapturingSelectionQuestionProvider: RielaNoteSelectionQuestionProviding, @unchecked Sendable {
  struct Request: Equatable {
    var noteId: String
    var noteRoot: String
    var question: String
    var bodyMarkdown: String
    var selectedText: String
    var selectionStart: Int
    var selectionEnd: Int
  }

  private let draft: RielaNoteSelectionAnswerDraft
  private(set) var requests: [Request] = []

  init(draft: RielaNoteSelectionAnswerDraft) {
    self.draft = draft
  }

  func answerQuestion(
    noteId: String,
    noteRoot: String,
    question: String,
    bodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async throws -> RielaNoteSelectionAnswerDraft {
    requests.append(Request(
      noteId: noteId,
      noteRoot: noteRoot,
      question: question,
      bodyMarkdown: bodyMarkdown,
      selectedText: selectedText,
      selectionStart: selectionStart,
      selectionEnd: selectionEnd
    ))
    return draft
  }
}
