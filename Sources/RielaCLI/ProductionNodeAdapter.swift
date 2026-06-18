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

func makeScenarioBackedStdioNodeExecutor(
  scenarioPath: String?,
  workingDirectory: String
) throws -> any WorkflowStdioNodeExecuting {
  let fallback = LocalWorkflowStdioNodeExecutor()
  guard let scenarioPath else {
    return fallback
  }
  let scenario = try WorkflowMockScenarioLoader().loadScenario(at: absoluteURL(
    scenarioPath,
    relativeTo: URL(fileURLWithPath: workingDirectory)
  ).path)
  return ScenarioWorkflowStdioNodeExecutor(scenario: scenario, fallback: fallback)
}

actor ScenarioWorkflowStdioNodeExecutor: WorkflowStdioNodeExecuting {
  private let scenario: WorkflowMockScenario
  private let fallback: any WorkflowStdioNodeExecuting
  private var counts: [String: Int] = [:]

  init(scenario: WorkflowMockScenario, fallback: any WorkflowStdioNodeExecuting) {
    self.scenario = scenario
    self.fallback = fallback
  }

  func execute(
    _ input: WorkflowStdioNodeExecutionInput,
    context: AdapterExecutionContext
  ) async throws -> WorkflowStdioNodeExecutionResult {
    guard let sequence = scenario.responses[input.nodeId] else {
      return try await fallback.execute(input, context: context)
    }
    let count = (counts[input.nodeId] ?? 0) + 1
    counts[input.nodeId] = count
    let response = sequence.isEmpty ? MockNodeResponse() : sequence[min(count - 1, sequence.count - 1)]
    if response.fail == true {
      throw AdapterExecutionError(.providerError, "scenario forced failure for stdio node '\(input.nodeId)'")
    }
    return WorkflowStdioNodeExecutionResult(payload: response.payload ?? [:])
  }
}

struct BuiltinWorkflowAddonResolver: WorkflowAddonResolving {
  func execute(_ input: WorkflowAddonExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    guard input.addon.name.hasPrefix("riela/") else {
      throw AdapterExecutionError(.providerError, "missing add-on resolver for '\(input.addon.name)'")
    }
    if input.addon.name == "riela/chat-persona-router" {
      return AdapterExecutionOutput(
        provider: "riela-builtin-addon",
        model: input.addon.name,
        promptText: "",
        completionPassed: true,
        when: ["target_yui": true, "target_mika": false, "target_rina": false],
        payload: [
          "status": .string("ok"),
          "addon": .string(input.addon.name),
          "target": .string("yui"),
          "target_yui": .bool(true),
          "target_mika": .bool(false),
          "target_rina": .bool(false),
        ]
      )
    }
    return AdapterExecutionOutput(
      provider: "riela-builtin-addon",
      model: input.addon.name,
      promptText: "",
      completionPassed: true,
      payload: [
        "status": .string("ok"),
        "addon": .string(input.addon.name),
        "stepId": .string(input.stepId),
      ]
    )
  }
}

private func environmentValue(_ key: String) -> String? {
  guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
    return nil
  }
  return value
}
