import RielaNote
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
  @State private var noteStoreChangeWatcher: RielaNoteStoreChangeWatcher?
  @State private var pendingNotebookExpansionSession: RielaNoteNotebookExpansionSession?
  @State private var isAgentReplacementConfirmationPresented = false
  // Left/right panes start folded; the top-right icons expand them.
  @AppStorage("rielaNoteWorkspace.leftPane.isExpanded") private var isFileTreePaneExpanded = false
  @AppStorage("rielaNoteWorkspace.rightPane.isExpanded") private var isMetadataPaneExpanded = false
  @AppStorage("rielaNoteWorkspace.leftPane.mode") private var selectedLeftPaneMode = RielaNoteLeftPaneMode.tree
  @AppStorage("rielaNoteWorkspace.agentBottomBar.isFolded") private var isAgentBottomBarFolded = false
  @State private var isSearchPopupPresented = false
  private let onOpenSettings: (() -> Void)?

  public init(client: any RielaNoteUIClient, onOpenSettings: (() -> Void)? = nil) {
    _viewModel = StateObject(wrappedValue: RielaNoteLibraryViewModel(client: client))
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
    .onChange(of: viewModel.notebookExpansionSession) { _, session in
      guard let session else {
        return
      }
      pendingNotebookExpansionSession = session
      guard agentViewModel.canBeginNotebookExpansionSession else {
        isAgentReplacementConfirmationPresented = true
        return
      }
      routeNotebookExpansion(session)
    }
    .alert("Unable to expand notebook", isPresented: notebookExpansionErrorBinding) {
      Button("OK") {
        viewModel.notebookExpansionError = nil
      }
    } message: {
      Text(viewModel.notebookExpansionError ?? "Notebook expansion failed.")
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
        let expansionSession = pendingNotebookExpansionSession.flatMap { session in
          if case let .notebook(notebookId) = selection,
             notebookId == session.conversationNotebookId {
            return session
          }
          return nil
        }
        Task {
          await viewModel.confirmPendingSelection(selection)
          if let expansionSession {
            if rielaNoteCompleteNotebookExpansionRouting(
              viewModel: viewModel,
              agentViewModel: agentViewModel,
              session: expansionSession
            ) {
              finishNotebookExpansionRouting()
            } else {
              pendingNotebookExpansionSession = nil
              viewModel.notebookExpansionError = "The expanded notebook couldn't be opened."
            }
          } else {
            pendingNotebookExpansionSession = nil
            finishPendingNavigation()
          }
        }
      }
      Button("Keep editing", role: .cancel) {
        viewModel.cancelPendingSelection()
        pendingNotebookExpansionSession = nil
      }
    } message: {
      Text("Switching notes will discard your edits.")
    }
    .confirmationDialog(
      "Replace unsaved Agent conversation?",
      isPresented: $isAgentReplacementConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard and expand", role: .destructive) {
        guard let session = pendingNotebookExpansionSession else {
          return
        }
        guard agentViewModel.discardCurrentConversation() else {
          return
        }
        routeNotebookExpansion(session)
      }
      .disabled(agentViewModel.state == .loading)
      Button("Keep current conversation", role: .cancel) {
        pendingNotebookExpansionSession = nil
      }
    } message: {
      Text("Wait for any active response, then save the current Agent conversation or discard it to open this expansion.")
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

  private var notebookExpansionErrorBinding: Binding<Bool> {
    Binding {
      viewModel.notebookExpansionError != nil
    } set: { presented in
      if !presented {
        viewModel.notebookExpansionError = nil
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

  private func finishNotebookExpansionRouting() {
    pendingNotebookExpansionSession = nil
    composeDestination = nil
    selectedTab = .agent
    isAgentBottomBarFolded = false
  }

  private func routeNotebookExpansion(_ session: RielaNoteNotebookExpansionSession) {
    Task {
      await viewModel.refresh()
      let didBeginExpansion = await rielaNoteBeginNotebookExpansionRouting(
        viewModel: viewModel,
        agentViewModel: agentViewModel,
        session: session
      )
      if didBeginExpansion {
        finishNotebookExpansionRouting()
      } else if viewModel.pendingSelection == nil {
        pendingNotebookExpansionSession = nil
        viewModel.notebookExpansionError = "The expanded notebook couldn't be opened."
      }
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
            RielaNoteDetailView(viewModel: viewModel, onAskAgent: openAgentForCurrentNote)
          case .compose(let destination):
            composeView(destination)
          }
        }
      }
    } else {
      regularLayout
    }
  }

  /// Regular-width layout: file tree (left, folded by default), note (center),
  /// note metadata (right, folded by default), search as a popup, and the agent
  /// bar pinned to the bottom of the screen.
  private var regularLayout: some View {
    VStack(spacing: 0) {
      regularToolbar
      Divider()
      paneSplit
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      RielaNoteAgentBottomBar(viewModel: agentViewModel) { noteId in
        Task {
          await viewModel.requestSelection(.note(noteId))
        }
      }
    }
    .sheet(isPresented: $isSearchPopupPresented) {
      RielaNoteSearchPopupSheet(viewModel: viewModel) {
        isSearchPopupPresented = false
      }
    }
    .onChange(of: viewModel.pendingSelection) { _, pendingSelection in
      if pendingSelection != nil, isSearchPopupPresented {
        isSearchPopupPresented = false
      }
    }
  }

  @ViewBuilder
  private var paneSplit: some View {
    #if os(macOS)
    HSplitView {
      paneSplitContent
    }
    #else
    HStack(spacing: 0) {
      paneSplitContent
    }
    #endif
  }

  @ViewBuilder
  private var paneSplitContent: some View {
    if isFileTreePaneExpanded {
      leftPane
      .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
    }
    Group {
      if let composeDestination {
        composeView(composeDestination)
      } else {
        RielaNoteDetailView(
          viewModel: viewModel,
          showsMetadata: false,
          showsExpandToggle: false,
          onAskAgent: openAgentForCurrentNote
        )
      }
    }
    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
    .layoutPriority(1)
    if isMetadataPaneExpanded {
      ScrollView {
        RielaNoteMetadataPane(viewModel: viewModel, expandsAllSections: true)
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minWidth: 240, idealWidth: 320, maxWidth: 420)
    }
  }

  private var leftPane: some View {
    VStack(spacing: 0) {
      Picker("Left pane", selection: $selectedLeftPaneMode) {
        Label("Tree", systemImage: "folder")
          .tag(RielaNoteLeftPaneMode.tree)
        Label("Notes", systemImage: "list.bullet")
          .tag(RielaNoteLeftPaneMode.notes)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      Divider()
      switch selectedLeftPaneMode {
      case .tree:
        RielaNoteFileTreePane(viewModel: viewModel) { _ in
          composeDestination = nil
        }
      case .notes:
        leftPaneNotesList
      }
    }
    .background(.background)
  }

  private var leftPaneNotesList: some View {
    let snapshot = viewModel.pagerNoteSnapshot
    return List {
      if let selectedNotebookTitle {
        Section {
          ForEach(snapshot.notes, id: \.noteId) { note in
            leftPaneNoteRow(note, snapshot: snapshot)
          }
          if viewModel.canLoadMoreNotebookNotes {
            Button {
              Task {
                await viewModel.loadMoreNotebookNotes()
              }
            } label: {
              Label("Load more", systemImage: "ellipsis.circle")
            }
            .buttonStyle(.plain)
          }
        } header: {
          HStack {
            Text(selectedNotebookTitle)
              .lineLimit(1)
            Spacer()
            if let position = snapshot.selectedNoteId.flatMap({ snapshot.positionText(for: $0) }) {
              Text(position)
                .monospacedDigit()
            }
          }
        }
      } else {
        ContentUnavailableView("No notebook selected", systemImage: "folder")
      }
    }
    .listStyle(.sidebar)
  }

  private func leftPaneNoteRow(
    _ note: Note,
    snapshot: RielaNotePagerNoteSnapshot
  ) -> some View {
    let isSelected = note.noteId == snapshot.selectedNoteId
    return Button {
      Task {
        await viewModel.requestSelection(.note(note.noteId))
        guard viewModel.pendingSelection == nil else {
          return
        }
        composeDestination = nil
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isSelected ? "doc.text.fill" : "doc.text")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
        Text(note.title ?? note.noteId)
          .fontWeight(isSelected ? .semibold : .regular)
          .lineLimit(1)
        Spacer(minLength: 6)
        Text(snapshot.positionText(for: note.noteId) ?? snapshot.totalText)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .monospacedDigit()
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var regularToolbar: some View {
    HStack(spacing: 10) {
      Text("Notes")
        .font(.headline)
      Button {
        openCompose(.memo)
      } label: {
        Label("New memo", systemImage: "square.and.pencil")
      }
      .help("New memo")
      .keyboardShortcut("n", modifiers: .command)
      Button {
        openCompose(.selectedNotebook)
      } label: {
        Label("New note", systemImage: "doc.badge.plus")
      }
      .disabled(!viewModel.canCreateNoteInSelectedNotebook)
      .help("New note in selected notebook")
      .keyboardShortcut("n", modifiers: [.command, .shift])
      Button {
        Task {
          await viewModel.refresh()
        }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help("Refresh notes")
      .keyboardShortcut("r", modifiers: .command)
      Spacer()
      Button {
        isSearchPopupPresented = true
      } label: {
        Label("Search", systemImage: "magnifyingglass")
      }
      .help("Search notes")
      .keyboardShortcut("f", modifiers: .command)
      if let onOpenSettings {
        Button(action: onOpenSettings) {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Note settings")
      }
      Divider()
        .frame(height: 16)
      Button {
        withAnimation {
          isFileTreePaneExpanded.toggle()
        }
      } label: {
        Label("Files", systemImage: "sidebar.leading")
      }
      .help(isFileTreePaneExpanded ? "Hide file list" : "Show file list")
      .keyboardShortcut("1", modifiers: [.command, .option])
      Button {
        withAnimation {
          isMetadataPaneExpanded.toggle()
        }
      } label: {
        Label("Metadata", systemImage: "sidebar.trailing")
      }
      .help(isMetadataPaneExpanded ? "Hide note metadata" : "Show note metadata")
      .keyboardShortcut("2", modifiers: [.command, .option])
    }
    .buttonStyle(.borderless)
    .labelStyle(.iconOnly)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func openAgentForCurrentNote(_ note: Note) {
    agentViewModel.prepareCurrentNoteQuestion(for: note)
    isAgentBottomBarFolded = false
    if horizontalSizeClass == .compact {
      selectedTab = .agent
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

@MainActor
func rielaNoteBeginNotebookExpansionRouting(
  viewModel: RielaNoteLibraryViewModel,
  agentViewModel: RielaNoteAgentViewModel,
  session: RielaNoteNotebookExpansionSession
) async -> Bool {
  guard agentViewModel.canBeginNotebookExpansionSession else {
    return false
  }
  await viewModel.requestSelection(.notebook(session.conversationNotebookId))
  return rielaNoteCompleteNotebookExpansionRouting(
    viewModel: viewModel,
    agentViewModel: agentViewModel,
    session: session
  )
}

@MainActor
func rielaNoteCompleteNotebookExpansionRouting(
  viewModel: RielaNoteLibraryViewModel,
  agentViewModel: RielaNoteAgentViewModel,
  session: RielaNoteNotebookExpansionSession
) -> Bool {
  guard viewModel.pendingSelection == nil,
        viewModel.selectedNotebookId == session.conversationNotebookId,
        viewModel.state == .loaded else {
    return false
  }
  return agentViewModel.beginNotebookExpansionSession(session)
}

private enum RielaNoteRootTab: Hashable {
  case library
  case agent
  case config
}

private enum RielaNoteLeftPaneMode: String, Hashable {
  case tree
  case notes
}

private enum RielaNoteLibraryRoute: Hashable {
  case detail
  case compose(RielaNoteCreationDestination)
}
