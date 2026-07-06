import RielaNote
import SwiftUI

public struct RielaNoteFilterPane: View {
  @ObservedObject private var viewModel: RielaNoteLibraryViewModel

  public init(viewModel: RielaNoteLibraryViewModel) {
    self.viewModel = viewModel
  }

  public var body: some View {
    Form {
      Section("Search") {
        TextField("Search notes", text: searchTextBinding)
          .textFieldStyle(.roundedBorder)
        Toggle("Also associated to matches", isOn: includeLinkedBinding)
      }
      Section("Sort") {
        Picker("Sort", selection: sortBinding) {
          Text("Newest").tag(NoteListSort.createdAtDesc)
          Text("Oldest").tag(NoteListSort.createdAtAsc)
          Text("Updated").tag(NoteListSort.updatedAtDesc)
          Text("Title").tag(NoteListSort.title)
        }
        .pickerStyle(.segmented)
      }
      Section("Created") {
        Picker("Created", selection: createdRangeBinding) {
          Text("Any").tag(RielaNoteListFilter.CreatedRange.any)
          Text("Today").tag(RielaNoteListFilter.CreatedRange.today)
          Text("7 days").tag(RielaNoteListFilter.CreatedRange.last7Days)
          Text("30 days").tag(RielaNoteListFilter.CreatedRange.last30Days)
          Text("Custom").tag(RielaNoteListFilter.CreatedRange.custom)
        }
        .pickerStyle(.menu)
        if viewModel.filter.createdRange == .custom {
          TextField("Created after ISO8601", text: customCreatedAfterBinding)
            .textFieldStyle(.roundedBorder)
          TextField("Created before ISO8601", text: customCreatedBeforeBinding)
            .textFieldStyle(.roundedBorder)
        }
      }
      Section("Classes") {
        tagClassButtons
      }
      Section("Tags") {
        tagButtons
      }
      if viewModel.hasSearchFilters {
        Button {
          Task {
            await viewModel.clearSearchFilters()
          }
        } label: {
          Label("Clear filters", systemImage: "xmark.circle")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Filters")
  }

  private var searchTextBinding: Binding<String> {
    Binding {
      viewModel.searchText
    } set: { text in
      Task {
        await viewModel.updateSearchText(text)
      }
    }
  }

  private var sortBinding: Binding<NoteListSort> {
    Binding {
      viewModel.filter.sort
    } set: { sort in
      Task {
        await viewModel.updateSort(sort)
      }
    }
  }

  private var createdRangeBinding: Binding<RielaNoteListFilter.CreatedRange> {
    Binding {
      viewModel.filter.createdRange
    } set: { range in
      Task {
        await viewModel.updateCreatedRange(range)
      }
    }
  }

  private var includeLinkedBinding: Binding<Bool> {
    Binding {
      viewModel.filter.includeLinked
    } set: { includeLinked in
      Task {
        await viewModel.updateIncludeLinked(includeLinked)
      }
    }
  }

  private var customCreatedAfterBinding: Binding<String> {
    Binding {
      viewModel.filter.customCreatedAfter
    } set: { value in
      Task {
        await viewModel.updateCustomCreatedAfter(value)
      }
    }
  }

  private var customCreatedBeforeBinding: Binding<String> {
    Binding {
      viewModel.filter.customCreatedBefore
    } set: { value in
      Task {
        await viewModel.updateCustomCreatedBefore(value)
      }
    }
  }

  private var tagClassButtons: some View {
    FlowLayout(spacing: 6) {
      ForEach(viewModel.availableSearchTagClasses, id: \.classId) { tagClass in
        Button {
          Task {
            await viewModel.toggleSearchClass(tagClass.classId)
          }
        } label: {
          Label(
            tagClass.label,
            systemImage: viewModel.selectedSearchClassIds.contains(tagClass.classId) ? "checkmark.circle" : "square.grid.2x2"
          )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  private var tagButtons: some View {
    FlowLayout(spacing: 6) {
      ForEach(viewModel.availableSearchTags, id: \.tagId) { tag in
        Button {
          Task {
            await viewModel.toggleSearchTag(tag.name)
          }
        } label: {
          Label(tag.name, systemImage: viewModel.selectedSearchTagNames.contains(tag.name) ? "checkmark" : "tag")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }
}
