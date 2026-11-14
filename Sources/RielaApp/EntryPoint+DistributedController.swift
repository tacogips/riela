#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaServer

extension RielaApp {
  var distributedControllerConfigurationURL: URL {
    if let path = ProcessInfo.processInfo.environment[DistributedControllerConfiguration.environmentKey], !path.isEmpty {
      return URL(fileURLWithPath: path)
    }
    return RielaAppProfileStore.profilesRootURL(appRootURL: profileStore.appRootURL)
      .appendingPathComponent(daemonProfileName.rawValue).appendingPathComponent("controller.json")
  }

  func distributedWorkflowEnvironment(_ base: [String: String]) -> [String: String] {
    var environment = base
    let url = distributedControllerConfigurationURL
    if FileManager.default.fileExists(atPath: url.path) {
      environment[DistributedControllerConfiguration.environmentKey] = url.path
    }
    return environment
  }

  func startDistributedController() async {
    await distributedControllerOperations.run { [self] in
      guard !terminationShutdownStarted else { return }
      await performDistributedControllerStart()
    }
  }

  func performDistributedControllerStart() async {
    guard distributedController == nil else { return }
    let configURL = distributedControllerConfigurationURL
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      distributedControllerStatus = "Workers: no controller configuration"
      rebuildMenu()
      return
    }
    distributedControllerGeneration += 1
    let generation = distributedControllerGeneration
    do {
      let environment = ProcessInfo.processInfo.environment
      let host = try DistributedControllerHost(
        configurationURL: configURL,
        environment: environment,
        capabilityStoreRoot: URL(
          fileURLWithPath: daemonSessionStoreRoot(profileName: daemonProfileName),
          isDirectory: true
        ).appendingPathComponent("runtime-records", isDirectory: true).path,
        apiKeyStore: apiKeyStore
      )
      distributedController = host
      distributedControllerStatus = "Worker controller: starting"
      rebuildMenu()
      let port = try await host.start()
      guard generation == distributedControllerGeneration else {
        await host.stop()
        return
      }
      distributedControllerStatus = "Worker controller: \(host.configuration.host):\(port)"
    } catch {
      guard generation == distributedControllerGeneration else { return }
      distributedController = nil
      distributedControllerStatus = "Worker controller: failed; check configuration and port"
    }
    rebuildMenu()
  }

  func stopDistributedController() async {
    await distributedControllerOperations.run { [self] in await performDistributedControllerStop() }
  }

  func performDistributedControllerStop() async {
    distributedControllerGeneration += 1
    let generation = distributedControllerGeneration
    let host = distributedController
    distributedControllerStatus = "Worker controller: stopping"
    rebuildMenu()
    await host?.stop()
    guard generation == distributedControllerGeneration else { return }
    distributedController = nil
    distributedControllerStatus = "Worker controller: stopped"
    rebuildMenu()
  }

  func showDistributedControllerSettings() {
    openSettingsFromMenu()
  }

  func saveDistributedControllerConfiguration(_ config: DistributedControllerConfiguration, at url: URL) async -> String {
    await distributedControllerOperations.run { [self] in
      guard !terminationShutdownStarted else { return "The app is shutting down." }
      return await performDistributedControllerConfigurationSave(config, at: url)
    }
  }

  func performDistributedControllerConfigurationSave(_ config: DistributedControllerConfiguration, at url: URL) async -> String {
    guard url == distributedControllerConfigurationURL else { return "The active profile changed. Reopen controller settings." }
    do {
      try config.validate()
      let previous = FileManager.default.fileExists(atPath: url.path) ? try DistributedControllerConfiguration.load(from: url) : nil
      if let controller = try previous?.controller(relativeTo: url),
        try await controller.jobs(now: Date()).contains(where: { $0.status == .queued || $0.status == .leased }) {
        return "Finish or cancel queued and running remote jobs before restarting the controller."
      }
      guard url == distributedControllerConfigurationURL else { return "The active profile changed. Reopen controller settings." }
      let wasRunning = distributedController != nil
      await performDistributedControllerStop()
      guard url == distributedControllerConfigurationURL else { return "The active profile changed. Reopen controller settings." }
      do {
        try await config.saveIfIdle(replacing: previous, at: url)
      } catch {
        if wasRunning { await performDistributedControllerStart() }
        throw error
      }
      await performDistributedControllerStart()
      return distributedController == nil
        ? "Settings saved. Controller could not start. Check the listen address and port, then Save and Restart."
        : "Settings saved. \(distributedControllerStatus)"
    } catch DistributedWorkerError.controllerBusy {
      return "Finish or cancel queued and running remote jobs before restarting the controller."
    } catch DistributedWorkerError.staleControllerConfiguration {
      return "Controller configuration changed. Reopen controller settings."
    } catch {
      return "Unable to save controller settings. Check the configuration and destination permissions."
    }
  }

  /// Native alert for the debug --open-worker-status launch option; the console
  /// Settings page shows the same rows.
  func showDistributedWorkerStatus() {
    Task {
      guard let host = distributedController else { return }
      let alert = NSAlert()
      alert.messageText = "Worker Status"
      do {
        let rows = try await distributedWorkerStatusRows(of: host)
        guard host === distributedController else { return }
        alert.informativeText = rows.isEmpty ? "No workers configured." : rows.map { row in
          guard let worker = row.worker else { return "\(row.id): not connected" }
          return "\(worker.workerId): \(worker.online ? "online" : "offline"), \(worker.activeJobIds.count)/\(worker.capacity) running\nGroups: \(worker.groups.sorted().joined(separator: ", "))"
        }.joined(separator: "\n\n")
      } catch {
        alert.informativeText = RielaApp.distributedWorkerStatusReadFailure
      }
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
    }
  }
}
#endif
