import Foundation
import XCTest
@testable import RielaCore

final class AgentToolPolicyLiveIntegrationTests: XCTestCase {
  private let optInEnvironmentKey = "RIELA_TEST_LIVE_CODEX_TOOL_POLICY"
  private let searchPrompt = "Use web search. Do not answer from memory. Search for the official Swift.org page announcing Swift 6.3, and return the result URL."

  func testCodexWebSearchAndNonePresetsLive() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment[optInEnvironmentKey] == "1",
      "set RIELA_TEST_LIVE_CODEX_TOOL_POLICY=1 to run authenticated Codex probes")

    guard let codexURL = codexExecutableURL() else {
      throw XCTSkip("codex executable is unavailable on PATH")
    }
    let webSearchOutput = try runCodex(codexURL, preset: .webSearch)
    XCTAssertTrue(containsItemType("web_search", in: webSearchOutput),
      "web-search preset must produce a web_search item")

    let noToolsOutput = try runCodex(codexURL, preset: .noTools)
    XCTAssertFalse(containsItemType("web_search", in: noToolsOutput),
      "none preset must not produce a web_search item")
    XCTAssertFalse(containsItemType("command_execution", in: noToolsOutput),
      "none preset must not produce a command_execution item")
  }

  private func codexExecutableURL() -> URL? {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["CODEX_EXECUTABLE"], !path.isEmpty {
      return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }
    for directory in (environment["PATH"] ?? "").split(separator: ":") {
      let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("codex")
      if FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
      }
    }
    return nil
  }

  private func runCodex(_ executableURL: URL, preset: AgentToolPolicyPreset) throws -> String {
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let presetArguments = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      preset, backend: .codexAgent, sessionReuse: false
    ))
    process.executableURL = executableURL
    process.arguments = ["exec", "--json"] + presetArguments + ["--disable", "multi_agent", "-"]
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    try process.run()
    standardInput.fileHandleForWriting.write(Data("\(searchPrompt)\n".utf8))
    try standardInput.fileHandleForWriting.close()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let errorText = String(bytes: error, encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, "codex exec failed: \(errorText)")
    return String(bytes: output, encoding: .utf8) ?? ""
  }

  private func containsItemType(_ expectedType: String, in output: String) -> Bool {
    output.split(whereSeparator: \.isNewline).contains { line in
      guard let data = String(line).data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) else {
        return false
      }
      return containsType(expectedType, in: value)
    }
  }

  private func containsType(_ expectedType: String, in value: Any) -> Bool {
    if let object = value as? [String: Any] {
      if object["type"] as? String == expectedType {
        return true
      }
      return object.values.contains { containsType(expectedType, in: $0) }
    }
    if let values = value as? [Any] {
      return values.contains { containsType(expectedType, in: $0) }
    }
    return false
  }
}
