import Foundation
import XCTest
@testable import RielaCore

final class AgentToolPolicyPresetContractTests: XCTestCase {
  func testPresetDecodingAndEncodingContract() throws {
    let noTools = try JSONDecoder().decode(AgentToolPolicy.self, from: Data(#"{"preset":"none"}"#.utf8))
    XCTAssertEqual(noTools.preset, .noTools)
    XCTAssertNil(noTools.mode)
    XCTAssertTrue(noTools.additionalArguments.isEmpty)
    XCTAssertTrue(noTools.codexArguments.isEmpty)
    XCTAssertTrue(noTools.claudeArguments.isEmpty)
    XCTAssertTrue(noTools.cursorArguments.isEmpty)

    let webSearch = try JSONDecoder().decode(AgentToolPolicy.self,
      from: Data(#"{"preset":"web-search","mode":"backend-arguments"}"#.utf8))
    XCTAssertEqual(webSearch.preset, .webSearch)
    XCTAssertEqual(webSearch.mode, .backendArguments)

    for value in ["shell", "None", ""] {
      XCTAssertThrowsError(try JSONDecoder().decode(AgentToolPolicy.self,
        from: Data(#"{"preset":"\#(value)"}"#.utf8)))
    }
    XCTAssertThrowsError(try JSONDecoder().decode(AgentNodePayload.self,
      from: Data(#"{"id":"node","model":"gpt","agentToolPolicy":{"preset":"shell"}}"#.utf8)))

    let legacyPolicy = AgentToolPolicy(mode: .backendArguments, codexArguments: ["--disable", "shell_tool"])
    let encodedLegacy = try JSONEncoder().encode(legacyPolicy)
    let legacyObject = try JSONDecoder().decode(JSONObject.self, from: encodedLegacy)
    XCTAssertNil(legacyObject["preset"])

    let presetPolicy = AgentToolPolicy(preset: .webSearch)
    let roundTrip = try JSONDecoder().decode(AgentToolPolicy.self, from: JSONEncoder().encode(presetPolicy))
    XCTAssertEqual(roundTrip, presetPolicy)
  }

  func testCodexPresetArgumentsAndSessionReuse() throws {
    let noToolsArguments = [
      "--ignore-user-config", "--ignore-rules", "--strict-config", "-c", #"web_search="disabled""#,
      "-c", "tools.experimental_request_user_input.enabled=false", "-c", "tools.update_plan.enabled=false",
      "-c", "mcp_servers={}", "--skip-git-repo-check", "--ephemeral",
      "--disable", "apps", "--disable", "auth_elicitation", "--disable", "browser_annotation_api",
      "--disable", "browser_use",
      "--disable", "browser_use_external", "--disable", "browser_use_full_cdp_access",
      "--disable", "computer_use", "--disable", "goals", "--disable", "image_generation",
      "--disable", "in_app_browser",
      "--disable", "memories",
      "--disable", "plugin_sharing", "--disable", "plugins", "--disable", "remote_plugin",
      "--disable", "shell_tool", "--disable", "unified_exec", "--disable", "unified_exec_tty",
      "--disable", "view_image"
    ]
    let resolvedNoTools = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      .noTools, backend: .codexAgent, sessionReuse: false))
    XCTAssertEqual(resolvedNoTools, noToolsArguments)

    var reuseArguments = noToolsArguments
    reuseArguments.remove(at: 12)
    XCTAssertEqual(AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .codexAgent, sessionReuse: true),
      reuseArguments)

    var webSearchArguments = noToolsArguments
    webSearchArguments[4] = #"web_search="live""#
    XCTAssertEqual(AgentToolPolicyPresetArguments.cliArguments(.webSearch, backend: .codexAgent, sessionReuse: false),
      webSearchArguments)

    for arguments in [noToolsArguments, webSearchArguments] {
      let disabledFeatures = arguments.enumerated().compactMap { index, argument -> String? in
        guard argument == "--disable", arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
      }
      XCTAssertFalse(disabledFeatures.contains("code_mode_host"))
      XCTAssertFalse(disabledFeatures.contains("code_mode_interrupt"))
    }
    XCTAssertTrue(zip(noToolsArguments, noToolsArguments.dropFirst()).contains {
      $0.0 == "-c" && $0.1 == #"web_search="disabled""#
    })
    XCTAssertTrue(zip(noToolsArguments, noToolsArguments.dropFirst()).contains {
      $0.0 == "--disable" && $0.1 == "shell_tool"
    })
    XCTAssertTrue(zip(noToolsArguments, noToolsArguments.dropFirst()).contains {
      $0.0 == "--disable" && $0.1 == "unified_exec"
    })
  }

  func testClaudePresetArguments() throws {
    XCTAssertEqual(AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .claudeCodeAgent, sessionReuse: false), [
      "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
      "--disable-slash-commands", "--setting-sources", ""
    ])
    XCTAssertEqual(AgentToolPolicyPresetArguments.cliArguments(.webSearch, backend: .claudeCodeAgent, sessionReuse: false), [
      "--tools", "WebSearch", "--allowedTools", "WebSearch", "--strict-mcp-config", "--mcp-config",
      #"{"mcpServers":{}}"#, "--disable-slash-commands", "--setting-sources", ""
    ])
    let noToolsArguments = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      .noTools, backend: .claudeCodeAgent, sessionReuse: false))
    XCTAssertEqual(noToolsArguments[1].count, 0)
  }

  func testSupportMatrixAndNonCliBackends() {
    let supported: [NodeExecutionBackend: Set<AgentToolPolicyPreset>] = [
      .codexAgent: Set(AgentToolPolicyPreset.allCases),
      .claudeCodeAgent: Set(AgentToolPolicyPreset.allCases),
      .cursorCliAgent: [],
      .officialOpenAISDK: Set(AgentToolPolicyPreset.allCases),
      .officialAnthropicSDK: Set(AgentToolPolicyPreset.allCases),
      .officialGeminiSDK: Set(AgentToolPolicyPreset.allCases),
      .officialCursorSDK: [.noTools]
    ]
    let nonCLIBackends: [NodeExecutionBackend] = [
      .cursorCliAgent, .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK
    ]

    for backend in NodeExecutionBackend.allCases {
      for preset in AgentToolPolicyPreset.allCases {
        XCTAssertEqual(AgentToolPolicyPresetArguments.isSupported(preset, backend: backend),
          supported[backend]?.contains(preset))
      }
    }
    for backend in nonCLIBackends {
      for preset in AgentToolPolicyPreset.allCases {
        XCTAssertNil(AgentToolPolicyPresetArguments.cliArguments(preset, backend: backend, sessionReuse: false))
      }
    }

    XCTAssertFalse(AgentToolPolicyPresetArguments.codexDisabledFeatures.isEmpty)
    XCTAssertEqual(Set(AgentToolPolicyPresetArguments.codexDisabledFeatures).count,
      AgentToolPolicyPresetArguments.codexDisabledFeatures.count)
    XCTAssertFalse(AgentToolPolicyPresetArguments.codexDisabledFeatures.contains("multi_agent"))
    XCTAssertTrue(AgentToolPolicyPresetArguments.codexSupportsSessionReuse)
  }
}
