import RielaNote

struct RielaNoteNotebookMutationFailure: Equatable {
  let context: RielaNoteNotebookBoardContext
  let message: String
}

public extension RielaNoteLibraryViewModel {
  internal var hasCurrentTagKanbanSnapshot: Bool {
    isTagKanbanActive
      && notebookSnapshotContext == notebookProgressMutationContext()
  }

  internal var hasCurrentProgressMutationFailure: Bool {
    guard case let .failed(message) = state else {
      return false
    }
    return notebookProgressMutationFailure == RielaNoteNotebookMutationFailure(
      context: notebookProgressMutationContext(),
      message: message
    )
  }

  func notebooks(for progress: NotebookProgress) -> [Notebook] {
    notebooks.filter { $0.progress == progress }
  }

  func setNotebookProgress(
    notebookId: String,
    progress: NotebookProgress
  ) async {
    let mutationGeneration = nextNotebookProgressMutationGeneration(
      notebookId: notebookId,
      progress: progress
    )
    let context = notebookProgressMutationContext()
    do {
      let updated = try await client.setNotebookProgress(
        notebookId: notebookId,
        progress: progress
      )
      guard isCurrentNotebookProgressMutation(
        notebookId: notebookId,
        mutationGeneration: mutationGeneration,
        context: context
      ) else {
        await reassertCurrentNotebookProgress(
          notebookId: notebookId,
          supersededGeneration: mutationGeneration,
          context: context
        )
        return
      }
      if let index = notebooks.firstIndex(where: { $0.notebookId == notebookId }) {
        notebooks[index] = updated
      }
      notebookProgressMutationFailure = nil
      state = .loaded
    } catch {
      guard isCurrentNotebookProgressMutation(
        notebookId: notebookId,
        mutationGeneration: mutationGeneration,
        context: context
      ) else {
        return
      }
      let failureMessage = rielaNoteLoadFailureMessage(error)
      await reconcileNotebookAfterProgressFailure(
        notebookId: notebookId,
        mutationGeneration: mutationGeneration,
        context: context
      )
      guard isCurrentNotebookProgressMutation(
        notebookId: notebookId,
        mutationGeneration: mutationGeneration,
        context: context
      ) else {
        return
      }
      notebookProgressMutationFailure = RielaNoteNotebookMutationFailure(
        context: context,
        message: failureMessage
      )
      state = .failed(failureMessage)
    }
  }

  private func nextNotebookProgressMutationGeneration(
    notebookId: String,
    progress: NotebookProgress
  ) -> Int {
    let generation = (notebookProgressMutationGenerations[notebookId] ?? 0) + 1
    notebookProgressMutationGenerations[notebookId] = generation
    notebookProgressMutationTargets[notebookId] = progress
    return generation
  }

  private func isCurrentNotebookProgressMutation(
    notebookId: String,
    mutationGeneration: Int,
    context: RielaNoteNotebookBoardContext
  ) -> Bool {
    notebookProgressMutationGenerations[notebookId] == mutationGeneration
      && selectedSearchTagNames.sorted() == context.tagFilter
      && filter == context.filter
  }

  private func notebookProgressMutationContext() -> RielaNoteNotebookBoardContext {
    RielaNoteNotebookBoardContext(
      tagFilter: selectedSearchTagNames.sorted(),
      filter: filter
    )
  }

  private func reconcileNotebookAfterProgressFailure(
    notebookId: String,
    mutationGeneration: Int,
    context: RielaNoteNotebookBoardContext
  ) async {
    let loadedNotebookCount = max(notebooksOffset, notebooks.count, notebookPageSize)
    guard let page = try? await client.listNotebooks(
      limit: loadedNotebookCount,
      offset: 0,
      tagFilter: context.tagFilter,
      filter: context.filter
    ),
    isCurrentNotebookProgressMutation(
      notebookId: notebookId,
      mutationGeneration: mutationGeneration,
      context: context
    ),
    let refreshed = page.first(where: { $0.notebookId == notebookId }),
    let index = notebooks.firstIndex(where: { $0.notebookId == notebookId }) else {
      return
    }
    notebooks[index] = refreshed
  }

  private func reassertCurrentNotebookProgress(
    notebookId: String,
    supersededGeneration: Int,
    context: RielaNoteNotebookBoardContext
  ) async {
    // Database convergence to the newest requested progress must not be gated on
    // the board context: a stale write that lands last has to be corrected even
    // if the user has since switched the active tag filter/sort. Only the UI
    // mutations below stay context-gated (via isCurrentNotebookProgressMutation).
    guard let currentGeneration = notebookProgressMutationGenerations[notebookId],
          currentGeneration > supersededGeneration,
          let currentTarget = notebookProgressMutationTargets[notebookId] else {
      return
    }
    do {
      let updated = try await client.setNotebookProgress(
        notebookId: notebookId,
        progress: currentTarget
      )
      guard isCurrentNotebookProgressMutation(
        notebookId: notebookId,
        mutationGeneration: currentGeneration,
        context: context
      ) else {
        await reassertCurrentNotebookProgress(
          notebookId: notebookId,
          supersededGeneration: currentGeneration,
          context: context
        )
        return
      }
      if let index = notebooks.firstIndex(where: { $0.notebookId == notebookId }) {
        notebooks[index] = updated
      }
      notebookProgressMutationFailure = nil
      state = .loaded
    } catch {
      guard isCurrentNotebookProgressMutation(
        notebookId: notebookId,
        mutationGeneration: currentGeneration,
        context: context
      ) else {
        return
      }
      await reconcileNotebookAfterProgressFailure(
        notebookId: notebookId,
        mutationGeneration: currentGeneration,
        context: context
      )
      let failureMessage = rielaNoteLoadFailureMessage(error)
      notebookProgressMutationFailure = RielaNoteNotebookMutationFailure(
        context: context,
        message: failureMessage
      )
      state = .failed(failureMessage)
    }
  }
}
