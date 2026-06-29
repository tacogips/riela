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
  let daemonRuntime = RielaAppDaemonWorkflowRuntime()
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
  var daemonInstances: [WorkflowInstance] = []
  var daemonCandidates: [RielaAppDaemonWorkflowCandidate] = []
  var daemonWorkflowSources: [RielaAppDaemonWorkflowCandidate] = []
  var appHomeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  private var daemonStatusRefreshTimer: Timer?
  var daemonWindowController: DaemonWorkflowWindowController?
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
    refreshDaemonInstanceCache()
    Task {
      await telemetry.recordLog(RielaTelemetryLog(
        name: "riela.app.start",
        attributes: [
          "runtime.surface": "app",
          "profile.name": daemonProfileName.rawValue,
          "workflow.count": String(daemonInstances.count)
        ]
      ))
    }
    logDaemon("profile=\(daemonProfileName.rawValue) discovered \(daemonInstances.count) workflow instance(s)")
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
    button.toolTip = "Riela workflow instances"
    button.setAccessibilityLabel("Riela workflow instances")
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.addItem(menuItem("Instances...", action: #selector(openDaemonInstances)))
    let launchAtLoginItem = menuItem("Launch on Login", action: #selector(toggleLaunchAtLogin))
    launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
    menu.addItem(launchAtLoginItem)
    menu.addItem(NSMenuItem(title: "Launch on Login: \(launchAtLogin.statusDescription)", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(NSMenuItem(title: "Status: \(status)", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Profile: \(daemonProfileName.rawValue)", action: nil, keyEquivalent: ""))
    menu.addItem(NSMenuItem(title: "Instances: \(daemonSummary())", action: nil, keyEquivalent: ""))
    menu.addItem(.separator())
    menu.addItem(menuItem("Quit", action: #selector(quit)))
    statusItem.menu = menu
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

  @objc private func openDaemonInstances() {
    logDaemon("opening instances window for profile=\(daemonProfileName.rawValue)")
    if daemonWindowController == nil {
      daemonWindowController = DaemonWorkflowWindowController(
        onRefresh: { [weak self] in
          self?.refreshDaemonWorkflowWindow()
        },
        onSelectProfile: { [weak self] profileName in
          self?.switchDaemonProfile(to: profileName)
        },
        onCreateProfile: { [weak self] profileName in
          self?.createDaemonProfile(rawProfileName: profileName)
        },
        onRemoveProfile: { [weak self] profileName in
          self?.removeDaemonProfile(profileName) ?? false
        },
        onAddDirectory: { [weak self] in
          self?.addDaemonWorkflowDirectory()
        },
        onAddProject: { [weak self] in
          self?.addDaemonProjectDirectory()
        },
        onAddInstance: { [weak self] request in
          self?.addDaemonWorkflowInstance(request)
        },
        onRevealSelectedSource: { [weak self] identity in
          self?.revealDaemonWorkflowSource(identity: identity)
        },
        onDuplicateWorkflow: { [weak self] identity in
          self?.duplicateDaemonWorkflowInstance(identity: identity)
        },
        onRenameWorkflow: { [weak self] identity in
          self?.renameDaemonWorkflowInstance(identity: identity)
        },
        onRemoveInstance: { [weak self] identity in
          self?.removeDaemonWorkflowInstance(identity: identity)
        },
        onStartInstance: { [weak self] identity in
          self?.startDaemonWorkflowInstance(identity: identity)
        },
        onStopInstance: { [weak self] identity in
          self?.stopDaemonWorkflowInstance(identity: identity)
        },
        onRestartInstance: { [weak self] identity in
          self?.restartDaemonWorkflowInstance(identity: identity)
        },
        onSetEnvironment: { [weak self] identity in
          self?.setDaemonWorkflowEnvironment(identity: identity)
        },
        onSetEnvironmentVariables: { [weak self] identity in
          self?.setDaemonWorkflowEnvironmentVariables(identity: identity)
        },
        onSetWorkingDirectory: { [weak self] identity in
          self?.setDaemonWorkflowWorkingDirectory(identity: identity)
        },
        onSetVariables: { [weak self] identity in
          self?.setDaemonWorkflowDefaultVariables(identity: identity)
        },
        environmentSummary: { [weak self] candidate in
          self?.daemonEnvironmentSummary(for: candidate) ?? "unknown"
        },
        environmentColumnStatus: { [weak self] candidate in
          self?.daemonEnvironmentColumnStatus(for: candidate) ?? "Unknown"
        },
        onWindowWillClose: { [weak self] in
          self?.restoreAccessoryActivationPolicyIfNoAppWindows()
        }
      )
    }
    refreshDaemonWorkflowWindow()
    promoteToRegularApplication()
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
        await daemonRuntime.start(
          candidate,
          configuration: daemonRuntimeConfiguration(for: candidate)
        )
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
      self?.openDaemonInstances()
    }
  }

  private func promoteToRegularApplication() {
    NSApp.setActivationPolicy(.regular)
  }

  private func restoreAccessoryActivationPolicyIfNoAppWindows() {
    guard daemonWindowController?.window?.isVisible != true,
      viewerWindowController?.window?.isVisible != true
    else {
      return
    }
    NSApp.setActivationPolicy(.accessory)
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
    for instance in daemonInstances {
      let candidate = instance.candidate
      let preference = instance.preference
      logDaemon(
        "profile=\(daemonProfileName.rawValue) candidate=\(candidate.id) available=\(preference.available) active=\(preference.active)"
      )
      guard preference.available, preference.active else {
        continue
      }
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate)
      )
      let snapshot = daemonRuntime.snapshot(for: candidate.id)
      logDaemon("start candidate=\(candidate.id) status=\(snapshot.status.rawValue) detail=\(snapshot.detail)")
    }
  }

  func refreshDaemonWorkflowWindow() {
    refreshDaemonInstanceCache()
    daemonWindowController?.update(
      profileName: daemonProfileName,
      profileNames: availableDaemonProfileNames(),
      candidates: daemonCandidates,
      workflowSources: daemonWorkflowSources,
      state: daemonState,
      snapshots: Dictionary(uniqueKeysWithValues: Set(daemonCandidates.map(\.id)).union(daemonState.preferences.keys).map {
        ($0, daemonRuntime.snapshot(for: $0))
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

  private func createDaemonProfile(rawProfileName: String) -> RielaAppProfileName? {
    let profileName = RielaAppProfileName(rawProfileName)
    do {
      try profileStore.createProfileDirectories(profileName)
      status = profileName.rawValue == rawProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        ? "Added profile \(profileName.rawValue)"
        : "Added profile \(profileName.rawValue) (safe name)"
      refreshDaemonWorkflowWindow()
      return profileName
    } catch {
      status = "Failed to add profile: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
      return nil
    }
  }

  private func removeDaemonProfile(_ profileName: RielaAppProfileName) -> Bool {
    guard profileName != .default else {
      status = "Default profile cannot be removed"
      refreshDaemonWorkflowWindow()
      return false
    }
    guard profileName != daemonProfileName else {
      status = "Current profile cannot be removed"
      refreshDaemonWorkflowWindow()
      return false
    }
    do {
      try profileStore.removeProfile(profileName)
      status = "Removed profile \(profileName.rawValue)"
      refreshDaemonWorkflowWindow()
      return true
    } catch {
      status = "Failed to remove profile: \(error.localizedDescription)"
      refreshDaemonWorkflowWindow()
      return false
    }
  }

  private func addDaemonWorkflowDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Workflow or Package Source to RielaApp"
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
    return daemonInstances.compactMap { instance in
      let candidate = instance.candidate
      guard RielaAppDaemonWorkflowState.path(candidate.workflowDirectory, isContainedIn: projectRootPath) else {
        return nil
      }
      return candidate
    }
  }

  private func removeDaemonWorkflowDirectory(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      return
    }
    if candidate.isManagedInstance, candidate.id != candidate.sourceIdentity {
      daemonState.preferences.removeValue(forKey: identity)
      guard saveDaemonState() else {
        refreshDaemonWorkflowWindow()
        return
      }
      Task { @MainActor in
        await daemonRuntime.stop(identity: identity)
        status = "Removed instance \(identity)"
        refreshDaemonWorkflowWindow()
      }
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
        removedDescription = "workflow source \(candidate.displayName)"
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
      removedDescription = "selected workflow source \(candidate.displayName)"
      canRollbackStateOnlyRemoval = true
    } else {
      status = "Only RielaApp imports and profile project workflow sources can be removed"
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
  func saveDaemonState() -> Bool {
    do {
      try daemonStore.save(daemonState)
      return true
    } catch {
      status = "Failed to save instance profile state: \(error.localizedDescription)"
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

  private func refreshDaemonInstanceCache() {
    daemonWorkflowSources = daemonDiscovery.discoverUserDaemonWorkflows(
      appWorkflowRoot: daemonAppWorkflowRoot,
      appPackageRoot: daemonAppPackageRoot,
      projectDirectories: daemonState.projectDirectories,
      additionalWorkflowDirectories: daemonState.workflowDirectories
    )
    daemonInstances = daemonState.workflowInstances(from: daemonWorkflowSources)
    daemonCandidates = daemonInstances.map(\.candidate)
  }
}

private extension RielaApp {
  private func revealDaemonWorkflowSource(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    let sourceURL = URL(fileURLWithPath: candidate.packageDirectory ?? candidate.workflowDirectory, isDirectory: true)
    NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    status = "Revealed \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  private func openDaemonWorkflowViewer(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      status = "Selected instance is no longer available"
      refreshDaemonWorkflowWindow()
      return
    }
    if viewerWindowController == nil {
      viewerWindowController = WorkflowViewerWindowController()
    }
    viewerWindowController?.show(
      workflowDirectory: candidate.workflowDirectory,
      sessionStoreRoot: nil,
      currentDirectory: daemonState.preference(for: candidate.id).workingDirectory ?? candidate.workingDirectory,
      environmentVariablesSummary: "\(daemonState.preference(for: candidate.id).environmentVariables.count) inline",
      workflowVariablesSummary: "\(daemonState.preference(for: candidate.id).defaultVariables.count) values",
      nodePatches: daemonState.preference(for: candidate.id).nodePatches,
      onSaveNodePatch: { [weak self] nodeId, patch in
        self?.saveDaemonNodePatch(identity: identity, nodeId: nodeId, patch: patch) ?? false
      },
      onSetWorkingDirectory: { [weak self] in
        self?.setDaemonWorkflowWorkingDirectory(identity: identity)
        guard let self,
          let candidate = self.daemonCandidates.first(where: { $0.id == identity })
        else {
          return nil
        }
        return self.daemonState.preference(for: identity).workingDirectory ?? candidate.workingDirectory
      },
      onSetEnvironmentVariables: { [weak self] in
        self?.setDaemonWorkflowEnvironmentVariables(identity: identity)
        guard let self else {
          return nil
        }
        return "\(self.daemonState.preference(for: identity).environmentVariables.count) inline"
      },
      onSetWorkflowVariables: { [weak self] in
        self?.setDaemonWorkflowDefaultVariables(identity: identity)
        guard let self else {
          return nil
        }
        return "\(self.daemonState.preference(for: identity).defaultVariables.count) values"
      }
    )
    status = "Opened viewer: \(candidate.displayName)"
    refreshDaemonWorkflowWindow()
  }

  private func isRielaWorkflowProject(_ projectRoot: URL) -> Bool {
    let workflowRoot = projectRoot.appendingPathComponent(".riela/workflows", isDirectory: true)
    let packageRoot = projectRoot.appendingPathComponent(".riela/packages", isDirectory: true)
    return FileManager.default.fileExists(atPath: workflowRoot.path)
      || FileManager.default.fileExists(atPath: packageRoot.path)
  }

  private func daemonSummary() -> String {
    guard !daemonState.preferences.isEmpty else {
      return "none"
    }
    var counts: [String: Int] = [:]
    for (identity, preference) in daemonState.preferences {
      let sourceIdentity = preference.sourceIdentity ?? identity
      let hasSource = daemonCandidates.contains { $0.id == identity || $0.sourceIdentity == sourceIdentity }
        || daemonWorkflowSources.contains { $0.id == sourceIdentity || $0.sourceIdentity == sourceIdentity }
      let label: String
      if !hasSource {
        label = "needs source"
      } else {
        switch daemonRuntime.snapshot(for: identity).status {
        case .running:
          label = "running"
        case .starting:
          label = "starting"
        case .reloading:
          label = "reloading"
        case .stopping:
          label = "stopping"
        case .failed:
          label = "failed"
        case .stopped:
          label = "stopped"
        }
      }
      counts[label, default: 0] += 1
    }
    let order = ["failed", "needs source", "starting", "reloading", "stopping", "running", "stopped"]
    return order.compactMap { label in
      guard let count = counts[label] else {
        return nil
      }
      return "\(count) \(label)"
    }.joined(separator: " / ")
  }

  private func initialDaemonProfileName() -> RielaAppProfileName {
    launchOptions.profileName ?? profileStore.loadActiveProfileName()
  }

  private func prepareInitialDaemonProfile() throws {
    try profileStore.prepareInitialProfile(daemonProfileName, persistsSelection: launchOptions.profileName != nil)
    let bootstrapper = RielaAppDefaultProfileBootstrapper(
      profileStore: profileStore,
      daemonStore: makeDaemonStore(profileName: daemonProfileName),
      profileName: daemonProfileName
    )
    let result = try bootstrapper.bootstrapIfNeeded()
    if !result.installedPackageNames.isEmpty {
      status = "Added starter workflows to profile \(daemonProfileName.rawValue)"
    }
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

#else
@main
struct RielaAppUnsupported {
  static func main() {
    print("RielaApp is available on macOS only.")
  }
}
#endif
