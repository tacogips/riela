import ClaudeCodeAgent
import CodexAgent
import CursorCLIAgent
import Foundation
import RielaAdapters
import RielaCore

func makeProductionNodeAdapter() -> any NodeAdapter {
  DispatchingNodeAdapter(
    configuration: DispatchingNodeAdapterConfiguration(
      registry: [
        .codexAgent: {
          CodexAgentAdapter(
            executableName: environmentValue("RIELA_CODEX_AGENT_EXECUTABLE") ?? "codex"
          )
        },
        .claudeCodeAgent: {
          ClaudeCodeAgentAdapter(
            executableName: environmentValue("RIELA_CLAUDE_CODE_AGENT_EXECUTABLE") ?? "claude"
          )
        },
        .cursorCliAgent: {
          CursorCLIAgentAdapter(
            executableName: environmentValue("RIELA_CURSOR_CLI_AGENT_EXECUTABLE") ?? "cursor-agent"
          )
        },
      ]
    )
  )
}

func makeScenarioBackedNodeAdapter(
  scenarioPath: String?,
  workingDirectory: String,
  autoImprove: Bool = false
) throws -> any NodeAdapter {
  guard let scenarioPath else {
    return makeProductionNodeAdapter()
  }
  let fallback = DeterministicLocalNodeAdapter()
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return autoImprove
    ? SupervisedScenarioNodeAdapter(scenario: scenario, fallback: fallback)
    : ScenarioNodeAdapter(scenario: scenario, fallback: fallback)
}

private func environmentValue(_ key: String) -> String? {
  guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
    return nil
  }
  return value
}
