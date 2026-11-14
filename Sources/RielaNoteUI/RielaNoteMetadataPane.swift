import RielaNote
import SwiftUI
import UniformTypeIdentifiers

/// Note metadata editor (tags, links, comments, files) shown either inline under
/// the note body (compact) or as the dedicated right-hand pane (regular).
public struct RielaNoteMetadataPane: View {
  @Environment(\.rielaNoteOpenFile) private var openFileAction
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel
  @State private var draftTagName = ""
  @State private var draftCommentMarkdown = ""
  @State private var isAddLinkPresented = false
  @State private var isLinkProposalPresented = false
  @State private var isTagsExpanded = false
  @State private var isLinksExpanded = false
  @State private var isCommentsExpanded = false
  @State private var isFilesExpanded = false
  @State private var commentError: String?
  @State private var tagError: String?
  @State private var fileOpenError: String?
  @State private var isFileExportPresented = false
  @State private var fileExportDocument = RielaNoteBinaryFileDocument(data: Data(), contentType: .data)
  @State private var fileExportContentType: UTType = .data
  @State private var fileExportFilename = "attachment"
  private let expandsAllSections: Bool

  public init(viewModel: RielaNoteLibraryViewModel, expandsAllSections: Bool = false) {
    self.viewModel = viewModel
    self.expandsAllSections = expandsAllSections
  }

  public var body: some View {
    Group {
      if let detail = viewModel.selectedDetail {
        sections(detail)
          .onAppear {
            applyDefaultExpansion(for: detail)
          }
          .onChange(of: detail.note.noteId) { _, _ in
            resetDraftState()
            applyDefaultExpansion(for: detail)
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
            isPresented: $isFileExportPresented,
            document: fileExportDocument,
            contentType: fileExportContentType,
            defaultFilename: fileExportFilename
          ) { _ in }
      } else {
        emptySelection
      }
    }
  }

  private var emptySelection: some View {
    VStack(spacing: 10) {
      Image(systemName: "info.circle")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.secondary)
      Text("No note")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(12)
  }

  private func sections(_ detail: RielaNoteDetail) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      DisclosureGroup(isExpanded: $isTagsExpanded) {
        tagEditor(detail.note)
          .padding(.top, 8)
      } label: {
        sectionLabel("Tags", count: detail.note.tags.count, systemImage: "tag")
      }
      DisclosureGroup(isExpanded: $isLinksExpanded) {
        links(detail)
          .padding(.top, 8)
      } label: {
        sectionLabel("Links", count: detail.links.count, systemImage: "link")
      }
      DisclosureGroup(isExpanded: $isCommentsExpanded) {
        comments(detail.comments)
          .padding(.top, 8)
      } label: {
        sectionLabel("Comments", count: detail.comments.count, systemImage: "text.bubble")
      }
      DisclosureGroup(isExpanded: $isFilesExpanded) {
        fileStrip(detail.files)
          .padding(.top, 8)
      } label: {
        sectionLabel("Files", count: detail.files.count, systemImage: "paperclip")
      }
    }
  }

  private func sectionLabel(_ title: String, count: Int, systemImage: String) -> some View {
    Label("\(title) (\(count))", systemImage: systemImage)
      .font(.headline)
  }

  private func applyDefaultExpansion(for detail: RielaNoteDetail) {
    if expandsAllSections {
      isTagsExpanded = true
      isLinksExpanded = true
      isCommentsExpanded = true
      isFilesExpanded = true
      return
    }
    isTagsExpanded = (1...4).contains(detail.note.tags.count)
    isLinksExpanded = (1...4).contains(detail.links.count)
    isCommentsExpanded = (1...3).contains(detail.comments.count)
    isFilesExpanded = (1...4).contains(detail.files.count)
  }

  private func resetDraftState() {
    draftTagName = ""
    draftCommentMarkdown = ""
    commentError = nil
    tagError = nil
    fileOpenError = nil
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
         let resolvedFile = viewModel.selectedResolvedFile {
        let file = resolvedFile.file
        HStack(spacing: 8) {
          Label(status, systemImage: iconName(for: file))
          Text(file.storageKind.rawValue)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          if openFileAction != nil {
            Button {
              openResolvedFile(resolvedFile)
            } label: {
              Label("Open", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            .help("Open the resolved file")
          }
          Button {
            presentResolvedFileExport(resolvedFile)
          } label: {
            Label("Save", systemImage: "square.and.arrow.down")
          }
          .controlSize(.small)
          .help("Save the resolved file")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        if let fileOpenError {
          Text(fileOpenError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
    }
  }

  private func openResolvedFile(_ resolvedFile: RielaNoteResolvedFile) {
    guard let openFileAction else {
      return
    }
    do {
      let url = try rielaNoteWriteResolvedFileToScratch(resolvedFile)
      fileOpenError = nil
      openFileAction(url)
    } catch {
      fileOpenError = "Could not open \(rielaNoteResolvedFileName(for: resolvedFile.file))."
    }
  }

  private func presentResolvedFileExport(_ resolvedFile: RielaNoteResolvedFile) {
    let contentType = UTType(mimeType: resolvedFile.file.mediaType) ?? .data
    fileExportContentType = contentType
    fileExportDocument = RielaNoteBinaryFileDocument(data: resolvedFile.data, contentType: contentType)
    fileExportFilename = rielaNoteResolvedFileName(for: resolvedFile.file)
    isFileExportPresented = true
  }

  private func links(_ detail: RielaNoteDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !detail.links.isEmpty {
        ForEach(detail.links, id: \.stableId) { link in
          let targetNoteId = link.counterpartNoteId(for: detail.note.noteId)
          Button {
            Task {
              await viewModel.requestSelection(.note(targetNoteId))
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
      if let commentError {
        Text(commentError)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button {
          let bodyMarkdown = draftCommentMarkdown
          commentError = nil
          Task {
            do {
              try await viewModel.addCommentToSelectedNote(bodyMarkdown)
              draftCommentMarkdown = ""
            } catch {
              // Keep the draft comment so a failed add is not lost.
              commentError = rielaNoteMutationErrorMessage(error)
            }
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
                  tagError = nil
                  Task {
                    do {
                      try await viewModel.removeTagFromSelectedNote(name: assignment.tag.name)
                    } catch {
                      tagError = rielaNoteMutationErrorMessage(error)
                    }
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
          tagError = nil
          Task {
            do {
              try await viewModel.applyTagToSelectedNote(name: tagName)
              draftTagName = ""
            } catch {
              // Keep the typed tag so a failed add is not lost.
              tagError = rielaNoteMutationErrorMessage(error)
            }
          }
        } label: {
          Label("Add tag", systemImage: "tag")
        }
        .disabled(draftTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let tagError {
        Text(tagError)
          .font(.caption)
          .foregroundStyle(.red)
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
}

private extension NoteLink {
  var stableId: String {
    "\(fromNoteId)-\(toNoteId)-\(linkKind)"
  }

  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
