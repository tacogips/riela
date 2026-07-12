import Foundation

extension RielaNoteLibraryViewModel {
  public func proposeBodyRewrite(
    instruction: String,
    draftBodyMarkdown: String,
    selectedText: String?,
    selectionStart: Int?,
    selectionEnd: Int?
  ) async -> RielaNoteEditRewriteDraft? {
    guard let noteId = selectedDetail?.note.noteId else {
      return nil
    }
    let normalizedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedInstruction.isEmpty, !isEditRewriteLoading else {
      return nil
    }
    editRewriteGeneration += 1
    let generation = editRewriteGeneration
    isEditRewriteLoading = true
    editRewriteError = nil
    editRewriteSummary = nil
    do {
      let draft = try await client.proposeNoteBodyRewrite(
        noteId: noteId,
        instruction: normalizedInstruction,
        bodyMarkdown: draftBodyMarkdown,
        selectedText: selectedText,
        selectionStart: selectionStart,
        selectionEnd: selectionEnd
      )
      guard isCurrentEditRewrite(generation: generation, noteId: noteId) else {
        isEditRewriteLoading = false
        return nil
      }
      editRewriteSummary = draft.summary
      isEditRewriteLoading = false
      return draft
    } catch {
      guard isCurrentEditRewrite(generation: generation, noteId: noteId) else {
        isEditRewriteLoading = false
        return nil
      }
      editRewriteError = editRewriteErrorMessage(error)
      editRewriteSummary = nil
      isEditRewriteLoading = false
      return nil
    }
  }

  public func clearEditRewriteState() {
    editRewriteGeneration += 1
    editRewriteError = nil
    editRewriteSummary = nil
    isEditRewriteLoading = false
  }

  public func markEditRewriteResultStale() {
    editRewriteGeneration += 1
    editRewriteError = "The draft changed while the edit agent was running. Retry with the latest draft."
    editRewriteSummary = nil
    isEditRewriteLoading = false
  }

  private func isCurrentEditRewrite(generation: Int, noteId: String) -> Bool {
    editRewriteGeneration == generation && selectedDetail?.note.noteId == noteId
  }

  private func editRewriteErrorMessage(_ error: Error) -> String {
    if case RielaNoteEditRewriteError.notConfigured = error {
      return "Edit agent is not configured."
    }
    rielaNoteLogUIError("editRewrite", error)
    return "Couldn't rewrite the draft. Please try again."
  }
}
