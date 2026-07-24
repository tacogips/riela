import RielaNote
import SwiftUI

/// Left-hand file tree: notebooks as expandable folders with their notes as
/// children. Expanding a notebook lazily fetches its notes; the selected
/// notebook always mirrors the live `notebookNotes` so edits stay fresh.
public struct RielaNoteFileTreePane: View {
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  @State private var expandedNotebookIds: Set<String> = []
  @State private var pagesByNotebook: [String: RielaNoteFileTreeNotebookNotesPageState] = [:]
  @State private var cacheGeneration = 0
  private let onOpenNote: (String) -> Void
  private let pageSize = 200

  public init(
    viewModel: RielaNoteLibraryViewModel,
    onOpenNote: @escaping (String) -> Void = { _ in }
  ) {
    self.viewModel = viewModel
    self.onOpenNote = onOpenNote
  }

  public var body: some View {
    List {
      Section("Notebooks") {
        ForEach(viewModel.notebooks, id: \.notebookId) { notebook in
          DisclosureGroup(isExpanded: expansionBinding(for: notebook.notebookId)) {
            notebookChildren(notebook)
          } label: {
            notebookRow(notebook)
          }
        }
        if viewModel.canLoadMoreNotebooks {
          Button {
            Task {
              await viewModel.loadMoreNotebooks()
            }
          } label: {
            Label("Load more", systemImage: "ellipsis.circle")
          }
          .buttonStyle(.plain)
        }
      }
    }
    .listStyle(.sidebar)
    .overlay {
      if viewModel.state == .loading && viewModel.notebooks.isEmpty {
        ProgressView()
      } else if viewModel.state == .loaded && viewModel.notebooks.isEmpty {
        ContentUnavailableView("No notes", systemImage: "note.text")
      }
    }
    .onChange(of: viewModel.selectedNotebookId) { _, notebookId in
      // Keep the tree in sync with selections made elsewhere (search popup,
      // agent citations, links): reveal the selected notebook's children.
      if let notebookId {
        expandedNotebookIds.insert(notebookId)
        Task {
          await loadNotesIfNeeded(notebookId: notebookId)
        }
      }
    }
    .onChange(of: viewModel.fileTreeInvalidationRevision) { _, _ in
      resetCachedPages()
    }
  }

  private func notebookRow(_ notebook: Notebook) -> some View {
    Button {
      Task {
        await viewModel.requestSelection(.notebook(notebook.notebookId))
        guard viewModel.pendingSelection == nil else {
          return
        }
        expandedNotebookIds.insert(notebook.notebookId)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: notebook.notebookId == viewModel.selectedNotebookId ? "folder.fill" : "folder")
          .foregroundStyle(notebook.notebookId == viewModel.selectedNotebookId ? Color.accentColor : Color.secondary)
        Text(notebook.title)
          .lineLimit(1)
        Spacer(minLength: 4)
        if let noteCount = notebook.noteCount {
          Text("\(noteCount)")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu {
      Button {
        Task {
          await rielaNoteFileTreeExpandAction(viewModel: viewModel, notebook: notebook)
        }
      } label: {
        Label("Expand with Agent", systemImage: "sparkles")
      }
      .disabled(viewModel.isExpandingNotebook(notebook.notebookId))
    }
  }

  @ViewBuilder
  private func notebookChildren(_ notebook: Notebook) -> some View {
    let state = pageState(for: notebook.notebookId)
    if state.notes.isEmpty {
      Text("No notes")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .task {
          await loadNotesIfNeeded(notebookId: notebook.notebookId)
        }
    } else {
      ForEach(state.notes, id: \.noteId) { note in
        noteRow(note)
      }
      if state.canLoadMore {
        Button {
          Task {
            await loadNextPage(notebookId: notebook.notebookId)
          }
        } label: {
          Label("Load more", systemImage: "ellipsis.circle")
        }
        .buttonStyle(.plain)
      } else if state.isLoading {
        ProgressView()
          .controlSize(.small)
      }
    }
  }

  private func noteRow(_ note: Note) -> some View {
    let isSelected = viewModel.selectedNote?.noteId == note.noteId
    return Button {
      Task {
        await viewModel.requestSelection(.note(note.noteId))
        guard viewModel.pendingSelection == nil else {
          return
        }
        onOpenNote(note.noteId)
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "doc.text.fill" : "doc.text")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        Text(note.title ?? note.noteId)
          .fontWeight(isSelected ? .semibold : .regular)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private func pageState(for notebookId: String) -> RielaNoteFileTreeNotebookNotesPageState {
    pagesByNotebook[notebookId] ?? RielaNoteFileTreeNotebookNotesPageState()
  }

  private func expansionBinding(for notebookId: String) -> Binding<Bool> {
    Binding {
      expandedNotebookIds.contains(notebookId)
    } set: { expanded in
      if expanded {
        expandedNotebookIds.insert(notebookId)
        Task {
          await loadNotesIfNeeded(notebookId: notebookId)
        }
      } else {
        expandedNotebookIds.remove(notebookId)
      }
    }
  }

  private func loadNotesIfNeeded(notebookId: String) async {
    let state = pageState(for: notebookId)
    guard !state.didLoad, !state.isLoading else {
      return
    }
    await loadNextPage(notebookId: notebookId, generation: cacheGeneration)
  }

  private func loadNextPage(notebookId: String, generation: Int? = nil) async {
    let generation = generation ?? cacheGeneration
    var state = pageState(for: notebookId)
    guard !state.isLoading else {
      return
    }
    state.markLoading()
    pagesByNotebook[notebookId] = state
    do {
      let page = try await viewModel.client.listNotes(
        notebookId: notebookId,
        limit: pageSize + 1,
        offset: state.nextOffset
      )
      guard generation == cacheGeneration else {
        return
      }
      state.mergeFetchedPage(page, pageSize: pageSize)
      pagesByNotebook[notebookId] = state
    } catch {
      guard generation == cacheGeneration else {
        return
      }
      state.markLoadFinished()
      pagesByNotebook[notebookId] = state
    }
  }

  private func resetCachedPages() {
    cacheGeneration += 1
    pagesByNotebook.removeAll()
    for notebookId in expandedNotebookIds {
      Task {
        await loadNotesIfNeeded(notebookId: notebookId)
      }
    }
  }
}

@MainActor
func rielaNoteFileTreeExpandAction(
  viewModel: RielaNoteLibraryViewModel,
  notebook: Notebook
) async {
  await viewModel.expandNotebook(notebook)
}
