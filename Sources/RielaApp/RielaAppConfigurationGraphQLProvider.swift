#if os(macOS)
import Foundation
import RielaAppSupport
import RielaCore
import RielaGraphQL

final class RielaAppConfigurationGraphQLProvider: RielaConfigurationGraphQLProviding, @unchecked Sendable {
  private weak var app: RielaApp?

  init(app: RielaApp) {
    self.app = app
  }

  func configuration() async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try await app.graphQLConfiguration()
    }
  }

  func updateAssistant(
    input: GraphQLUpdateAssistantConfigurationInput
  ) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(
        input.expectedRevision,
        expectedProfile: input.expectedProfile
      )
      var settings = app.daemonState.assistant
      if let assistance = input.assistance {
        settings.assistance = assistance
      }
      if let rawVendor = input.vendor {
        guard let vendor = RielaAppAssistantVendor(rawValue: rawVendor), vendor != .automatic else {
          throw RielaConfigurationGraphQLError(
            code: "INVALID_CONFIGURATION",
            message: "assistant vendor '\(rawVendor)' is not selectable"
          )
        }
        settings.vendor = vendor
      }
      if let model = input.model {
        settings.setSelectedModel(model, for: settings.vendor)
      }
      if let error = app.saveAssistantSettings(settings) {
        throw RielaConfigurationGraphQLError(code: "CONFIGURATION_IO_FAILURE", message: error)
      }
      app.webRevision += 1
      return try await app.graphQLConfiguration()
    }
  }

  func updateAppearance(
    input: GraphQLUpdateAppearanceConfigInput
  ) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(
        input.expectedRevision,
        expectedProfile: input.expectedProfile
      )
      guard let colorScheme = RielaAppColorScheme(rawValue: input.colorScheme) else {
        throw RielaConfigurationGraphQLError(
          code: "INVALID_CONFIGURATION",
          message: "unsupported color scheme '\(input.colorScheme)'"
        )
      }
      do {
        try app.appearanceSettingsStore.save(RielaAppAppearanceSettings(colorScheme: colorScheme))
      } catch {
        throw RielaConfigurationGraphQLError(
          code: "CONFIGURATION_IO_FAILURE",
          message: "appearance configuration could not be saved"
        )
      }
      rielaAppApplyColorScheme(colorScheme)
      app.webRevision += 1
      return try await app.graphQLConfiguration()
    }
  }

  func updateHTTPServer(
    input: GraphQLUpdateHTTPServerConfigInput
  ) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: nil)
      do {
        if let configuredPort = input.configuredPort {
          try app.webServerController?.updateConfiguredPort(configuredPort)
        }
        if let isEnabled = input.isEnabled {
          if isEnabled {
            await app.webServerController?.start()
          } else {
            await app.webServerController?.stop(explicit: true)
          }
        }
      } catch {
        throw RielaConfigurationGraphQLError(
          code: "INVALID_CONFIGURATION",
          message: error.localizedDescription
        )
      }
      app.webRevision += 1
      return try await app.graphQLConfiguration()
    }
  }

  func createProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard app.createDaemonProfile(rawProfileName: input.name) != nil else {
        throw RielaConfigurationGraphQLError(code: "CONFIGURATION_IO_FAILURE", message: app.status)
      }
      app.webRevision += 1
      return try await app.graphQLConfiguration()
    }
  }

  func removeProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard app.removeDaemonProfile(RielaAppProfileName(input.name)) else {
        throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: app.status)
      }
      app.webRevision += 1
      return try await app.graphQLConfiguration()
    }
  }

  func switchProfile(input: GraphQLProfileConfigurationInput) async throws -> GraphQLRielaConfiguration {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      await app.switchDaemonProfileAndWait(to: input.name)
      return try await app.graphQLConfiguration()
    }
  }

  func addWorkflowDirectory(
    input: GraphQLWorkflowDirConfigInput
  ) async throws -> GraphQLConfigurationRevision {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      var state = app.daemonState
      state.addWorkflowDirectory(input.path)
      guard app.saveDaemonState(state, profileName: app.daemonProfileName) else {
        throw RielaConfigurationGraphQLError(code: "CONFIGURATION_IO_FAILURE", message: app.status)
      }
      app.webRevision += 1
      app.refreshDaemonWorkflowWindow()
      return app.graphQLConfigurationRevision
    }
  }

  func updateWorkflowInstance(
    input: GraphQLWorkflowInstanceConfigInput
  ) async throws -> GraphQLConfigurationRevision {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      guard app.resolveDaemonWorkflowInstance(identity: input.identity) != nil else {
        throw RielaConfigurationGraphQLError(code: "INSTANCE_NOT_FOUND", message: "Workflow instance was not found")
      }
      let saved = app.updateDaemonPreference(identity: input.identity) { preference in
        if let value = input.workingDirectory {
          preference.workingDirectory = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = input.environmentFilePath {
          preference.environmentFilePath = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        input.environmentVariableUpdates?.forEach { name, value in
          if !value.isEmpty { preference.environmentVariables[name] = value }
        }
        input.environmentVariablesToClear?.forEach { preference.environmentVariables.removeValue(forKey: $0) }
        if let workflowVariables = input.workflowVariables {
          preference.defaultVariables = workflowVariables
        }
      }
      guard saved else {
        throw RielaConfigurationGraphQLError(code: "CONFIGURATION_IO_FAILURE", message: app.status)
      }
      app.webRevision += 1
      app.restartActiveDaemonWorkflowAfterConfigurationChange(
        identity: input.identity,
        changeDescription: "web configuration"
      )
      return app.graphQLConfigurationRevision
    }
  }

  func registerEventSource(
    input: GraphQLEventSourceConfigurationInput
  ) async throws -> GraphQLConfigurationRevision {
    try await withApp { app in
      try app.validateGraphQLConfigurationRevision(input.expectedRevision, expectedProfile: input.expectedProfile)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard
        let source = String(data: try encoder.encode(JSONValue.object(input.source)), encoding: .utf8),
        let binding = String(data: try encoder.encode(JSONValue.object(input.binding)), encoding: .utf8)
      else {
        throw RielaConfigurationGraphQLError(
          code: "CONFIGURATION_IO_FAILURE",
          message: "event source configuration could not be encoded"
        )
      }
      if let message = app.registerDaemonWorkflowEventSource(identity: input.identity, sourceJSON: source, bindingJSON: binding) {
        throw RielaConfigurationGraphQLError(code: "INVALID_CONFIGURATION", message: message)
      }
      app.webRevision += 1
      return app.graphQLConfigurationRevision
    }
  }

  private func withApp<Value: Sendable>(
    _ operation: @escaping @MainActor (RielaApp) async throws -> Value
  ) async throws -> Value {
    guard let app else {
      throw RielaConfigurationGraphQLError(
        code: "CONFIGURATION_UNAVAILABLE",
        message: "RielaApp is unavailable"
      )
    }
    return try await Task { @MainActor in
      try await operation(app)
    }.value
  }
}

extension RielaApp {
  func graphQLConfiguration() async throws -> GraphQLRielaConfiguration {
    let settings = daemonState.assistant
    let selectedVendor = settings.vendor.settingsSelectableVendor
    var catalogs: [GraphQLConfigurationModelCatalog] = []
    for vendor in RielaAppAssistantVendor.selectableVendors {
      let models: [String]
      if vendor == selectedVendor, vendor.supportsLiveModelListing {
        models = (try? await RielaAppAssistantModelLoader().models(for: vendor)) ?? vendor.modelSuggestions
      } else {
        models = vendor.modelSuggestions
      }
      catalogs.append(GraphQLConfigurationModelCatalog(vendor: vendor.rawValue, models: models))
    }
    let appearance = appearanceSettingsStore.load()
    let serverSettings = webServerController?.settings ?? RielaAppWebServerSettings()
    return GraphQLRielaConfiguration(
      profile: daemonProfileName.rawValue,
      revision: webRevision,
      assistant: GraphQLAssistantConfiguration(
        assistance: settings.assistance,
        vendor: selectedVendor.rawValue,
        model: settings.selectedModel(for: selectedVendor),
        modelCatalogs: catalogs
      ),
      appearance: GraphQLAppearanceConfiguration(
        colorScheme: appearance.colorScheme.rawValue,
        options: RielaAppColorScheme.allCases.map(\.rawValue)
      ),
      server: GraphQLHTTPServerConfiguration(
        isEnabled: serverSettings.isEnabled,
        configuredPort: serverSettings.port,
        boundPort: webServerController?.state.boundPort,
        restartRequired: webServerController?.restartRequired ?? false,
        state: webServerController?.state.label ?? "stopped"
      ),
      profiles: availableDaemonProfileNames().map(\.rawValue),
      workflowDirectories: daemonState.workflowDirectories
    )
  }

  var graphQLConfigurationRevision: GraphQLConfigurationRevision {
    GraphQLConfigurationRevision(profile: daemonProfileName.rawValue, revision: webRevision)
  }

  func validateGraphQLConfigurationRevision(
    _ expectedRevision: Int,
    expectedProfile: String?
  ) throws {
    if let expectedProfile, expectedProfile != daemonProfileName.rawValue {
      throw RielaConfigurationGraphQLError(
        code: "PROFILE_CONFLICT",
        message: "the active profile changed after this configuration was loaded"
      )
    }
    guard expectedRevision == webRevision else {
      throw RielaConfigurationGraphQLError(
        code: "REVISION_CONFLICT",
        message: "expected revision \(expectedRevision), current revision is \(webRevision)"
      )
    }
  }
}
#endif
