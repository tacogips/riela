import RielaNote
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public struct RielaNoteDetailView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  @State private var bodyDraft = RielaNoteBodyDraftState()
  @State private var copiedFeedbackVisible = false
  @State private var isMarkdownExportPresented = false
  @State private var markdownExportDocument = RielaNoteMarkdownFileDocument(markdown: "")
  @State private var markdownExportFilename = "note.md"
  @State private var draftTagName = ""
  @State private var draftCommentMarkdown = ""
  @State private var isAddLinkPresented = false
  @State private var isLinkProposalPresented = false
  @State private var isTagsExpanded = false
  @State private var isLinksExpanded = false
  @State private var isCommentsExpanded = false
  @State private var isFilesExpanded = false

  public init(viewModel: RielaNoteLibraryViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    Group {
      if let detail = viewModel.selectedDetail {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header(detail.note)
            if viewModel.sourcePageImageAttachment != nil {
              Picker("Mode", selection: contentModeBinding) {
                Label("Text", systemImage: "doc.text").tag(RielaNoteLibraryViewModel.NoteContentMode.text)
                Label("Image", systemImage: "photo").tag(RielaNoteLibraryViewModel.NoteContentMode.sourceImage)
              }
              .pickerStyle(.segmented)
            }
            content(detail)
            metadata(detail)
          }
          .padding()
          .frame(maxWidth: 880, alignment: .leading)
        }
        .navigationTitle(detail.note.title ?? "Note")
        .onAppear {
          applyDefaultMetadataExpansion(for: detail)
        }
        .onChange(of: detail.note.noteId) { _, _ in
          resetEditingState()
          applyDefaultMetadataExpansion(for: detail)
        }
        .sheet(isPresented: $isAddLinkPresented) {
          RielaNoteLinkSearchSheet(
            viewModel: viewModel,
            detail: detail,
            onCancel: { isAddLinkPresented = false },
            onLinked: { isAddLinkPresented = false }
          )
        }
        .sheet(isPresented: $isLinkProposalPresented) {
          RielaNoteLinkProposalSheet(viewModel: viewModel) {
            isLinkProposalPresented = false
            viewModel.clearLinkProposals()
          }
        }
        .fileExporter(
          isPresented: $isMarkdownExportPresented,
          document: markdownExportDocument,
          contentType: rielaNoteMarkdownContentType,
          defaultFilename: markdownExportFilename
        ) { _ in }
      } else {
        emptySelection
      }
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

  private func header(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      actionRow(note)
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

  private func actionRow(_ note: Note) -> some View {
    HStack(alignment: .top, spacing: 8) {
      if !note.readOnly {
        editControl(note)
        translationControl(note)
      }
      Spacer(minLength: 12)
      HStack(spacing: 8) {
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
        if horizontalSizeClass != .compact {
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

  private func translationControl(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        TextField("Target", text: $viewModel.translationTargetLanguage)
          .textFieldStyle(.roundedBorder)
          .frame(width: 110)
          .disabled(viewModel.isTranslateNoteLoading || bodyDraft.isEditingBody)
          .help("Translation target language")
        Button {
          Task {
            await viewModel.translateSelectedNote()
          }
        } label: {
          if viewModel.isTranslateNoteLoading {
            ProgressView()
              .controlSize(.small)
          } else {
            Label("Translate note", systemImage: "translate")
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(
          viewModel.translationTargetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || viewModel.isTranslateNoteLoading
            || bodyDraft.isEditingBody
            || note.readOnly
        )
        .help("Translate the whole note")
      }
      if let error = viewModel.translateNoteError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      } else if let summary = viewModel.translateNoteSummary {
        Text(summary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func editControl(_ note: Note) -> some View {
    if !bodyDraft.isEditingBody {
      Button {
        startEditing(note)
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private var notePager: some View {
    if let position = viewModel.selectedNotePositionText {
      HStack(spacing: 8) {
        Button {
          Task {
            await viewModel.selectPreviousNote()
          }
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(!viewModel.canSelectPreviousNote)
        .keyboardShortcut(.leftArrow, modifiers: .command)
        .help("Previous note")
        Text(position)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .frame(minWidth: 72)
        Button {
          Task {
            await viewModel.selectNextNote()
          }
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(!viewModel.canSelectNextNote)
        .keyboardShortcut(.rightArrow, modifiers: .command)
        .help("Next note")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func content(_ detail: RielaNoteDetail) -> some View {
    if bodyDraft.isEditingBody, !detail.note.readOnly {
      bodyEditor(detail.note)
    } else {
      switch viewModel.contentMode {
      case .text:
        RielaNoteMarkdownBodyView(markdown: bodyDraft.previewBodyMarkdown(for: detail.note))
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

  private func metadata(_ detail: RielaNoteDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      DisclosureGroup(isExpanded: $isTagsExpanded) {
        tagEditor(detail.note)
          .padding(.top, 8)
      } label: {
        metadataLabel("Tags", count: detail.note.tags.count, systemImage: "tag")
      }
      DisclosureGroup(isExpanded: $isLinksExpanded) {
        links(detail)
          .padding(.top, 8)
      } label: {
        metadataLabel("Links", count: detail.links.count, systemImage: "link")
      }
      DisclosureGroup(isExpanded: $isCommentsExpanded) {
        comments(detail.comments)
          .padding(.top, 8)
      } label: {
        metadataLabel("Comments", count: detail.comments.count, systemImage: "text.bubble")
      }
      DisclosureGroup(isExpanded: $isFilesExpanded) {
        fileStrip(detail.files)
          .padding(.top, 8)
      } label: {
        metadataLabel("Files", count: detail.files.count, systemImage: "paperclip")
      }
    }
  }

  private func metadataLabel(_ title: String, count: Int, systemImage: String) -> some View {
    Label("\(title) (\(count))", systemImage: systemImage)
      .font(.headline)
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
      TextEditor(text: $bodyDraft.draftBodyMarkdown)
        .font(.body.monospaced())
        .frame(minHeight: 320)
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Spacer()
        Button("Cancel") {
          bodyDraft.cancel()
          resetEditingState()
        }
        Button {
          let targetNoteId = bodyDraft.editingNoteId
          let draftBodyMarkdown = bodyDraft.draftBodyMarkdown
          Task {
            await viewModel.saveSelectedNoteBody(draftBodyMarkdown, expectedNoteId: targetNoteId)
            resetEditingState()
          }
        } label: {
          Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(.borderedProminent)
      }
    }
  }

  private func fileStrip(_ files: [NoteFileAttachment]) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if files.isEmpty {
        Text("No files")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(files, id: \.file.fileId) { attachment in
              Button {
                Task {
                  await viewModel.selectFileAttachment(attachment)
                }
              } label: {
                Label(
                  attachment.file.originalFilename ?? attachment.file.fileId,
                  systemImage: iconName(for: attachment)
                )
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help("Resolve file")
            }
          }
        }
        .scrollIndicators(.hidden)
      }
      if let status = viewModel.selectedResolvedFileStatusText,
         let file = viewModel.selectedResolvedFile?.file {
        HStack(spacing: 8) {
          Label(status, systemImage: iconName(for: file))
          Text(file.storageKind.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func links(_ detail: RielaNoteDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !detail.links.isEmpty {
        ForEach(detail.links, id: \.stableId) { link in
          let targetNoteId = link.counterpartNoteId(for: detail.note.noteId)
          Button {
            Task {
              await viewModel.selectNote(targetNoteId)
            }
          } label: {
            Label(
              linkLabel(link, currentNoteId: detail.note.noteId, linkedNotes: detail.linkedNotesById),
              systemImage: rielaNoteLinkIconName(link.linkKind)
            )
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("Open linked note")
        }
      } else {
        Text("No links")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        Button {
          isAddLinkPresented = true
        } label: {
          Label("Add link", systemImage: "link.badge.plus")
        }
        Button {
          isLinkProposalPresented = true
          Task {
            await viewModel.proposeLinksForSelectedNote()
          }
        } label: {
          Label("Extract links (AI)", systemImage: "sparkles")
        }
        .disabled(viewModel.isLinkProposalLoading)
      }
    }
  }

  private func comments(_ comments: [NoteComment]) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if !comments.isEmpty {
        ForEach(comments, id: \.commentId) { comment in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(comment.author)
                .font(.caption)
                .fontWeight(.semibold)
              Text(comment.createdAt)
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button {
                promoteComment(comment.commentId)
              } label: {
                Image(systemName: "book")
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .disabled(viewModel.isCommentPromotionLoading)
              .help("Create notebook from this comment")
            }
            RielaNoteMarkdownBodyView(markdown: comment.bodyMarkdown)
              .font(.subheadline)
          }
          .padding(.vertical, 4)
        }
        if let promotionError = viewModel.commentPromotionError {
          Text(promotionError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      } else {
        Text("No comments")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      TextEditor(text: $draftCommentMarkdown)
        .font(.body)
        .frame(minHeight: 90)
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Spacer()
        Button {
          let bodyMarkdown = draftCommentMarkdown
          Task {
            await viewModel.addCommentToSelectedNote(bodyMarkdown)
            draftCommentMarkdown = ""
          }
        } label: {
          Label("Add comment", systemImage: "text.bubble")
        }
        .disabled(draftCommentMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func tagEditor(_ note: Note) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !note.tags.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(note.tags, id: \.tag.tagId) { assignment in
            HStack(spacing: 4) {
              RielaNoteTagChip(label: assignment.tag.name, provenance: assignment.provenance)
              if assignment.deletable {
                Button {
                  Task {
                    await viewModel.removeTagFromSelectedNote(name: assignment.tag.name)
                  }
                } label: {
                  Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove tag")
              }
            }
          }
        }
      }
      HStack(spacing: 8) {
        TextField("Tag", text: $draftTagName)
          .textFieldStyle(.roundedBorder)
          .frame(maxWidth: 240)
        let suggestions = rielaNoteTagSuggestions(
          availableTags: viewModel.availableSearchTags,
          existingAssignments: note.tags,
          query: draftTagName
        )
        Menu {
          ForEach(suggestions, id: \.tagId) { tag in
            Button(tag.name) {
              draftTagName = tag.name
            }
          }
        } label: {
          Image(systemName: "tag")
        }
        .disabled(suggestions.isEmpty)
        .help("Tag suggestions")
        Button {
          let tagName = draftTagName
          Task {
            await viewModel.applyTagToSelectedNote(name: tagName)
            draftTagName = ""
          }
        } label: {
          Label("Add tag", systemImage: "tag")
        }
        .disabled(draftTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func iconName(for attachment: NoteFileAttachment) -> String {
    iconName(for: attachment.file, role: attachment.role)
  }

  private func iconName(for file: FileRecord, role: NoteFileRole? = nil) -> String {
    if role == .sourcePageImage || file.mediaType.hasPrefix("image/") {
      return "photo"
    }
    if file.mediaType.hasPrefix("video/") {
      return "video"
    }
    if file.mediaType.hasPrefix("audio/") {
      return "waveform"
    }
    return "paperclip"
  }

  private func linkLabel(_ link: NoteLink, currentNoteId: String, linkedNotes: [String: Note]) -> String {
    let targetNoteId = link.counterpartNoteId(for: currentNoteId)
    let targetTitle = linkedNotes[targetNoteId]?.title ?? targetNoteId
    return "\(link.linkKind): \(targetTitle)"
  }

  private func resetEditingState() {
    bodyDraft.reset()
    draftTagName = ""
    draftCommentMarkdown = ""
    viewModel.clearTranslateNoteState()
    viewModel.clearLinkProposals()
  }

  private func startEditing(_ note: Note) {
    bodyDraft.toggle(noteId: note.noteId, bodyMarkdown: note.bodyMarkdown)
  }

  private func promoteComment(_ commentId: String) {
    let noteId = viewModel.selectedDetail?.note.noteId
    Task {
      await viewModel.promoteCommentToNotebook(commentId: commentId)
      guard viewModel.selectedDetail?.note.noteId == noteId else {
        return
      }
      if viewModel.commentPromotionError == nil {
        isLinksExpanded = true
      }
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

  private func applyDefaultMetadataExpansion(for detail: RielaNoteDetail) {
    isTagsExpanded = (1...4).contains(detail.note.tags.count)
    isLinksExpanded = (1...4).contains(detail.links.count)
    isCommentsExpanded = (1...3).contains(detail.comments.count)
    isFilesExpanded = (1...4).contains(detail.files.count)
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

private extension NoteLink {
  var stableId: String {
    "\(fromNoteId)-\(toNoteId)-\(linkKind)"
  }

  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
