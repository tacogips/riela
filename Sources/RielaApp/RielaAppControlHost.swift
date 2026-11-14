#if os(macOS)
import AppKit
import Foundation
import RielaAppSupport
import RielaCLI
import RielaCore
import RielaGraphQL
import RielaServer

@MainActor
struct RielaAppControlPorts: RielaAppInstanceControlPorts {
  let app: RielaApp
  let profileName: RielaAppProfileName

  func profile() async -> String { app.daemonProfileName.rawValue }
  func bootstrap() async -> RielaAppControlBootstrap { .init(profile: app.daemonProfileName.rawValue, revision: app.webRevision) }
  func isShuttingDown() async -> Bool { app.terminationShutdownStarted }
  func serialized(_ body: @escaping @Sendable () async -> RielaAppControlResult) async -> RielaAppControlResult {
    await app.distributedControllerOperations.run { await body() }
  }
  nonisolated func reloadPorts() -> any RielaAppInstanceReloadPorts { RielaAppReloadPorts(app: app, profileName: profileName) }
  nonisolated func cancelPorts() -> any RielaAppInstanceCancelPorts { RielaAppCancelPorts(app: app, profileName: profileName) }
  func validateRevision(expectedRevision: Int, expectedProfile: String) async -> RielaAppControlConflict? {
    do {
      try app.validateGraphQLConfigurationRevision(expectedRevision, expectedProfile: expectedProfile)
      return nil
    } catch let error as RielaConfigurationGraphQLError {
      let status = error.code == "SOURCE_NOT_FOUND" ? 404 : error.code == "INVALID_CONFIGURATION" ? 400 : 409
      return .init(code: error.code.lowercased(), message: error.message, status: status)
    } catch {
      return .init(code: "configuration_io_failure", message: "Could not save execution configuration.", status: 500)
    }
  }
  func instanceExists(identity: String) async -> Bool { app.daemonInstances.contains { $0.identity == identity } }
  func environmentStatus(identity: String) async -> RuntimeEnvironmentStatus {
    let runtimeIdentity = app.profileRuntimeIdentity(profileName: app.daemonProfileName, localIdentity: identity)
    return await app.daemonRuntime.environmentStatus(identity: runtimeIdentity, profile: app.daemonProfileName.rawValue)
  }
  func reloadEnvironment(identity: String) async -> RielaAppEnvironmentReloadOutcome {
    let selectedProfile = app.daemonProfileName
    let runtimeIdentity = app.profileRuntimeIdentity(profileName: selectedProfile, localIdentity: identity)
    guard let resolved = app.resolveDaemonWorkflowInstance(identity: runtimeIdentity) else { return .notReady }
    let configuration = app.daemonRuntimeConfiguration(for: resolved.candidate, preference: resolved.preference)
    do {
      _ = try await app.daemonRuntime.reloadEnvironment(for: resolved.candidate, configuration: configuration)
      if resolved.preference.active, app.daemonRuntime.snapshot(for: runtimeIdentity).status != .running,
         let approved = await app.approvedDaemonWorkflowInstance(identity: runtimeIdentity),
         app.daemonProfileName == selectedProfile, !app.terminationShutdownStarted {
        await app.daemonRuntime.start(approved.candidate,
          configuration: app.daemonRuntimeConfiguration(for: approved.candidate, preference: approved.preference),
          server: app.daemonServerConfiguration(profileName: selectedProfile),
          sessionStoreRoot: app.daemonSessionStoreRoot(profileName: selectedProfile))
      }
      return .reloaded(await app.daemonRuntime.environmentStatus(identity: runtimeIdentity, profile: selectedProfile.rawValue))
    } catch {
      var status = await app.daemonRuntime.environmentStatus(identity: runtimeIdentity, profile: selectedProfile.rawValue)
      status.lastError = error as? RuntimeEnvironmentError ?? .sourceFailed
      return .failed(status)
    }
  }
  func launchConfiguredRun(identity: String, input: RielaAppConfiguredRunInput) async -> RielaAppControlResult {
    do {
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard !app.terminationShutdownStarted,
            let approved = await app.approvedDaemonWorkflowInstance(identity: app.profileRuntimeIdentity(profileName: app.daemonProfileName, localIdentity: identity)) else {
        return .error(status: 422, code: "instance_not_ready")
      }
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard !app.terminationShutdownStarted, approved.profileName == app.daemonProfileName else {
        return .error(status: 409, code: "configuration_conflict")
      }
      let configuration = app.daemonRuntimeConfiguration(for: approved.candidate, preference: approved.preference)
      let snapshot = try await app.daemonRuntime.prepareEnvironment(for: approved.candidate, configuration: configuration)
      let context = RielaWebWorkflowContext(profile: app.daemonProfileName, assistant: app.daemonState.assistant,
        sources: app.daemonWorkflowSources, workingDirectory: app.appHomeDirectory, appRoot: app.profileStore.appRootURL,
        sessionStoreRoot: app.daemonSessionStoreRoot(profileName: app.daemonProfileName),
        principalId: RielaAppWebRegistryAuthorizer.principalId, environment: snapshot.runtimeEnvironment())
      return .init(httpResponse: app.webWorkflowRuntime.handler(context: context).launchConfiguredWorkflow(
        identity: identity, source: approved.candidate, configuration: approved.preference.configuration,
        variables: input.variables, allowOverlap: input.allowOverlap ?? false))
    } catch let error as RuntimeEnvironmentError {
      return .error(status: 422, code: error.rawValue)
    } catch {
      return .error(status: 409, code: "configuration_conflict")
    }
  }
  func launchStatus(launchId: String, profile: String) async -> RielaAppControlResult {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    let path = "/api/v1/workflow-editor/launches/" + (launchId.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    return .init(httpResponse: app.webWorkflowEditorLaunch(request: .init(method: "GET", path: path,
      headers: ["x-riela-profile": profile])))
  }
}

extension RielaApp {
  var controlService: RielaAppInstanceControlService {
    RielaAppInstanceControlService(ports: RielaAppControlPorts(app: self, profileName: daemonProfileName))
  }
  func startOwnerStartup() {
    let run = RielaAppRunDirectory(appRoot: profileStore.appRootURL)
    let server = RielaAppControlChannelServer(run: run, handler: { [weak self] operation, profile in
      guard let self else { return .error(status: 503, code: "app_not_running") }
      return await self.controlService.handle(operation, profile: profile)
    }, log: { message in Task { @MainActor [weak self] in self?.logDaemon(message) } })
    controlChannel = server
    if !run.socketPathFits { logDaemon("app_channel_path_too_long") }
    RielaAppOwnerStartup(run: run, waitObserver: { [weak self] in
      Task { @MainActor in
        guard let self, !self.ownerStartupComplete, !self.terminationShutdownStarted else { return }
        self.status = "Waiting for a local riela CLI operation…"
        self.rebuildMenu()
      }
    }).start(bindChannel: { [weak self] url in
      do { try server.bind(socketURL: url) } catch {
        Task { @MainActor in self?.logDaemon("app_channel_insecure: \(error)") }
      }
    }, phaseB: { [weak self] lock in
      guard let self, !self.terminationShutdownStarted else {
        server.stop()
        RielaAppOwnerStartup.unlinkSocketIfOwned(run, lock: lock)
        return
      }
      self.ownerLock = lock
      self.ownerStartupComplete = true
      self.status = "Ready"
      self.runPhaseB()
    }, failed: { [weak self] error in
      self?.status = "app_channel_insecure"
      self?.logDaemon("app_channel_insecure: \(error)")
      NSApp.terminate(nil)
    })
  }
}
#endif
