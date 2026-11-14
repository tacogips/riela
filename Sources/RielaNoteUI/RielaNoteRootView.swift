import SwiftUI

public struct RielaNoteRootView: View {
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var viewModel: RielaNoteLibraryViewModel
  @StateObject private var agentViewModel: RielaNoteAgentViewModel
  @StateObject private var configAgentViewModel: RielaNoteConfigAgentViewModel
  @State private var selectedTab: RielaNoteRootTab = .library
  @State private var libraryPath: [RielaNoteLibraryRoute] = []
  @State private var composeDestination: RielaNoteCreationDestination?
  @State private var isFilterSheetPresented = false
  @State private var didRunInitialLoad = false
  @State private var regularColumnVisibility: NavigationSplitViewVisibility = .all
  @State private var noteStoreChangeWatcher: RielaNoteStoreChangeWatcher?
  private let onOpenSettings: (() -> Void)?

  public init(client: any RielaNoteUIClient, onOpenSettings: (() -> Void)? = nil) {
    _viewModel = StateObject(wrappedValue: RielaNoteLibraryViewModel(
      client: client,
      translationTargetLanguage: client.defaultTranslationTargetLanguage
    ))
    _agentViewModel = StateObject(wrappedValue: RielaNoteAgentViewModel(client: client))
    _configAgentViewModel = StateObject(wrappedValue: RielaNoteConfigAgentViewModel(client: client))
    self.onOpenSettings = onOpenSettings
  }

  public init(viewModel: RielaNoteLibraryViewModel, onOpenSettings: (() -> Void)? = nil) {
    _viewModel = StateObject(wrappedValue: viewModel)
    _agentViewModel = StateObject(wrappedValue: RielaNoteAgentViewModel(client: viewModel.client))
    _configAgentViewModel = StateObject(wrappedValue: RielaNoteConfigAgentViewModel(client: viewModel.client))
    self.onOpenSettings = onOpenSettings
  }

  public init(
    viewModel: RielaNoteLibraryViewModel,
    agentViewModel: RielaNoteAgentViewModel,
    configAgentViewModel: RielaNoteConfigAgentViewModel,
    onOpenSettings: (() -> Void)? = nil
  ) {
    _viewModel = StateObject(wrappedValue: viewModel)
    _agentViewModel = StateObject(wrappedValue: agentViewModel)
    _configAgentViewModel = StateObject(wrappedValue: configAgentViewModel)
    self.onOpenSettings = onOpenSettings
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
        RielaNoteNotebookListView(
          viewModel: viewModel,
          onCreate: openCompose,
          onOpenNote: { _ in
            libraryPath = [.detail]
          }
        )
        .toolbar {
          ToolbarItem {
            Button {
              isFilterSheetPresented = true
            } label: {
              Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filters")
          }
          settingsToolbarItem
        }
        .sheet(isPresented: $isFilterSheetPresented) {
          NavigationStack {
            RielaNoteFilterPane(viewModel: viewModel)
              .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                  Button("Done") {
                    isFilterSheetPresented = false
                  }
                }
              }
          }
        }
        .navigationTitle("Notes")
        .navigationDestination(for: RielaNoteLibraryRoute.self) { route in
          switch route {
          case .detail:
            RielaNoteDetailView(viewModel: viewModel)
          case .compose(let destination):
            composeView(destination)
          }
        }
      }
    } else {
      NavigationSplitView(columnVisibility: regularColumnVisibilityBinding) {
        RielaNoteFilterPane(viewModel: viewModel)
          .navigationTitle("Filters")
          .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
          .toolbar {
            settingsToolbarItem
          }
      } content: {
        RielaNoteNotebookListView(
          viewModel: viewModel,
          onCreate: openCompose,
          onOpenNote: { _ in
            composeDestination = nil
          }
        )
          .navigationTitle("Notes")
          .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 460)
      } detail: {
        if let composeDestination {
          composeView(composeDestination)
        } else {
          RielaNoteDetailView(viewModel: viewModel)
        }
      }
    }
  }

  @ToolbarContentBuilder
  private var settingsToolbarItem: some ToolbarContent {
    if let onOpenSettings {
      ToolbarItem {
        Button(action: onOpenSettings) {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Note settings")
      }
    }
  }

  private func openCompose(_ destination: RielaNoteCreationDestination) {
    composeDestination = destination
    if horizontalSizeClass == .compact {
      libraryPath = [.compose(destination)]
    }
  }

  private func composeView(_ destination: RielaNoteCreationDestination) -> some View {
    RielaNoteComposeView(
      destination: destination,
      selectedNotebookTitle: selectedNotebookTitle,
      onCancel: {
        composeDestination = nil
        if horizontalSizeClass == .compact {
          libraryPath.removeAll()
        }
      },
      onSave: { bodyMarkdown in
        Task {
          switch destination {
          case .memo:
            await viewModel.createUserMemo(body: bodyMarkdown)
          case .selectedNotebook:
            await viewModel.createNoteInSelectedNotebook(body: bodyMarkdown)
          }
          composeDestination = nil
          libraryPath = [.detail]
        }
      }
    )
  }

  private var selectedNotebookTitle: String? {
    guard let selectedNotebookId = viewModel.selectedNotebookId else {
      return nil
    }
    return viewModel.notebooks.first { $0.notebookId == selectedNotebookId }?.title
  }

  private var regularColumnVisibilityBinding: Binding<NavigationSplitViewVisibility> {
    Binding {
      viewModel.isDetailExpanded ? .detailOnly : regularColumnVisibility
    } set: { visibility in
      regularColumnVisibility = visibility
      viewModel.isDetailExpanded = visibility == .detailOnly
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
  case compose(RielaNoteCreationDestination)
}
