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
  @State private var isLoading = false
  @State private var isAdvancedExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Add link")
        .font(.headline)
      TextField("Search full note text", text: $query)
        .textFieldStyle(.roundedBorder)
        .onSubmit(search)
        .onChange(of: query) { _, _ in
          search()
        }
      HStack(alignment: .top, spacing: 12) {
        resultList
          .frame(minWidth: 260, maxWidth: 340, maxHeight: .infinity)
        Divider()
        preview
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      DisclosureGroup("Advanced", isExpanded: $isAdvancedExpanded) {
        TextField("Link kind", text: $linkKind)
          .textFieldStyle(.roundedBorder)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button {
          let targetNoteId = selectedNoteId
          let kind = linkKind
          Task {
            if let targetNoteId {
              await viewModel.linkSelectedNote(to: targetNoteId, kind: kind)
              onLinked()
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
    .frame(width: 760, height: 520)
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
      if isLoading {
        ProgressView()
      } else if filteredResults.isEmpty {
        ContentUnavailableView.search
      }
    }
    .onChange(of: selectedNoteId) { _, noteId in
      guard let noteId else {
        selectedDetail = nil
        return
      }
      Task {
        selectedDetail = try? await viewModel.client.noteDetail(noteId: noteId)
      }
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

  private func search() {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      results = []
      selectedNoteId = nil
      selectedDetail = nil
      return
    }
    isLoading = true
    Task {
      let page = (try? await viewModel.client.searchNotes(
        query: normalized,
        tagFilter: [],
        classFilter: [],
        filter: RielaNoteListFilter(),
        limit: 20,
        offset: 0
      )) ?? []
      await MainActor.run {
        results = page
        selectedNoteId = filteredResults.first?.note.noteId
        isLoading = false
      }
    }
  }
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

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Extracted link proposals")
        .font(.headline)
      if viewModel.isLinkProposalLoading {
        ProgressView()
      } else if viewModel.linkProposals.isEmpty {
        ContentUnavailableView("No link proposals", systemImage: "sparkles")
      } else {
        List {
          ForEach(viewModel.linkProposals, id: \.targetNote.noteId) { proposal in
            VStack(alignment: .leading, spacing: 6) {
              Text(proposal.targetNote.title ?? proposal.targetNote.noteId)
                .font(.subheadline)
                .fontWeight(.semibold)
              Text(proposal.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
              HStack {
                Text(proposal.linkKind)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Spacer()
                Button {
                  Task {
                    await viewModel.acceptLinkProposal(proposal)
                  }
                } label: {
                  Label("Accept", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
              }
            }
            .padding(.vertical, 4)
          }
        }
      }
      HStack {
        Spacer()
        Button("Done", action: onDone)
      }
    }
    .padding()
    .frame(width: 520, height: 420)
  }
}

private extension NoteLink {
  func counterpartNoteId(for noteId: String) -> String {
    fromNoteId == noteId ? toNoteId : fromNoteId
  }
}
