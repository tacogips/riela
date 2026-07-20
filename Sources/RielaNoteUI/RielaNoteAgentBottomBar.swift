import SwiftUI
import UniformTypeIdentifiers

/// Agent bar pinned to the bottom of the note screen, mirroring the RielaApp
/// riela-helper mini chat: a rounded bordered panel with a fold button, a
/// transcript, and a pill-shaped composer. The composer follows Codex-app
/// ergonomics: multiline input, Enter to send, and file attachments inlined
/// into the outgoing message.
public struct RielaNoteAgentBottomBar: View {
  @ObservedObject private var viewModel: RielaNoteAgentViewModel
  @AppStorage("rielaNoteWorkspace.agentBottomBar.isFolded") private var isFolded = false
  @State private var isTranscriptExpanded = true
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
    Group {
      if isFolded {
        foldedBar
      } else {
        expandedPanel
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
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
    .onChange(of: isFolded) { _, folded in
      if !folded, viewModel.composerFocusRequestRevision > 0 {
        isComposerFocused = true
      }
    }
  }

  private var foldedBar: some View {
    HStack {
      Spacer()
      Button {
        withAnimation {
          isFolded = false
        }
      } label: {
        Image(systemName: "sparkles")
          .foregroundStyle(Color.accentColor)
          .padding(10)
          .background(panelBackground)
      }
      .buttonStyle(.plain)
      .help("Ask Riela Note")
      .accessibilityLabel("Expand note agent")
    }
  }

  private var expandedPanel: some View {
    VStack(spacing: 8) {
      header
      if isTranscriptExpanded, !viewModel.turns.isEmpty {
        transcript
      }
      if let errorMessage = viewModel.errorMessage {
        statusText(errorMessage, isError: true)
      }
      if let attachmentError = viewModel.attachmentError {
        statusText(attachmentError, isError: true)
      }
      if !viewModel.draftAttachments.isEmpty {
        attachmentChips
      }
      composer
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(panelBackground)
  }

  private var panelBackground: some View {
    RoundedRectangle(cornerRadius: 18)
      .fill(.background)
      .overlay(
        RoundedRectangle(cornerRadius: 18)
          .stroke(.separator, lineWidth: 1)
      )
  }

  private var header: some View {
    HStack(spacing: 8) {
      Label("Riela Note Agent", systemImage: "sparkles")
        .font(.system(size: 13, weight: .semibold))
      if viewModel.isTemporaryChat {
        Text("Temp chat (not saved)")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let notebookId = viewModel.autoSaveNotebookId {
        Label(notebookId, systemImage: "tray.full")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Toggle("Temp", isOn: $viewModel.isTemporaryChat)
        .toggleStyle(.switch)
        .controlSize(.mini)
        .help("Temp chat is not saved to a notebook")
      Button {
        Task {
          await viewModel.saveTemporaryConversation()
        }
      } label: {
        Image(systemName: "square.and.arrow.down")
      }
      .buttonStyle(.borderless)
      .disabled(!viewModel.canSaveTemporaryConversation)
      .help("Save this conversation")
      Button {
        viewModel.startNewConversation()
      } label: {
        Image(systemName: "plus.bubble")
      }
      .buttonStyle(.borderless)
      .disabled(!viewModel.canStartNewConversation)
      .help("New chat")
      if !viewModel.turns.isEmpty {
        Button {
          withAnimation {
            isTranscriptExpanded.toggle()
          }
        } label: {
          Image(systemName: isTranscriptExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
        }
        .buttonStyle(.borderless)
        .help(isTranscriptExpanded ? "Hide conversation" : "Show conversation")
      }
      Button {
        withAnimation {
          isFolded = true
        }
      } label: {
        Image(systemName: "chevron.down")
      }
      .buttonStyle(.borderless)
      .help("Collapse note agent")
      .accessibilityLabel("Collapse note agent")
    }
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(viewModel.turns) { turn in
            RielaNoteAgentTurnView(turn: turn, onOpenCitation: onOpenCitation)
              .id(turn.id)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(height: 220)
      .onAppear {
        proxy.scrollTo(viewModel.turns.last?.id, anchor: .bottom)
      }
      .onChange(of: viewModel.turns.count) { _, _ in
        withAnimation {
          proxy.scrollTo(viewModel.turns.last?.id, anchor: .bottom)
        }
      }
    }
  }

  private func statusText(_ message: String, isError: Bool) -> some View {
    HStack(spacing: 6) {
      Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
      Text(message)
        .lineLimit(2)
      Spacer()
    }
    .font(.caption)
    .foregroundStyle(isError ? .red : .secondary)
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
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Button {
        isFileImporterPresented = true
      } label: {
        Image(systemName: "paperclip")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.state == .loading)
      .help("Attach text files")
      .accessibilityLabel("Attach files")
      TextField("Ask Riela Note", text: $viewModel.draftMessage, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .focused($isComposerFocused)
        .onSubmit {
          submit()
        }
      Button {
        submit()
      } label: {
        if viewModel.state == .loading {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "arrow.up.circle.fill")
            .font(.system(size: 22))
            .foregroundStyle(viewModel.canSubmit ? Color.accentColor : Color.secondary)
        }
      }
      .buttonStyle(.plain)
      .disabled(!viewModel.canSubmit)
      .help("Send")
      .accessibilityLabel("Send agent message")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 18)
        .fill(.quaternary.opacity(0.4))
        .overlay(
          RoundedRectangle(cornerRadius: 18)
            .stroke(.separator, lineWidth: 1)
        )
    )
  }

  private func submit() {
    guard viewModel.canSubmit else {
      return
    }
    Task {
      await viewModel.submitDraft()
      isComposerFocused = true
    }
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
}
