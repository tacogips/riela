import XCTest
@testable import RielaCore

final class AgentToolPolicyResolutionTests: XCTestCase {
  func testBindsArgumentsAsSingleValuesWithoutReinterpretingSuppliedTemplates() throws {
    let policy = AgentToolPolicy(codexArguments: ["-c", "{{catalogArgument}}", "--disable", "shell_tool"])
    let supplied = #"model_catalog_json="/path with spaces/{{data}}.json""#
    let result = try resolveAgentToolPolicy(policy, variables: ["catalogArgument": .string(supplied), "data": .string("ignore")])
    XCTAssertEqual(result?.codexArguments, ["-c", supplied, "--disable", "shell_tool"])
    XCTAssertEqual(policy.codexArguments[1], "{{catalogArgument}}")
  }

  func testMissingNullNulAndOversizedBindingsFailClosed() throws {
    let policy = AgentToolPolicy(codexArguments: ["{{catalogArgument}}"])
    for variables: JSONObject in [[:], ["catalogArgument": .null], ["catalogArgument": .string("a\0b")],
      ["catalogArgument": .string(String(repeating: "a", count: 65_537))]] {
      XCTAssertThrowsError(try resolveAgentToolPolicy(policy, variables: variables))
    }
  }

  func testTrustedSourcesExcludeUpstreamAgentOutput() throws {
    let policy = AgentToolPolicy(codexArguments: ["-c", "{{catalogArgument}}"])
    let input: JSONObject = ["catalogArgument": .string("model_catalog_json=/catalog.json")]
    let trusted = agentToolPolicyTrustedVariables(nodeVariables: [:], workflowInput: input)
    // Workflow input binds, also through runtimeVariables.
    XCTAssertEqual(try resolveAgentToolPolicy(policy, variables: input, trustedVariables: trusted)?.codexArguments,
      ["-c", "model_catalog_json=/catalog.json"])
    let viaRuntime = AgentToolPolicy(codexArguments: ["-c", "{{runtimeVariables.catalogArgument}}"])
    XCTAssertEqual(try resolveAgentToolPolicy(viaRuntime, variables: ["runtimeVariables": .object(input)],
      trustedVariables: trusted)?.codexArguments.last, "model_catalog_json=/catalog.json")
    // A value present only in upstream output (merged variables) is not a source.
    let upstreamOnly: JSONObject = ["catalogArgument": .string(#"sandbox_mode="danger-full-access""#)]
    XCTAssertThrowsError(try resolveAgentToolPolicy(policy, variables: upstreamOnly,
      trustedVariables: agentToolPolicyTrustedVariables(nodeVariables: [:], workflowInput: [:]))) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .templateResolutionFailed)
    }
    // Upstream output shadowing a trusted key with a different value is refused.
    XCTAssertThrowsError(try resolveAgentToolPolicy(policy, variables: upstreamOnly, trustedVariables: trusted)) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked)
    }
    // Node variables are authored, so they bind.
    let node = agentToolPolicyTrustedVariables(nodeVariables: ["catalogArgument": .string("a=b")], workflowInput: [:])
    XCTAssertEqual(try resolveAgentToolPolicy(policy, variables: ["catalogArgument": .string("a=b")],
      trustedVariables: node)?.codexArguments.last, "a=b")
  }

  func testTemplateValuesCannotStartOptionsOrAddLineBreaks() throws {
    for (template, value) in [("{{value}}", "--dangerously-bypass-approvals-and-sandbox"), ("{{value}}", "-cx=y"),
      ("key={{value}}", "a\nb"), ("{{value}}", "a\r--flag")] {
      XCTAssertThrowsError(try resolveAgentToolPolicy(AgentToolPolicy(codexArguments: [template]),
        variables: ["value": .string(value)])) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .policyBlocked, "\(template) <- \(value)")
      }
    }
    // An authored literal option and a literal prefix keep working.
    let accepted = try resolveAgentToolPolicy(AgentToolPolicy(codexArguments: ["--profile={{value}}", "key={{value}}"]),
      variables: ["value": .string("-leading-dash-is-data")])
    XCTAssertEqual(accepted?.codexArguments, ["--profile=-leading-dash-is-data", "key=-leading-dash-is-data"])
  }

  func testPresetCodexNoToolsExpandsAndPreservesMode() throws {
    for mode: AgentToolPolicyMode? in [nil, .backendArguments] {
      let result = try XCTUnwrap(resolveAgentToolPolicy(
        AgentToolPolicy(mode: mode, preset: .noTools), executionBackend: .codexAgent, variables: [:]
      ))
      XCTAssertEqual(result.codexArguments,
        AgentToolPolicyPresetArguments.cliArguments(.noTools, backend: .codexAgent, sessionReuse: false))
      XCTAssertNil(result.preset)
      XCTAssertEqual(result.additionalArguments, [])
      XCTAssertEqual(result.mode, mode)
    }
  }

  func testPresetCodexWebSearchAppendsAuthoredArgumentsInOrder() throws {
    let policy = AgentToolPolicy(additionalArguments: ["--a"], codexArguments: ["--b"], preset: .webSearch)
    let result = try XCTUnwrap(resolveAgentToolPolicy(policy, executionBackend: .codexAgent, variables: [:]))
    let presetArguments = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      .webSearch, backend: .codexAgent, sessionReuse: false
    ))
    XCTAssertEqual(result.codexArguments, presetArguments + ["--a", "--b"])
    XCTAssertTrue(result.additionalArguments.isEmpty)
    XCTAssertNil(result.preset)
  }

  func testPresetClaudeWebSearchAppendsAuthoredArgumentsAndLeavesCodexArgumentsAlone() throws {
    let policy = AgentToolPolicy(additionalArguments: ["--a"], codexArguments: ["--b"],
      claudeArguments: ["--c"], preset: .webSearch)
    let result = try XCTUnwrap(resolveAgentToolPolicy(policy, executionBackend: .claudeCodeAgent, variables: [:]))
    let presetArguments = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      .webSearch, backend: .claudeCodeAgent, sessionReuse: false
    ))
    XCTAssertEqual(result.claudeArguments, presetArguments + ["--a", "--c"])
    XCTAssertEqual(result.codexArguments, ["--b"])
    XCTAssertTrue(result.additionalArguments.isEmpty)
    XCTAssertNil(result.preset)
  }

  func testPresetCodexSessionReuseOmitsEphemeralArgument() throws {
    let result = try XCTUnwrap(resolveAgentToolPolicy(
      AgentToolPolicy(preset: .noTools), executionBackend: .codexAgent, sessionReuse: true, variables: [:]
    ))
    XCTAssertFalse(result.codexArguments.contains("--ephemeral"))
  }

  func testPresetTemplatesRenderAfterLiteralPresetArguments() throws {
    let policy = AgentToolPolicy(codexArguments: ["-c", "key={{x}}"], preset: .noTools)
    let trusted: JSONObject = ["x": .string("value")]
    let result = try XCTUnwrap(resolveAgentToolPolicy(policy, executionBackend: .codexAgent, variables: trusted,
      trustedVariables: trusted))
    let presetArguments = try XCTUnwrap(AgentToolPolicyPresetArguments.cliArguments(
      .noTools, backend: .codexAgent, sessionReuse: false
    ))
    XCTAssertEqual(result.codexArguments, presetArguments + ["-c", "key=value"])
    XCTAssertTrue(result.codexArguments.contains("mcp_servers={}"))

    let claude = try XCTUnwrap(resolveAgentToolPolicy(AgentToolPolicy(preset: .noTools),
      executionBackend: .claudeCodeAgent, variables: [:]))
    XCTAssertTrue(claude.claudeArguments.contains(#"{"mcpServers":{}}"#))
  }

  func testPresetSDKsKeepPolicyAndCursorNoneIsSupported() throws {
    for backend: NodeExecutionBackend in [.officialOpenAISDK, .officialAnthropicSDK, .officialGeminiSDK] {
      let policy = AgentToolPolicy(additionalArguments: ["--a"], codexArguments: ["--b"], preset: .webSearch)
      XCTAssertEqual(try resolveAgentToolPolicy(policy, executionBackend: backend, variables: [:]), policy)
    }
    let cursorPolicy = AgentToolPolicy(preset: .noTools)
    XCTAssertEqual(try resolveAgentToolPolicy(cursorPolicy, executionBackend: .officialCursorSDK, variables: [:]),
      cursorPolicy)
  }

  func testPresetWithoutPresetKeepsAdditionalArgumentsSeparate() throws {
    let policy = AgentToolPolicy(additionalArguments: ["--a"], codexArguments: ["--b"])
    XCTAssertEqual(try resolveAgentToolPolicy(policy, executionBackend: .codexAgent, variables: [:]), policy)
  }

  func testPresetUnsupportedBackendsAndMissingBackendFailClosed() {
    for (policy, backend) in [
      (AgentToolPolicy(preset: .webSearch), NodeExecutionBackend.officialCursorSDK),
      (AgentToolPolicy(preset: .noTools), .cursorCliAgent)
    ] {
      XCTAssertThrowsError(try resolveAgentToolPolicy(policy, executionBackend: backend, variables: [:])) { error in
        XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
      }
    }
    XCTAssertThrowsError(try resolveAgentToolPolicy(AgentToolPolicy(preset: .noTools), variables: [:])) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidInput)
    }
  }

  func testRunnerNeverBindsToolPolicyFromUpstreamAgentOutput() async throws {
    let workflow = WorkflowDefinition(workflowId: "tool-policy-trust", defaults: .init(nodeTimeoutMs: 30_000, maxLoopIterations: 1),
      entryStepId: "produce", nodeRegistry: [.init(id: "produce", nodeFile: "produce.json"), .init(id: "consume", nodeFile: "consume.json")],
      steps: [.init(id: "produce", nodeId: "produce", transitions: [.init(toStepId: "consume", label: "always")]),
        .init(id: "consume", nodeId: "consume")],
      nodes: [.init(id: "produce", nodeFile: "produce.json"), .init(id: "consume", nodeFile: "consume.json")])
    let schema: JSONObject = ["type": .string("object"),
      "properties": .object(["catalogArgument": .object(["type": .string("string")])])]
    let payloads: [String: AgentNodePayload] = [
      "produce": .init(id: "produce", executionBackend: .codexAgent, model: "fixture", agentSandbox: .readOnly,
        output: .init(jsonSchema: schema, maxValidationAttempts: 1)),
      "consume": .init(id: "consume", executionBackend: .codexAgent, model: "fixture", agentSandbox: .readOnly,
        agentToolPolicy: .init(codexArguments: ["-c", "{{catalogArgument}}"]))
    ]
    let injected: JSONObject = ["catalogArgument": .string(#"sandbox_mode="danger-full-access""#)]
    // Upstream output only: no trusted source binds the template.
    for (variables, upstream, expected) in [
      (JSONObject(), injected, AdapterExecutionErrorCode.templateResolutionFailed),
      (["catalogArgument": .string("model_catalog_json=/catalog.json")], injected, .policyBlocked)
    ] {
      let adapter = ToolPolicyRecordingAdapter(upstream: upstream)
      do {
        let result = try await DeterministicWorkflowRunner(adapter: adapter).run(.init(workflow: workflow,
          nodePayloads: payloads, variables: variables))
        XCTFail("tool policy bound from upstream output: \(result.session.status)")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, expected)
      }
      let consumed = await adapter.consumeArguments
      XCTAssertNil(consumed, "consume step must not reach the adapter")
    }
    let adapter = ToolPolicyRecordingAdapter(upstream: [:])
    let result = try await DeterministicWorkflowRunner(adapter: adapter).run(.init(workflow: workflow,
      nodePayloads: payloads, variables: ["catalogArgument": .string("model_catalog_json=/catalog.json")]))
    XCTAssertEqual(result.session.status, .completed)
    let consumed = await adapter.consumeArguments
    XCTAssertEqual(consumed, ["-c", "model_catalog_json=/catalog.json"])
  }
}

private actor ToolPolicyRecordingAdapter: NodeAdapter {
  let upstream: JSONObject
  var consumeArguments: [String]?
  init(upstream: JSONObject) { self.upstream = upstream }
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    if input.node.id == "consume" { consumeArguments = input.node.agentToolPolicy?.codexArguments }
    return .init(provider: "fixture", model: "fixture", promptText: "", completionPassed: true,
      payload: input.node.id == "produce" ? upstream : ["done": .bool(true)])
  }
}
