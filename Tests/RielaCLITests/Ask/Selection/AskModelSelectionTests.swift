import Foundation
import RielaAppSupport
import RielaCore
import XCTest
@testable import RielaCLI

final class AskModelSelectionTests: XCTestCase {
  func testStoredCLIModelUsesExecutableOnPath() throws {
    let directory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/ask-riela/ask-01-catalog-and-selection/test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codex = directory.appendingPathComponent("codex")
    try Data().write(to: codex)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
    var settings = RielaAppAssistantSettings(vendor: .codexCLI)
    settings.setSelectedModel("gpt-6.1-terra", for: .codexCLI)

    let result = try resolve(settings: settings, environment: ["PATH": directory.path])
    XCTAssertEqual(result.backend, .codexAgent)
    XCTAssertEqual(result.providerInstanceId, "codex-agent")
    XCTAssertEqual(result.model, "gpt-6.1-terra")
    XCTAssertEqual(result.warnings, [])
  }

  func testAutomaticPicksAvailableAnthropicCredentialAndPassesAlias() throws {
    for key in ["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"] {
      let result = try resolve(environment: [key: "fixture"])
      XCTAssertEqual(result.vendor, .anthropicAPI)
      XCTAssertEqual(result.backend, .officialAnthropicSDK)
      XCTAssertEqual(result.model, "claude-sonnet-5-5")
      XCTAssertEqual(result.apiKeyEnvironment, key == "CLAUDE_API_KEY" ? key : nil)
    }
  }

  func testAutomaticWithNoAvailableBackendFails() {
    assertError("ask_vendor_unavailable", mentioning: "OPENAI_API_KEY") { try resolve() }
  }

  func testProviderInstanceWinsAndSuppliesMetadataAndDefaultSentinel() throws {
    let provider = ProviderInstance(
      instanceId: "team/openai", driver: .officialOpenAISDK, providerName: "team",
      providerProxy: "https://fixture.invalid", apiKeyEnvironment: "TEAM_KEY", customModels: [.init(id: "team-model")]
    )
    let environment = ["TEAM_KEY": "fixture"]
    let request = AskModelRequest(vendor: "ignored", providerInstanceId: provider.instanceId)
    let result = try resolve(request: request, extra: [provider], environment: environment)
    XCTAssertEqual(result.providerInstanceId, provider.instanceId)
    XCTAssertEqual(result.vendor, .openAIAPI)
    XCTAssertEqual(result.providerName, "team")
    XCTAssertEqual(result.providerProxy, "https://fixture.invalid")
    XCTAssertEqual(result.apiKeyEnvironment, "TEAM_KEY")
    XCTAssertNil(result.model)

    var custom = request
    custom.model = "team-model"
    XCTAssertEqual(try resolve(request: custom, extra: [provider], environment: environment).warnings, [])
    assertError("ask_vendor_unavailable", mentioning: "TEAM_KEY") {
      try resolve(request: custom, extra: [provider], environment: ["OPENAI_API_KEY": "fixture"])
    }
  }

  func testUnknownInstanceGeminiAndUnknownVendorFail() {
    assertError("provider_instance_not_found", mentioning: "missing") {
      try resolve(request: .init(providerInstanceId: "missing"))
    }
    assertError("ask_provider_unsupported", mentioning: "official/gemini-sdk") {
      try resolve(request: .init(providerInstanceId: NodeExecutionBackend.officialGeminiSDK.rawValue))
    }
    assertError("ask_vendor_unknown", mentioning: "bogus") {
      try resolve(request: .init(vendor: "bogus"))
    }
  }

  func testUnlistedModelWarnsAgainstSelectedInstanceOnly() throws {
    let other = ProviderInstance(
      instanceId: "other/openai", driver: .officialOpenAISDK, customModels: [.init(id: "other-model")]
    )
    let result = try resolve(
      request: .init(vendor: "openai-api", model: "other-model"), extra: [other],
      environment: ["OPENAI_API_KEY": "fixture"]
    )
    XCTAssertEqual(result.model, "other-model")
    XCTAssertEqual(result.warnings, [BotsService.unknownModelWarning("other-model", driver: .officialOpenAISDK)])
  }

  func testDefaultAndEmptyModelOverridesAreOmitted() throws {
    for model in ["default", ""] {
      let result = try resolve(request: .init(vendor: "openai-api", model: model), environment: ["OPENAI_API_KEY": "fixture"])
      XCTAssertNil(result.model)
      XCTAssertTrue(result.warnings.isEmpty)
    }
  }

  func testEffortWithOptionsAndExplicitVendorAvailability() throws {
    assertError("ask_option_unsupported", mentioning: "ultra") {
      try resolve(request: .init(vendor: "openai-api", effort: "ultra"), environment: ["OPENAI_API_KEY": "fixture"])
    }
    assertError("ask_vendor_unavailable", mentioning: "OPENAI_API_KEY") {
      try resolve(request: .init(vendor: "openai-api"))
    }
    assertError("ask_vendor_unavailable", mentioning: "codex") {
      try resolve(request: .init(vendor: "codex-cli"))
    }
  }

  private func resolve(
    settings: RielaAppAssistantSettings = .init(vendor: .automatic), request: AskModelRequest = .init(),
    extra: [ProviderInstance] = [], environment: [String: String] = [:]
  ) throws -> AskResolvedModel {
    let instances = NodeExecutionBackend.allCases.map(ProviderInstance.builtIn) + extra
    return try AskModelSelection.resolve(
      settings: settings, request: request, catalog: ModelCatalog.build(instances: instances, reports: [:]),
      environment: ["PATH": ""].merging(environment) { _, replacement in replacement }
    )
  }

  private func assertError(
    _ code: String, mentioning text: String, file: StaticString = #filePath, line: UInt = #line,
    _ operation: () throws -> AskResolvedModel
  ) {
    XCTAssertThrowsError(try operation(), file: file, line: line) { error in
      let selectionError = error as? AskSelectionError
      XCTAssertEqual(selectionError?.code, code, file: file, line: line)
      XCTAssertTrue(selectionError?.message.contains(text) == true, file: file, line: line)
    }
  }
}
