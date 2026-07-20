import SwiftUI
import UniformTypeIdentifiers

public struct RielaNoteAgentView: View {
  @ObservedObject private var viewModel: RielaNoteAgentViewModel
  @State private var isFileImporterPresented = false
  @FocusState private var isComposerFocused: Bool
  private let onOpenCitation: (String) -> Void

  public init(
    viewModel: RielaNoteAgentViewModel,
    onOpenCitation: @escaping (String) -> Void = { _ in }
  ) {
    self.viewModel = viewModel
    self.onOpenCitation = onOpenCitation
  }

  public var body: some View {
    VStack(spacing: 0) {
      toolbar
      if let errorMessage = viewModel.errorMessage {
        errorBanner(errorMessage)
      }
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(viewModel.turns) { turn in
            RielaNoteAgentTurnView(turn: turn, onOpenCitation: onOpenCitation)
          }
        }
        .padding()
        .frame(maxWidth: 900, alignment: .leading)
        .frame(maxWidth: .infinity)
      }
      Divider()
      if let attachmentError = viewModel.attachmentError {
        errorBanner(attachmentError)
      }
      if !viewModel.draftAttachments.isEmpty {
        attachmentChips
      }
      composer
    }
    .navigationTitle("Agent")
    .fileImporter(
      isPresented: $isFileImporterPresented,
      allowedContentTypes: [.item],
      allowsMultipleSelection: true
    ) { result in
      attachFiles(result)
    }
    .task(id: viewModel.composerFocusRequestRevision) {
      guard viewModel.composerFocusRequestRevision > 0 else {
        return
      }
      await Task.yield()
      isComposerFocused = true
    }
  }

  private var attachmentChips: some View {
    FlowLayout(spacing: 6) {
      ForEach(viewModel.draftAttachments) { attachment in
        HStack(spacing: 4) {
          Image(systemName: "doc.text")
          Text(attachment.filename)
            .lineLimit(1)
          Button {
            viewModel.removeAttachment(id: attachment.id)
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Remove attachment")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.secondary.opacity(0.14), in: Capsule())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.top, 8)
  }

  private func attachFiles(_ result: Result<[URL], Error>) {
    guard case let .success(urls) = result else {
      return
    }
    for url in urls {
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing {
          url.stopAccessingSecurityScopedResource()
        }
      }
      guard let data = try? Data(contentsOf: url) else {
        viewModel.reportAttachmentReadFailure(filename: url.lastPathComponent)
        continue
      }
      viewModel.addAttachment(filename: url.lastPathComponent, data: data)
    }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Toggle("Temp chat (not saved)", isOn: $viewModel.isTemporaryChat)
        .toggleStyle(.switch)
      Spacer()
      if let notebookId = viewModel.autoSaveNotebookId {
        Label(notebookId, systemImage: "tray.full")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Button {
        viewModel.startNewConversation()
      } label: {
        Label("New chat", systemImage: "plus.bubble")
      }
      .disabled(!viewModel.canStartNewConversation)
      Button {
        Task {
          await viewModel.saveTemporaryConversation()
        }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .disabled(!viewModel.canSaveTemporaryConversation)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Label("Agent error", systemImage: "exclamationmark.triangle")
        .fontWeight(.semibold)
      Text(message)
        .lineLimit(2)
      Spacer()
    }
    .font(.caption)
    .foregroundStyle(.red)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.red.opacity(0.08))
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      Button {
        isFileImporterPresented = true
      } label: {
        Image(systemName: "paperclip")
      }
      .buttonStyle(.borderless)
      .disabled(viewModel.state == .loading)
      .help("Attach text files")
      TextField("Ask Riela Note", text: $viewModel.draftMessage, axis: .vertical)
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...5)
        .focused($isComposerFocused)
        .onSubmit {
          Task {
            await viewModel.submitDraft()
          }
        }
      Button {
        Task {
          await viewModel.submitDraft()
        }
      } label: {
        if case .loading = viewModel.state {
          Label("Sending", systemImage: "hourglass")
        } else {
          Label("Send", systemImage: "paperplane.fill")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!viewModel.canSubmit)
    }
    .padding()
  }
}

struct RielaNoteAgentTurnView: View {
  var turn: RielaNoteAgentTurn
  var onOpenCitation: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      message(label: "You", markdown: turn.userMarkdown, systemImage: "person")
      message(label: "Agent", markdown: turn.assistantMarkdown, systemImage: "sparkles")
      if !turn.citations.isEmpty {
        citationStrip
      }
    }
    .padding(12)
    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private func message(label: String, markdown: String, systemImage: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(label, systemImage: systemImage)
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      RielaNoteMarkdownText(markdown: markdown)
        .font(.body)
        .lineSpacing(3)
    }
  }

  private var citationStrip: some View {
    FlowLayout(spacing: 8) {
      ForEach(turn.citations) { citation in
        Button {
          onOpenCitation(citation.noteId)
        } label: {
          Label(citation.title ?? citation.noteId, systemImage: "link")
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
      }
    }
  }
}
