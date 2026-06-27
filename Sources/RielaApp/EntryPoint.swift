#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport
import RielaObservability
import RielaServer
import UniformTypeIdentifiers

@main
@MainActor
final class RielaApp: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let controller = WorkflowServingController()
  private let launchOptions = RielaAppLaunchOptions.current()
  private var daemonDiscovery = RielaAppDaemonWorkflowDiscovery()
  private let daemonRuntime = RielaAppDaemonWorkflowRuntime()
  private let telemetry = RielaTelemetryFactory.make(configuration: .fromEnvironment(
    surface: .app
  ))
  private var profileStore = RielaAppProfileStore()
  private var daemonStore = RielaAppDaemonWorkflowStore(profileName: .default)
  private let launchAtLogin = RielaLaunchAtLoginController()
  private let daemonStatusRefreshInterval: TimeInterval = 2
  private var selectedWorkflow: WorkflowServeSelection?
  private var selectedWorkingDirectory = FileManager.default.currentDirectoryPath
  private var selectedSessionStoreRoot: String?
  var status = "Ready"
  private var daemonProfileName = RielaAppProfileName.default
  var daemonState = RielaAppDaemonWorkflowState()
  var daemonCandidates: [RielaAppDaemonWorkflowCandidate] = []
  var appHomeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  private var daemonStatusRefreshTimer: Timer?
  private var daemonWindowController: DaemonWorkflowWindowController?
  private var viewerWindowController: WorkflowViewerWindowController?

  static func main() {
    let app = NSApplication.shared
    let delegate = RielaApp()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    appHomeDirectory = configuredHomeDirectory()
    profileStore = RielaAppProfileStore(
      appRootURL: launchOptions.appRoot ?? RielaAppProfileStore.defaultAppRootURL(homeDirectory: appHomeDirectory)
    )
    daemonProfileName = initialDaemonProfileName()
    do {
      try prepareInitialDaemonProfile()
    } catch {
      status = "Failed to prepare profile: \(error.localizedDescription)"
    }
    daemonDiscovery = RielaAppDaemonWorkflowDiscovery(homeDirectory: appHomeDirectory, projectRoot: launchOptions.projectRoot)
    daemonStore = makeDaemonStore(profileName: daemonProfileName)
    daemonState = daemonStore.load()
    daemonCandidates = discoverDaemonCandidates()
    Task {
      await telemetry.recordLog(RielaTelemetryLog(
        name: "riela.app.start",
        attributes: [
          "runtime.surface": "app",
          "profile.name": daemonProfileName.rawValue,
          "workflow.count": String(daemonCandidates.count)
        ]
      ))
    }
    logDaemon("profile=\(daemonProfileName.rawValue) discovered \(daemonCandidates.count) user daemon workflow candidate(s)")
    configureStatusItem()
    rebuildMenu()
    startDaemonStatusRefreshTimer()
    importDaemonSourcesIfRequested()
    openInitialViewerIfRequested()
    openInitialWorkflowsIfRequested()
    if shouldAutostartDaemonWorkflows() {
      autostartDaemonWorkflows()
    } else {
      logDaemon("daemon workflow autostart disabled by command-line option")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    daemonStatusRefreshTimer?.invalidate()
    daemonStatusRefreshTimer = nil
    Task {
      await telemetry.flush(timeout: .seconds(2))
    }
  }

  private func configureStatusItem() {
    guard let button = statusItem.button else {
      return
    }
    button.image = RielaAppIcon.workflowTemplateImage()
    button.imagePosition = .imageOnly
    button.imageScaling = .scaleProportionallyDown
    button.toolTip = "Riela workflows"
    button.setAccessibilityLabel("Riela workflows")
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Workflows...", action: #selector(openDaemonWorkflows)))
    menu.addItem(menuItem("Open Profile Folder", action: #selector(openProfileFolder)))
    menu.addItem(menuItem(
      "Auto-Start Enabled Workflows",
      action: #selector(startProfileWorkflows),
      enabled: hasStartableProfileWorkflows
    ))
    menu.addItem(menuItem(
      "Stop and Disable Auto-Start",
      action: #selector(stopProfileWorkflows),
      enabled: hasRunningProfileWorkflows
    ))
    menu.addItem(.separator())
    let launchAtLoginItem = menuItem("Launch on Login", action: #selector(toggleLaunchAtLogin))
    launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
    menu.addItem(launchAtLoginItem)
    menu.addItem(NSMenuItem(title: "Launch on Login: \(launchAtLogin.statusDescription)", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Status: \(status)", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Profile: \(daemonProfileName.rawValue)", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Workflows: \(daemonSummary())", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem("Quit", action: #selector(quit)))
    statusItem.menu = menu
  }

  private var hasStartableProfileWorkflows: Bool {
    daemonCandidates.contains { candidate in
      let preference = daemonState.preference(for: candidate.id)
      return preference.available && !preference.active
    }
  }

  private var hasRunningProfileWorkflows: Bool {
    daemonCandidates.contains { candidate in
      let preference = daemonState.preference(for: candidate.id)
      return preference.available && preference.active
    }
  }

  private func menuItem(_ title: String, action: Selector, enabled: Bool = true) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = enabled
    return item
  }

  @objc private func selectWorkflow() {
    let panel = NSOpenPanel()
    panel.title = "Select Workflow to Serve"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    selectedWorkflow = .directDirectory(url.path, identifier: url.lastPathComponent)
    selectedWorkingDirectory = url.deletingLastPathComponent().path
    selectedSessionStoreRoot = nil
    status = "Selected"
    rebuildMenu()
  }

  @objc private func openDaemonWorkflows() {
    logDaemon("opening workflows window for profile=\(daemonProfileName.rawValue)")
    if daemonWindowController == nil {
      daemonWindowController = DaemonWorkflowWindowController(
        onRefresh: { [weak self] in
          self?.refreshDaemonWorkflowWindow()
        },
        onSelectProfile: { [weak self] profileName in
          self?.switchDaemonProfile(to: profileName)
        },
        onAddDirectory: { [weak self] in
          self?.addDaemonWorkflowDirectory()
        },
        onAddProject: { [weak self] in
          self?.addDaemonProjectDirectory()
        },
        onOpenProfileFolder: { [weak self] in
          self?.openProfileFolder()
        },
        onRevealSelectedSource: { [weak self] identity in
          self?.revealDaemonWorkflowSource(identity: identity)
        },
        onRemoveDirectory: { [weak self] identity in
          self?.removeDaemonWorkflowDirectory(identity: identity)
        },
        onSetEnabled: { [weak self] identity, enabled in
          self?.setDaemonWorkflow(identity: identity, available: enabled)
        },
        onSetActive: { [weak self] identity, active in
          self?.setDaemonWorkflowActive(identity: identity, active: active)
        },
        onSetEnvironment: { [weak self] identity in
          self?.setDaemonWorkflowEnvironment(identity: identity)
        },
        environmentSummary: { [weak self] candidate in
          self?.daemonEnvironmentSummary(for: candidate) ?? "unknown"
        },
        environmentColumnStatus: { [weak self] candidate in
          self?.daemonEnvironmentColumnStatus(for: candidate) ?? "Unknown"
        }
      )
    }
    refreshDaemonWorkflowWindow()
    daemonWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func importDaemonSourcesIfRequested() {
    let sources = launchOptions.importSources
    guard !sources.isEmpty else {
      return
    }
    importDaemonWorkflowOrPackageSources(
      sources,
      startsImmediately: launchOptions.autostartsDaemonWorkflows,
      startsImportedCandidates: false
    )
  }

  private func importDaemonWorkflowOrPackageSources(
    _ sources: [URL],
    startsImmediately: Bool,
    startsImportedCandidates: Bool = true
  ) {
    let previousState = daemonState
    var importedNames: [String] = []
    var updatedNames: [String] = []
    var autostartOffNames: [String] = []
    var failures: [String] = []
    var importedCandidates: [RielaAppDaemonWorkflowCandidate] = []
    for source in sources {
      do {
        let importResult = try installDaemonWorkflowOrPackageSource(source)
        let candidate = importResult.candidate
        importedCandidates.append(candidate)
        if importResult.replacedExisting {
          updatedNames.append(candidate.displayName)
        } else {
          importedNames.append(candidate.displayName)
        }
        logDaemon("imported source=\(source.path) candidate=\(candidate.id) profile=\(daemonProfileName.rawValue)")
        let preference = RielaAppImportPreferencePolicy.preference(
          identity: candidate.id,
          existingPreference: daemonState.preferences[candidate.id],
          replacedExisting: importResult.replacedExisting,
          startsImmediately: startsImmediately
        )
        daemonState.preferences[candidate.id] = preference
        if !preference.active {
          autostartOffNames.append(candidate.displayName)
        }
      } catch {
        failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
        logDaemon("failed to import source=\(source.path) error=\(error.localizedDescription)")
      }
    }
    if !importedCandidates.isEmpty, !saveDaemonState() {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    let summary = RielaAppImportSummary(
      importedNames: importedNames,
      updatedNames: updatedNames,
      failures: failures,
      profileName: daemonProfileName,
      startsImmediately: startsImmediately,
      autostartOffNames: autostartOffNames
    )
    if let statusMessage = summary.statusMessage {
      status = statusMessage
    }
    refreshDaemonWorkflowWindow()
    if let selectedCandidate = importedCandidates.last {
      daemonWindowController?.selectCandidate(identity: selectedCandidate.id)
    }
    guard startsImmediately, startsImportedCandidates, !importedCandidates.isEmpty else {
      return
    }
    let candidatesToStart = importedCandidates
      .filter { candidate in
        RielaAppImportPreferencePolicy.shouldStartAfterImport(
          preference: daemonState.preference(for: candidate.id),
          startsImportedCandidates: startsImportedCandidates
        )
      }
    let selectedIdentity = importedCandidates.last?.id
    guard !candidatesToStart.isEmpty else {
      return
    }
    Task { @MainActor in
      for candidate in candidatesToStart {
        await daemonRuntime.start(candidate, inheritedEnvironment: daemonEnvironment(for: candidate))
      }
      refreshDaemonWorkflowWindow()
      if let selectedIdentity {
        daemonWindowController?.selectCandidate(identity: selectedIdentity)
      }
    }
  }

  private func startDaemonStatusRefreshTimer() {
    daemonStatusRefreshTimer?.invalidate()
    let timer = Timer(timeInterval: daemonStatusRefreshInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.refreshDaemonWorkflowWindow()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    daemonStatusRefreshTimer = timer
  }

  @objc private func serveWorkflow() {
    guard let selectedWorkflow else {
      return
    }
    Task { @MainActor in
      do {
        let state = try await controller.start(WorkflowServeStartRequest(
          selection: selectedWorkflow,
          workingDirectory: selectedWorkingDirectory
        ))
        apply(state)
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func stopWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.stop())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func restartWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.restart())
      } catch {
        status = "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func updateWorkflow() {
    Task { @MainActor in
      do {
        apply(try await controller.reload(WorkflowServeReloadRequest()))
      } catch {
        let current = await controller.currentState()
        status = current.status == .running ? "Update failed, still running" : "Failed: \(error)"
        rebuildMenu()
      }
    }
  }

  @objc private func openViewer() {
    guard let path = selectedWorkflow?.path else {
      selectWorkflow()
      return
    }
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(workflowDirectory: path, sessionStoreRoot: selectedSessionStoreRoot)
  }

  private func openInitialViewerIfRequested() {
    guard let initialViewer = launchOptions.initialViewer else {
      return
    }
    let path = initialViewer.workflowPath
    selectedWorkflow = .directDirectory(path, identifier: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent)
    selectedWorkingDirectory = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent().path
    selectedSessionStoreRoot = initialViewer.sessionStoreRoot
    status = "Selected"
    rebuildMenu()
    DispatchQueue.main.async { [weak self] in
      self?.openViewer()
    }
  }

  private func openInitialWorkflowsIfRequested() {
    guard launchOptions.opensWorkflows else {
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.openDaemonWorkflows()
    }
  }

  @objc private func openProfileFolder() {
    let profileURL = daemonProfileRoot
    do {
      try profileStore.createProfileDirectories(daemonProfileName)
      NSWorkspace.shared.open(profileURL)
      status = "Opened profile folder: \(daemonProfileName.rawValue)"
    } catch {
      status = "Failed to open profile folder: \(error.localizedDescription)"
    }
    refreshDaemonWorkflowWindow()
  }

  private func revealDaemonWorkflowSource(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected workflow is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let sourceURL = URL(fileURLWithPath: candidate.packageDirectory ?? candidate.workflowDirectory, isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    status = "Revealed \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  @objc private func toggleLaunchAtLogin() {
    do {
      try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
      status = "Launch on Login: \(launchAtLogin.statusDescription)"
    } catch {
      status = "Failed to update Launch on Login: \(error.localizedDescription)"
    }
    rebuildMenu()
  }

  private func shouldAutostartDaemonWorkflows() -> Bool {
    launchOptions.autostartsDaemonWorkflows
  }

  private func autostartDaemonWorkflows() {
    Task { @MainActor in
      await startEnabledDaemonWorkflows()
      refreshDaemonWorkflowWindow()
      rebuildMenu()
    }
  }

  private func startEnabledDaemonWorkflows() async {
    for candidate in daemonCandidates {
      let preference = daemonState.preference(for: candidate.id)
      logDaemon(
        "profile=\(daemonProfileName.rawValue) candidate=\(candidate.id) available=\(preference.available) active=\(preference.active)"
      )
      guard preference.available, preference.active else {
        continue
      }
      await daemonRuntime.start(candidate, inheritedEnvironment: daemonEnvironment(for: candidate))
      let snapshot = daemonRuntime.snapshot(for: candidate.id)
      logDaemon("start candidate=\(candidate.id) status=\(snapshot.status.rawValue) detail=\(snapshot.detail)")
    }
  }

  @objc private func startProfileWorkflows() {
    let previousState = daemonState
    for candidate in daemonCandidates where daemonState.preference(for: candidate.id).available {
      var preference = daemonState.preference(for: candidate.id)
      preference.active = true
      daemonState.preferences[candidate.id] = preference
    }
    guard saveDaemonState() else {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      await startEnabledDaemonWorkflows()
      status = "Auto-start enabled and started profile workflows"
      refreshDaemonWorkflowWindow()
    }
  }

  @objc private func stopProfileWorkflows() {
    let previousState = daemonState
    let candidates = daemonCandidates
    for candidate in candidates {
      var preference = daemonState.preference(for: candidate.id)
      preference.active = false
      daemonState.preferences[candidate.id] = preference
    }
    guard saveDaemonState() else {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      for candidate in candidates {
        await daemonRuntime.stop(identity: candidate.id)
      }
      status = "Auto-start disabled and stopped profile workflows"
      refreshDaemonWorkflowWindow()
    }
  }

  func refreshDaemonWorkflowWindow() {
    daemonCandidates = discoverDaemonCandidates()
    daemonWindowController?.update(
      profileName: daemonProfileName,
      profileNames: availableDaemonProfileNames(),
      candidates: daemonCandidates,
      state: daemonState,
      snapshots: Dictionary(uniqueKeysWithValues: daemonCandidates.map { candidate in
        (candidate.id, daemonRuntime.snapshot(for: candidate.id))
      }),
      statusMessage: status
    )
    rebuildMenu()
  }

  private func switchDaemonProfile(to rawProfileName: String) {
    let profileName = RielaAppProfileName(rawProfileName)
    guard profileName != daemonProfileName else {
      status = daemonProfileStatus(rawProfileName: rawProfileName, profileName: profileName)
      refreshDaemonWorkflowWindow()
      return
    }
    do {
      try profileStore.saveActiveProfileName(profileName)
    } catch {
      status = "Failed to save profile: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      let previousCandidates = daemonCandidates
      for candidate in previousCandidates {
        await daemonRuntime.stop(identity: candidate.id)
      }
      daemonProfileName = profileName
      daemonStore = makeDaemonStore(profileName: profileName)
      daemonState = daemonStore.load()
      status = daemonProfileStatus(rawProfileName: rawProfileName, profileName: profileName)
      refreshDaemonWorkflowWindow()
      if shouldAutostartDaemonWorkflows() {
        await startEnabledDaemonWorkflows()
      } else {
        logDaemon("profile switch autostart disabled by command-line option")
      }
      refreshDaemonWorkflowWindow()
    }
  }

  private func daemonProfileStatus(rawProfileName: String, profileName: RielaAppProfileName) -> String {
    RielaAppProfileSwitchSummary(
      rawProfileName: rawProfileName,
      profileName: profileName,
      autostartsDaemonWorkflows: launchOptions.autostartsDaemonWorkflows
    ).statusMessage
  }

  private func availableDaemonProfileNames() -> [RielaAppProfileName] {
    profileStore.listProfileNames(including: daemonProfileName)
  }

  private func addDaemonWorkflowDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Workflow or Package to RielaApp"
    panel.message = "Select one or more workflow folders, package folders, .rielapkg files, or .zip packages."
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = packageImportContentTypes()
    guard panel.runModal() == .OK, !panel.urls.isEmpty else {
      return
    }
    importDaemonWorkflowOrPackageSources(panel.urls, startsImmediately: true)
  }

  private func installDaemonWorkflowOrPackageSource(_ url: URL) throws -> RielaAppDaemonImportResult {
    let url = url.standardizedFileURL
    switch RielaAppImportSourceClassifier.kind(for: url) {
    case .packageSource:
      let installResult = try daemonPackageInstaller.installPackageSourceResult(url)
      let installedURL = installResult.installedURL
      guard let candidate = daemonDiscovery.discoverAppPackageDirectory(installedURL.path) else {
        throw RielaAppManagedWorkflowInstallError.invalidPackageDirectory(installedURL.path)
      }
      return RielaAppDaemonImportResult(candidate: candidate, replacedExisting: installResult.replacedExisting)
    case .workflowDirectory:
      let installResult = try daemonWorkflowInstaller.installWorkflowDirectoryResult(url)
      let installedURL = installResult.installedURL
      guard let candidate = daemonDiscovery.discoverAppWorkflowDirectory(installedURL.path) else {
        throw RielaAppManagedWorkflowInstallError.invalidWorkflowDirectory(installedURL.path)
      }
      return RielaAppDaemonImportResult(candidate: candidate, replacedExisting: installResult.replacedExisting)
    case .unsupported:
      throw RielaAppManagedWorkflowInstallError.unsupportedPackageSource(url.path)
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func packageImportContentTypes() -> [UTType] {
    RielaAppManagedPackageInstaller.supportedPackageArchiveExtensions.compactMap {
      UTType(filenameExtension: $0)
    }
  }

  private func addDaemonProjectDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Riela Project to Profile"
    panel.message = "Select one or more project folders containing .riela/workflows or .riela/packages."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK, !panel.urls.isEmpty else {
      return
    }
    addDaemonProjectDirectories(panel.urls)
  }

  private func addDaemonProjectDirectories(_ urls: [URL]) {
    let previousState = daemonState
    var acceptedProjects: [(root: URL, alreadyAdded: Bool)] = []
    var failures: [String] = []
    for url in urls {
      let projectRoot = url.standardizedFileURL
      guard isRielaWorkflowProject(projectRoot) else {
        failures.append("\(projectRoot.lastPathComponent): folder has no .riela/workflows or .riela/packages")
        continue
      }
      let wasAlreadyAdded = daemonState.containsProjectDirectory(projectRoot.path)
      daemonState.addProjectDirectory(projectRoot.path)
      acceptedProjects.append((projectRoot, wasAlreadyAdded))
    }
    if !acceptedProjects.isEmpty, !saveDaemonState() {
      daemonState = previousState
      refreshDaemonWorkflowWindow()
      return
    }
    refreshDaemonWorkflowWindow()
    let projectResults = acceptedProjects.map { project in
      RielaAppProjectImportSummary.Project(
        name: project.root.lastPathComponent,
        workflowCount: daemonCandidates(in: project.root).count,
        alreadyAdded: project.alreadyAdded
      )
    }
    status = RielaAppProjectImportSummary(
      projects: projectResults,
      failures: failures,
      profileName: daemonProfileName
    ).statusMessage ?? status
    refreshDaemonWorkflowWindow()
    if let projectRoot = acceptedProjects.last?.root,
      let candidate = daemonCandidates(in: projectRoot).first {
      daemonWindowController?.selectCandidate(identity: candidate.id)
    }
  }

  private func daemonCandidates(in projectRoot: URL) -> [RielaAppDaemonWorkflowCandidate] {
    let projectRootPath = projectRoot.standardizedFileURL.path
    return daemonCandidates.filter { candidate in
      RielaAppDaemonWorkflowState.path(candidate.workflowDirectory, isContainedIn: projectRootPath)
    }
  }

  private func removeDaemonWorkflowDirectory(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      return
    }
    let previousState = daemonState
    let candidateURL = URL(fileURLWithPath: candidate.workflowDirectory, isDirectory: true)
    let removedDescription: String
    let canRollbackStateOnlyRemoval: Bool
    if let packageDirectory = candidate.packageDirectory,
      daemonPackageInstaller.containsInstalledPackageDirectory(URL(fileURLWithPath: packageDirectory, isDirectory: true)) {
      do {
        try daemonPackageInstaller.removeInstalledPackageDirectory(URL(fileURLWithPath: packageDirectory, isDirectory: true))
        removedDescription = "package \(candidate.displayName)"
        canRollbackStateOnlyRemoval = false
      } catch {
        status = "Failed to remove package: \(error.localizedDescription)"
        refreshDaemonWorkflowWindow()
        return
      }
    } else if daemonWorkflowInstaller.containsInstalledWorkflowDirectory(candidateURL) {
      do {
        try daemonWorkflowInstaller.removeInstalledWorkflowDirectory(candidateURL)
        removedDescription = "workflow \(candidate.displayName)"
        canRollbackStateOnlyRemoval = false
      } catch {
        status = "Failed to remove workflow: \(error.localizedDescription)"
        refreshDaemonWorkflowWindow()
        return
      }
    } else if let projectDirectory = daemonState.projectDirectory(containing: candidate.workflowDirectory) {
      daemonState.removeProjectDirectory(projectDirectory)
      removedDescription = "project \(URL(fileURLWithPath: projectDirectory, isDirectory: true).lastPathComponent)"
      canRollbackStateOnlyRemoval = true
    } else if daemonState.containsWorkflowDirectory(candidate.workflowDirectory) {
      daemonState.removeWorkflowDirectory(candidate.workflowDirectory)
      removedDescription = "selected workflow \(candidate.displayName)"
      canRollbackStateOnlyRemoval = true
    } else {
      status = "Only RielaApp imports and profile project workflows can be removed"
      refreshDaemonWorkflowWindow()
      return
    }
    daemonState.preferences.removeValue(forKey: identity)
    status = "Removed \(removedDescription) from profile \(daemonProfileName.rawValue)"
    guard saveDaemonState() else {
      if canRollbackStateOnlyRemoval {
        daemonState = previousState
      }
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      refreshDaemonWorkflowWindow()
    }
  }

  private func setDaemonWorkflow(identity: String, available: Bool) {
    let candidateName = daemonCandidates.first(where: { $0.id == identity })?.displayName ?? identity
    let didSave = updateDaemonPreference(identity: identity) { preference in
      preference.available = available
      preference.active = available
    }
    guard didSave else {
      return
    }
    status = available
      ? "Enabled \(candidateName) in profile \(daemonProfileName.rawValue)"
      : "Disabled \(candidateName) in profile \(daemonProfileName.rawValue)"
    rebuildMenu()
    if available, let candidate = daemonCandidates.first(where: { $0.id == identity }) {
      Task { @MainActor in
        await daemonRuntime.start(candidate, inheritedEnvironment: daemonEnvironment(for: candidate))
        refreshDaemonWorkflowWindow()
      }
    } else {
      Task { @MainActor in
        await daemonRuntime.stop(identity: identity)
        refreshDaemonWorkflowWindow()
      }
    }
  }

  private func setDaemonWorkflowActive(identity: String, active: Bool) {
    if active, !daemonState.preference(for: identity).available {
      status = "Enable workflow before starting"
      refreshDaemonWorkflowWindow()
      return
    }
    guard updateDaemonPreference(identity: identity, mutate: { preference in
      preference.active = active
    }) else {
      return
    }
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      if active {
        await daemonRuntime.start(candidate, inheritedEnvironment: daemonEnvironment(for: candidate))
        status = "Auto-start enabled and started \(candidate.displayName)"
      } else {
        await daemonRuntime.stop(identity: identity)
        status = "Auto-start disabled and stopped \(candidate.displayName)"
      }
      refreshDaemonWorkflowWindow()
    }
  }

  func updateDaemonPreference(
    identity: String,
    mutate: (inout RielaAppDaemonWorkflowPreference) -> Void
  ) -> Bool {
    let previousPreference = daemonState.preferences[identity]
    var preference = daemonState.preference(for: identity)
    mutate(&preference)
    daemonState.preferences[identity] = preference
    let didSave = saveDaemonState()
    if !didSave {
      if let previousPreference {
        daemonState.preferences[identity] = previousPreference
      } else {
        daemonState.preferences.removeValue(forKey: identity)
      }
    }
    refreshDaemonWorkflowWindow()
    return didSave
  }

  @discardableResult
  private func saveDaemonState() -> Bool {
    do {
      try daemonStore.save(daemonState)
      return true
    } catch {
      status = "Failed to save workflow profile state: \(error.localizedDescription)"
      return false
    }
  }

  private var daemonWorkflowInstaller: RielaAppManagedWorkflowInstaller {
    RielaAppManagedWorkflowInstaller(workflowRoot: daemonAppWorkflowRoot)
  }

  private var daemonPackageInstaller: RielaAppManagedPackageInstaller {
    RielaAppManagedPackageInstaller(packageRoot: daemonAppPackageRoot)
  }

  private var daemonAppWorkflowRoot: URL {
    RielaAppProfileStore.workflowRootURL(appRootURL: profileStore.appRootURL, profileName: daemonProfileName)
  }

  private var daemonAppPackageRoot: URL {
    RielaAppProfileStore.packageRootURL(appRootURL: profileStore.appRootURL, profileName: daemonProfileName)
  }

  private var daemonProfileRoot: URL {
    RielaAppProfileStore.profilesRootURL(appRootURL: profileStore.appRootURL)
      .appendingPathComponent(daemonProfileName.rawValue, isDirectory: true)
  }

  private func discoverDaemonCandidates() -> [RielaAppDaemonWorkflowCandidate] {
    daemonDiscovery.discoverUserDaemonWorkflows(
      appWorkflowRoot: daemonAppWorkflowRoot,
      appPackageRoot: daemonAppPackageRoot,
      projectDirectories: daemonState.projectDirectories,
      additionalWorkflowDirectories: daemonState.workflowDirectories
    )
  }
}

private struct RielaAppDaemonImportResult {
  var candidate: RielaAppDaemonWorkflowCandidate
  var replacedExisting: Bool
}

private extension RielaApp {
  private func isRielaWorkflowProject(_ projectRoot: URL) -> Bool {
    let workflowRoot = projectRoot.appendingPathComponent(".riela/workflows", isDirectory: true)
    let packageRoot = projectRoot.appendingPathComponent(".riela/packages", isDirectory: true)
    return FileManager.default.fileExists(atPath: workflowRoot.path)
      || FileManager.default.fileExists(atPath: packageRoot.path)
  }

  private func daemonSummary() -> String {
    let enabled = daemonCandidates.filter { daemonState.preference(for: $0.id).available }.count
    let running = daemonCandidates.filter { candidate in
      let preference = daemonState.preference(for: candidate.id)
      return preference.available && preference.active
    }.count
    return "\(running) running / \(enabled) enabled"
  }

  private func initialDaemonProfileName() -> RielaAppProfileName {
    launchOptions.profileName ?? profileStore.loadActiveProfileName()
  }

  private func prepareInitialDaemonProfile() throws {
    try profileStore.prepareInitialProfile(daemonProfileName, persistsSelection: launchOptions.profileName != nil)
  }

  private func makeDaemonStore(profileName: RielaAppProfileName) -> RielaAppDaemonWorkflowStore {
    let stateURL = RielaAppProfileStore.profilesRootURL(appRootURL: profileStore.appRootURL)
      .appendingPathComponent(profileName.rawValue, isDirectory: true)
      .appendingPathComponent("daemon-workflows.json")
    let legacyStateURLs = profileStore.appRootURL == RielaAppProfileStore.defaultAppRootURL(homeDirectory: appHomeDirectory)
      ? RielaAppDaemonWorkflowStore.defaultLegacyStateURLs(homeDirectory: appHomeDirectory)
      : []
    return RielaAppDaemonWorkflowStore(
      stateURL: stateURL,
      legacyStateURLs: profileName == .default ? legacyStateURLs : [],
      profileName: profileName
    )
  }

  private func configuredHomeDirectory() -> URL {
    launchOptions.homeDirectory(defaultHome: NSHomeDirectory())
  }

  private func logDaemon(_ message: String) {
    let line = "[RielaApp daemon] \(message)\n"
    if let data = line.data(using: .utf8) {
      FileHandle.standardError.write(data)
    }
  }

  @objc private func quit() {
    NSApplication.shared.terminate(nil)
  }

  private func apply(_ state: WorkflowServeState) {
    switch state.status {
    case .running:
      status = "Running"
    case .stopped:
      status = "Stopped"
    case .starting:
      status = "Starting"
    case .reloading:
      status = "Updating"
    case .stopping:
      status = "Stopping"
    case .failed:
      status = state.diagnostics.first?.message ?? "Failed"
    }
    rebuildMenu()
  }
}

private enum RielaAppIcon {
  static func workflowTemplateImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()

    NSColor.black.setStroke()
    let edgePath = NSBezierPath()
    edgePath.lineWidth = 1.8
    edgePath.lineCapStyle = .round
    edgePath.lineJoinStyle = .round
    edgePath.move(to: NSPoint(x: 5, y: 9))
    edgePath.line(to: NSPoint(x: 9, y: 13))
    edgePath.line(to: NSPoint(x: 13, y: 13))
    edgePath.move(to: NSPoint(x: 5, y: 9))
    edgePath.line(to: NSPoint(x: 9, y: 5))
    edgePath.line(to: NSPoint(x: 13, y: 5))
    edgePath.stroke()

    NSColor.black.setFill()
    for center in [
      NSPoint(x: 5, y: 9),
      NSPoint(x: 13, y: 13),
      NSPoint(x: 13, y: 5)
    ] {
      NSBezierPath(ovalIn: NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)).fill()
    }

    image.unlockFocus()
    image.isTemplate = true
    return image
  }
}

#else
@main
struct RielaAppUnsupported {
  static func main() {
    print("RielaApp is available on macOS only.")
  }
}
#endif
