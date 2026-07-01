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
  let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let controller = WorkflowServingController()
  private let launchOptions = RielaAppLaunchOptions.current()
  private var daemonDiscovery = RielaAppDaemonWorkflowDiscovery()
  let daemonRuntime = RielaAppDaemonWorkflowRuntime()
  private let telemetry = RielaTelemetryFactory.make(configuration: .fromEnvironment(surface: .app))
  private var profileStore = RielaAppProfileStore()
  private var daemonStore = RielaAppDaemonWorkflowStore(profileName: .default)
  let launchAtLogin = RielaLaunchAtLoginController()
  private let daemonStatusRefreshInterval: TimeInterval = 2
  var selectedWorkflow: WorkflowServeSelection?
  var selectedWorkingDirectory = FileManager.default.currentDirectoryPath
  var selectedSessionStoreRoot: String?
  var status = "Ready"
  var daemonProfileName = RielaAppProfileName.default
  var daemonState = RielaAppDaemonWorkflowState()
  var daemonInstances: [WorkflowInstance] = []
  var daemonProfileInstances: [RielaAppProfiledWorkflowInstance] = []
  var daemonProfileStates: [RielaAppProfileName: RielaAppDaemonWorkflowState] = [:]
  var daemonProfileWorkflowSources: [RielaAppProfileName: [RielaAppDaemonWorkflowCandidate]] = [:]
  var daemonCandidates: [RielaAppDaemonWorkflowCandidate] = []
  var daemonWorkflowSources: [RielaAppDaemonWorkflowCandidate] = []
  var appHomeDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
  private var daemonStatusRefreshTimer: Timer?
  var daemonWindowController: DaemonWorkflowWindowController?
  var viewerWindowController: WorkflowViewerWindowController?

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

  @objc func selectWorkflow() {
    let panel = NSOpenPanel()
    panel.title = "Choose Workflow to View"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    selectedWorkflow = .directDirectory(url.path, identifier: url.lastPathComponent)
    selectedWorkingDirectory = url.deletingLastPathComponent().path
    selectedSessionStoreRoot = nil
    status = "Workflow ready to view"
    rebuildMenu()
  }

  @objc func openDaemonInstances() {
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
          self?.addDaemonWorkflowSourceOnlyDirectory()
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
        onRelinkInstance: { [weak self] identity, sourceIdentity in
          self?.relinkDaemonWorkflowInstance(identity: identity, sourceIdentity: sourceIdentity)
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
        onSetWorkingDirectory: { [weak self] identity in
          self?.setDaemonWorkflowWorkingDirectory(identity: identity)
        },
        onSaveEnvironmentVariables: { [weak self] identity, text in
          self?.saveDaemonWorkflowEnvironmentVariables(identity: identity, text: text) ?? "RielaApp is not available"
        },
        onSaveWorkflowVariables: { [weak self] identity, text in
          self?.saveDaemonWorkflowDefaultVariables(identity: identity, text: text) ?? "RielaApp is not available"
        },
        onRegisterEventSource: { [weak self] identity, sourceJSON, bindingJSON in
          self?.registerDaemonWorkflowEventSource(
            identity: identity,
            sourceJSON: sourceJSON,
            bindingJSON: bindingJSON
          ) ?? "RielaApp is not available"
        },
        configuredEnvironmentValues: { [weak self] candidate in
          self?.daemonConfiguredEnvironmentValues(for: candidate) ?? []
        },
        onSaveAssistantAssistance: { [weak self] assistance in
          self?.saveAssistantAssistance(assistance) ?? "RielaApp is not available"
        },
        onSaveAssistantSettings: { [weak self] settings in
          self?.saveAssistantSettings(settings) ?? "RielaApp is not available"
        },
        onSubmitAssistantMessage: { [weak self] message, workingDirectory in
          self?.submitAssistantMessage(message, workingDirectory: workingDirectory)
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

  private func openInitialViewerIfRequested() {
    guard let initialViewer = launchOptions.initialViewer else {
      return
    }
    let path = initialViewer.workflowPath
    selectedWorkflow = .directDirectory(path, identifier: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent)
    selectedWorkingDirectory = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent().path
    selectedSessionStoreRoot = initialViewer.sessionStoreRoot
    status = "Workflow ready to view"
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

  @objc func toggleLaunchAtLogin() {
    do {
      try launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
      status = "Launch on Login \(launchAtLogin.statusDescription)"
    } catch {
      status = "Failed to update Launch on Login: \(error.localizedDescription)"
    }
    viewerWindowController?.updateAssistantPanel(settings: daemonState.assistant, profileName: daemonProfileName)
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
    refreshDaemonInstanceCache()
    for profiledInstance in daemonProfileInstances {
      let candidate = profiledInstance.runtimeCandidate
      let preference = profiledInstance.preference
      logDaemon(
        "profile=\(profiledInstance.profileName.rawValue) candidate=\(candidate.id) available=\(preference.available) active=\(preference.active)"
      )
      guard preference.available, preference.active else {
        continue
      }
      await daemonRuntime.start(
        candidate,
        configuration: daemonRuntimeConfiguration(for: candidate, preference: preference)
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
      profileInstances: daemonProfileInstances,
      state: daemonState,
      snapshots: Dictionary(uniqueKeysWithValues: Set(daemonProfileInstances.map(\.id)).union(daemonCandidates.map(\.id)).map {
        ($0, daemonRuntime.snapshot(for: $0))
      }),
      assistantAssistance: daemonState.assistant.assistance,
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

  private func addDaemonWorkflowSourceOnlyDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Workflow Source"
    panel.message = "Choose workflow folders, package folders, .rielapkg files, or .zip packages."
    panel.prompt = "Add"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = packageImportContentTypes()
    guard panel.runModal() == .OK, !panel.urls.isEmpty else {
      return
    }
    importDaemonWorkflowOrPackageSourcesOnly(panel.urls)
  }

  private func importDaemonWorkflowOrPackageSourcesOnly(_ sources: [URL]) {
    var importedNames: [String] = []
    var updatedNames: [String] = []
    var failures: [String] = []
    for source in sources {
      do {
        let importResult = try installDaemonWorkflowOrPackageSource(source)
        let candidate = importResult.candidate
        if importResult.replacedExisting {
          updatedNames.append(candidate.displayName)
        } else {
          importedNames.append(candidate.displayName)
        }
        logDaemon("added source=\(source.path) candidate=\(candidate.id) profile=\(daemonProfileName.rawValue)")
      } catch {
        failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
        logDaemon("failed to add source=\(source.path) error=\(error.localizedDescription)")
      }
    }
    let summaryParts = [
      importedNames.isEmpty ? nil : "Added \(importedNames.joined(separator: ", "))",
      updatedNames.isEmpty ? nil : "Updated \(updatedNames.joined(separator: ", "))",
      failures.isEmpty ? nil : "Failed \(failures.joined(separator: "; "))"
    ].compactMap { $0 }
    if !summaryParts.isEmpty {
      status = summaryParts.joined(separator: ". ")
    }
    refreshDaemonWorkflowWindow()
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
    panel.title = "Add Project Source"
    panel.message = "Choose project folders containing .riela/workflows or .riela/packages."
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
    daemonAppWorkflowRoot(profileName: daemonProfileName)
  }

  private var daemonAppPackageRoot: URL {
    daemonAppPackageRoot(profileName: daemonProfileName)
  }

  private func refreshDaemonInstanceCache() {
    let profileNames = availableDaemonProfileNames()
    daemonProfileStates = [:]
    daemonProfileWorkflowSources = [:]
    daemonProfileInstances = []
    for profileName in profileNames {
      let state = profileName == daemonProfileName ? daemonState : makeDaemonStore(profileName: profileName).load()
      let sources = daemonWorkflowSources(profileName: profileName, state: state)
      let instances = state.workflowInstances(from: sources)
      daemonProfileStates[profileName] = state
      daemonProfileWorkflowSources[profileName] = sources
      daemonProfileInstances.append(contentsOf: instances.filter(\.isConfigured).map {
        RielaAppProfiledWorkflowInstance(profileName: profileName, instance: $0)
      })
      guard profileName == daemonProfileName else {
        continue
      }
      daemonWorkflowSources = sources
      daemonInstances = instances
      daemonCandidates = instances.map(\.candidate)
    }
  }

  func daemonWorkflowSources(
    profileName: RielaAppProfileName,
    state: RielaAppDaemonWorkflowState
  ) -> [RielaAppDaemonWorkflowCandidate] {
    daemonDiscovery.discoverUserDaemonWorkflows(
      appWorkflowRoot: daemonAppWorkflowRoot(profileName: profileName),
      appPackageRoot: daemonAppPackageRoot(profileName: profileName),
      projectDirectories: state.projectDirectories,
      additionalWorkflowDirectories: state.workflowDirectories
    )
  }

  private func daemonAppWorkflowRoot(profileName: RielaAppProfileName) -> URL {
    RielaAppProfileStore.workflowRootURL(appRootURL: profileStore.appRootURL, profileName: profileName)
  }

  private func daemonAppPackageRoot(profileName: RielaAppProfileName) -> URL {
    RielaAppProfileStore.packageRootURL(appRootURL: profileStore.appRootURL, profileName: profileName)
  }
}

extension RielaApp {
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

  func makeDaemonStore(profileName: RielaAppProfileName) -> RielaAppDaemonWorkflowStore {
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

  @objc func quit() {
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
