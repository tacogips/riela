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
