import Foundation

extension RielaNoteLibraryViewModel {
  public func translateSelectedNote(targetLanguage rawTargetLanguage: String? = nil) async {
    guard let detail = selectedDetail else {
      return
    }
    guard !detail.note.readOnly, !isTranslateNoteLoading else {
      return
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
        return
      }
      selectedDetail = try await client.updateNoteBody(noteId: noteId, bodyMarkdown: draft.rewrittenMarkdown)
      if let index = notebookNotes.firstIndex(where: { $0.noteId == noteId }),
         let updatedNote = selectedDetail?.note {
        notebookNotes[index] = updatedNote
      }
      clearResolvedFileSelection()
      contentMode = .text
      let summary = draft.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      translateNoteSummary = summary.isEmpty ? "Translated to \(targetLanguage)." : summary
      isTranslateNoteLoading = false
    } catch {
      guard isCurrentTranslation(generation: generation, noteId: noteId) else {
        return
      }
      translateNoteError = translateNoteErrorMessage(error)
      translateNoteSummary = nil
      isTranslateNoteLoading = false
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
