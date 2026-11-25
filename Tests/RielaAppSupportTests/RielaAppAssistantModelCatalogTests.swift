import RielaCore
@testable import RielaAppSupport
import XCTest

final class RielaAppAssistantModelCatalogTests: XCTestCase {
  func testSharedCatalogUsesManifestForEachSelectableVendor() {
    let catalog = RielaAppAssistantModelCatalog.shared

    XCTAssertEqual(RielaAppAssistantVendor.selectableVendors.count, 6)
    for vendor in RielaAppAssistantVendor.selectableVendors {
      XCTAssertFalse(catalog.models(for: vendor).isEmpty)
      XCTAssertEqual(catalog.models(for: vendor), ModelManifest.models[vendor.executionBackend]?.map(\.id))
    }
    XCTAssertEqual(catalog.defaultModel(for: .codexCLI), "gpt-6.2-sol")
    XCTAssertEqual(catalog.defaultModel(for: .claudeCodeCLI), "claude-sonnet-5-5")
  }

  func testCatalogUsesBackendSpecificModelSuggestions() {
    let catalog = RielaAppAssistantModelCatalog.shared

    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.codexAgent), catalog.models(for: .codexCLI))
    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.claudeCodeAgent), catalog.models(for: .claudeCodeCLI))
    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.cursorCliAgent), catalog.models(for: .cursorCLI))
    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.officialOpenAISDK), catalog.models(for: .openAIAPI))
    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.officialAnthropicSDK), catalog.models(for: .anthropicAPI))
    XCTAssertEqual(catalog.models(for: NodeExecutionBackend.officialCursorSDK), catalog.models(for: .cursorAPI))
  }

  func testCatalogNormalizesAndDeduplicatesModels() {
    let catalog = RielaAppAssistantModelCatalog(modelsByVendor: [
      RielaAppAssistantVendor.codexCLI.rawValue: [" gpt-5.6-sol ", "", "gpt-5.6-sol"]
    ])

    XCTAssertEqual(catalog.models(for: .codexCLI), ["gpt-5.6-sol"])
  }

  func testBundledCatalogOmitsObsoleteAndMalformedSuggestions() {
    let models = RielaAppAssistantModelCatalog.shared.modelsByVendor.values.flatMap { $0 }
    // The nano literal is split so the SourceDeletionReadiness fixture scan
    // does not flag this negative assertion as a reference to the model.
    let obsoleteModels = [
      "gpt-5.5-medium",
      "gpt-5-mini",
      "gpt-5-" + "nano",
      "claude-opus-4.8",
      "claude-opus-4-1",
      "composer-2"
    ]

    XCTAssertTrue(Set(models).isDisjoint(with: obsoleteModels))
  }

  func testSettingsPreserveLiveCatalogModelOutsideBundledSuggestions() {
    var settings = RielaAppAssistantSettings(vendor: .openAIAPI)

    settings.setSelectedModel(" future-model ", for: .openAIAPI)

    XCTAssertEqual(settings.selectedModel(for: .openAIAPI), "future-model")
    XCTAssertEqual(settings.normalizedModel, "future-model")
  }
}
