import Foundation
import RielaCore
import XCTest
@testable import RielaAdapters

private actor CapabilityProbeRunner: LocalProcessRunning {
  func run(
    configuration: LocalProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalProcessResult {
    if configuration.arguments == ["--version"] {
      return LocalProcessResult(stdout: "tool 1.2.3\n", stderr: "", terminationStatus: 0)
    }
    let authenticated = configuration.executableURL.lastPathComponent != "claude"
    return LocalProcessResult(
      stdout: "",
      stderr: authenticated ? "" : "not logged in",
      terminationStatus: authenticated ? 0 : 1
    )
  }
}

final class BackendCapabilityProbeTests: XCTestCase {
  func testProbeCoversAllBackendsWithoutExposingCredentialValues() async throws {
    let now = Date(timeIntervalSinceReferenceDate: 100)
    let capabilities = await BackendCapabilityProbe(runner: CapabilityProbeRunner()).probeAll(
      environment: [
        "OPENAI_API_KEY": "secret-openai",
        "GEMINI_API_KEY": "secret-gemini"
      ],
      now: now,
      executableURLs: [
        .codexAgent: URL(fileURLWithPath: "/test/codex"),
        .claudeCodeAgent: URL(fileURLWithPath: "/test/claude"),
        .cursorCliAgent: URL(fileURLWithPath: "/test/cursor-agent")
      ]
    )
    XCTAssertEqual(capabilities.map(\.backend), NodeExecutionBackend.allCases)
    XCTAssertEqual(capabilities.first { $0.backend == .codexAgent }?.authentication, .available)
    XCTAssertEqual(capabilities.first { $0.backend == .claudeCodeAgent }?.authentication, .failed)
    XCTAssertEqual(capabilities.first { $0.backend == .cursorCliAgent }?.authentication, .unknown)
    XCTAssertEqual(capabilities.first { $0.backend == .officialOpenAISDK }?.availability, .available)
    XCTAssertEqual(capabilities.first { $0.backend == .officialAnthropicSDK }?.availability, .unavailable)
    let encoded = String(data: try JSONEncoder().encode(capabilities), encoding: .utf8) ?? ""
    XCTAssertFalse(encoded.contains("secret-openai"))
    XCTAssertFalse(encoded.contains("secret-gemini"))
  }
}
