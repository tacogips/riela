import RielaNote

extension NoteServiceRielaNoteUIClient {
  public func notebookForExpansion(notebookId: String) async throws -> Notebook {
    try service.getNotebookForExpansion(notebookId)
  }

  public func notesForNotebookExpansion(notebookId: String) async throws -> [Note] {
    try service.listNotes(notebookId: notebookId, limit: Int.max, offset: 0)
  }

  public func compactNotebook(
    request: RielaNoteNotebookCompactRequest
  ) async throws -> RielaNoteNotebookCompactDraft {
    guard let notebookExpansionProvider else {
      throw RielaNoteNotebookExpansionError.notConfigured
    }
    return try await notebookExpansionProvider.compactNotebook(
      noteRoot: service.noteRootPath(),
      request: request
    )
  }

  public func updateNotebookCompactCache(
    notebookId: String,
    compactMetadataJSON: String,
    expectedMarker: RielaNoteNotebookExpansionSourceMarker
  ) async throws -> Notebook? {
    try service.updateNotebookCompactMetadata(
      notebookId: notebookId,
      compactMetadataJSON: compactMetadataJSON,
      expectedUpdatedAt: expectedMarker.updatedAt,
      expectedNoteCount: expectedMarker.noteCount
    )
  }

  public func saveNotebookExpansion(
    title: String,
    seedPromptMarkdown: String,
    compactSummaryMarkdown: String,
    notebookMetaJSON: String,
    sourceNoteIds: [String]
  ) async throws -> SavedConversation {
    try service.saveConversation(
      title: title,
      transcript: [NoteConversationTurn(
        userMarkdown: seedPromptMarkdown,
        assistantMarkdown: compactSummaryMarkdown
      )],
      notebookMetaJSON: notebookMetaJSON,
      sourceLinks: NoteConversationSourceLinks(
        sourceNoteIds: sourceNoteIds,
        linkKind: "source-citation",
        provenance: .ai
      ),
      assignedBy: "riela-note-notebook-expansion"
    )
  }

  public func answerNotebookExpansion(
    request: RielaNoteNotebookExpansionRequest
  ) async throws -> RielaNoteNotebookExpansionAnswer {
    guard let notebookExpansionProvider else {
      throw RielaNoteNotebookExpansionError.notConfigured
    }
    return try await notebookExpansionProvider.answerNotebookExpansion(request: request)
  }

  public func appendNotebookExpansionTurn(
    notebookId: String,
    turnId: String,
    questionMarkdown: String,
    assistantMarkdown: String,
    sourceNoteIds: [String]
  ) async throws -> Note {
    try service.appendConversationTurn(
      notebookId: notebookId,
      turn: NoteConversationTurn(
        userMarkdown: questionMarkdown,
        assistantMarkdown: assistantMarkdown
      ),
      sourceLinks: NoteConversationSourceLinks(
        sourceNoteIds: sourceNoteIds,
        linkKind: "source-citation",
        provenance: .ai,
        allowMissingSourceNotes: true
      ),
      assignedBy: "riela-note-notebook-expansion",
      idempotencyKey: turnId
    )
  }
}
