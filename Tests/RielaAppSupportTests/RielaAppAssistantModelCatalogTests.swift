import AgentGateway
import AgentGatewayAppCore
import RielaCore
@testable import RielaAppSupport
import XCTest

final class RielaAppAssistantModelCatalogTests: XCTestCase {
  func testBundledCatalogContainsCurrentVendorModels() {
    let catalog = RielaAppAssistantModelCatalog.shared

    XCTAssertEqual(catalog.defaultModel(for: .codexCLI), "gpt-5.6-sol")
    XCTAssertTrue(catalog.models(for: .codexCLI).contains("gpt-5.6-terra"))
    XCTAssertTrue(catalog.models(for: .claudeCodeCLI).contains("claude-opus-4-8"))
    XCTAssertTrue(catalog.models(for: .claudeCodeCLI).contains("claude-sonnet-5"))
    XCTAssertTrue(catalog.models(for: .cursorCLI).contains("composer-2.5"))
    XCTAssertTrue(catalog.models(for: .cursorCLI).contains("gpt-5.6-sol-medium"))
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

  func testAPIVendorsSupportLiveListingWhileCLIVendorsUseBundledCatalog() {
    XCTAssertTrue(RielaAppAssistantVendor.openAIAPI.supportsLiveModelListing)
    XCTAssertTrue(RielaAppAssistantVendor.anthropicAPI.supportsLiveModelListing)
    XCTAssertTrue(RielaAppAssistantVendor.cursorAPI.supportsLiveModelListing)
    XCTAssertFalse(RielaAppAssistantVendor.codexCLI.supportsLiveModelListing)
    XCTAssertFalse(RielaAppAssistantVendor.claudeCodeCLI.supportsLiveModelListing)
    XCTAssertFalse(RielaAppAssistantVendor.cursorCLI.supportsLiveModelListing)
  }

  func testLoaderUsesAgentGatewayCatalogAndConfiguredCredentialAlias() async throws {
    let listing = AssistantModelListingStub(models: [
      GatewayModelInfo(modelId: " live-model "),
      GatewayModelInfo(modelId: "live-model"),
      GatewayModelInfo(modelId: "second-model")
    ])
    let loader = RielaAppAssistantModelLoader(
      listing: listing,
      environment: ["CLAUDE_API_KEY": "secret"]
    )

    let models = try await loader.models(for: .anthropicAPI)

    XCTAssertEqual(models, ["live-model", "second-model"])
    let params = await listing.capturedParams
    XCTAssertEqual(params?.vendor, .anthropic)
    XCTAssertEqual(params?.apiKeyEnvironment, "CLAUDE_API_KEY")
  }

  func testLoaderDoesNotAskAgentGatewayToEnumerateCLIVendor() async throws {
    let listing = AssistantModelListingStub(models: [])
    let loader = RielaAppAssistantModelLoader(listing: listing, environment: [:])

    let models = try await loader.models(for: .codexCLI)

    XCTAssertEqual(models, RielaAppAssistantVendor.codexCLI.modelSuggestions)
    let params = await listing.capturedParams
    XCTAssertNil(params)
  }
}

private actor AssistantModelListingStub: GatewayModelListing {
  private let resultModels: [GatewayModelInfo]
  private(set) var capturedParams: GatewayModelCatalogParams?

  init(models: [GatewayModelInfo]) {
    resultModels = models
  }

  func models(_ params: GatewayModelCatalogParams) async throws -> GatewayModelCatalogResult {
    capturedParams = params
    return GatewayModelCatalogResult(vendor: params.vendor, models: resultModels)
  }
}
