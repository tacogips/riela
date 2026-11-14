import Foundation

public enum AgentToolPolicyPresetArguments {
  // Verified against codex-cli 0.164.0. Keep code_mode_host enabled because it
  // routes tool calls; code_mode stays off by default, so this exposes no code execution.
  // `code_mode_interrupt` stays enabled as part of the tool-routing host.
  // Keep `unified_exec`: the CLI accepts it, although features list still says true.
  // Features are in argv order; multi_agent stays excluded because the adapter owns it.
  public static let codexDisabledFeatures = [
    "apps",
    "auth_elicitation",
    "browser_annotation_api",
    "browser_use",
    "browser_use_external",
    "browser_use_full_cdp_access",
    "computer_use",
    "goals",
    "image_generation",
    "in_app_browser",
    "memories",
    "plugin_sharing",
    "plugins",
    "remote_plugin",
    "shell_tool",
    "unified_exec",
    "unified_exec_tty",
    "view_image"
  ]

  public static let codexSupportsSessionReuse = true

  public static func isSupported(_ preset: AgentToolPolicyPreset, backend: NodeExecutionBackend) -> Bool {
    switch (preset, backend) {
    case (_, .codexAgent), (_, .claudeCodeAgent), (_, .officialOpenAISDK),
         (_, .officialAnthropicSDK), (_, .officialGeminiSDK):
      true
    case (.noTools, .officialCursorSDK):
      true
    case (.webSearch, .officialCursorSDK), (_, .cursorCliAgent):
      false
    }
  }

  public static func cliArguments(
    _ preset: AgentToolPolicyPreset,
    backend: NodeExecutionBackend,
    sessionReuse: Bool
  ) -> [String]? {
    switch backend {
    case .codexAgent:
      codexArguments(preset, sessionReuse: sessionReuse)
    case .claudeCodeAgent:
      claudeArguments(preset)
    case .cursorCliAgent, .officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK, .officialCursorSDK:
      nil
    }
  }

  private static func codexArguments(_ preset: AgentToolPolicyPreset, sessionReuse: Bool) -> [String] {
    var arguments = [
      "--ignore-user-config",
      "--ignore-rules",
      "--strict-config",
      "-c",
      preset == .noTools ? #"web_search="disabled""# : #"web_search="live""#,
      "-c",
      "tools.experimental_request_user_input.enabled=false",
      "-c",
      "tools.update_plan.enabled=false",
      "-c",
      "mcp_servers={}",
      "--skip-git-repo-check"
    ]
    if !sessionReuse {
      arguments.append("--ephemeral")
    }
    for feature in codexDisabledFeatures {
      arguments.append(contentsOf: ["--disable", feature])
    }
    return arguments
  }

  private static func claudeArguments(_ preset: AgentToolPolicyPreset) -> [String] {
    var arguments = ["--tools", preset == .noTools ? "" : "WebSearch"]
    if preset == .webSearch {
      arguments.append(contentsOf: ["--allowedTools", "WebSearch"])
    }
    arguments.append(contentsOf: [
      "--strict-mcp-config",
      "--mcp-config",
      #"{"mcpServers":{}}"#,
      "--disable-slash-commands",
      "--setting-sources",
      ""
    ])
    return arguments
  }
}
