import RielaCore
import XCTest

final class ModelManifestTests: XCTestCase {
  func testAcceptedIdsLeadManifestAndPreviousSuggestionsRemain() {
    let claude = [
      "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5",
      "claude-sonnet-5", "claude-opus-4-8", "claude-fable-5", "claude-sonnet-4-6", "claude-haiku-4-5"
    ]
    let gpt = ["gpt-6.2-sol", "gpt-6.1-terra", "gpt-6-astra"]
    let expected: [NodeExecutionBackend: [String]] = [
      .codexAgent: gpt + [
        "gpt-5.6-sol", "gpt-5.5", "gpt-5.4-mini", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.4", "gpt-5.3-codex-spark"
      ],
      .officialOpenAISDK: gpt + ["gpt-5.6", "gpt-5.4-mini", "gpt-5.5", "gpt-5.4"],
      .claudeCodeAgent: claude,
      .officialAnthropicSDK: claude,
      .cursorCliAgent: [
        "auto", "composer-2.5", "gpt-5.6-sol-medium", "gpt-5.6-terra-medium", "gpt-5.6-luna-medium",
        "claude-opus-4-8-high", "claude-sonnet-5-high"
      ],
      .officialCursorSDK: ["composer-2.5"],
      .officialGeminiSDK: ["gemini-3.5-flash-lite", "gemini-3.5-flash"]
    ]
    XCTAssertEqual(ModelManifest.models.mapValues { $0.map(\.id) }, expected)
    for (backend, models) in ModelManifest.models {
      XCTAssertEqual(Set(models.map(\.id)).count, models.count, backend.rawValue)
    }
    for backend in [NodeExecutionBackend.codexAgent, .officialOpenAISDK] {
      XCTAssertTrue(ModelManifest.models[backend, default: []].allSatisfy { !$0.options.reasoningEfforts.isEmpty })
    }
  }
}
