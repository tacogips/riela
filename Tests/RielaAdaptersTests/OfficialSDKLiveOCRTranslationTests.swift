import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class OfficialSDKLiveOCRTranslationTests: XCTestCase {
  func testOpenAITranslatesBrowserCapturedJapaneseImageToEnglish() async throws {
    try requireLiveOCRTranslationTestsEnabled()
    let apiKey = try requireEnvironment("OPENAI_API_KEY")
    let adapter = OpenAiSDKAdapter(configuration: OfficialSDKAdapterConfiguration(
      environment: ["OPENAI_API_KEY": apiKey],
      timeout: .seconds(60)
    ))

    let output = try await adapter.execute(
      input(
        backend: .officialOpenAISDK,
        model: environmentValue("RIELA_LIVE_OPENAI_OCR_MODEL") ?? "gpt-5",
        promptText: ocrTranslationPrompt(sourceLanguage: "Japanese", targetLanguage: "English"),
        imageName: "japanese_meeting"
      ),
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 90))
    )

    assertOCRTranslation(
      output,
      sourceContainsAny: ["会議"],
      sourceAndTranslationContainsAny: ["10", "ten", "十時"],
      translationContainsAny: ["meeting"]
    )
  }

  func testOpenAITranslatesBrowserCapturedEnglishImageToJapanese() async throws {
    try requireLiveOCRTranslationTestsEnabled()
    let apiKey = try requireEnvironment("OPENAI_API_KEY")
    let adapter = OpenAiSDKAdapter(configuration: OfficialSDKAdapterConfiguration(
      environment: ["OPENAI_API_KEY": apiKey],
      timeout: .seconds(60)
    ))

    let output = try await adapter.execute(
      input(
        backend: .officialOpenAISDK,
        model: environmentValue("RIELA_LIVE_OPENAI_OCR_MODEL") ?? "gpt-5",
        promptText: ocrTranslationPrompt(sourceLanguage: "English", targetLanguage: "Japanese"),
        imageName: "english_library"
      ),
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 90))
    )

    assertOCRTranslation(
      output,
      sourceContainsAny: ["library"],
      sourceAndTranslationContainsAny: ["6", "six", "六", "午後6時"],
      translationContainsAny: ["図書館"]
    )
  }

  func testAnthropicTranslatesBrowserCapturedEnglishImageToJapanese() async throws {
    try requireLiveOCRTranslationTestsEnabled()
    let apiKey = try requireEnvironment("ANTHROPIC_API_KEY")
    let adapter = AnthropicSDKAdapter(configuration: AnthropicSDKAdapterConfiguration(
      officialSDK: OfficialSDKAdapterConfiguration(
        environment: ["ANTHROPIC_API_KEY": apiKey],
        timeout: .seconds(60)
      ),
      maxTokens: 256
    ))

    let output: AdapterExecutionOutput
    do {
      output = try await adapter.execute(
        input(
          backend: .officialAnthropicSDK,
          model: environmentValue("RIELA_LIVE_ANTHROPIC_OCR_MODEL") ?? "claude-sonnet-4-5",
          promptText: ocrTranslationPrompt(sourceLanguage: "English", targetLanguage: "Japanese"),
          imageName: "english_library"
        ),
        context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 90))
      )
    } catch let error as AdapterExecutionError where isProviderAccountUnavailable(error) {
      throw XCTSkip("Anthropic API is reachable but unavailable for live OCR translation: \(error.message)")
    }

    assertOCRTranslation(
      output,
      sourceContainsAny: ["library"],
      sourceAndTranslationContainsAny: ["6", "six", "六", "午後6時"],
      translationContainsAny: ["図書館"]
    )
  }

  func testGeminiTranslatesBrowserCapturedChineseImageToEnglish() async throws {
    try requireLiveOCRTranslationTestsEnabled()
    let apiKey = try requireEnvironment("GEMINI_API_KEY", fallback: "GOOGLE_API_KEY")
    let apiKeyEnv = environmentValue("GOOGLE_API_KEY") == apiKey ? "GOOGLE_API_KEY" : "GEMINI_API_KEY"
    let adapter = GeminiSDKAdapter(configuration: OfficialSDKAdapterConfiguration(
      apiKeyEnv: apiKeyEnv,
      environment: [apiKeyEnv: apiKey],
      timeout: .seconds(60)
    ))

    let output = try await adapter.execute(
      input(
        backend: .officialGeminiSDK,
        model: environmentValue("RIELA_LIVE_GEMINI_OCR_MODEL") ?? "gemini-3.5-flash",
        promptText: ocrTranslationPrompt(sourceLanguage: "Simplified Chinese", targetLanguage: "English"),
        imageName: "chinese_ticket"
      ),
      context: AdapterExecutionContext(deadline: Date(timeIntervalSinceNow: 90))
    )

    assertOCRTranslation(
      output,
      sourceContainsAny: ["入口", "门票"],
      sourceAndTranslationContainsAny: ["ticket"],
      translationContainsAny: ["entrance", "entry"]
    )
  }

  private func ocrTranslationPrompt(sourceLanguage: String, targetLanguage: String) -> String {
    """
    OCR the attached image and translate the visible \(sourceLanguage) sentence to \(targetLanguage).
    Return exactly two lines, keeping the OCR text and translation side by side as labeled plain text.
    Example:
    OCR: Bonjour.
    Translation: Hello.
    """
  }

  private func input(
    backend: NodeExecutionBackend,
    model: String,
    promptText: String,
    imageName: String
  ) throws -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(id: "live-ocr-translation", executionBackend: backend, model: model),
      promptText: promptText,
      mergedVariables: ["imagePaths": .array([.string(try fixtureURL(imageName).path)])]
    )
  }

  private func fixtureURL(_ name: String) throws -> URL {
    if let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "BrowserOCRFixtures") {
      return url
    }
    return try XCTUnwrap(
      Bundle.module.url(forResource: name, withExtension: "png"),
      "Missing browser OCR fixture \(name).png"
    )
  }

  private func requireLiveOCRTranslationTestsEnabled() throws {
    guard environmentValue("RIELA_LIVE_OCR_TRANSLATION_TESTS") == "1" else {
      throw XCTSkip("Set RIELA_LIVE_OCR_TRANSLATION_TESTS=1 to run live OCR translation provider tests")
    }
  }

  private func requireEnvironment(_ name: String, fallback: String? = nil) throws -> String {
    if let value = environmentValue(name) {
      return value
    }
    if let fallback, let value = environmentValue(fallback) {
      return value
    }
    throw XCTSkip("Missing \(fallback.map { "\(name)/\($0)" } ?? name)")
  }

  private func environmentValue(_ name: String) -> String? {
    ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
  }

  private func isProviderAccountUnavailable(_ error: AdapterExecutionError) -> Bool {
    guard error.code == .providerError else {
      return false
    }
    let normalized = error.message.lowercased()
    return normalized.contains("credit balance")
      || normalized.contains("billing")
      || normalized.contains("insufficient_quota")
      || normalized.contains("quota")
  }

  private func assertOCRTranslation(
    _ output: AdapterExecutionOutput,
    sourceContainsAny sourceNeedles: [String],
    sourceAndTranslationContainsAny sharedNeedles: [String],
    translationContainsAny translationNeedles: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard case let .string(text) = output.payload["text"] else {
      return XCTFail("Expected text payload, got \(String(describing: output.payload["text"]))", file: file, line: line)
    }
    let normalized = text.lowercased()
    XCTAssertTrue(
      normalized.contains("ocr:"),
      "Expected output to include an OCR line, got: \(text)",
      file: file,
      line: line
    )
    XCTAssertTrue(
      normalized.contains("translation:"),
      "Expected output to include a translation line, got: \(text)",
      file: file,
      line: line
    )
    XCTAssertTrue(
      sourceNeedles.contains { normalized.contains($0.lowercased()) },
      "Expected OCR text to contain one of \(sourceNeedles), got: \(text)",
      file: file,
      line: line
    )
    XCTAssertTrue(
      sharedNeedles.contains { normalized.contains($0.lowercased()) },
      "Expected OCR/translation text to contain one of \(sharedNeedles), got: \(text)",
      file: file,
      line: line
    )
    XCTAssertTrue(
      translationNeedles.contains { normalized.contains($0.lowercased()) },
      "Expected translation to contain one of \(translationNeedles), got: \(text)",
      file: file,
      line: line
    )
  }
}
