import RielaNote
import SwiftUI

public enum RielaNoteCreationDestination: String, Identifiable, Hashable, Sendable {
  case memo
  case selectedNotebook

  public var id: String {
    rawValue
  }

  var title: String {
    switch self {
    case .memo:
      return "New memo"
    case .selectedNotebook:
      return "New note"
    }
  }

  func destinationText(selectedNotebookTitle: String?) -> String {
    switch self {
    case .memo:
      return "User memo"
    case .selectedNotebook:
      return selectedNotebookTitle.map { "Notebook: \($0)" } ?? "Selected notebook"
    }
  }
}

public struct RielaNoteComposeView: View {
  let destination: RielaNoteCreationDestination
  let selectedNotebookTitle: String?
  let onCancel: () -> Void
  let onSave: (String) -> Void
  @State private var bodyMarkdown = ""
  @State private var isSaving = false
  @FocusState private var isEditorFocused: Bool

  public init(
    destination: RielaNoteCreationDestination,
    selectedNotebookTitle: String? = nil,
    onCancel: @escaping () -> Void,
    onSave: @escaping (String) -> Void
  ) {
    self.destination = destination
    self.selectedNotebookTitle = selectedNotebookTitle
    self.onCancel = onCancel
    self.onSave = onSave
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      TextEditor(text: $bodyMarkdown)
        .font(.body.monospaced())
        .focused($isEditorFocused)
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button {
          guard !isSaving else {
            return
          }
          isSaving = true
          onSave(bodyMarkdown)
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSaving || bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .keyboardShortcut(.return, modifiers: .command)
      }
    }
    .padding()
    .navigationTitle(destination.title)
    .task {
      isEditorFocused = true
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(destination.destinationText(selectedNotebookTitle: selectedNotebookTitle), systemImage: "tray.and.arrow.down")
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(derivedTitle)
        .font(.title2)
        .fontWeight(.semibold)
        .lineLimit(2)
    }
  }

  private var derivedTitle: String {
    NoteTitleDerivation.fallbackTitle(from: bodyMarkdown, defaultTitle: "Untitled")
  }
}
