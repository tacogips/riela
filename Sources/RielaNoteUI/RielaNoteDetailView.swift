import RielaNote
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Callback that hands a resolved attachment's on-disk copy to the host app for
/// opening (`NSWorkspace.open`/QuickLook). Injected via the environment from
/// `NoteWindowController` so `RielaNoteUI` stays AppKit-free.
@MainActor
public struct RielaNoteOpenFileAction {
  private let action: (URL) -> Void

  public init(_ action: @escaping (URL) -> Void) {
    self.action = action
  }

  public func callAsFunction(_ url: URL) {
    action(url)
  }
}

private struct RielaNoteOpenFileActionKey: EnvironmentKey {
  static let defaultValue: RielaNoteOpenFileAction? = nil
}

public extension EnvironmentValues {
  var rielaNoteOpenFile: RielaNoteOpenFileAction? {
    get { self[RielaNoteOpenFileActionKey.self] }
    set { self[RielaNoteOpenFileActionKey.self] = newValue }
  }
}

public struct RielaNoteDetailView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.rielaNoteOpenFile) private var openFileAction
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  @State private var bodyDraft = RielaNoteBodyDraftState()
  @State private var rewriteInstruction = ""
  @State private var selectedBodyRange = NSRange(location: 0, length: 0)
  @State private var armedSelectionRange: NSRange?
  @State private var isSelectionQuestionMode = false
  @State private var copiedFeedbackVisible = false
  @State private var isMarkdownExportPresented = false
  @State private var markdownExportDocument = RielaNoteMarkdownFileDocument(markdown: "")
  @State private var markdownExportFilename = "note.md"
  @State private var bodyEditError: String?
  @State private var visibleNoteId: String?
  @State private var commentDraftNoteId: String?
  @State private var commentDraft = ""
  @State private var commentError: String?
  @FocusState private var isRewriteFieldFocused: Bool
  @FocusState private var isCommentFieldFocused: Bool
  private let showsMetadata: Bool
  private let showsExpandToggle: Bool
  private let onAskAgent: (Note) -> Void

  public init(
    viewModel: RielaNoteLibraryViewModel,
    showsMetadata: Bool = true,
    showsExpandToggle: Bool = true,
    onAskAgent: @escaping (Note) -> Void = { _ in }
  ) {
    self.viewModel = viewModel
    self.showsMetadata = showsMetadata
    self.showsExpandToggle = showsExpandToggle
    self.onAskAgent = onAskAgent
  }

  public var body: some View {
    Group {
      if let detail = viewModel.selectedDetail {
        reader(detail: detail)
        .navigationTitle(detail.note.title ?? "Note")
        .onChange(of: detail.note.noteId) { _, noteId in
          resetEditingState()
          synchronizeVisibleNoteId(noteId)
        }
        .fileExporter(
          isPresented: $isMarkdownExportPresented,
          document: markdownExportDocument,
          contentType: rielaNoteMarkdownContentType,
          defaultFilename: markdownExportFilename
        ) { _ in }
        // Keep shared state in sync with the local editor flag so list/root views
        // can guard navigation and present the discard confirmation (hosted at the
        // root) even from panes that don't own this draft.
        .onChange(of: bodyDraft.isEditingBody) { _, isEditing in
          viewModel.setEditingBody(isEditing)
        }
      } else {
        emptySelection
      }
    }
  }

  private func reader(detail: RielaNoteDetail) -> some View {
    let notes = viewModel.pagerNoteSnapshot.notes.isEmpty
      ? [detail.note]
      : viewModel.pagerNoteSnapshot.notes
    return ScrollView(.vertical) {
      LazyVStack(spacing: 0) {
        ForEach(notes, id: \.noteId) { note in
          readerPage(note, selectedDetail: detail)
            .id(note.noteId)
            .containerRelativeFrame(.vertical, alignment: .top)
        }
      }
      .scrollTargetLayout()
    }
    .scrollTargetBehavior(.paging)
    .scrollPosition(id: $visibleNoteId)
    .scrollDisabled(bodyDraft.isEditingBody)
    .onAppear {
      synchronizeVisibleNoteId(detail.note.noteId)
      Task {
        await viewModel.loadNextNotebookNotesPageIfNeeded(visibleNoteId: detail.note.noteId)
      }
    }
    .onChange(of: visibleNoteId) { _, noteId in
      handleVisibleNoteChange(noteId)
    }
  }

  private func readerPage(_ note: Note, selectedDetail: RielaNoteDetail) -> some View {
    let isSelected = note.noteId == selectedDetail.note.noteId
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header(note, isSelected: isSelected)
        if isSelected, viewModel.sourcePageImageAttachment != nil {
          Picker("Mode", selection: contentModeBinding) {
            Label("Text", systemImage: "doc.text").tag(RielaNoteLibraryViewModel.NoteContentMode.text)
            Label("Image", systemImage: "photo").tag(RielaNoteLibraryViewModel.NoteContentMode.sourceImage)
          }
          .pickerStyle(.segmented)
        }
        content(note, selectedDetail: selectedDetail)
        if showsMetadata, isSelected {
          RielaNoteMetadataPane(viewModel: viewModel)
        }
      }
      .padding()
      .frame(maxWidth: 880, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .top)
    }
  }

  private var emptySelection: some View {
    VStack(spacing: 12) {
      Image(systemName: "note.text")
        .font(.system(size: 28, weight: .semibold))
        .foregroundStyle(.secondary)
      Text("No note")
        .font(.headline)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }

  private var contentModeBinding: Binding<RielaNoteLibraryViewModel.NoteContentMode> {
    Binding {
      viewModel.contentMode
    } set: { mode in
      Task {
        await viewModel.setContentMode(mode)
      }
    }
  }

  private func header(_ note: Note, isSelected: Bool) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      actionRow(note, isSelected: isSelected)
      commentComposer(note)
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(note.title ?? note.noteId)
          .font(.title2)
          .fontWeight(.semibold)
          .lineLimit(3)
        if note.readOnly {
          Image(systemName: "lock.fill")
            .foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 8) {
        Label("#\(note.noteNumber)", systemImage: "number")
        Label(note.updatedAt, systemImage: "clock")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      notePager
    }
  }

  private func actionRow(_ note: Note, isSelected: Bool) -> some View {
    HStack(alignment: .top, spacing: 8) {
      if !note.readOnly, isSelected {
        editControl(note)
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
        Button {
          onAskAgent(note)
        } label: {
          Image(systemName: "sparkles")
        }
        .help("Ask agent about this note")
        Button {
          startComment(note)
        } label: {
          Image(systemName: "text.bubble")
        }
        .help("Add comment")
        Button {
          copyDisplayedMarkdown(for: note)
        } label: {
          Image(systemName: copiedFeedbackVisible ? "checkmark" : "doc.on.doc")
        }
        .help("Copy markdown")
        Button {
          exportDisplayedMarkdown(for: note)
        } label: {
          Image(systemName: "square.and.arrow.down")
        }
        .help("Download markdown")
        if horizontalSizeClass != .compact, showsExpandToggle {
          Button {
            viewModel.isDetailExpanded.toggle()
          } label: {
            Image(
              systemName: viewModel.isDetailExpanded
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right"
            )
          }
          .help(viewModel.isDetailExpanded ? "Restore columns" : "Expand detail")
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func commentComposer(_ note: Note) -> some View {
    if commentDraftNoteId == note.noteId {
      VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .bottom, spacing: 8) {
          TextField("Add comment", text: $commentDraft, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            .focused($isCommentFieldFocused)
          Button("Cancel") {
            resetCommentComposer()
          }
          Button {
            submitComment(note)
          } label: {
            Label("Add", systemImage: "checkmark")
          }
          .buttonStyle(.borderedProminent)
          .disabled(commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if let commentError {
          Text(commentError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  @ViewBuilder
  private func editControl(_ note: Note) -> some View {
    if bodyDraft.isEditingBody {
      rewritePill(note)
    } else {
      Button {
        startEditing(note)
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private func rewritePill(_ note: Note) -> some View {
    let isLoading = isSelectionQuestionMode
      ? viewModel.isSelectionQuestionLoading
      : viewModel.isEditRewriteLoading
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: isSelectionQuestionMode ? "questionmark.circle" : "pencil")
          .foregroundStyle(.secondary)
        if let armedSelectionRange,
           rielaNoteSelectedText(in: bodyDraft.draftBodyMarkdown, range: armedSelectionRange) != nil {
          HStack(spacing: 4) {
            // Report the UTF-16 length to match the selectionStart/selectionEnd
            // offsets actually sent to the workflow (NSRange is UTF-16-based).
            Text("Selection \(armedSelectionRange.length)")
              .font(.caption2)
            Button {
              self.armedSelectionRange = nil
              // Clearing the badge returns the pill to rewrite mode (D1).
              isSelectionQuestionMode = false
            } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
          }
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(.secondary.opacity(0.14), in: Capsule())
        }
        TextField(isSelectionQuestionMode ? "Ask about selection" : "Ask for changes", text: $rewriteInstruction)
          .textFieldStyle(.plain)
          .frame(minWidth: 180, maxWidth: 320)
          .focused($isRewriteFieldFocused)
          .onSubmit {
            submitPill(for: note)
          }
        Button {
          submitPill(for: note)
        } label: {
          if isLoading {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.up.circle.fill")
          }
        }
        .buttonStyle(.plain)
        .disabled(rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
        .help(isSelectionQuestionMode ? "Ask about selection" : "Submit changes")
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      pillCaption
    }
  }

  @ViewBuilder
  private var pillCaption: some View {
    if viewModel.didSaveSelectionQuestionComment {
      // Success feedback survives the mode toggle: `submitSelectionQuestion`
      // clears `isSelectionQuestionMode` on success, so gating on the mode here
      // would render this caption for zero frames. It clears with the next
      // selection question, note switch, or editor reset.
      Text("Saved as comment")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else if isSelectionQuestionMode {
      if let error = viewModel.selectionQuestionError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
    } else if let error = viewModel.editRewriteError {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    } else if let summary = viewModel.editRewriteSummary {
      Text(summary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func submitPill(for note: Note) {
    if isSelectionQuestionMode {
      submitSelectionQuestion(for: note)
    } else {
      submitRewrite(for: note)
    }
  }

  @ViewBuilder
  private var notePager: some View {
    if let position = viewModel.selectedNotePositionText {
      HStack(spacing: 8) {
        Button {
          Task { await viewModel.requestSelection(.previousNote) }
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(!viewModel.canSelectPreviousNote || bodyDraft.isEditingBody)
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .help("Previous note")
        Text(position)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(minWidth: 72)
        Button {
          Task { await viewModel.requestSelection(.nextNote) }
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(!viewModel.canSelectNextNote || bodyDraft.isEditingBody)
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .help("Next note")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func content(_ note: Note, selectedDetail: RielaNoteDetail) -> some View {
    let isSelected = note.noteId == selectedDetail.note.noteId
    if isSelected, bodyDraft.isEditingBody, !note.readOnly {
      bodyEditor(note)
    } else if !isSelected {
      RielaNoteMarkdownBodyView(markdown: note.bodyMarkdown)
        .font(.body)
        .padding(.vertical, 4)
    } else {
      switch viewModel.contentMode {
      case .text:
        RielaNoteMarkdownBodyView(markdown: bodyDraft.previewBodyMarkdown(for: note))
          .font(.body)
          .padding(.vertical, 4)
      case .sourceImage:
        VStack(alignment: .leading, spacing: 10) {
          sourceImageToolbar
          RielaNoteSourceImageView(
            decodedImage: viewModel.decodedSourceImage,
            resolvedFile: viewModel.resolvedSourceImage,
            attachment: viewModel.sourcePageImageAttachment,
            isLoading: viewModel.isSourceImageLoading,
            zoomScale: viewModel.sourceImageZoom
          )
        }
      }
    }
  }

  private var sourceImageToolbar: some View {
    HStack(spacing: 8) {
      Button {
        viewModel.zoomOutSourceImage()
      } label: {
        Image(systemName: "minus.magnifyingglass")
      }
      .disabled(viewModel.sourceImageZoom <= RielaNoteLibraryViewModel.sourceImageMinimumZoom)
      .help("Zoom out")
      Text("\(Int(viewModel.sourceImageZoom * 100))%")
        .font(.caption)
        .monospacedDigit()
        .frame(width: 48)
      Button {
        viewModel.resetSourceImageZoom()
      } label: {
        Image(systemName: "1.magnifyingglass")
      }
      .disabled(viewModel.sourceImageZoom == 1.0)
      .help("Actual size")
      Button {
        viewModel.zoomInSourceImage()
      } label: {
        Image(systemName: "plus.magnifyingglass")
      }
      .disabled(viewModel.sourceImageZoom >= RielaNoteLibraryViewModel.sourceImageMaximumZoom)
      .help("Zoom in")
      Button {
        Task {
          await viewModel.retrySourceImage()
        }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .help("Retry source image")
      if let decoded = viewModel.decodedSourceImage {
        Text("\(decoded.pixelWidth)x\(decoded.pixelHeight)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Spacer()
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func bodyEditor(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .topLeading) {
        RielaNoteSelectableTextEditor(text: $bodyDraft.draftBodyMarkdown, selectedRange: $selectedBodyRange)
          .font(.body.monospaced())
          .frame(minHeight: 320)
          .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        if rielaNoteRewriteRangeIsValid(selectedBodyRange, in: bodyDraft.draftBodyMarkdown) {
          HStack(spacing: 6) {
            Button {
              armSelectionScope()
            } label: {
              Label("Ask for changes Cmd-K", systemImage: "pencil")
            }
            .keyboardShortcut("k", modifiers: .command)
            Button {
              armSelectionQuestionScope()
            } label: {
              Label("Ask question ⇧⌘K", systemImage: "questionmark.circle")
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .padding(10)
        }
      }
      if let bodyEditError {
        Text(bodyEditError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") {
          bodyDraft.cancel()
          resetEditingState()
        }
        Button {
          let targetNoteId = bodyDraft.editingNoteId
          let draftBodyMarkdown = bodyDraft.draftBodyMarkdown
          bodyEditError = nil
          Task {
            do {
              try await viewModel.saveSelectedNoteBody(draftBodyMarkdown, expectedNoteId: targetNoteId)
              resetEditingState()
            } catch {
              // Keep the editor open with the draft intact so the edit is not lost.
              bodyEditError = rielaNoteMutationErrorMessage(error)
            }
          }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func resetEditingState() {
    bodyDraft.reset()
    rewriteInstruction = ""
    selectedBodyRange = NSRange(location: 0, length: 0)
    armedSelectionRange = nil
    isSelectionQuestionMode = false
    bodyEditError = nil
    viewModel.clearEditRewriteState()
    viewModel.clearSelectionQAState()
    viewModel.clearLinkProposals()
  }

  private func resetCommentComposer() {
    commentDraftNoteId = nil
    commentDraft = ""
    commentError = nil
  }

  private func startComment(_ note: Note) {
    commentDraftNoteId = note.noteId
    commentDraft = ""
    commentError = nil
    isCommentFieldFocused = true
  }

  private func submitComment(_ note: Note) {
    let bodyMarkdown = commentDraft
    let targetNoteId = note.noteId
    Task {
      do {
        try await viewModel.addComment(bodyMarkdown, toNoteId: targetNoteId)
        guard commentDraftNoteId == targetNoteId else {
          return
        }
        resetCommentComposer()
      } catch {
        guard commentDraftNoteId == targetNoteId else {
          return
        }
        commentError = rielaNoteMutationErrorMessage(error)
      }
    }
  }

  private func synchronizeVisibleNoteId(_ noteId: String) {
    guard visibleNoteId != noteId else {
      return
    }
    visibleNoteId = noteId
  }

  private func handleVisibleNoteChange(_ noteId: String?) {
    guard let noteId, !bodyDraft.isEditingBody else {
      return
    }
    Task {
      await viewModel.loadNextNotebookNotesPageIfNeeded(visibleNoteId: noteId)
      guard visibleNoteId == noteId, !bodyDraft.isEditingBody else {
        return
      }
      guard viewModel.selectedNote?.noteId != noteId else {
        return
      }
      await viewModel.requestSelection(.note(noteId))
    }
  }

  private func startEditing(_ note: Note) {
    bodyDraft.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
    rewriteInstruction = ""
    selectedBodyRange = NSRange(location: 0, length: 0)
    armedSelectionRange = nil
    isSelectionQuestionMode = false
    viewModel.clearEditRewriteState()
    viewModel.clearSelectionQAState()
    isRewriteFieldFocused = true
  }

  private func armSelectionScope() {
    guard rielaNoteRewriteRangeIsValid(selectedBodyRange, in: bodyDraft.draftBodyMarkdown) else {
      armedSelectionRange = nil
      return
    }
    armedSelectionRange = selectedBodyRange
    isSelectionQuestionMode = false
    isRewriteFieldFocused = true
  }

  private func armSelectionQuestionScope() {
    guard rielaNoteRewriteRangeIsValid(selectedBodyRange, in: bodyDraft.draftBodyMarkdown) else {
      armedSelectionRange = nil
      isSelectionQuestionMode = false
      return
    }
    armedSelectionRange = selectedBodyRange
    isSelectionQuestionMode = true
    viewModel.clearSelectionQAState()
    isRewriteFieldFocused = true
  }

  private func submitSelectionQuestion(for note: Note) {
    let question = rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty else {
      return
    }
    let currentDraft = bodyDraft.draftBodyMarkdown
    // A question requires a still-valid, non-empty selection — no whole-note fallback (D1).
    guard let activeRange = armedSelectionRange,
          rielaNoteRewriteRangeIsValid(activeRange, in: currentDraft),
          let selectedText = rielaNoteSelectedText(in: currentDraft, range: activeRange) else {
      viewModel.markSelectionQuestionSelectionStale()
      return
    }
    Task {
      let saved = await viewModel.askSelectionQuestion(
        question: question,
        draftBodyMarkdown: currentDraft,
        selectedText: selectedText,
        selectionStart: activeRange.location,
        selectionEnd: activeRange.location + activeRange.length
      )
      guard bodyDraft.isEditingBody, bodyDraft.editingNoteId == note.noteId else {
        return
      }
      if saved {
        rewriteInstruction = ""
        armedSelectionRange = nil
        isSelectionQuestionMode = false
      }
    }
  }

  private func submitRewrite(for note: Note) {
    let instruction = rewriteInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !instruction.isEmpty else {
      return
    }
    let currentDraft = bodyDraft.draftBodyMarkdown
    let activeRange = armedSelectionRange.flatMap { range -> NSRange? in
      rielaNoteRewriteRangeIsValid(range, in: currentDraft) ? range : nil
    }
    let selectedText = activeRange.flatMap { rielaNoteSelectedText(in: currentDraft, range: $0) }
    let submittedDraft = currentDraft
    let submittedRange = activeRange
    let submittedSelectedText = selectedText
    Task {
      let rewrite = await viewModel.proposeBodyRewrite(
        instruction: instruction,
        draftBodyMarkdown: submittedDraft,
        selectedText: selectedText,
        selectionStart: activeRange?.location,
        selectionEnd: activeRange.map { $0.location + $0.length }
      )
      guard bodyDraft.isEditingBody,
            bodyDraft.editingNoteId == note.noteId,
            let rewrite else {
        return
      }
      guard rielaNoteRewriteResultIsFresh(
        currentDraft: bodyDraft.draftBodyMarkdown,
        submittedDraft: submittedDraft,
        submittedRange: submittedRange,
        submittedSelectedText: submittedSelectedText
      ) else {
        viewModel.markEditRewriteResultStale()
        return
      }
      if let activeRange = submittedRange,
         let updated = rielaNoteApplyingRewrite(
           draft: bodyDraft.draftBodyMarkdown,
           range: activeRange,
           replacement: rewrite.rewrittenMarkdown
         ) {
        bodyDraft.draftBodyMarkdown = updated
        let insertedRange = NSRange(location: activeRange.location, length: rewrite.rewrittenMarkdown.utf16.count)
        selectedBodyRange = insertedRange
        armedSelectionRange = insertedRange
      } else {
        bodyDraft.draftBodyMarkdown = rewrite.rewrittenMarkdown
        selectedBodyRange = NSRange(location: 0, length: 0)
        armedSelectionRange = nil
      }
      rewriteInstruction = ""
    }
  }

  private func displayedMarkdown(for note: Note) -> String {
    rielaNoteDisplayedMarkdown(
      noteMarkdown: note.bodyMarkdown,
      draftMarkdown: bodyDraft.previewBodyMarkdown(for: note),
      isEditing: bodyDraft.isEditingBody && bodyDraft.editingNoteId == note.noteId
    )
  }

  private func copyDisplayedMarkdown(for note: Note) {
    let markdown = displayedMarkdown(for: note)
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(markdown, forType: .string)
    #elseif os(iOS)
    UIPasteboard.general.string = markdown
    #endif
    copiedFeedbackVisible = true
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      copiedFeedbackVisible = false
    }
  }

  private func exportDisplayedMarkdown(for note: Note) {
    markdownExportDocument = RielaNoteMarkdownFileDocument(markdown: displayedMarkdown(for: note))
    markdownExportFilename = rielaNoteExportFilename(title: note.title, noteId: note.noteId)
    isMarkdownExportPresented = true
  }

}

/// Sanitized on-disk filename for a resolved attachment: prefers its original
/// filename (basename only, so path components can't escape the scratch dir),
/// falling back to `<fileId>` with an extension derived from the media type.
func rielaNoteResolvedFileName(for file: FileRecord) -> String {
  if let original = file.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
     !original.isEmpty {
    let base = (original as NSString).lastPathComponent
    if !base.isEmpty, base != ".", base != ".." {
      return base
    }
  }
  let ext = UTType(mimeType: file.mediaType)?.preferredFilenameExtension
  if let ext, !ext.isEmpty {
    return "\(file.fileId).\(ext)"
  }
  return file.fileId
}

/// Writes a resolved attachment's bytes to a per-session scratch file and returns
/// its URL. The host app opens the URL through the injected open-file callback so
/// `RielaNoteUI` never touches `NSWorkspace`/QuickLook directly.
func rielaNoteWriteResolvedFileToScratch(
  _ resolvedFile: RielaNoteResolvedFile,
  directory: URL? = nil
) throws -> URL {
  let baseDirectory = directory ?? FileManager.default.temporaryDirectory
    .appendingPathComponent("riela-note-attachments", isDirectory: true)
  let scratchDirectory = baseDirectory.appendingPathComponent(
    resolvedFile.file.fileId,
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
  let destination = scratchDirectory.appendingPathComponent(
    rielaNoteResolvedFileName(for: resolvedFile.file)
  )
  try resolvedFile.data.write(to: destination, options: .atomic)
  return destination
}

/// `FileDocument` wrapper that lets the note detail view drive `fileExporter`
/// for arbitrary attachment bytes, matching the markdown download affordance.
struct RielaNoteBinaryFileDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.data] }

  var data: Data
  var contentType: UTType

  init(data: Data, contentType: UTType) {
    self.data = data
    self.contentType = contentType
  }

  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
    contentType = configuration.contentType
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

/// Human-readable message for a failed mutation, surfaced in a view's inline
/// error slot. Keeps raw error descriptions out of the UI.
func rielaNoteMutationErrorMessage(_ error: Error) -> String {
  switch error {
  case let serviceError as NoteServiceError:
    switch serviceError {
    case .notFound:
      return "That note is no longer available."
    case .readOnly:
      return "This note is read-only."
    case .protectedTag:
      return "That tag can't be changed."
    case .invalidInput(let message):
      return message
    case .invalidRow:
      return "A stored note could not be read."
    }
  default:
    return "The change could not be saved. Please try again."
  }
}

struct RielaNoteBodyDraftState: Equatable {
  var isEditingBody = false
  var draftBodyMarkdown = ""
  var editingNoteId: String?

  mutating func toggle(noteId: String, bodyMarkdown: String) {
    if isEditingBody {
      isEditingBody = false
      return
    }
    if editingNoteId != noteId {
      draftBodyMarkdown = bodyMarkdown
      editingNoteId = noteId
    }
    isEditingBody = true
  }

  func previewBodyMarkdown(for note: Note) -> String {
    guard editingNoteId == note.noteId else {
      return note.bodyMarkdown
    }
    return draftBodyMarkdown
  }

  /// Opens the editor with AI-proposed text prefilled for review. The
  /// `originalBodyMarkdown` is retained implicitly: Cancel calls `reset`, and the
  /// non-editing preview falls back to the note's stored body, so discarding the
  /// draft restores the original.
  mutating func loadProposedDraft(noteId: String, proposedBodyMarkdown: String) {
    editingNoteId = noteId
    draftBodyMarkdown = proposedBodyMarkdown
    isEditingBody = true
  }

  mutating func cancel() {
    reset()
  }

  mutating func reset() {
    isEditingBody = false
    draftBodyMarkdown = ""
    editingNoteId = nil
  }
}

func rielaNoteTagSuggestions(
  availableTags: [Tag],
  existingAssignments: [TagAssignment],
  query: String
) -> [Tag] {
  let existingNames = Set(existingAssignments.map(\.tag.name))
  let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  return availableTags
    .filter { tag in
      !existingNames.contains(tag.name)
        && (normalizedQuery.isEmpty || tag.name.lowercased().contains(normalizedQuery))
    }
    .sorted { lhs, rhs in
      lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

func rielaNoteLinkIconName(_ linkKind: String) -> String {
  linkKind == "source-citation" ? "quote.bubble" : "link"
}
