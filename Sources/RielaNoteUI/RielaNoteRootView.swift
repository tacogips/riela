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
          await viewModel.requestSelection(.note(noteId))
          // A body edit in the library detail defers the switch behind the
          // discard confirmation; hold the tab/path change until it resolves.
          guard viewModel.pendingSelection == nil else {
            return
          }
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
    // Hosted at the root so a selection change requested from any pane (list,
    // links, agent citation) while a body edit is in progress confirms before
    // discarding the draft. Discard runs the deferred navigation; Keep editing
    // dismisses without navigating.
    .confirmationDialog(
      "You have unsaved changes",
      isPresented: pendingSelectionBinding,
      titleVisibility: .visible
    ) {
      Button("Discard changes", role: .destructive) {
        // Capture synchronously: dismissing the dialog fires the binding setter,
        // which would otherwise clear `pendingSelection` before the async confirm
        // reads it.
        guard let selection = viewModel.pendingSelection else {
          return
        }
        Task {
          await viewModel.confirmPendingSelection(selection)
          finishPendingNavigation()
        }
      }
      Button("Keep editing", role: .cancel) {
        viewModel.cancelPendingSelection()
      }
    } message: {
      Text("Switching notes will discard your edits.")
    }
  }

  private var pendingSelectionBinding: Binding<Bool> {
    Binding {
      viewModel.pendingSelection != nil
    } set: { presented in
      if !presented, viewModel.pendingSelection != nil {
        viewModel.cancelPendingSelection()
      }
    }
  }

  /// After a confirmed (discarded) navigation completes, mirror the pane routing
  /// the immediate paths perform: surface the library detail for the new note.
  private func finishPendingNavigation() {
    composeDestination = nil
    selectedTab = .library
    if horizontalSizeClass == .compact {
      libraryPath = [.detail]
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
        // Let the error propagate to the compose view so it can preserve the draft
        // and render the mapped human-readable reason; only dismiss on success.
        switch destination {
        case .memo:
          try await viewModel.createUserMemo(body: bodyMarkdown)
        case .selectedNotebook:
          try await viewModel.createNoteInSelectedNotebook(body: bodyMarkdown)
        }
        composeDestination = nil
        libraryPath = [.detail]
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
