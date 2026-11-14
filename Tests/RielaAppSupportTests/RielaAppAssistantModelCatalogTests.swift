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
    let obsoleteModels = [
      "gpt-5.5-medium",
      "gpt-5-mini",
      "gpt-5-nano",
      "claude-opus-4.8",
      "claude-opus-4-1",
      "composer-2"
    ]

    XCTAssertTrue(Set(models).isDisjoint(with: obsoleteModels))
  }
}
