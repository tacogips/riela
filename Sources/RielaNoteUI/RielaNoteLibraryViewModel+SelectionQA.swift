import Foundation

extension RielaNoteLibraryViewModel {
  /// Asks the agent a question scoped to the selected text, then persists the answer as an
  /// agent-authored comment. Returns `true` only when a comment was persisted and the
  /// selected detail refreshed. On any failure nothing is persisted and
  /// `selectionQuestionError` is set. Stale results (note switch / superseding request) are
  /// dropped without mutating state.
  @discardableResult
  public func askSelectionQuestion(
    question: String,
    draftBodyMarkdown: String,
    selectedText: String,
    selectionStart: Int,
    selectionEnd: Int
  ) async -> Bool {
    guard let noteId = selectedDetail?.note.noteId else {
      return false
    }
    let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedQuestion.isEmpty,
          !selectedText.isEmpty,
          !isSelectionQuestionLoading else {
      return false
    }
    selectionQuestionGeneration += 1
    let generation = selectionQuestionGeneration
    isSelectionQuestionLoading = true
    selectionQuestionError = nil
    didSaveSelectionQuestionComment = false
    do {
      let answer = try await client.answerNoteSelectionQuestion(
        noteId: noteId,
        question: normalizedQuestion,
        bodyMarkdown: draftBodyMarkdown,
        selectedText: selectedText,
        selectionStart: selectionStart,
        selectionEnd: selectionEnd
      )
      guard isCurrentSelectionQuestion(generation: generation, noteId: noteId) else {
        return false
      }
      let commentMarkdown = rielaNoteSelectionQACommentMarkdown(
        selectedText: selectedText,
        question: normalizedQuestion,
        answerMarkdown: answer.answerMarkdown
      )
      let detail = try await client.addComment(
        noteId: noteId,
        bodyMarkdown: commentMarkdown,
        author: "note-agent"
      )
      guard isCurrentSelectionQuestion(generation: generation, noteId: noteId) else {
        return false
      }
      selectedDetail = detail
      didSaveSelectionQuestionComment = true
      isSelectionQuestionLoading = false
      return true
    } catch {
      guard isCurrentSelectionQuestion(generation: generation, noteId: noteId) else {
        return false
      }
      selectionQuestionError = selectionQuestionErrorMessage(error)
      didSaveSelectionQuestionComment = false
      isSelectionQuestionLoading = false
      return false
    }
  }

  /// Promotes a comment into a new linked notebook and refreshes the selected detail so the
  /// new link surfaces in the Links section.
  public func promoteCommentToNotebook(commentId: String) async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    guard !isCommentPromotionLoading else {
      return
    }
    commentPromotionGeneration += 1
    let generation = commentPromotionGeneration
    isCommentPromotionLoading = true
    commentPromotionError = nil
    do {
      let detail = try await client.promoteCommentToNotebook(noteId: noteId, commentId: commentId)
      guard isCurrentCommentPromotion(generation: generation, noteId: noteId) else {
        return
      }
      // Promotion adds a link + new notebook/note but never mutates the source note row,
      // so refreshing selectedDetail is sufficient (the list-row Note is unchanged).
      selectedDetail = detail
      isCommentPromotionLoading = false
    } catch {
      guard isCurrentCommentPromotion(generation: generation, noteId: noteId) else {
        return
      }
      commentPromotionError = String(describing: error)
      isCommentPromotionLoading = false
    }
  }

  public func clearSelectionQAState() {
    selectionQuestionGeneration += 1
    commentPromotionGeneration += 1
    selectionQuestionError = nil
    isSelectionQuestionLoading = false
    didSaveSelectionQuestionComment = false
    commentPromotionError = nil
    isCommentPromotionLoading = false
  }

  public func markSelectionQuestionSelectionStale() {
    selectionQuestionGeneration += 1
    selectionQuestionError =
      "The selection changed while the question was being prepared. Reselect the text and try again."
    didSaveSelectionQuestionComment = false
    isSelectionQuestionLoading = false
  }

  private func isCurrentSelectionQuestion(generation: Int, noteId: String) -> Bool {
    selectionQuestionGeneration == generation && selectedDetail?.note.noteId == noteId
  }

  private func isCurrentCommentPromotion(generation: Int, noteId: String) -> Bool {
    commentPromotionGeneration == generation && selectedDetail?.note.noteId == noteId
  }

  private func selectionQuestionErrorMessage(_ error: Error) -> String {
    if case RielaNoteSelectionQuestionError.notConfigured = error {
      return "Selection question agent is not configured."
    }
    return String(describing: error)
  }
}
