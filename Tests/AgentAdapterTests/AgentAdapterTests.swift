import Darwin
import Foundation
import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore
final class AgentAdapterTests: XCTestCase {
  func testAdapterDeletionReadinessKeepsOfficialCursorSDKSeparateFromCursorCLI() throws {
    let codex = try XCTUnwrap(AdapterDeletionReadiness.domain(for: .codexAgent))
    let claude = try XCTUnwrap(AdapterDeletionReadiness.domain(for: .claudeCodeAgent))
    let cursorCLI = try XCTUnwrap(AdapterDeletionReadiness.domain(for: .cursorCliAgent))
    let cursorSDK = try XCTUnwrap(AdapterDeletionReadiness.domain(for: .officialCursorSDK))

    XCTAssertEqual(codex.status, .implemented)
    XCTAssertEqual(claude.status, .implemented)
    XCTAssertEqual(cursorCLI.status, .implemented)
    XCTAssertEqual(cursorSDK.status, .deletionBlocked)
    XCTAssertTrue(cursorSDK.notes.contains("not aliased to cursor-cli-agent"))
    XCTAssertNotEqual(cursorCLI.backend, cursorSDK.backend)
  }

  func testCodexAgentProducesProviderOutput() async throws {
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: "done"))
    let output = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.provider, "codex-agent")
    XCTAssertEqual(output.payload["text"], .string("done"))
  }

  func testClaudeAgentProducesProviderOutput() async throws {
    let adapter = ClaudeCodeAgentAdapter(runner: CapturingRunner(output: "done"))
    let output = try await adapter.execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.provider, "claude-code-agent")
  }

  func testCursorAgentProducesProviderOutput() async throws {
    let adapter = CursorCLIAgentAdapter(runner: CapturingRunner(output: "done"))
    let output = try await adapter.execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.provider, "cursor-cli-agent")
  }

  func testCodexCommandBuilderOwnsExactArgvAndPromptBoundary() async throws {
    let runner = RecordingRunner(output: "done")
    let deadline = Date(timeIntervalSinceNow: 10)
    let adapter = CodexAgentAdapter(
      executableName: "codex-dev",
      runner: runner,
      environment: ["CODEX_HOME": "/tmp/codex-home"],
      additionalArguments: ["--sandbox", "workspace-write"]
    )

    _ = try await adapter.execute(
      input(
        backend: .codexAgent,
        effort: .high,
        workingDirectory: "/tmp/work",
        systemPromptText: "system",
        variables: [
          "codexAdditionalArgs": .array([.string("--dangerously-bypass-approvals-and-sandbox")])
        ],
        arguments: [
          "imagePaths": .array([.string("/tmp/argument.png"), .string("/tmp/duplicate.png")])
        ],
        mergedVariables: [
          "imagePaths": .array([.string("/tmp/screenshot.png"), .string("/tmp/duplicate.png")]),
          "message": .object([
            "attachments": .array([
              .object(["kind": .string("image"), "localPath": .string("/tmp/nested.png")]),
              .object([
                "mediaType": .string("image/png"),
                "source": .object(["downloadPath": .string("/tmp/source.png")])
              ])
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext(deadline: deadline)
    )

    let runs = await runner.runs()
    XCTAssertEqual(runs.prefix(2).map(\.configuration.arguments), [["codex-dev", "--version"], ["codex-dev", "login", "status"]])
    let preflightRun = try XCTUnwrap(runs.first)
    XCTAssertEqual(preflightRun.configuration.environment["RIELA_AGENT_BACKEND"], "codex-agent")
    XCTAssertEqual(preflightRun.configuration.environment["CODEX_HOME"], "/tmp/codex-home")
    let run = try XCTUnwrap(runs.last)
    XCTAssertEqual(run.configuration.executableURL.path, "/usr/bin/env")
    XCTAssertEqual(
      run.configuration.arguments,
      [
        "codex-dev", "exec", "--json", "--model", "model", "-c", #"model_reasoning_effort="high""#,
        "--sandbox", "workspace-write", "--dangerously-bypass-approvals-and-sandbox", "--image",
        "/tmp/screenshot.png", "--image", "/tmp/duplicate.png", "--image", "/tmp/nested.png",
        "--image", "/tmp/source.png", "--image", "/tmp/argument.png", "--", "-"
      ]
    )
    XCTAssertEqual(run.configuration.environment["RIELA_AGENT_BACKEND"], "codex-agent")
    XCTAssertEqual(run.configuration.environment["CODEX_HOME"], "/tmp/codex-home")
    XCTAssertEqual(run.configuration.workingDirectoryURL?.path, "/tmp/work")
    XCTAssertEqual(run.stdin, "system\n\nhello")
    XCTAssertEqual(run.deadline, deadline)
  }

  func testCodexCommandBuilderTerminatesOptionsBeforeFlagLikePrompt() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CodexAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(backend: .codexAgent, promptText: "--model other"),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let run = try XCTUnwrap(runs.last)
    XCTAssertEqual(Array(run.configuration.arguments.suffix(2)), ["--", "-"])
    XCTAssertEqual(run.stdin, "--model other")
    XCTAssertEqual(run.configuration.arguments.filter { $0 == "--model" }.count, 1)
  }

  func testCodexProcessCommandBuilderRejectsArgvPromptWhenStdinIsPiped() throws {
    let legacyArguments = ["codex", "exec", "--json", "--model", "gpt-5.5", "--", "hello"]

    XCTAssertThrowsError(
      try CodexProcessCommandBuilder.validatePipedStdinExecPromptTransport(arguments: legacyArguments)
    ) { error in
      guard let adapterError = error as? AdapterExecutionError else {
        XCTFail("Expected AdapterExecutionError, got \(error)")
        return
      }
      XCTAssertEqual(adapterError.code, .policyBlocked)
      XCTAssertTrue(adapterError.message.contains("prompt cannot be passed as argv when stdin is piped"))
    }
  }

  func testCodexProcessCommandBuilderAllowsStdinPromptMarkerWhenStdinIsPiped() throws {
    let arguments = ["codex", "exec", "--json", "--model", "gpt-5.5", "--", "-"]

    XCTAssertNoThrow(
      try CodexProcessCommandBuilder.validatePipedStdinExecPromptTransport(arguments: arguments)
    )
  }

  func testCodexProcessCommandBuilderMatchesReferenceExecCompatibilityArgs() {
    let args = CodexProcessCommandBuilder.buildExecArguments(
      prompt: "test prompt",
      options: CodexProcessOptions(
        model: "gpt-5.5",
        sandbox: "workspace-write",
        approvalMode: "on-failure",
        fullAuto: true,
        configOverrides: [#"model_reasoning_effort="high""#],
        additionalArguments: ["--skip-git-repo-check"]
      ),
      terminatePromptWithDoubleDash: false
    )

    XCTAssertEqual(
      args,
      [
        "exec",
        "--json",
        "--model",
        "gpt-5.5",
        "--dangerously-bypass-approvals-and-sandbox",
        "--sandbox",
        "workspace-write",
        "-c",
        #"model_reasoning_effort="high""#,
        "--skip-git-repo-check",
        "test prompt"
      ]
    )
  }

  func testCodexProcessCommandBuilderBuildsResumeCompatibilityArgs() {
    let args = CodexProcessCommandBuilder.buildResumeArguments(
      sessionId: "session-1",
      prompt: "resume prompt",
      options: CodexProcessOptions(
        model: "gpt-5.5",
        sandbox: "workspace-write",
        fullAuto: true,
        images: ["./one.png"],
        configOverrides: [#"model_reasoning_effort="high""#],
        additionalArguments: ["--skip-git-repo-check"]
      )
    )

    XCTAssertEqual(
      args,
      [
        "exec",
        "--sandbox",
        "workspace-write",
        "resume",
        "--json",
        "--model",
        "gpt-5.5",
        "--dangerously-bypass-approvals-and-sandbox",
        "-c",
        #"model_reasoning_effort="high""#,
        "--skip-git-repo-check",
        "--image",
        "./one.png",
        "--",
        "session-1",
        "resume prompt"
      ]
    )
  }

  func testCodexProcessCommandBuilderBuildsForkArgsAndEnvironmentOverlay() {
    let args = CodexProcessCommandBuilder.buildForkArguments(
      sessionId: "session-1",
      nthMessage: 3,
      options: CodexProcessOptions(
        model: "gpt-5.5",
        sandbox: "read-only",
        approvalMode: "always",
        fullAuto: true,
        configOverrides: [#"model_reasoning_effort="medium""#],
        additionalArguments: ["--skip-git-repo-check"]
      )
    )
    let environment = CodexProcessCommandBuilder.buildEnvironment(
      base: ["PATH": "/bin", "CODEX_AGENT_TEST_ENV": "old"],
      options: CodexProcessOptions(environmentVariables: ["CODEX_AGENT_TEST_ENV": "typed-env-value"])
    )

    XCTAssertEqual(
      args,
      [
        "fork",
        "session-1",
        "--nth-message",
        "3",
        "--model",
        "gpt-5.5",
        "--dangerously-bypass-approvals-and-sandbox",
        "--sandbox",
        "read-only",
        "-c",
        #"model_reasoning_effort="medium""#,
        "--skip-git-repo-check"
      ]
    )
    XCTAssertFalse(args.contains("--ask-for-approval"))
    XCTAssertEqual(environment["PATH"], "/bin")
    XCTAssertEqual(environment["CODEX_AGENT_TEST_ENV"], "typed-env-value")
  }

  func testCodexAgentEventNormalizerPortsSdkNormalizedEvents() {
    var normalizer = CodexAgentEventNormalizer()

    let started = normalizer.normalize(
      [
        "type": .string("session_meta"),
        "payload": .object(["meta": .object(["id": .string("codex-session-1")])])
      ],
      includeSessionStarted: true
    )
    XCTAssertEqual(started, [
      CodexAgentNormalizedEvent(type: "session.started", sessionId: "codex-session-1", payload: ["resumed": .bool(false)])
    ])

    let messageEvents = normalizer.normalize(
      [
        "type": .string("response_item"),
        "payload": .object([
          "type": .string("message"),
          "role": .string("assistant"),
          "content": .array([
            .object(["type": .string("output_text"), "text": .string("hello")])
          ])
        ])
      ],
      fallbackSessionId: "codex-session-1"
    )
    XCTAssertEqual(messageEvents.map(\.type), ["assistant.delta", "assistant.snapshot"])
    XCTAssertEqual(messageEvents.last?.payload["content"], .string("hello"))

    let toolCall = normalizer.normalize(
      [
        "type": .string("response_item"),
        "payload": .object([
          "type": .string("function_call"),
          "name": .string("read_file"),
          "call_id": .string("call-1"),
          "arguments": .string(#"{"path":"README.md"}"#)
        ])
      ],
      fallbackSessionId: "codex-session-1"
    )
    XCTAssertEqual(toolCall.first?.type, "tool.call")
    XCTAssertEqual(toolCall.first?.payload["name"], .string("read_file"))
    XCTAssertEqual(toolCall.first?.payload["input"], .object(["path": .string("README.md")]))

    let toolResult = normalizer.normalize(
      [
        "type": .string("response_item"),
        "payload": .object([
          "type": .string("function_call_output"),
          "call_id": .string("call-1"),
          "output": .object(["status": .string("ok")])
        ])
      ],
      fallbackSessionId: "codex-session-1"
    )
    XCTAssertEqual(toolResult.first?.type, "tool.result")
    XCTAssertEqual(toolResult.first?.payload["name"], .string("read_file"))
    XCTAssertEqual(toolResult.first?.payload["isError"], .bool(false))
  }

  func testClaudeCommandBuilderOwnsPrintModeArgvAndAttachmentPrompt() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(
      executableName: "claude-dev",
      runner: runner,
      permissionMode: .plan,
      environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-home"],
      additionalArguments: ["--verbose"]
    )

    _ = try await adapter.execute(
      input(
        backend: .claudeCodeAgent,
        effort: .medium,
        systemPromptText: "system",
        variables: [
          "attachmentPaths": .array([.string("/tmp/b/note.txt")]),
          "claudeAdditionalArgs": .array([.string("--allowedTools"), .string("Read")])
        ],
        arguments: [
          "imagePaths": .array([.string("/tmp/a/image.png")])
        ],
        mergedVariables: [
          "message": .object([
            "attachments": .array([
              .object(["contentType": .string("image/jpeg"), "imagePath": .string("/tmp/c/photo.jpg")])
            ])
          ])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertEqual(runs.prefix(2).map(\.configuration.arguments), [["claude-dev", "--version"], ["claude-dev", "auth", "status"]])
    XCTAssertEqual(runs.first?.configuration.environment["RIELA_AGENT_BACKEND"], "claude-code-agent")
    XCTAssertEqual(runs.first?.configuration.environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-home")
    let run = try XCTUnwrap(runs.last)
    XCTAssertEqual(
      run.configuration.arguments,
      [
        "claude-dev", "-p", "--output-format", "text", "--model", "model", "--effort", "medium",
        "--permission-mode", "plan", "--add-dir", "/tmp/a", "--add-dir", "/tmp/b", "--add-dir",
        "/tmp/c", "--verbose", "--allowedTools", "Read"
      ]
    )
    XCTAssertEqual(run.configuration.environment["RIELA_AGENT_BACKEND"], "claude-code-agent")
    XCTAssertEqual(run.configuration.environment["CLAUDE_CONFIG_DIR"], "/tmp/claude-home")
    XCTAssertEqual(
      run.stdin,
      """
      System instruction:
      system

      User instruction:
      hello

      Attached files:
      - /tmp/b/note.txt
      - /tmp/c/photo.jpg
      - /tmp/a/image.png
      """
    )
  }

  func testCursorCommandBuilderOwnsCursorOptionsWithoutCoreLeakage() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CursorCLIAgentAdapter(
      executableName: "cursor-dev",
      runner: runner,
      mode: .ask,
      environment: ["CURSOR_CONFIG_DIR": "/tmp/cursor-home"],
      additionalArguments: ["--force"]
    )

    _ = try await adapter.execute(
      input(
        backend: .cursorCliAgent,
        effort: .low,
        systemPromptText: "system",
        variables: [
          "cursorAdditionalArgs": .array([.string("--workspace"), .string("/tmp/work")])
        ],
        mergedVariables: [
          "imagePaths": .array([.string("/tmp/screenshot.png")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertEqual(
      runs.prefix(2).map(\.configuration.arguments),
      [
        ["cursor-dev", "--version"],
        ["cursor-dev", "--print", "--output-format", "text", "--model", "model", "--workspace", "/tmp/work", "--", "Reply with exactly OK."]
      ]
    )
    XCTAssertEqual(runs.first?.configuration.environment["RIELA_AGENT_BACKEND"], "cursor-cli-agent")
    XCTAssertEqual(runs.first?.configuration.environment["CURSOR_CONFIG_DIR"], "/tmp/cursor-home")
    let run = try XCTUnwrap(runs.last)
    XCTAssertEqual(
      run.configuration.arguments,
      [
        "cursor-dev", "--print", "--output-format", "stream-json", "--model", "model", "--mode",
        "ask", "--image", "/tmp/screenshot.png", "--force", "--workspace", "/tmp/work", "--",
        "system\n\nhello"
      ]
    )
    XCTAssertEqual(run.configuration.environment["RIELA_AGENT_BACKEND"], "cursor-cli-agent")
    XCTAssertEqual(run.configuration.environment["CURSOR_CONFIG_DIR"], "/tmp/cursor-home")
    XCTAssertEqual(run.stdin, "")
  }

  func testCursorCLIAgentEffortResolutionMatchesTypeScriptComposerRule() {
    XCTAssertFalse(CursorCLIAgentEffortResolution.modelSupportsCursorEffortSuffix(model: "composer-2.5"))
    XCTAssertTrue(CursorCLIAgentEffortResolution.modelSupportsCursorEffortSuffix(model: "gpt-5.5"))
    XCTAssertNil(CursorCLIAgentEffortResolution.resolveCursorAgentEffort(model: "composer-2.5", effort: .high))
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveCursorAgentEffort(model: "gpt-5.5", effort: .high),
      .high
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.3-codex", effort: .high),
      "gpt-5.3-codex-high"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.3-codex-low-fast", effort: .high),
      "gpt-5.3-codex-high-fast"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5", effort: .high),
      "gpt-5.5-high"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5", effort: .medium),
      "gpt-5.5-medium"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5-fast", effort: .medium),
      "gpt-5.5-medium-fast"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5", effort: .xhigh),
      "gpt-5.5-extra-high"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5-extra-high", effort: .low),
      "gpt-5.5-low"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "gpt-5.5-extra-high-fast", effort: .low),
      "gpt-5.5-low-fast"
    )
    XCTAssertEqual(
      CursorCLIAgentEffortResolution.resolveModelForEffort(model: "composer-2.5", effort: .high),
      "composer-2.5"
    )
  }

  func testCursorForwardsEffortForNonComposerModels() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CursorCLIAgentAdapter(
      executableName: "cursor-dev",
      runner: runner,
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(
        backend: .cursorCliAgent,
        model: "gpt-5.3-codex",
        effort: .high
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let run = try XCTUnwrap(runs.last)
    XCTAssertTrue(run.configuration.arguments.contains("gpt-5.3-codex-high"))
    XCTAssertFalse(run.configuration.arguments.contains("composer-2.5"))
  }

  func testCursorDoesNotForwardEffortForComposerModels() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CursorCLIAgentAdapter(
      executableName: "cursor-dev",
      runner: runner,
      authPreflight: false
    )

    _ = try await adapter.execute(
      input(
        backend: .cursorCliAgent,
        model: "composer-2.5",
        effort: .high
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let run = try XCTUnwrap(runs.last)
    XCTAssertTrue(run.configuration.arguments.contains("composer-2.5"))
    XCTAssertFalse(run.configuration.arguments.contains("--effort"))
    XCTAssertFalse(run.configuration.arguments.contains("high"))
  }

  func testResolveAdapterImagePathsUsesRuntimeInputsDescriptorsDedupeAndForwardPolicy() {
    let resolved = resolveAdapterImagePaths(
      input(
        backend: .codexAgent,
        arguments: [
          "imagePaths": .array([.string("/tmp/argument.png"), .string("/tmp/duplicate.png")])
        ],
        mergedVariables: [
          "imagePaths": .array([.string("/tmp/merged.png"), .string("/tmp/duplicate.png")]),
          "message": .object([
            "attachments": .array([
              .object(["kind": .string("image"), "localPath": .string("/tmp/local.png")]),
              .object([
                "mimetype": .string("image/webp"),
                "source": .object(["imagePath": .string("/tmp/source.webp")])
              ])
            ])
          ])
        ]
      )
    )

    XCTAssertEqual(resolved, ["/tmp/merged.png", "/tmp/duplicate.png", "/tmp/local.png", "/tmp/source.webp", "/tmp/argument.png"])

    let disabled = resolveAdapterImagePaths(
      input(
        backend: .codexAgent,
        variables: ["forwardImageAttachments": .bool(false)],
        arguments: ["imagePaths": .array([.string("/tmp/argument.png")])],
        mergedVariables: ["imagePaths": .array([.string("/tmp/merged.png")])]
      )
    )

    XCTAssertEqual(disabled, [])
  }

  func testForwardImageAttachmentsFalseDisablesCodexClaudeAndCursorImageForwarding() async throws {
    let inputWithImagesDisabled = input(
      backend: .codexAgent,
      variables: ["forwardImageAttachments": .bool(false)],
      arguments: ["imagePaths": .array([.string("/tmp/argument.png")])],
      mergedVariables: ["imagePaths": .array([.string("/tmp/merged.png")])]
    )

    let codexRunner = RecordingRunner(output: "done")
    _ = try await CodexAgentAdapter(runner: codexRunner, authPreflight: false).execute(
      inputWithImagesDisabled,
      context: AdapterExecutionContext()
    )
    let codexRuns = await codexRunner.runs()
    let codexRun = try XCTUnwrap(codexRuns.last)
    XCTAssertFalse(codexRun.configuration.arguments.contains("--image"))

    let claudeRunner = RecordingRunner(output: "done")
    _ = try await ClaudeCodeAgentAdapter(runner: claudeRunner, authPreflight: false).execute(
      inputWithImagesDisabled,
      context: AdapterExecutionContext()
    )
    let claudeRuns = await claudeRunner.runs()
    let claudeRun = try XCTUnwrap(claudeRuns.last)
    XCTAssertFalse(claudeRun.configuration.arguments.contains("--add-dir"))
    XCTAssertFalse(claudeRun.stdin.contains("Attached files:"))

    let cursorRunner = RecordingRunner(output: "done")
    _ = try await CursorCLIAgentAdapter(runner: cursorRunner, authPreflight: false).execute(
      inputWithImagesDisabled,
      context: AdapterExecutionContext()
    )
    let cursorRuns = await cursorRunner.runs()
    let cursorRun = try XCTUnwrap(cursorRuns.last)
    XCTAssertFalse(cursorRun.configuration.arguments.contains("--image"))
  }

  func testAdapterAuthPreflightFailuresMapToPolicyBlocked() async throws {
    let adapter = CodexAgentAdapter(
      runner: RecordingRunner(),
      checkAuthPreflight: { _ in
        throw AdapterExecutionError(.policyBlocked, "codex-agent authentication is unavailable: not logged in")
      }
    )

    do {
      _ = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("not logged in"))
    }
  }

  func testAuthPreflightFalseSkipsInjectedPreflightForLocalAgents() async throws {
    let codexRunner = RecordingRunner(output: "done")
    _ = try await CodexAgentAdapter(
      runner: codexRunner,
      authPreflight: false,
      checkAuthPreflight: { _ in
        throw AdapterExecutionError(.policyBlocked, "codex preflight should not run")
      }
    ).execute(input(backend: .codexAgent), context: AdapterExecutionContext())
    let codexRuns = await codexRunner.runs()
    XCTAssertEqual(codexRuns.count, 1)

    let claudeRunner = RecordingRunner(output: "done")
    _ = try await ClaudeCodeAgentAdapter(
      runner: claudeRunner,
      authPreflight: false,
      checkAuthPreflight: { _ in
        throw AdapterExecutionError(.policyBlocked, "claude preflight should not run")
      }
    ).execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
    let claudeRuns = await claudeRunner.runs()
    XCTAssertEqual(claudeRuns.count, 1)

    let cursorRunner = RecordingRunner(output: "done")
    _ = try await CursorCLIAgentAdapter(
      runner: cursorRunner,
      authPreflight: false,
      checkAuthPreflight: { _ in
        throw AdapterExecutionError(.policyBlocked, "cursor preflight should not run")
      }
    ).execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
    let cursorRuns = await cursorRunner.runs()
    XCTAssertEqual(cursorRuns.count, 1)
  }

  func testNodeAgentEnvironmentOverridesAdapterEnvironmentForCliExecution() async throws {
    let input = input(
      backend: .codexAgent,
      agentEnvironment: [
        "OPENAI_BASE_URL": "https://node-router.test/v1",
        "CODEX_HOME": "/tmp/node-codex-home",
        "RIELA_AGENT_BACKEND": "spoofed"
      ]
    )
    let runner = RecordingRunner(output: "done")

    _ = try await CodexAgentAdapter(
      runner: runner,
      environment: [
        "OPENAI_BASE_URL": "https://adapter-router.test/v1",
        "CODEX_HOME": "/tmp/adapter-codex-home"
      ],
      authPreflight: false
    ).execute(input, context: AdapterExecutionContext())

    let runs = await runner.runs()
    let run = try XCTUnwrap(runs.last)
    XCTAssertEqual(run.configuration.environment["OPENAI_BASE_URL"], "https://node-router.test/v1")
    XCTAssertEqual(run.configuration.environment["CODEX_HOME"], "/tmp/node-codex-home")
    XCTAssertEqual(run.configuration.environment["RIELA_AGENT_BACKEND"], "codex-agent")
  }

  func testNodeAgentEnvironmentIsUsedByCliAuthPreflightAndExecution() async throws {
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.1.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "Logged in", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "done", stderr: "", terminationStatus: 0)
    ])

    _ = try await CodexAgentAdapter(
      runner: runner,
      environment: ["OPENAI_BASE_URL": "https://adapter-router.test/v1"]
    ).execute(
      input(backend: .codexAgent, agentEnvironment: ["OPENAI_BASE_URL": "https://node-router.test/v1"]),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertEqual(runs.count, 3)
    XCTAssertEqual(runs[0].configuration.environment["OPENAI_BASE_URL"], "https://node-router.test/v1")
    XCTAssertEqual(runs[1].configuration.environment["OPENAI_BASE_URL"], "https://node-router.test/v1")
    XCTAssertEqual(runs[2].configuration.environment["OPENAI_BASE_URL"], "https://node-router.test/v1")
  }

  func testCodexDefaultAuthPreflightMapsLoginFailureToPolicyBlockedBeforeCommand() async throws {
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.1.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "", stderr: "not logged in", terminationStatus: 1),
      LocalAgentProcessResult(stdout: "should not run", stderr: "", terminationStatus: 0)
    ])
    let adapter = CodexAgentAdapter(runner: runner, environment: ["CODEX_HOME": "/tmp/codex-home"])

    do {
      _ = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked codex preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("not logged in"))
    }

    let runs = await runner.runs()
    XCTAssertEqual(runs.map(\.configuration.arguments), [["codex", "--version"], ["codex", "login", "status"]])
    XCTAssertEqual(runs.first?.configuration.environment["CODEX_HOME"], "/tmp/codex-home")
  }

  func testCodexDefaultPreflightMapsUnavailableCliBeforeAuth() async throws {
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "", stderr: "env: codex: No such file or directory", terminationStatus: 127)
    ])
    let adapter = CodexAgentAdapter(runner: runner)

    do {
      _ = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked codex CLI preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("CLI is unavailable"))
      XCTAssertFalse(error.message.contains("authentication is unavailable"))
    }

    let runs = await runner.runs()
    XCTAssertEqual(runs.map(\.configuration.arguments), [["codex", "--version"]])
  }

  func testClaudeDefaultPreflightMapsUnavailableCliAndAuthToPolicyBlockedBeforeCommand() async throws {
    let unavailableCliRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "", stderr: "claude: command not found", terminationStatus: 127)
    ])
    let unavailableCliAdapter = ClaudeCodeAgentAdapter(runner: unavailableCliRunner)

    do {
      _ = try await unavailableCliAdapter.execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked claude CLI preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("CLI is unavailable"))
    }

    let authFailureRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "2.1.86", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: #"{"loggedIn":false}"#, stderr: "", terminationStatus: 0)
    ])
    let authFailureAdapter = ClaudeCodeAgentAdapter(runner: authFailureRunner, environment: ["CLAUDE_CONFIG_DIR": "/tmp/claude-home"])

    do {
      _ = try await authFailureAdapter.execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked claude auth preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("authentication is unavailable"))
    }

    let runs = await authFailureRunner.runs()
    XCTAssertEqual(runs.map(\.configuration.arguments), [["claude", "--version"], ["claude", "auth", "status"]])
    XCTAssertEqual(runs.map { $0.configuration.environment["CLAUDE_CONFIG_DIR"] }, ["/tmp/claude-home", "/tmp/claude-home"])
  }

  func testCursorDefaultPreflightMapsUnavailableCliAuthAndModelToPolicyBlockedBeforeCommand() async throws {
    let unavailableCliRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "", stderr: "cursor-agent: command not found", terminationStatus: 127)
    ])
    let unavailableCliAdapter = CursorCLIAgentAdapter(runner: unavailableCliRunner)

    do {
      _ = try await unavailableCliAdapter.execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked cursor CLI preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("CLI is unavailable"))
    }

    let authFailureRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "", stderr: "login expired", terminationStatus: 1)
    ])
    let authFailureAdapter = CursorCLIAgentAdapter(runner: authFailureRunner)

    do {
      _ = try await authFailureAdapter.execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked cursor auth preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("authentication is unavailable"))
    }

    let modelFailureRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "", stderr: "model is not enabled", terminationStatus: 1)
    ])
    let modelFailureAdapter = CursorCLIAgentAdapter(runner: modelFailureRunner, environment: ["CURSOR_CONFIG_DIR": "/tmp/cursor-home"])

    do {
      _ = try await modelFailureAdapter.execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy-blocked cursor model preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("model 'model' is unavailable"))
    }

    let runs = await modelFailureRunner.runs()
    XCTAssertEqual(
      runs.map(\.configuration.arguments),
      [
        ["cursor-agent", "--version"],
        ["cursor-agent", "--print", "--output-format", "text", "--model", "model", "--", "Reply with exactly OK."]
      ]
    )
    XCTAssertEqual(runs.map { $0.configuration.environment["CURSOR_CONFIG_DIR"] }, ["/tmp/cursor-home", "/tmp/cursor-home"])
  }

  func testInjectedAuthPreflightRethrowsCancellation() async {
    await assertThrowsCancellation {
      _ = try await CodexAgentAdapter(
        runner: CapturingRunner(output: "unused"),
        checkAuthPreflight: { _ in throw CancellationError() }
      ).execute(input(backend: .codexAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await ClaudeCodeAgentAdapter(
        runner: CapturingRunner(output: "unused"),
        checkAuthPreflight: { _ in throw CancellationError() }
      ).execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await CursorCLIAgentAdapter(
        runner: CapturingRunner(output: "unused"),
        checkAuthPreflight: { _ in throw CancellationError() }
      ).execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
    }
  }

  func testDefaultAuthPreflightRethrowsCancellation() async {
    await assertThrowsCancellation {
      _ = try await CodexAgentAdapter(runner: OutcomeRunner([.cancellation]))
        .execute(input(backend: .codexAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await ClaudeCodeAgentAdapter(runner: OutcomeRunner([.cancellation]))
        .execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await ClaudeCodeAgentAdapter(runner: OutcomeRunner([
        .result(LocalAgentProcessResult(stdout: "2.1.86", stderr: "", terminationStatus: 0)),
        .cancellation
      ])).execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await CursorCLIAgentAdapter(runner: OutcomeRunner([.cancellation]))
        .execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
    }

    await assertThrowsCancellation {
      _ = try await CursorCLIAgentAdapter(runner: OutcomeRunner([
        .result(LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0)),
        .cancellation
      ])).execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())
    }
  }

  private func assertThrowsCancellation(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      try await operation()
      XCTFail("Expected cancellation", file: file, line: line)
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)", file: file, line: line)
    }
  }
}
