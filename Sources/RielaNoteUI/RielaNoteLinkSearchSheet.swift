import RielaNote
import SwiftUI

struct RielaNoteLinkSearchSheet: View {
  @ObservedObject var viewModel: RielaNoteLibraryViewModel
  var detail: RielaNoteDetail
  var onCancel: () -> Void
  var onLinked: () -> Void
  @State private var query = ""
  @State private var results: [NoteSearchResult] = []
  @State private var selectedNoteId: String?
  @State private var selectedDetail: RielaNoteDetail?
  @State private var linkKind = "related"
  @State private var state = LinkSearchState.idle
  @State private var searchTask: Task<Void, Never>?
  @State private var previewTask: Task<Void, Never>?
  @State private var errorText: String?
  @State private var isAdvancedExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add link")
        .font(.headline)
      TextField("Search full note text", text: $query)
        .textFieldStyle(.roundedBorder)
        .onSubmit(runSearchImmediately)
        .onChange(of: query) { _, _ in
          scheduleSearch()
        }
      if let errorText {
        Text(errorText)
          .font(.caption)
          .foregroundStyle(.red)
      }
      HStack(alignment: .top, spacing: 12) {
        resultList
          .frame(minWidth: 260, idealWidth: 320, maxWidth: 340, maxHeight: .infinity)
        Divider()
        preview
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
        VStack(alignment: .leading, spacing: 6) {
          TextField("Link kind", text: $linkKind)
            .textFieldStyle(.roundedBorder)
          Text("Allowed: related, source-citation")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button {
          let targetNoteId = selectedNoteId
          let kind = rielaNoteAllowedLinkKind(linkKind)
          errorText = nil
          Task {
            if let targetNoteId {
              do {
                try await viewModel.linkSelectedNote(to: targetNoteId, kind: kind)
                onLinked()
              } catch {
                // Keep the sheet open on failure; only dismiss on success.
                errorText = rielaNoteMutationErrorMessage(error)
              }
            }
          }
        } label: {
          Label("Add link", systemImage: "link.badge.plus")
        }
        .buttonStyle(.borderedProminent)
        .disabled(selectedNoteId == nil)
      }
    }
    .padding()
    .frame(minWidth: 520, idealWidth: 760, minHeight: 420, idealHeight: 520)
    .onDisappear {
      searchTask?.cancel()
      previewTask?.cancel()
    }
  }

  private var resultList: some View {
    List(selection: $selectedNoteId) {
      ForEach(filteredResults, id: \.note.noteId) { result in
        VStack(alignment: .leading, spacing: 4) {
          Text(result.note.title ?? result.note.noteId)
            .font(.subheadline)
            .fontWeight(.semibold)
            .lineLimit(2)
          Text(result.snippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
        .tag(result.note.noteId)
      }
    }
    .overlay {
      if state == .loading {
        ProgressView()
      } else if state == .loaded && filteredResults.isEmpty {
        ContentUnavailableView.search
      }
    }
    .onChange(of: selectedNoteId) { _, noteId in
      loadPreview(noteId)
    }
  }

  @ViewBuilder
  private var preview: some View {
    if let selectedDetail {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(selectedDetail.note.title ?? selectedDetail.note.noteId)
            .font(.title3)
            .fontWeight(.semibold)
          RielaNoteMarkdownBodyView(markdown: selectedDetail.note.bodyMarkdown)
        }
        .padding(.trailing, 8)
      }
    } else {
      ContentUnavailableView("Select a candidate", systemImage: "doc.text.magnifyingglass")
    }
  }

  private var filteredResults: [NoteSearchResult] {
    rielaNoteSearchLinkResults(
      results,
      currentNoteId: detail.note.noteId,
      existingLinks: detail.links
    )
  }

  private func scheduleSearch() {
    searchTask?.cancel()
    searchTask = Task {
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else {
        return
      }
      await MainActor.run {
        search()
      }
    }
  }

  private func runSearchImmediately() {
    searchTask?.cancel()
    search()
  }

  private func search() {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      results = []
      selectedNoteId = nil
      selectedDetail = nil
      errorText = nil
      state = .idle
      return
    }
    let previousSelection = selectedNoteId
    state = .loading
    errorText = nil
    searchTask = Task {
      do {
        let page = try await viewModel.client.searchNotes(
          query: normalized,
          tagFilter: [],
          classFilter: [],
          filter: RielaNoteListFilter(),
          limit: 20,
          offset: 0
        )
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard query.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else {
            return
          }
          results = page
          if previousSelection == nil || !filteredResults.contains(where: { $0.note.noteId == previousSelection }) {
            selectedNoteId = filteredResults.first?.note.noteId
          }
          state = .loaded
        }
      } catch {
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard query.trimmingCharacters(in: .whitespacesAndNewlines) == normalized else {
            return
          }
          results = []
          selectedNoteId = nil
          selectedDetail = nil
          errorText = String(describing: error)
          state = .failed
        }
      }
    }
  }

  private func loadPreview(_ noteId: String?) {
    previewTask?.cancel()
    guard let noteId else {
      selectedDetail = nil
      return
    }
    previewTask = Task {
      do {
        let detail = try await viewModel.client.noteDetail(noteId: noteId)
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard selectedNoteId == noteId else {
            return
          }
          selectedDetail = detail
          errorText = nil
        }
      } catch {
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard selectedNoteId == noteId else {
            return
          }
          selectedDetail = nil
          errorText = String(describing: error)
        }
      }
    }
  }
}

private enum LinkSearchState: Equatable {
  case idle
  case loading
  case loaded
  case failed
}

func rielaNoteSearchLinkResults(
  _ results: [NoteSearchResult],
  currentNoteId: String,
  existingLinks: [NoteLink]
) -> [NoteSearchResult] {
  let linkedNoteIds = Set(existingLinks.map { $0.counterpartNoteId(for: currentNoteId) })
  var seenNoteIds: Set<String> = []
  return results.filter { result in
    let noteId = result.note.noteId
    return noteId != currentNoteId
      && !linkedNoteIds.contains(noteId)
      && seenNoteIds.insert(noteId).inserted
  }
}

struct RielaNoteLinkProposalSheet: View {
  @ObservedObject var viewModel: RielaNoteLibraryViewModel
  var onDone: () -> Void
  @State private var selectedNoteId: String?
  @State private var selectedDetail: RielaNoteDetail?
  @State private var previewError: String?
  @State private var previewTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Extracted link proposals")
        .font(.headline)
      if let error = viewModel.linkProposalError {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
      }
      if viewModel.isLinkProposalLoading {
        ProgressView()
      } else if viewModel.linkProposals.isEmpty {
        ContentUnavailableView("No link proposals", systemImage: "sparkles")
      } else {
        proposalContent
      }
      HStack {
        Spacer()
        Button("Done", action: onDone)
      }
    }
    .padding()
    .frame(minWidth: 520, idealWidth: 760, minHeight: 420, idealHeight: 520)
    .onDisappear {
      previewTask?.cancel()
    }
  }

  private var proposalContent: some View {
    HStack(alignment: .top, spacing: 12) {
      List(selection: $selectedNoteId) {
        ForEach(viewModel.linkProposals, id: \.targetNote.noteId) { proposal in
          proposalRow(proposal)
            .tag(proposal.targetNote.noteId)
        }
      }
      .frame(minWidth: 260, idealWidth: 340)
      Divider()
      proposalPreview
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .onAppear {
      if selectedNoteId == nil {
        selectedNoteId = viewModel.linkProposals.first?.targetNote.noteId
      }
    }
    .onChange(of: selectedNoteId) { _, noteId in
      loadProposalPreview(noteId)
    }
  }

  private func proposalRow(_ proposal: NoteLinkProposal) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(proposal.targetNote.title ?? proposal.targetNote.noteId)
        .font(.subheadline)
        .fontWeight(.semibold)
      Text(proposal.reason)
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Text(proposal.source)
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.12), in: Capsule())
        Text(rielaNoteAllowedLinkKind(proposal.linkKind))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          Task {
            // The error surfaces via viewModel.linkProposalError; nothing else to
            // do on failure since the proposal stays in the list.
            try? await viewModel.acceptLinkProposal(proposal)
          }
        } label: {
          Label("Accept", systemImage: "checkmark")
        }
        .buttonStyle(.bordered)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private var proposalPreview: some View {
    if let selectedDetail {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text(selectedDetail.note.title ?? selectedDetail.note.noteId)
            .font(.title3)
            .fontWeight(.semibold)
          RielaNoteMarkdownBodyView(markdown: selectedDetail.note.bodyMarkdown)
        }
      }
    } else if let previewError {
      ContentUnavailableView("Preview unavailable", systemImage: "exclamationmark.triangle", description: Text(previewError))
    } else {
      ContentUnavailableView("Select a proposal", systemImage: "doc.text.magnifyingglass")
    }
  }

  private func loadProposalPreview(_ noteId: String?) {
    previewTask?.cancel()
    guard let noteId else {
      selectedDetail = nil
      previewError = nil
      return
    }
    previewTask = Task {
      do {
        let detail = try await viewModel.client.noteDetail(noteId: noteId)
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard selectedNoteId == noteId else {
            return
          }
          selectedDetail = detail
          previewError = nil
        }
      } catch {
        guard !Task.isCancelled else {
          return
        }
        await MainActor.run {
          guard selectedNoteId == noteId else {
            return
          }
          selectedDetail = nil
          previewError = String(describing: error)
        }
      }
    }
  }
}

private extension NoteLink {
  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
