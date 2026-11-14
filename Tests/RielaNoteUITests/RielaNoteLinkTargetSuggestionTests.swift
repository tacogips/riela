import Foundation
import RielaNote
@testable import RielaNoteUI
import XCTest

final class RielaNoteLinkTargetSuggestionTests: XCTestCase {
  func testSearchLinkResultsPreserveFullTextMatchesAndSearchRanking() {
    let current = Self.note(noteId: "note-current", title: "Current")
    let bodyOnlyMatch = Self.note(noteId: "note-body", title: "Unrelated title")
    let titleMatch = Self.note(noteId: "note-title", title: "Roadmap")
    let existing = Self.note(noteId: "note-existing", title: "Existing")
    let link = NoteLink(
      fromNoteId: current.noteId,
      toNoteId: existing.noteId,
      linkKind: "related",
      provenance: .human,
      createdAt: "2026-07-04T00:00:00Z"
    )

    let results = [
      NoteSearchResult(note: current, snippet: "self", rank: 0, matchedTags: []),
      NoteSearchResult(note: bodyOnlyMatch, snippet: "roadmap appears only in body", rank: 1, matchedTags: []),
      NoteSearchResult(note: existing, snippet: "already linked", rank: 2, matchedTags: []),
      NoteSearchResult(note: titleMatch, snippet: "title match", rank: 3, matchedTags: []),
      NoteSearchResult(note: bodyOnlyMatch, snippet: "duplicate", rank: 4, matchedTags: [])
    ]

    let filtered = rielaNoteSearchLinkResults(
      results,
      currentNoteId: current.noteId,
      existingLinks: [link]
    )

    XCTAssertEqual(filtered.map(\.note.noteId), [bodyOnlyMatch.noteId, titleMatch.noteId])
  }

  func testLinkIconDistinguishesSourceCitations() {
    XCTAssertEqual(rielaNoteLinkIconName("source-citation"), "quote.bubble")
    XCTAssertEqual(rielaNoteLinkIconName("related"), "link")
  }

  #if os(macOS)
  func testLinkProposalDefaultProviderHonorsWorkflowDirEnvironmentOverride() throws {
    let workflowDefinitionDirectory = try makeLinkWorkflowDirectoryFixture(function: #function)
    let executable = try makeLinkExecutableFixture(function: #function)

    let provider = try XCTUnwrap(RielaWorkflowNoteLinkProposalProvider.defaultProvider(environment: [
      "RIELA_NOTE_LINK_EXTRACT_WORKFLOW_DIR": workflowDefinitionDirectory,
      "RIELA_NOTE_LINK_EXTRACT_RIELA_EXECUTABLE": executable
    ]))

    XCTAssertEqual(provider.workflowDefinitionDirectory, workflowDefinitionDirectory)
    XCTAssertEqual(provider.executablePath, executable)
    XCTAssertTrue(provider.allowEnvironmentOverrides)
  }
  #endif

  private static func note(noteId: String, title: String) -> Note {
    Note(
      noteId: noteId,
      notebookId: "notebook-1",
      noteNumber: 1,
      title: title,
      bodyMarkdown: "# \(title)",
      readOnly: false,
      createdAt: "2026-07-04T00:00:00Z",
      updatedAt: "2026-07-04T00:00:00Z"
    )
  }
}

#if os(macOS)
private func makeLinkWorkflowDirectoryFixture(function: String) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteLinkTargetSuggestionTests", isDirectory: true)
    .appendingPathComponent(function, isDirectory: true)
    .appendingPathComponent("examples", isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  let workflowDirectory = directory.appendingPathComponent("note-link-extract", isDirectory: true)
  try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
  try "{}\n".write(
    to: workflowDirectory.appendingPathComponent("workflow.json"),
    atomically: true,
    encoding: .utf8
  )
  return directory.path
}

private func makeLinkExecutableFixture(function: String) throws -> String {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp/RielaNoteLinkTargetSuggestionTests", isDirectory: true)
    .appendingPathComponent("\(function)-executable", isDirectory: true)
  if FileManager.default.fileExists(atPath: directory.path) {
    try FileManager.default.removeItem(at: directory)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appendingPathComponent("riela")
  try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return executable.path
}
#endif
