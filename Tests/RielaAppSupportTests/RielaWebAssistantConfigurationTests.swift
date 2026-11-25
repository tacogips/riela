import RielaAppSupport
import RielaCore
import RielaGraphQL
import XCTest

final class RielaWebAssistantConfigurationTests: XCTestCase {
  func testAutomaticKeepsStoredChoicesAndReportsNoModel() throws {
    var previous = RielaAppAssistantSettings(vendor: .codexCLI)
    previous.setSelectedModel("team-model", for: .codexCLI)
    let input = GraphQLUpdateAssistantConfigurationInput(expectedRevision: 0, expectedProfile: "default", vendor: "automatic")

    let settings = try RielaWebConfigurationSupport.applying(input, to: previous)
    let configuration = RielaWebConfigurationSupport.assistantConfiguration(settings)

    XCTAssertEqual(settings.vendor, .automatic)
    XCTAssertEqual(settings.modelsByVendor, previous.modelsByVendor)
    XCTAssertEqual(configuration.vendor, "automatic")
    XCTAssertEqual(configuration.model, "")
  }

  func testModelRequiresConcreteVendor() {
    let settings = RielaAppAssistantSettings(vendor: .codexCLI)
    let input = GraphQLUpdateAssistantConfigurationInput(
      expectedRevision: 0, expectedProfile: "default", vendor: "automatic", model: "default"
    )
    XCTAssertThrowsError(try RielaWebConfigurationSupport.applying(input, to: settings)) { error in
      XCTAssertEqual(error as? RielaConfigurationGraphQLError, RielaConfigurationGraphQLError(
        code: "INVALID_CONFIGURATION", message: "assistant model needs a concrete vendor"
      ))
    }
  }

  func testInjectedCatalogSuggestionsAndManifestFallback() {
    let settings = RielaAppAssistantSettings(vendor: .codexCLI)
    let supplied = RielaWebConfigurationSupport.assistantConfiguration(settings, catalogModels: [.codexAgent: ["team-model"]])
    let bundled = RielaWebConfigurationSupport.assistantConfiguration(settings)
    XCTAssertEqual(supplied.modelCatalogs.first { $0.vendor == "codex-cli" }?.models, ["team-model"])
    XCTAssertEqual(bundled.modelCatalogs.first { $0.vendor == "codex-cli" }?.models, ModelManifest.models[.codexAgent]?.map(\.id))
    XCTAssertEqual(supplied.modelCatalogs.first { $0.vendor == "anthropic-api" }?.models, RielaAppAssistantVendor.anthropicAPI.modelSuggestions)
  }
}
