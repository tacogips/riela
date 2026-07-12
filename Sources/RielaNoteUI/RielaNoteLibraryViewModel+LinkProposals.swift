import RielaNote

extension RielaNoteLibraryViewModel {
  public func proposeLinksForSelectedNote() async {
    guard let noteId = selectedDetail?.note.noteId else {
      return
    }
    guard !isLinkProposalLoading else {
      return
    }
    linkProposalGeneration += 1
    let generation = linkProposalGeneration
    isLinkProposalLoading = true
    linkProposalError = nil
    do {
      let proposals = try await client.proposeNoteLinks(noteId: noteId)
      guard isCurrentLinkProposal(generation: generation, noteId: noteId) else {
        return
      }
      linkProposals = proposals
      isLinkProposalLoading = false
    } catch {
      guard isCurrentLinkProposal(generation: generation, noteId: noteId) else {
        return
      }
      linkProposalError = String(describing: error)
      linkProposals = []
      isLinkProposalLoading = false
    }
  }

  public func clearLinkProposals() {
    linkProposalGeneration += 1
    linkProposals = []
    linkProposalError = nil
    isLinkProposalLoading = false
  }

  public func acceptLinkProposal(_ proposal: NoteLinkProposal) async throws {
    guard let noteId = selectedDetail?.note.noteId else {
      throw NoteServiceError.notFound("No note is selected.")
    }
    guard linkProposals.contains(where: {
      $0.targetNote.noteId == proposal.targetNote.noteId && $0.linkKind == proposal.linkKind
    }) else {
      throw NoteServiceError.invalidInput("That link proposal is no longer available.")
    }
    // A link failure surfaces in the proposal sheet's own error slot; it never
    // poisons the list `LoadState`, which stays `.loaded`.
    linkProposalError = nil
    do {
      selectedDetail = try await client.linkNote(
        noteId: noteId,
        targetNoteId: proposal.targetNote.noteId,
        linkKind: rielaNoteAllowedLinkKind(proposal.linkKind),
        provenance: .ai
      )
      linkProposals.removeAll {
        $0.targetNote.noteId == proposal.targetNote.noteId && $0.linkKind == proposal.linkKind
      }
    } catch {
      linkProposalError = rielaNoteLoadFailureMessage(error)
      throw error
    }
  }

  private func isCurrentLinkProposal(generation: Int, noteId: String) -> Bool {
    linkProposalGeneration == generation && selectedDetail?.note.noteId == noteId
  }
}
