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
    if !viewModel.isSearching {
      ContentUnavailableView(
        "Search your notes",
        systemImage: "magnifyingglass",
        description: Text("Type a query or pick filters to see matching notes.")
      )
    } else if viewModel.searchResults.isEmpty {
      if viewModel.state == .loading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView.search
      }
    } else {
      List {
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
      .listStyle(.inset)
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
