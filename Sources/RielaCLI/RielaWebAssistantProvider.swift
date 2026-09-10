import Foundation
import RielaAppSupport
import RielaCore

public enum RielaWebAssistantProvider {
  public static func resolve(_ vendor: RielaAppAssistantVendor, environment: [String: String]) throws -> RielaAppAssistantVendor {
    if vendor != .automatic {
      return vendor
    }
    if executablePath(named: "codex", environment: environment) != nil {
      return .codexCLI
    }
    if executablePath(named: "claude", environment: environment) != nil {
      return .claudeCodeCLI
    }
    if executablePath(named: "cursor-agent", environment: environment) != nil {
      return .cursorCLI
    }
    if environment["OPENAI_API_KEY"]?.isEmpty == false {
      return .openAIAPI
    }
    if environment["ANTHROPIC_API_KEY"]?.isEmpty == false || environment["CLAUDE_API_KEY"]?.isEmpty == false {
      return .anthropicAPI
    }
    if environment["CURSOR_API_KEY"]?.isEmpty == false {
      return .cursorAPI
    }
    throw AdapterExecutionError(.policyBlocked, "No assistant agent is available. Install codex/claude/cursor-agent or set OPENAI_API_KEY, ANTHROPIC_API_KEY, or CURSOR_API_KEY.")
  }

  public static func backend(for vendor: RielaAppAssistantVendor) -> NodeExecutionBackend {
    switch vendor {
    case .automatic, .codexCLI:
      .codexAgent
    case .claudeCodeCLI:
      .claudeCodeAgent
    case .cursorCLI:
      .cursorCliAgent
    case .openAIAPI:
      .officialOpenAISDK
    case .anthropicAPI:
      .officialAnthropicSDK
    case .cursorAPI:
      .officialCursorSDK
    }
  }

  private static func executablePath(named name: String, environment: [String: String]) -> String? {
    let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin")
      .split(separator: ":")
      .map(String.init)
    return paths
      .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

}
