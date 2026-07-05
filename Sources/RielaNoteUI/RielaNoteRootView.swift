import SwiftUI

public struct RielaNoteRootView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel: RielaNoteLibraryViewModel
  @StateObject private var agentViewModel: RielaNoteAgentViewModel
  @StateObject private var configAgentViewModel: RielaNoteConfigAgentViewModel
  @State private var selectedTab: RielaNoteRootTab = .library
  @State private var libraryPath: [RielaNoteLibraryRoute] = []
  @State private var didRunInitialLoad = false
  @State private var noteStoreChangeWatcher: RielaNoteStoreChangeWatcher?

  public init(client: any RielaNoteUIClient) {
    _viewModel = StateObject(wrappedValue: RielaNoteLibraryViewModel(client: client))
    _agentViewModel = StateObject(wrappedValue: RielaNoteAgentViewModel(client: client))
    _configAgentViewModel = StateObject(wrappedValue: RielaNoteConfigAgentViewModel(client: client))
  }

  public init(viewModel: RielaNoteLibraryViewModel) {
    _viewModel = StateObject(wrappedValue: viewModel)
    _agentViewModel = StateObject(wrappedValue: RielaNoteAgentViewModel(client: viewModel.client))
    _configAgentViewModel = StateObject(wrappedValue: RielaNoteConfigAgentViewModel(client: viewModel.client))
  }

  public init(
    viewModel: RielaNoteLibraryViewModel,
    agentViewModel: RielaNoteAgentViewModel,
    configAgentViewModel: RielaNoteConfigAgentViewModel
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    _agentViewModel = StateObject(wrappedValue: agentViewModel)
    _configAgentViewModel = StateObject(wrappedValue: configAgentViewModel)
  }

  public var body: some View {
    TabView(selection: $selectedTab) {
      libraryNavigation
      .tabItem {
        Label("Library", systemImage: "books.vertical")
      }
      .tag(RielaNoteRootTab.library)

      RielaNoteAgentView(viewModel: agentViewModel) { noteId in
        Task {
          await viewModel.selectNote(noteId)
          selectedTab = .library
          if horizontalSizeClass == .compact {
            libraryPath = [.detail]
          }
        }
      }
      .tabItem {
        Label("Agent", systemImage: "sparkles")
      }
      .tag(RielaNoteRootTab.agent)

      RielaNoteConfigAgentView(viewModel: configAgentViewModel)
        .tabItem {
          Label("Config", systemImage: "slider.horizontal.3")
        }
        .tag(RielaNoteRootTab.config)
    }
    .task {
      await viewModel.load()
      didRunInitialLoad = true
      startNoteStoreChangeWatcher()
    }
    .onChange(of: scenePhase) { _, newPhase in
      guard newPhase == .active, didRunInitialLoad else {
        return
      }
      Task {
        await viewModel.refresh()
      }
    }
    .onDisappear {
      noteStoreChangeWatcher?.stop()
      noteStoreChangeWatcher = nil
    }
  }

  @ViewBuilder
  private var libraryNavigation: some View {
    if horizontalSizeClass == .compact {
      NavigationStack(path: $libraryPath) {
        RielaNoteNotebookListView(viewModel: viewModel) { _ in
          libraryPath = [.detail]
        }
        .navigationTitle("Notes")
        .navigationDestination(for: RielaNoteLibraryRoute.self) { _ in
          RielaNoteDetailView(viewModel: viewModel)
        }
      }
    } else {
      NavigationSplitView {
        RielaNoteNotebookListView(viewModel: viewModel)
          .navigationTitle("Notes")
      } detail: {
        RielaNoteDetailView(viewModel: viewModel)
      }
    }
  }

  private func startNoteStoreChangeWatcher() {
    guard noteStoreChangeWatcher == nil else {
      return
    }
    let watcher = RielaNoteStoreChangeWatcher(
      fileURLs: viewModel.client.noteStoreChangeObservationURLs
    ) {
      await viewModel.refresh()
    }
    guard watcher.start() else {
      return
    }
    noteStoreChangeWatcher = watcher
  }
}

private enum RielaNoteRootTab: Hashable {
  case library
  case agent
  case config
}

private enum RielaNoteLibraryRoute: Hashable {
  case detail
}
