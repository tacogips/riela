import RielaNote
import SwiftUI

/// Search presented as a popup: filters on the left, live results on the right.
/// Picking a result selects the note and dismisses the popup.
public struct RielaNoteSearchPopupSheet: View {
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  private let onClose: () -> Void

  public init(viewModel: RielaNoteLibraryViewModel, onClose: @escaping () -> Void) {
    self.viewModel = viewModel
    self.onClose = onClose
  }

  public var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Search notes", systemImage: "magnifyingglass")
          .font(.headline)
        Spacer()
        Button("Done") {
          onClose()
        }
        .keyboardShortcut(.defaultAction)
      }
      .padding()
      Divider()
      HStack(spacing: 0) {
        RielaNoteFilterPane(viewModel: viewModel)
          .frame(width: 300)
        Divider()
        results
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 720, idealWidth: 820, minHeight: 460, idealHeight: 560)
  }

  @ViewBuilder
  private var results: some View {
    switch contentMode {
    case .idle:
      ContentUnavailableView(
        "Search your notes",
        systemImage: "magnifyingglass",
        description: Text("Type a query or pick filters to see matching notes.")
      )
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .empty:
      ContentUnavailableView.search
    case .tagKanban:
      tagKanbanResults()
    case let .tagKanbanFailed(message):
      tagKanbanResults(failureMessage: message)
    case let .tagKanbanLoadFailed(message):
      ContentUnavailableView(
        "Unable to load notebook board",
        systemImage: "exclamationmark.triangle",
        description: Text(message)
      )
    case .noteResults:
      List {
        noteResultRows
      }
      .listStyle(.inset)
    }
  }

  private func tagKanbanResults(failureMessage: String? = nil) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16) {
        if let failureMessage {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
              Text("Unable to update notebook board")
                .font(.headline)
            }
            Text(failureMessage)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
          .overlay {
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.red.opacity(0.8), lineWidth: 1)
          }
          .accessibilityIdentifier("notebook-kanban-error")
        }
        RielaNoteTagKanbanSections(viewModel: viewModel) { notebookId in
          await viewModel.requestSelection(.notebook(notebookId))
          onClose()
        }
        Divider()
        Text("Notes")
          .font(.headline)
        if viewModel.searchResults.isEmpty {
          Text("No matching notes")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          noteResultRows
        }
      }
      .padding()
    }
  }

  var contentMode: RielaNoteSearchPopupContentMode {
    guard viewModel.isSearching else {
      return .idle
    }
    if viewModel.isTagKanbanActive {
      if case let .failed(message) = viewModel.state {
        return viewModel.hasCurrentProgressMutationFailure
          ? .tagKanbanFailed(message)
          : .tagKanbanLoadFailed(message)
      }
      guard viewModel.state != .loading,
            viewModel.hasCurrentTagKanbanSnapshot else {
        return .loading
      }
      return .tagKanban
    }
    guard !viewModel.searchResults.isEmpty else {
      return viewModel.state == .loading ? .loading : .empty
    }
    return .noteResults
  }

  @ViewBuilder
  private var noteResultRows: some View {
    ForEach(viewModel.searchResults, id: \.note.noteId) { result in
      Button {
        openResult(result.note.noteId)
      } label: {
        RielaNoteSearchResultRow(
          result: result,
          isSelected: viewModel.selectedNote?.noteId == result.note.noteId
        )
      }
      .buttonStyle(.plain)
    }
    if viewModel.canLoadMoreSearchResults {
      Button {
        Task {
          await viewModel.loadMoreSearchResults()
        }
      } label: {
        Label("Load more", systemImage: "ellipsis.circle")
      }
      .buttonStyle(.plain)
    }
  }

  private func openResult(_ noteId: String) {
    Task {
      await viewModel.requestSelection(.note(noteId))
      // Yield presentation to the root so its pending-selection confirmation can
      // surface when body edits defer this search-result selection.
      onClose()
    }
  }
}

enum RielaNoteSearchPopupContentMode: Equatable {
  case idle
  case loading
  case empty
  case tagKanban
  case tagKanbanFailed(String)
  case tagKanbanLoadFailed(String)
  case noteResults
}
