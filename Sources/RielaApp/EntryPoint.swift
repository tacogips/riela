#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport
import RielaObservability
import RielaServer

@main
@MainActor
final class RielaApp: NSObject, NSApplicationDelegate {
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let controller = WorkflowServingController()
  private var daemonDiscovery = RielaAppDaemonWorkflowDiscovery()
  private let daemonRuntime = RielaAppDaemonWorkflowRuntime()
  private let telemetry = RielaTelemetryFactory.make(configuration: .fromEnvironment(
    surface: .app
  ))
  private let profileStore = RielaAppProfileStore()
  private var daemonStore = RielaAppDaemonWorkflowStore(profileName: .default)
  private let launchAtLogin = RielaLaunchAtLoginController()
  private let daemonStatusRefreshInterval: TimeInterval = 2
  private var selectedWorkflow: WorkflowServeSelection?
  private var selectedWorkingDirectory = FileManager.default.currentDirectoryPath
  private var selectedSessionStoreRoot: String?
  private var status = "Ready"
  private var daemonProfileName = RielaAppProfileName.default
  private var daemonState = RielaAppDaemonWorkflowState()
  private var daemonCandidates: [RielaAppDaemonWorkflowCandidate] = []
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
    daemonProfileName = initialDaemonProfileName()
    daemonDiscovery = RielaAppDaemonWorkflowDiscovery(projectRoot: commandLineProjectRoot())
    daemonStore = RielaAppDaemonWorkflowStore(profileName: daemonProfileName)
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
    openInitialViewerIfRequested()
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
    menu.addItem(menuItem(
      "Start Enabled Workflows",
      action: #selector(startProfileWorkflows),
      enabled: hasStartableProfileWorkflows
    ))
    menu.addItem(menuItem(
      "Stop Workflows in Profile",
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
        onRemoveDirectory: { [weak self] identity in
          self?.removeDaemonWorkflowDirectory(identity: identity)
        },
        onSetEnabled: { [weak self] identity, enabled in
          self?.setDaemonWorkflow(identity: identity, available: enabled)
        },
        onSetActive: { [weak self] identity, active in
          self?.setDaemonWorkflowActive(identity: identity, active: active)
        }
      )
    }
    refreshDaemonWorkflowWindow()
    daemonWindowController?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
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
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let optionIndex = arguments.firstIndex(of: "--open-viewer"),
      arguments.indices.contains(optionIndex + 1)
    else {
      return
    }
    let path = arguments[optionIndex + 1]
    selectedWorkflow = .directDirectory(path, identifier: URL(fileURLWithPath: path, isDirectory: true).lastPathComponent)
    selectedWorkingDirectory = URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent().path
    if let sessionStoreOptionIndex = arguments.firstIndex(of: "--session-store-root"),
      arguments.indices.contains(sessionStoreOptionIndex + 1) {
      selectedSessionStoreRoot = arguments[sessionStoreOptionIndex + 1]
    }
    status = "Selected"
    rebuildMenu()
    openViewer()
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
    !CommandLine.arguments.dropFirst().contains("--no-autostart-daemons")
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
      await daemonRuntime.start(candidate)
      let snapshot = daemonRuntime.snapshot(for: candidate.id)
      logDaemon("start candidate=\(candidate.id) status=\(snapshot.status.rawValue) detail=\(snapshot.detail)")
    }
  }

  @objc private func startProfileWorkflows() {
    for candidate in daemonCandidates where daemonState.preference(for: candidate.id).available {
      var preference = daemonState.preference(for: candidate.id)
      preference.active = true
      daemonState.preferences[candidate.id] = preference
    }
    saveDaemonState()
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      await startEnabledDaemonWorkflows()
      status = "Started profile workflows"
      refreshDaemonWorkflowWindow()
    }
  }

  @objc private func stopProfileWorkflows() {
    let candidates = daemonCandidates
    for candidate in candidates {
      var preference = daemonState.preference(for: candidate.id)
      preference.active = false
      daemonState.preferences[candidate.id] = preference
    }
    saveDaemonState()
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      for candidate in candidates {
        await daemonRuntime.stop(identity: candidate.id)
      }
      status = "Stopped profile workflows"
      refreshDaemonWorkflowWindow()
    }
  }

  private func refreshDaemonWorkflowWindow() {
    daemonCandidates = discoverDaemonCandidates()
    daemonWindowController?.update(
      profileName: daemonProfileName,
      profileNames: availableDaemonProfileNames(),
      candidates: daemonCandidates,
      state: daemonState,
      snapshots: Dictionary(uniqueKeysWithValues: daemonCandidates.map { candidate in
        (candidate.id, daemonRuntime.snapshot(for: candidate.id))
      })
    )
    rebuildMenu()
  }

  private func switchDaemonProfile(to rawProfileName: String) {
    let profileName = RielaAppProfileName(rawProfileName)
    guard profileName != daemonProfileName else {
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      let previousCandidates = daemonCandidates
      for candidate in previousCandidates {
        await daemonRuntime.stop(identity: candidate.id)
      }
      daemonProfileName = profileName
      daemonStore = RielaAppDaemonWorkflowStore(profileName: profileName)
      daemonState = daemonStore.load()
      do {
        try profileStore.saveActiveProfileName(profileName)
        status = "Profile: \(profileName.rawValue)"
      } catch {
        status = "Failed to save profile: \(error.localizedDescription)"
      }
      refreshDaemonWorkflowWindow()
      await startEnabledDaemonWorkflows()
      refreshDaemonWorkflowWindow()
    }
  }

  private func availableDaemonProfileNames() -> [RielaAppProfileName] {
    profileStore.listProfileNames(including: daemonProfileName)
  }

  private func addDaemonWorkflowDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Workflow or Package to RielaApp"
    panel.message = "Select a workflow folder, package folder, .rielapkg, or .zip package."
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    let candidate: RielaAppDaemonWorkflowCandidate
    do {
      candidate = try installDaemonWorkflowOrPackageSource(url)
    } catch {
      status = "Failed to add workflow: \(error.localizedDescription)"
      rebuildMenu()
      return
    }
    startImportedCandidate(candidate)
  }

  private func installDaemonWorkflowOrPackageSource(_ url: URL) throws -> RielaAppDaemonWorkflowCandidate {
    let url = url.standardizedFileURL
    if isDirectory(url), FileManager.default.fileExists(atPath: url.appendingPathComponent("workflow.json").path) {
      let installedURL = try daemonWorkflowInstaller.installWorkflowDirectory(url)
      guard let candidate = daemonDiscovery.discoverAppWorkflowDirectory(installedURL.path) else {
        throw RielaAppManagedWorkflowInstallError.invalidWorkflowDirectory(installedURL.path)
      }
      return candidate
    }
    if isPackageSource(url) {
      let installedURL = try daemonPackageInstaller.installPackageSource(url)
      guard let candidate = daemonDiscovery.discoverAppPackageDirectory(installedURL.path) else {
        throw RielaAppManagedWorkflowInstallError.invalidPackageDirectory(installedURL.path)
      }
      return candidate
    }
    throw RielaAppManagedWorkflowInstallError.unsupportedPackageSource(url.path)
  }

  private func isPackageSource(_ url: URL) -> Bool {
    if isDirectory(url) {
      return FileManager.default.fileExists(atPath: url.appendingPathComponent("riela-package.json").path)
    }
    let pathExtension = url.pathExtension.lowercased()
    return pathExtension == "rielapkg" || pathExtension == "zip"
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }

  private func startImportedCandidate(_ candidate: RielaAppDaemonWorkflowCandidate) {
    daemonState.preferences[candidate.id] = RielaAppDaemonWorkflowPreference(
      identity: candidate.id,
      available: true,
      active: true
    )
    saveDaemonState()
    refreshDaemonWorkflowWindow()
    Task { @MainActor in
      await daemonRuntime.start(candidate)
      refreshDaemonWorkflowWindow()
    }
  }

  private func addDaemonProjectDirectory() {
    let panel = NSOpenPanel()
    panel.title = "Add Riela Project to Profile"
    panel.message = "Select a project folder containing .riela/workflows or .riela/packages."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else {
      return
    }
    let projectRoot = url.standardizedFileURL
    guard isRielaWorkflowProject(projectRoot) else {
      status = "Selected folder has no .riela/workflows or .riela/packages"
      rebuildMenu()
      return
    }
    daemonState.addProjectDirectory(projectRoot.path)
    saveDaemonState()
    refreshDaemonWorkflowWindow()
  }

  private func removeDaemonWorkflowDirectory(identity: String) {
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      return
    }
    let candidateURL = URL(fileURLWithPath: candidate.workflowDirectory, isDirectory: true)
    if let packageDirectory = candidate.packageDirectory,
      daemonPackageInstaller.containsInstalledPackageDirectory(URL(fileURLWithPath: packageDirectory, isDirectory: true)) {
      do {
        try daemonPackageInstaller.removeInstalledPackageDirectory(URL(fileURLWithPath: packageDirectory, isDirectory: true))
      } catch {
        status = "Failed to remove package: \(error.localizedDescription)"
        rebuildMenu()
        return
      }
    } else if daemonWorkflowInstaller.containsInstalledWorkflowDirectory(candidateURL) {
      do {
        try daemonWorkflowInstaller.removeInstalledWorkflowDirectory(candidateURL)
      } catch {
        status = "Failed to remove workflow: \(error.localizedDescription)"
        rebuildMenu()
        return
      }
    } else if let projectDirectory = daemonState.projectDirectory(containing: candidate.workflowDirectory) {
      daemonState.removeProjectDirectory(projectDirectory)
    } else if daemonState.containsWorkflowDirectory(candidate.workflowDirectory) {
      daemonState.removeWorkflowDirectory(candidate.workflowDirectory)
    } else {
      status = "Only RielaApp workflows and profile project workflows can be removed"
      rebuildMenu()
      return
    }
    daemonState.preferences.removeValue(forKey: identity)
    saveDaemonState()
    Task { @MainActor in
      await daemonRuntime.stop(identity: identity)
      refreshDaemonWorkflowWindow()
    }
  }

  private func setDaemonWorkflow(identity: String, available: Bool) {
    updateDaemonPreference(identity: identity) { preference in
      preference.available = available
      preference.active = available
    }
    if available, let candidate = daemonCandidates.first(where: { $0.id == identity }) {
      Task { @MainActor in
        await daemonRuntime.start(candidate)
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
    updateDaemonPreference(identity: identity) { preference in
      preference.active = active
    }
    guard let candidate = daemonCandidates.first(where: { $0.id == identity }) else {
      refreshDaemonWorkflowWindow()
      return
    }
    Task { @MainActor in
      if active {
        await daemonRuntime.start(candidate)
        status = "Started \(candidate.displayName)"
      } else {
        await daemonRuntime.stop(identity: identity)
        status = "Stopped \(candidate.displayName)"
      }
      refreshDaemonWorkflowWindow()
    }
  }

  private func updateDaemonPreference(
    identity: String,
    mutate: (inout RielaAppDaemonWorkflowPreference) -> Void
  ) {
    var preference = daemonState.preference(for: identity)
    mutate(&preference)
    daemonState.preferences[identity] = preference
    saveDaemonState()
    refreshDaemonWorkflowWindow()
  }

  private func saveDaemonState() {
    do {
      try daemonStore.save(daemonState)
    } catch {
      status = "Failed to save startup workflow state: \(error)"
    }
  }

  private var daemonWorkflowInstaller: RielaAppManagedWorkflowInstaller {
    RielaAppManagedWorkflowInstaller(workflowRoot: daemonAppWorkflowRoot)
  }

  private var daemonPackageInstaller: RielaAppManagedPackageInstaller {
    RielaAppManagedPackageInstaller(packageRoot: daemonAppPackageRoot)
  }

  private var daemonAppWorkflowRoot: URL {
    RielaAppProfileStore.defaultWorkflowRootURL(profileName: daemonProfileName)
  }

  private var daemonAppPackageRoot: URL {
    RielaAppProfileStore.defaultPackageRootURL(profileName: daemonProfileName)
  }

  private func discoverDaemonCandidates() -> [RielaAppDaemonWorkflowCandidate] {
    daemonDiscovery.discoverUserDaemonWorkflows(
      appWorkflowRoot: daemonAppWorkflowRoot,
      appPackageRoot: daemonAppPackageRoot,
      projectDirectories: daemonState.projectDirectories,
      additionalWorkflowDirectories: daemonState.workflowDirectories
    )
  }

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
    commandLineDaemonProfileName() ?? profileStore.loadActiveProfileName()
  }

  private func commandLineDaemonProfileName() -> RielaAppProfileName? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    for (index, argument) in arguments.enumerated() {
      if argument == "--profile", arguments.indices.contains(index + 1) {
        return RielaAppProfileName(arguments[index + 1])
      }
      if argument.hasPrefix("--profile=") {
        return RielaAppProfileName(String(argument.dropFirst("--profile=".count)))
      }
    }
    return nil
  }

  private func commandLineProjectRoot() -> URL? {
    let arguments = Array(CommandLine.arguments.dropFirst())
    for (index, argument) in arguments.enumerated() {
      if argument == "--project-root", arguments.indices.contains(index + 1) {
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL
      }
      if argument.hasPrefix("--project-root=") {
        return URL(
          fileURLWithPath: String(argument.dropFirst("--project-root=".count)),
          isDirectory: true
        ).standardizedFileURL
      }
    }
    return nil
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
