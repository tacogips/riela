import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL

extension ServeWebHost: RielaConfigurationGraphQLProviding {
  var profileStore: RielaAppProfileStore {
    RielaAppProfileStore(appRootURL: RielaAppProfileStore.defaultAppRootURL(homeDirectory: homeDirectory))
  }

  var stateStore: RielaAppDaemonWorkflowStore {
    RielaAppDaemonWorkflowStore(profileName: profile, homeDirectory: homeDirectory)
  }

  var appearanceStore: RielaAppAppearanceSettingsStore {
    RielaAppAppearanceSettingsStore(appRootURL: profileStore.appRootURL)
  }

  var sessionStoreRoot: String {
    sessionStoreOverride ?? homeDirectory
      .appendingPathComponent(".riela/profiles/\(profile.rawValue)/sessions", isDirectory: true).path
  }

  var configurationRevision: GraphQLConfigurationRevision {
    GraphQLConfigurationRevision(profile: profile.rawValue, revision: revision)
  }

  func configuration() async throws -> GraphQLRielaConfiguration {
    refreshConfigurationState()
    let current = configurationRevision
    let assistant = await RielaWebConfigurationSupport.assistantConfiguration(state.assistant)
    try validateRevision(current.revision, profile: current.profile)
    return GraphQLRielaConfiguration(
      profile: profile.rawValue, revision: revision, assistant: assistant,
      appearance: GraphQLAppearanceConfiguration(
        colorScheme: appearanceStore.load().colorScheme.rawValue, options: RielaAppColorScheme.allCases.map(\.rawValue)
      ),
      server: GraphQLHTTPServerConfiguration(
        isEnabled: true, configuredPort: configuredPort, boundPort: port,
        restartRequired: configuredPort != port, state: "running"
      ),
      profiles: profileStore.listProfileNames(including: profile).map(\.rawValue),
      workflowDirectories: state.workflowDirectories
    )
  }

  func updateAssistant(input: GraphQLUpdateAssistantConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    var updated = state
    updated.assistant = try RielaWebConfigurationSupport.applying(input, to: state.assistant)
    try saveState(updated)
    return try await configuration()
  }

  func updateAppearance(input: GraphQLUpdateAppearanceConfigInput) async throws -> GraphQLRielaConfiguration {
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    guard let scheme = RielaAppColorScheme(rawValue: input.colorScheme) else {
      throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: "unsupported color scheme")
    }
    try appearanceStore.save(RielaAppAppearanceSettings(colorScheme: scheme))
    revision += 1
    return try await configuration()
  }

  func updateHTTPServer(input: GraphQLUpdateHTTPServerConfigInput) async throws -> GraphQLRielaConfiguration {
    try validateRevision(input.expectedRevision, profile: nil)
    guard input.isEnabled != false else {
      throw RielaConfigurationGraphQLError(
        code: "INVALID_CONFIGURATION", message: "Stop the serve process with SIGINT or SIGTERM."
      )
    }
    if let requestedPort = input.configuredPort {
      guard (1...65_535).contains(requestedPort) else {
        throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: "port must be between 1 and 65535")
      }
      try ServeWebSettingsStore(homeDirectory: homeDirectory).save(port: requestedPort)
      configuredPort = requestedPort
    }
    revision += 1
    return try await configuration()
  }

  func createProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    try profileStore.createProfileDirectories(RielaAppProfileName(input.name))
    revision += 1
    return try await configuration()
  }

  func removeProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    let selected = RielaAppProfileName(input.name)
    guard selected != .default, selected != profile else {
      throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: "Default and current profiles cannot be removed")
    }
    try profileStore.removeProfile(selected)
    revision += 1
    return try await configuration()
  }

  func switchProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try requireIdleInstanceOperation()
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    instanceOperationInProgress = true
    await runtime.stopAll()
    instanceOperationInProgress = false
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    try profileStore.saveActiveProfileName(RielaAppProfileName(input.name))
    refreshConfigurationState()
    runtimeProfile = profile
    await startConfiguredInstances()
    return try await configuration()
  }

  func addWorkflowDirectory(input: GraphQLWorkflowDirConfigInput) async throws -> GraphQLConfigurationRevision {
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    var updated = state
    updated.addWorkflowDirectory(input.path)
    try saveState(updated)
    return configurationRevision
  }

  func updateWorkflowInstance(input: GraphQLWorkflowInstanceConfigInput) async throws -> GraphQLConfigurationRevision {
    try requireIdleInstanceOperation()
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    guard let instance = instances.first(where: { $0.identity == input.identity }) else {
      throw RielaConfigurationGraphQLError(code: "INSTANCE_NOT_FOUND", message: "Workflow instance was not found")
    }
    var updated = state
    var preference = RielaWebConfigurationSupport.applying(input, to: instance.preference)
    preference.sourceIdentity = instance.sourceIdentity
    updated.preferences[input.identity] = preference
    try saveState(updated)
    await restartRunningInstance(input.identity)
    return configurationRevision
  }

  func registerEventSource(input: GraphQLEventSourceConfigurationInput) async throws -> GraphQLConfigurationRevision {
    try requireIdleInstanceOperation()
    try validateRevision(input.expectedRevision, profile: input.expectedProfile)
    guard let instance = instances.first(where: { $0.identity == input.identity }) else {
      throw RielaConfigurationGraphQLError(code: "INSTANCE_NOT_FOUND", message: "Workflow instance was not found")
    }
    let encoder = JSONEncoder()
    let source = try encoder.encode(JSONValue.object(input.source))
    let binding = try encoder.encode(JSONValue.object(input.binding))
    guard let sourceJSON = String(data: source, encoding: .utf8),
          let bindingJSON = String(data: binding, encoding: .utf8) else {
      throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: "Event source JSON could not be encoded")
    }
    _ = try RielaWorkflowEventRegistration.register(
      candidate: instance.candidate, sourceJSON: sourceJSON, bindingJSON: bindingJSON
    )
    refreshConfigurationState()
    revision += 1
    await restartRunningInstance(input.identity)
    return configurationRevision
  }

  func refreshConfigurationState() {
    let nextProfile = profileStore.loadActiveProfileName()
    let nextState = RielaAppDaemonWorkflowStore(profileName: nextProfile, homeDirectory: homeDirectory).load()
    let nextSources = RielaAppDaemonWorkflowDiscovery(homeDirectory: homeDirectory, projectRoot: workingDirectory)
      .discoverUserDaemonWorkflows(
        appWorkflowRoot: RielaAppProfileStore.workflowRootURL(appRootURL: profileStore.appRootURL, profileName: nextProfile),
        appPackageRoot: RielaAppProfileStore.packageRootURL(appRootURL: profileStore.appRootURL, profileName: nextProfile),
        projectDirectories: nextState.projectDirectories,
        additionalWorkflowDirectories: nextState.workflowDirectories
      )
    let nextAppearance = appearanceStore.load()
    let nextProfiles = profileStore.listProfileNames(including: nextProfile)
    if nextProfile != profile || nextState != state || nextSources != sources
      || nextAppearance != observedAppearance || nextProfiles != observedProfiles {
      observedAppearance = nextAppearance
      observedProfiles = nextProfiles
      profile = nextProfile
      state = nextState
      sources = nextSources
      instances = state.workflowInstances(from: sources)
      revision += 1
    }
  }

  func validateRevision(_ expected: Int, profile expectedProfile: String?) throws {
    refreshConfigurationState()
    try RielaWebConfigurationSupport.validateRevision(
      expected: expected, current: revision, expectedProfile: expectedProfile, currentProfile: profile.rawValue
    )
  }

  private func saveState(_ updated: RielaAppDaemonWorkflowState) throws {
    try stateStore.save(updated)
    refreshConfigurationState()
  }
}

/// Separate from the optional menu-bar HTTP listener's settings.
struct ServeWebSettingsStore {
  let homeDirectory: URL

  private var url: URL { homeDirectory.appendingPathComponent(".riela/serve-web.json") }

  func loadPort() -> Int? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONDecoder().decode([String: Int].self, from: data),
          let port = object["port"], (1...65_535).contains(port) else { return nil }
    return port
  }

  func save(port: Int) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(["port": port]).write(to: url, options: .atomic)
  }
}
