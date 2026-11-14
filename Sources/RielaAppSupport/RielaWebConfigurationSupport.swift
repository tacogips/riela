import Foundation
import RielaCore
import RielaGraphQL

/// Configuration rules shared by AppKit and the browser server host.
public enum RielaWebConfigurationSupport {
  public static func validateRevision(
    expected: Int, current: Int, expectedProfile: String?, currentProfile: String
  ) throws {
    if let expectedProfile, expectedProfile != currentProfile {
      throw RielaConfigurationGraphQLError(
        code: "PROFILE_CONFLICT", message: "the active profile changed after this configuration was loaded"
      )
    }
    guard expected == current else {
      throw RielaConfigurationGraphQLError(
        code: "REVISION_CONFLICT", message: "expected revision \(expected), current revision is \(current)"
      )
    }
  }

  public static func workflowStorageConfiguration(
    appRootURL: URL, profileName: RielaAppProfileName, state: RielaAppDaemonWorkflowState, homeDirectory: URL
  ) -> GraphQLWorkflowStorageConfiguration {
    let defaultDirectory = RielaAppProfileStore.workflowStorageRootURL(appRootURL: appRootURL, profileName: profileName)
    let directory = RielaAppProfileStore.workflowStorageRootURL(
      appRootURL: appRootURL, profileName: profileName, storageDirectory: state.workflowStorageDirectory
    )
    return GraphQLWorkflowStorageConfiguration(
      directory: directory.path, defaultDirectory: defaultDirectory.path,
      isDefault: directory.path == defaultDirectory.path,
      cliWorkflowHome: cliWorkflowHome(homeDirectory: homeDirectory).path
    )
  }

  /// Applies a requested storage directory to `state` and creates its
  /// `workflows` and `packages` roots. A blank request restores the default;
  /// the CLI's own `~/.riela` workflow storage is refused so RielaApp and the
  /// CLI never share definitions.
  public static func applyingWorkflowStorage(
    _ input: GraphQLUpdateWorkflowStorageConfigInput, to original: RielaAppDaemonWorkflowState,
    appRootURL: URL, profileName: RielaAppProfileName, homeDirectory: URL
  ) throws -> RielaAppDaemonWorkflowState {
    var state = original
    let requested = input.directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let defaultDirectory = RielaAppProfileStore.workflowStorageRootURL(appRootURL: appRootURL, profileName: profileName)
    var directory = defaultDirectory
    if !requested.isEmpty {
      let expanded = requested == "~" || requested.hasPrefix("~/")
        ? homeDirectory.path + requested.dropFirst()
        : requested
      guard expanded.hasPrefix("/") else {
        throw RielaConfigurationGraphQLError(
          code: "INVALID_CONFIGURATION", message: "workflow storage directory must be an absolute path"
        )
      }
      directory = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
    let cliHome = cliWorkflowHome(homeDirectory: homeDirectory).standardizedFileURL.path
    let cliOwned = [cliHome] + ["workflows", "packages", "temporary-workflows", "workflow-state"].map { "\(cliHome)/\($0)" }
    if cliOwned.contains(where: { directory.path == $0 || ($0 != cliHome && directory.path.hasPrefix($0 + "/")) }) {
      throw RielaConfigurationGraphQLError(
        code: "INVALID_CONFIGURATION",
        message: "workflow storage directory must be separate from the riela CLI workflow home \(cliHome)"
      )
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
      throw RielaConfigurationGraphQLError(
        code: "INVALID_CONFIGURATION", message: "workflow storage path is not a directory: \(directory.path)"
      )
    }
    do {
      for child in ["workflows", "packages"] {
        try FileManager.default.createDirectory(
          at: directory.appendingPathComponent(child, isDirectory: true), withIntermediateDirectories: true
        )
      }
    } catch {
      throw RielaConfigurationGraphQLError(
        code: "CONFIGURATION_IO_FAILURE", message: "could not create workflow storage: \(error.localizedDescription)"
      )
    }
    state.workflowStorageDirectory = directory.path == defaultDirectory.path ? nil : directory.path
    return state
  }

  /// The CLI's default user-scope workflow storage (`$HOME/.riela`).
  public static func cliWorkflowHome(homeDirectory: URL) -> URL {
    homeDirectory.appendingPathComponent(".riela", isDirectory: true)
  }

  public static func assistantConfiguration(_ settings: RielaAppAssistantSettings) async -> GraphQLAssistantConfiguration {
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
    return GraphQLAssistantConfiguration(
      assistance: settings.assistance, vendor: selectedVendor.rawValue,
      model: settings.selectedModel(for: selectedVendor), modelCatalogs: catalogs
    )
  }

  public static func applying(
    _ input: GraphQLUpdateAssistantConfigurationInput, to original: RielaAppAssistantSettings
  ) throws -> RielaAppAssistantSettings {
    var settings = original
    if let assistance = input.assistance { settings.assistance = assistance }
    if let rawVendor = input.vendor {
      guard let vendor = RielaAppAssistantVendor(rawValue: rawVendor), vendor != .automatic else {
        throw RielaConfigurationGraphQLError(
          code: "INVALID_CONFIGURATION", message: "assistant vendor '\(rawVendor)' is not selectable"
        )
      }
      settings.vendor = vendor
    }
    if let model = input.model { settings.setSelectedModel(model, for: settings.vendor) }
    return settings
  }

  public static func applying(
    _ input: GraphQLWorkflowInstanceConfigInput, to original: RielaAppDaemonWorkflowPreference
  ) -> RielaAppDaemonWorkflowPreference {
    var preference = original
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
    if let workflowVariables = input.workflowVariables { preference.defaultVariables = workflowVariables }
    return preference
  }
}
