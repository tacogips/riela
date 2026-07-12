import Foundation

extension RielaNoteLibraryViewModel {
  /// Runs a whole-note translation and returns the proposed draft for the caller
  /// to load into the body editor for review. The translation is never persisted
  /// here — the store body is untouched until the user saves through the normal
  /// Save path (which enforces the `expectedNoteId` version check). A stale
  /// result (the note was switched while the workflow ran) is dropped, returning
  /// `nil`.
  @discardableResult
  public func translateSelectedNote(targetLanguage rawTargetLanguage: String? = nil) async
    -> RielaNoteEditRewriteDraft?
  {
    guard let detail = selectedDetail else {
      return nil
    }
    guard !detail.note.readOnly, !isTranslateNoteLoading else {
      return nil
    }
    let targetLanguage = rielaNoteNormalizedTranslationTargetLanguage(rawTargetLanguage ?? translationTargetLanguage)
    translationTargetLanguage = targetLanguage
    translateNoteGeneration += 1
    let generation = translateNoteGeneration
    let noteId = detail.note.noteId
    let originalMarkdown = detail.note.bodyMarkdown
    isTranslateNoteLoading = true
    translateNoteError = nil
    translateNoteSummary = nil
    do {
      let draft = try await client.proposeNoteBodyRewrite(
        noteId: noteId,
        instruction: rielaNoteTranslateWholeNoteInstruction(targetLanguage: targetLanguage),
        bodyMarkdown: originalMarkdown,
        selectedText: nil,
        selectionStart: nil,
        selectionEnd: nil
      )
      guard isCurrentTranslation(generation: generation, noteId: noteId) else {
        isTranslateNoteLoading = false
        return nil
      }
      let summary = draft.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      translateNoteSummary = summary.isEmpty ? "Translated to \(targetLanguage). Review and save." : summary
      isTranslateNoteLoading = false
      return draft
    } catch {
      guard isCurrentTranslation(generation: generation, noteId: noteId) else {
        isTranslateNoteLoading = false
        return nil
      }
      translateNoteError = translateNoteErrorMessage(error)
      translateNoteSummary = nil
      isTranslateNoteLoading = false
      return nil
    }
  }

  public func clearTranslateNoteState() {
    translateNoteGeneration += 1
    translateNoteError = nil
    translateNoteSummary = nil
    isTranslateNoteLoading = false
  }

  private func isCurrentTranslation(generation: Int, noteId: String) -> Bool {
    translateNoteGeneration == generation && selectedDetail?.note.noteId == noteId
  }

  private func translateNoteErrorMessage(_ error: Error) -> String {
    if case RielaNoteEditRewriteError.notConfigured = error {
      return "Translation is not configured."
    }
    return String(describing: error)
  }
}

public func rielaNoteNormalizedTranslationTargetLanguage(_ rawValue: String) -> String {
  let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? "English" : trimmed
}

public func rielaNoteTranslateWholeNoteInstruction(targetLanguage: String) -> String {
  let language = rielaNoteNormalizedTranslationTargetLanguage(targetLanguage)
  return """
  Translate the entire note to \(language).
  Return only the translated note body as Markdown.
  Preserve headings, lists, and paragraph structure where possible.
  Do not add commentary, explanations, or labels.
  """
}
