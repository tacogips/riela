import RielaNote
import SwiftUI

struct RielaNoteTagKanbanSections: View {
  @ObservedObject var viewModel: RielaNoteLibraryViewModel
  var onSelectNotebook: (String) async -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      ForEach(NotebookProgress.allCases, id: \.self) { progress in
        let notebooks = viewModel.notebooks(for: progress)
        VStack(alignment: .leading, spacing: 8) {
          Text(rielaNoteNotebookProgressLabel(progress))
            .font(.headline)
          Divider()
          if notebooks.isEmpty {
            Text("No notebooks")
              .font(.caption)
              .foregroundStyle(.tertiary)
          } else {
            ForEach(notebooks, id: \.notebookId) { notebook in
              notebookRow(notebook)
            }
          }
        }
      }
      if viewModel.canLoadMoreNotebooks {
        Button {
          Task {
            await viewModel.loadMoreNotebooks()
          }
        } label: {
          Label("Load more notebooks", systemImage: "ellipsis.circle")
        }
      }
    }
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Notebook Kanban")
  }

  private func notebookRow(_ notebook: Notebook) -> some View {
    HStack(spacing: 8) {
      Button {
        Task {
          await onSelectNotebook(notebook.notebookId)
        }
      } label: {
        RielaNoteNotebookRow(notebook: notebook)
      }
      .buttonStyle(.plain)
      Menu {
        ForEach(NotebookProgress.allCases, id: \.self) { targetProgress in
          Button {
            Task {
              await viewModel.setNotebookProgress(
                notebookId: notebook.notebookId,
                progress: targetProgress
              )
            }
          } label: {
            Label(
              rielaNoteNotebookProgressLabel(targetProgress),
              systemImage: rielaNoteNotebookProgressSystemImage(targetProgress)
            )
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("Change progress for \(notebook.title)")
    }
  }
}
