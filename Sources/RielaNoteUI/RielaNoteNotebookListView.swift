import RielaNote
import SwiftUI

public struct RielaNoteNotebookListView: View {
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  @State private var isSearchPresented = false
  private let onCreate: (RielaNoteCreationDestination) -> Void
  private let onOpenNote: (String) -> Void

  public init(
    viewModel: RielaNoteLibraryViewModel,
    onCreate: @escaping (RielaNoteCreationDestination) -> Void = { _ in },
    onOpenNote: @escaping (String) -> Void = { _ in }
  ) {
    self.viewModel = viewModel
    self.onCreate = onCreate
    self.onOpenNote = onOpenNote
  }

  public var body: some View {
    List(selection: selectedNoteIdBinding) {
      if viewModel.isSearching {
        searchResults
      } else {
        notebooks
        notebookNotes
      }
    }
    .searchable(text: $viewModel.searchText, isPresented: $isSearchPresented)
    .onSubmit(of: .search) {
      Task {
        await viewModel.submitSearch()
      }
    }
    .onChange(of: viewModel.searchText) { _, newValue in
      Task {
        await viewModel.updateSearchText(newValue)
      }
    }
    .refreshable {
      await viewModel.refresh()
    }
    .toolbar {
      ToolbarItem {
        Button {
          isSearchPresented = true
        } label: {
          Label("Search", systemImage: "magnifyingglass")
        }
        .help("Search notes")
        .keyboardShortcut("f", modifiers: .command)
      }
      ToolbarItem {
        Button {
          Task {
            await viewModel.refresh()
          }
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .help("Refresh notes")
        .keyboardShortcut("r", modifiers: .command)
      }
      ToolbarItem {
        Button {
          onCreate(.selectedNotebook)
        } label: {
          Label("New note", systemImage: "doc.badge.plus")
        }
        .disabled(!viewModel.canCreateNoteInSelectedNotebook)
        .help("New note in selected notebook")
        .keyboardShortcut("n", modifiers: [.command, .shift])
      }
      ToolbarItem {
        Button {
          onCreate(.memo)
        } label: {
          Label("New memo", systemImage: "square.and.pencil")
        }
        .help("New memo")
        .keyboardShortcut("n", modifiers: .command)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      RielaNoteQuickCreateButton(
        canCreateInNotebook: viewModel.canCreateNoteInSelectedNotebook,
        onCreateMemo: { onCreate(.memo) },
        onCreateInNotebook: { onCreate(.selectedNotebook) }
      )
    }
    .overlay {
      if case let .failed(message) = viewModel.state {
        ContentUnavailableView("Unable to load notes", systemImage: "exclamationmark.triangle", description: Text(message))
      } else if !viewModel.isSearching && viewModel.notebooks.isEmpty {
        ContentUnavailableView("No notes", systemImage: "note.text")
      } else if viewModel.isSearching && viewModel.searchResults.isEmpty {
        ContentUnavailableView.search
      }
    }
  }

  private var notebooks: some View {
    Section("Notebooks") {
      ForEach(viewModel.notebooks, id: \.notebookId) { notebook in
        Button {
          Task {
            await viewModel.selectNotebook(notebook.notebookId)
          }
        } label: {
          RielaNoteNotebookRow(notebook: notebook)
        }
        .buttonStyle(.plain)
      }
      if viewModel.canLoadMoreNotebooks {
        Button {
          Task {
            await viewModel.loadMoreNotebooks()
          }
        } label: {
          Label("Load more", systemImage: "ellipsis.circle")
        }
      }
    }
  }

  @ViewBuilder
  private var notebookNotes: some View {
    if !viewModel.notebookNotes.isEmpty {
      Section("Notes") {
        ForEach(viewModel.notebookNotes, id: \.noteId) { note in
          RielaNoteListRow(note: note, isSelected: viewModel.selectedNote?.noteId == note.noteId)
            .tag(note.noteId)
            .onTapGesture {
              open(note.noteId)
            }
            .accessibilityAddTraits(viewModel.selectedNote?.noteId == note.noteId ? .isSelected : [])
        }
        if viewModel.canLoadMoreNotebookNotes {
          Button {
            Task {
              await viewModel.loadMoreNotebookNotes()
            }
          } label: {
            Label("Load more", systemImage: "ellipsis.circle")
          }
        }
      }
    }
  }

  private var selectedNoteIdBinding: Binding<String?> {
    Binding {
      viewModel.selectedNote?.noteId
    } set: { noteId in
      guard let noteId, noteId != viewModel.selectedNote?.noteId else {
        return
      }
      open(noteId)
    }
  }

  private var searchResults: some View {
    Section {
      ForEach(viewModel.searchResults, id: \.note.noteId) { result in
        RielaNoteSearchResultRow(
          result: result,
          isSelected: viewModel.selectedNote?.noteId == result.note.noteId
        )
        .tag(result.note.noteId)
        .onTapGesture {
          open(result.note.noteId)
        }
        .accessibilityAddTraits(viewModel.selectedNote?.noteId == result.note.noteId ? .isSelected : [])
      }
      if viewModel.canLoadMoreSearchResults {
        Button {
          Task {
            await viewModel.loadMoreSearchResults()
          }
        } label: {
          Label("Load more", systemImage: "ellipsis.circle")
        }
      }
    }
  }

  private func open(_ noteId: String) {
    Task {
      await viewModel.selectNote(noteId)
      onOpenNote(noteId)
    }
  }

}

struct RielaNoteNotebookRow: View {
  var notebook: Notebook

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text(notebook.title)
          .font(.headline)
          .lineLimit(2)
        Spacer(minLength: 8)
        if let kind = notebook.kindTagName {
          RielaNoteTagChip(label: kind.replacingOccurrences(of: "notebook-kind:", with: ""), provenance: .system)
        }
      }
      if let preview = notebook.firstNotePreview, !preview.isEmpty {
        Text(preview)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      HStack(spacing: 5) {
        Text("Created \(rielaNoteRelativeTimestampText(notebook.createdAt))")
        if let noteCount = notebook.noteCount {
          Text("-")
          Text(rielaNoteNotebookNoteCountText(noteCount))
        }
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }
}

func rielaNoteNotebookNoteCountText(_ count: Int) -> String {
  count == 1 ? "1 note" : "\(count) notes"
}

struct RielaNoteSearchResultRow: View {
  var result: NoteSearchResult
  var isSelected: Bool = false

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: isSelected ? "doc.text.magnifyingglass" : "magnifyingglass")
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 6) {
        Text(result.note.title ?? result.note.noteId)
          .font(.headline)
          .fontWeight(isSelected ? .semibold : .regular)
          .lineLimit(2)
        Text(result.snippet)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
        if result.isLinkedNeighbor {
          Label("Linked", systemImage: "link")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        RielaNoteTagChipRow(tags: result.note.tags)
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
  }
}

struct RielaNoteListRow: View {
  var note: Note
  var isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: isSelected ? "doc.text.fill" : "doc.text")
        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 4) {
        Text(note.title ?? note.noteId)
          .font(.subheadline)
          .fontWeight(isSelected ? .semibold : .regular)
          .lineLimit(2)
        Text("#\(note.noteNumber)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer(minLength: 8)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }
}

private extension Notebook {
  var kindTagName: String? {
    tags.first { assignment in
      assignment.tag.name.hasPrefix("notebook-kind:")
    }?.tag.name
  }
}
