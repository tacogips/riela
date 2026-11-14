import Darwin
import Foundation
import XCTest
@testable import ClaudeCodeAgent
@testable import CodexAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testPerNodeAgentSandboxAndToolPolicyReachCodexCommand() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CodexAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(
        backend: .codexAgent,
        agentSandbox: .readOnly,
        agentToolPolicy: AgentToolPolicy(
          additionalArguments: ["--disable", "shell"],
          codexArguments: ["--config", "tools.web_search=false"]
        )
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let args = try XCTUnwrap(runs.last?.configuration.arguments)
    XCTAssertTrue(args.containsSubsequence(["--sandbox", "read-only"]))
    XCTAssertTrue(args.containsSubsequence(["--disable", "shell"]))
    XCTAssertTrue(args.containsSubsequence(["--config", "tools.web_search=false"]))
  }

  func testPerNodeAgentSandboxAndToolPolicyReachClaudeCommand() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = ClaudeCodeAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(
        backend: .claudeCodeAgent,
        agentSandbox: .readOnly,
        agentToolPolicy: AgentToolPolicy(claudeArguments: ["--disallowedTools", "Bash,Read"])
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let args = try XCTUnwrap(runs.last?.configuration.arguments)
    XCTAssertTrue(args.containsSubsequence(["--permission-mode", "plan"]))
    XCTAssertTrue(args.containsSubsequence(["--disallowedTools", "Bash,Read"]))
  }

  func testPerNodeAgentSandboxAndToolPolicyReachCursorCommand() async throws {
    let runner = RecordingRunner(output: "done")
    let adapter = CursorCLIAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(
        backend: .cursorCliAgent,
        agentSandbox: .workspaceWrite,
        agentToolPolicy: AgentToolPolicy(cursorArguments: ["--disable-tool", "shell"])
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let args = try XCTUnwrap(runs.last?.configuration.arguments)
    XCTAssertTrue(args.containsSubsequence(["--sandbox", "workspace-write"]))
    XCTAssertTrue(args.containsSubsequence(["--disable-tool", "shell"]))
  }

  func testAgentAdaptersReportBackendEventsFromStreamJSONStdout() async throws {
    let recorder = BackendEventRecorder()
    let context = AdapterExecutionContext { event in
      await recorder.append(event)
    }

    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: #"{"type":"turn.started"}"# + "\n" + #"{"type":"assistant.snapshot","content":"done"}"#),
      authPreflight: false
    ).execute(input(backend: .codexAgent), context: context)
    _ = try await ClaudeCodeAgentAdapter(
      runner: StreamingRecordingRunner(output: #"{"type":"assistant","message":{"content":"done"}}"#),
      authPreflight: false
    ).execute(input(backend: .claudeCodeAgent), context: context)
    _ = try await CursorCLIAgentAdapter(
      runner: StreamingRecordingRunner(output: #"{"type":"session.thinking"}"# + "\n" + #"{"type":"result","result":"done"}"#),
      authPreflight: false
    ).execute(input(backend: .cursorCliAgent), context: context)

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.provider), ["codex-agent", "codex-agent", "claude-code-agent", "cursor-cli-agent", "cursor-cli-agent"])
    XCTAssertEqual(events.map(\.eventType), ["turn.started", "assistant.snapshot", "assistant", "session.thinking", "result"])
    XCTAssertEqual(events.map(\.channel), [.lifecycle, .assistant, nil, .lifecycle, .lifecycle])
    XCTAssertEqual(events[1].contentSnapshot, "done")
  }

  func testAgentAdaptersIgnoreNonJSONAndStderrForBackendEvents() async throws {
    let recorder = BackendEventRecorder()
    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: "plain output", error: #"{"type":"turn.started"}"#),
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events, [])
  }

  func testCursorDefaultPreflightUsesResolvedGpt55ModelInProbeAndDiagnostics() async throws {
    let modelFailureRunner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "", stderr: "model is not enabled", terminationStatus: 1)
    ])
    let modelFailureAdapter = CursorCLIAgentAdapter(runner: modelFailureRunner)

    do {
      _ = try await modelFailureAdapter.execute(
        input(backend: .cursorCliAgent, model: "gpt-5.5", effort: .high),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked cursor model preflight failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("model 'gpt-5.5-high' is unavailable"))
      XCTAssertFalse(error.message.contains("model 'gpt-5.5' is unavailable"))
    }

    let runs = await modelFailureRunner.runs()
    XCTAssertEqual(
      runs.map(\.configuration.arguments),
      [
        ["cursor-agent", "--version"],
        ["cursor-agent", "--print", "--output-format", "text", "--model", "gpt-5.5-high", "--", "Reply with exactly OK."]
      ]
    )
  }

  func testCursorDefaultPreflightIncludesNodeAdditionalArgumentsInProbe() async throws {
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "OK", stderr: "", terminationStatus: 0),
      LocalAgentProcessResult(stdout: "done", stderr: "", terminationStatus: 0)
    ])
    _ = try await CursorCLIAgentAdapter(runner: runner).execute(
      input(
        backend: .cursorCliAgent,
        variables: ["cursorAdditionalArgs": .array([.string("--trust")])]
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertEqual(
      runs.map(\.configuration.arguments),
      [
        ["cursor-agent", "--version"],
        ["cursor-agent", "--print", "--output-format", "text", "--model", "model", "--trust", "--", "Reply with exactly OK."],
        ["cursor-agent", "--print", "--output-format", "stream-json", "--model", "model", "--trust", "--", "hello"]
      ]
    )
  }

  func testDefaultAuthPreflightsUseBoundedDeadlineWhenContextDeadlineIsNil() async throws {
    let codexRunner = RecordingRunner(output: "done")
    _ = try await CodexAgentAdapter(runner: codexRunner).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext()
    )
    let codexRuns = await codexRunner.runs()
    XCTAssertNotNil(codexRuns.first?.deadline)
    XCTAssertNil(codexRuns.last?.deadline)

    let claudeRunner = RecordingRunner(output: "done")
    _ = try await ClaudeCodeAgentAdapter(runner: claudeRunner).execute(
      input(backend: .claudeCodeAgent),
      context: AdapterExecutionContext()
    )
    let claudeRuns = await claudeRunner.runs()
    XCTAssertEqual(claudeRuns.prefix(2).filter { $0.deadline != nil }.count, 2)
    XCTAssertNil(claudeRuns.last?.deadline)

    let cursorRunner = RecordingRunner(output: "done")
    _ = try await CursorCLIAgentAdapter(runner: cursorRunner).execute(
      input(backend: .cursorCliAgent),
      context: AdapterExecutionContext()
    )
    let cursorRuns = await cursorRunner.runs()
    XCTAssertEqual(cursorRuns.prefix(2).filter { $0.deadline != nil }.count, 2)
    XCTAssertNil(cursorRuns.last?.deadline)
  }

  func testDefaultAuthPreflightTimeoutsMapToPolicyBlocked() async throws {
    let timeout = AdapterExecutionError(.timeout, "local agent process timed out")
    let codexRunner = OutcomeRunner([.error(timeout)])
    do {
      _ = try await CodexAgentAdapter(runner: codexRunner).execute(
        input(backend: .codexAgent),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked codex preflight timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("authentication is unavailable"))
      XCTAssertTrue(error.message.contains("timed out"))
    }

    let claudeCliRunner = OutcomeRunner([.error(timeout)])
    do {
      _ = try await ClaudeCodeAgentAdapter(runner: claudeCliRunner).execute(
        input(backend: .claudeCodeAgent),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked claude CLI preflight timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("CLI is unavailable"))
      XCTAssertTrue(error.message.contains("timed out"))
    }

    let claudeAuthRunner = OutcomeRunner([
      .result(LocalAgentProcessResult(stdout: "2.1.86", stderr: "", terminationStatus: 0)),
      .error(timeout)
    ])
    do {
      _ = try await ClaudeCodeAgentAdapter(runner: claudeAuthRunner).execute(
        input(backend: .claudeCodeAgent),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked claude auth preflight timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("authentication is unavailable"))
      XCTAssertTrue(error.message.contains("timed out"))
    }

    let cursorCliRunner = OutcomeRunner([.error(timeout)])
    do {
      _ = try await CursorCLIAgentAdapter(runner: cursorCliRunner).execute(
        input(backend: .cursorCliAgent),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked cursor CLI preflight timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("CLI is unavailable"))
      XCTAssertTrue(error.message.contains("timed out"))
    }

    let cursorModelRunner = OutcomeRunner([
      .result(LocalAgentProcessResult(stdout: "0.45.0", stderr: "", terminationStatus: 0)),
      .error(timeout)
    ])
    do {
      _ = try await CursorCLIAgentAdapter(runner: cursorModelRunner).execute(
        input(backend: .cursorCliAgent),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected policy-blocked cursor model preflight timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertTrue(error.message.contains("model 'model' is unavailable"))
      XCTAssertTrue(error.message.contains("timed out"))
    }
  }

  func testNoOutputContractPreservesJSONLookingTextAsTextPayload() async throws {
    let text = """
    Here is an example response:
    ```json
    {"when":{"always":false},"payload":{"status":"wrong"}}
    ```
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: text))
    let output = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.when, ["always": true])
    XCTAssertEqual(output.payload["text"], .string(text))
  }

  func testOutputContractParsesEnvelope() async throws {
    let adapter = CodexAgentAdapter(
      runner: CapturingRunner(
        output: #"{"completionPassed":false,"when":{"needs_revision":true},"payload":{"status":"review"}}"#
      )
    )
    let output = try await adapter.execute(
      input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.completionPassed, false)
    XCTAssertEqual(output.when, ["needs_revision": true])
    XCTAssertEqual(output.payload["status"], .string("review"))
  }

  func testCodexJSONStreamUsesFinalAssistantContentForOutputContract() async throws {
    let codexJSONL = """
    {"type":"session_meta","payload":{"meta":{"id":"codex-session-1","source":"exec"}}}
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\\"summary\\":\\"ok\\"}"}]}}
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: codexJSONL))
    let output = try await adapter.execute(
      input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["summary"], .string("ok"))
    XCTAssertNil(output.payload["type"])
  }

  func testCodexJSONStreamSkipsThreadStartedAndUsesAgentMessageForOutputContract() async throws {
    let codexJSONL = """
    {"type":"thread.started","thread_id":"codex-thread-1"}
    {"type":"event_msg","payload":{"type":"agent_message","message":"{\\"replyText\\":\\"了解です。Mikaに渡します。\\",\\"handoff_mika\\":true}"}}
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: codexJSONL))
    let output = try await adapter.execute(
      input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("了解です。Mikaに渡します。"))
    XCTAssertEqual(output.payload["handoff_mika"], .bool(true))
    XCTAssertNil(output.payload["thread_id"])
  }

  func testCodexJSONStreamUsesItemCompletedAgentMessageTextForOutputContract() async throws {
    let codexJSONL = """
    {"type":"thread.started","thread_id":"codex-thread-1"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"replyText\\":\\"Mikaに渡します。\\",\\"handoff_mika\\":true}"}}
    {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: codexJSONL))
    let output = try await adapter.execute(
      input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("Mikaに渡します。"))
    XCTAssertEqual(output.payload["handoff_mika"], .bool(true))
    XCTAssertNil(output.payload["thread_id"])
  }

  func testCodexJSONStreamUsesTurnCompleteLastAgentMessageForOutputContract() async throws {
    let codexJSONL = """
    {"type":"thread.started","thread_id":"codex-thread-1"}
    {"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"{\\"replyText\\":\\"了解。自然に続ける。\\",\\"handoff_rina\\":false}"}}
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: codexJSONL))
    let output = try await adapter.execute(
      input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("了解。自然に続ける。"))
    XCTAssertEqual(output.payload["handoff_rina"], .bool(false))
    XCTAssertNil(output.payload["thread_id"])
  }

  func testCodexJSONStreamUsesFinalAssistantContentForTextPayload() async throws {
    let codexJSONL = """
    {"type":"session_meta","payload":{"meta":{"id":"codex-session-1","source":"exec"}}}
    {"type":"assistant.snapshot","content":"final text"}
    """
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: codexJSONL))
    let output = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("final text"))
  }

  func testCursorStreamJSONUsesFinalAssistantContentForTextPayload() async throws {
    let cursorJSONL = """
    {"type":"session.started","sessionId":"cursor-session-1","cwd":"/tmp","model":"model"}
    {"type":"session.assistant_message","sessionId":"cursor-session-1","message":{"displayText":"draft","rawText":"draft"}}
    {"type":"session.assistant_message","sessionId":"cursor-session-1","message":{"displayText":"","rawText":"final text"}}
    """
    let adapter = CursorCLIAgentAdapter(runner: CapturingRunner(output: cursorJSONL), authPreflight: false)
    let output = try await adapter.execute(input(backend: .cursorCliAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("final text"))
  }

  func testCursorStreamJSONUsesCompletedResultForOutputContract() async throws {
    let cursorJSONL = """
    {"type":"session.started","sessionId":"cursor-session-1","cwd":"/tmp","model":"model"}
    {"type":"session.completed","sessionId":"cursor-session-1","result":"{\\"summary\\":\\"ok\\"}"}
    """
    let adapter = CursorCLIAgentAdapter(runner: CapturingRunner(output: cursorJSONL), authPreflight: false)
    let output = try await adapter.execute(
      input(backend: .cursorCliAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["summary"], .string("ok"))
    XCTAssertNil(output.payload["type"])
  }

  func testCursorStreamJSONUsesAssistantMessageFromHeadlessStreamForOutputContract() async throws {
    let cursorJSONL = """
    {"type":"system","subtype":"init","session_id":"cursor-session-1","model":"Sonnet 4.5"}
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"prompt"}]},"session_id":"cursor-session-1"}
    {"type":"thinking","subtype":"delta","text":"reasoning","session_id":"cursor-session-1"}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"{\\"replyText\\":\\"見方を少し変えるなら、雑談も設計できる。\\",\\"handoff_yui\\":false}"}]},"session_id":"cursor-session-1"}
    {"type":"result","subtype":"success","result":"{\\"replyText\\":\\"見方を少し変えるなら、雑談も設計できる。\\",\\"handoff_yui\\":false}","session_id":"cursor-session-1"}
    """
    let adapter = CursorCLIAgentAdapter(runner: CapturingRunner(output: cursorJSONL), authPreflight: false)
    let output = try await adapter.execute(
      input(backend: .cursorCliAgent, output: NodeOutputContract(description: "business JSON")),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("見方を少し変えるなら、雑談も設計できる。"))
    XCTAssertEqual(output.payload["handoff_yui"], .bool(false))
    XCTAssertNil(output.payload["subtype"])
  }

  func testOutputContractRejectsPlainTextOutput() async throws {
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: "plain text"))

    do {
      _ = try await adapter.execute(
        input(backend: .codexAgent, output: NodeOutputContract(description: "business JSON")),
        context: AdapterExecutionContext()
      )
      XCTFail("Expected invalid output")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidOutput)
    }
  }

  func testProviderFailureRedactsSecretsFromStderr() async throws {
    let openAIKey = "sk-" + "testsecret" + "123456"
    let anthropicKey = "anthropic-" + "secret-" + "123456"
    let cursorKey = "cursor-" + "secret-" + "123456"
    let bearerToken = "abcdefghijklmnopqrstuvwxyz" + "123456"
    let stderr = [
      "OPENAI_API_KEY=\(openAIKey) ANTHROPIC_API_KEY=\(anthropicKey) CURSOR_API_KEY=\(cursorKey)",
      "Authorization: Bearer \(bearerToken)"
    ].joined(separator: "\n")
    let adapter = CodexAgentAdapter(runner: CapturingRunner(output: "", error: stderr, status: 1), authPreflight: false)

    do {
      _ = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())
      XCTFail("Expected provider failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertFalse(error.message.contains(openAIKey))
      XCTAssertFalse(error.message.contains(anthropicKey))
      XCTAssertFalse(error.message.contains(cursorKey))
      XCTAssertFalse(error.message.contains(bearerToken))
      XCTAssertTrue(error.message.contains("<redacted"))
    }
  }

  func testProviderFailureRedactsConfiguredEnvironmentSecretValue() async throws {
    let configuredSecret = "/tmp/riela-codex-home-\(UUID().uuidString)"
    let adapter = CodexAgentAdapter(
      runner: CapturingRunner(output: "", error: "failed using \(configuredSecret)", status: 1),
      environment: ["CODEX_HOME": configuredSecret],
      authPreflight: false
    )

    do {
      _ = try await adapter.execute(input(backend: .codexAgent), context: AdapterExecutionContext())
      XCTFail("Expected provider failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertFalse(error.message.contains(configuredSecret))
      XCTAssertTrue(error.message.contains("<redacted>"))
    }
  }

  func testDefaultPreflightRedactsConfiguredEnvironmentSecretValue() async throws {
    let configuredSecret = "/tmp/riela-claude-config-\(UUID().uuidString)"
    let runner = SequencedRunner([
      LocalAgentProcessResult(stdout: "", stderr: "failed using \(configuredSecret)", terminationStatus: 1)
    ])
    let adapter = ClaudeCodeAgentAdapter(
      runner: runner,
      environment: ["CLAUDE_CONFIG_DIR": configuredSecret]
    )

    do {
      _ = try await adapter.execute(input(backend: .claudeCodeAgent), context: AdapterExecutionContext())
      XCTFail("Expected policy blocked failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertFalse(error.message.contains(configuredSecret))
      XCTAssertTrue(error.message.contains("<redacted>"))
    }
  }

  func testFoundationRunnerDrainsLargeOutput() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' x; dd if=/dev/zero bs=1024 count=256 2>/dev/null | tr '\\0' e >&2"]
      ),
      stdin: "",
      deadline: Date(timeIntervalSinceNow: 15)
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout.count, 262_144)
    XCTAssertEqual(result.stderr.count, 262_144)
  }

  func testFoundationRunnerUnsetsAmbientEnvironmentKeys() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        unsetEnvironmentKeys: ["PATH"]
      ),
      stdin: "",
      deadline: Date(timeIntervalSinceNow: 2)
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertFalse(result.stdout.split(separator: "\n").contains { $0.hasPrefix("PATH=") })
  }

  func testFoundationRunnerClosesChildUnusedPipeDescriptorsForStdinEOF() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(executableURL: URL(fileURLWithPath: "/bin/cat")),
      stdin: "hello from stdin",
      deadline: Date(timeIntervalSinceNow: 2)
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout, "hello from stdin")
    XCTAssertEqual(result.stderr, "")
  }

  func testFoundationRunnerClosesUnrelatedInheritedFileDescriptors() async throws {
    let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("riela-inherited-fd-\(UUID().uuidString).txt")
    try "secret".write(to: fileURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let descriptor = open(fileURL.path, O_RDONLY)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    defer { close(descriptor) }
    let flags = fcntl(descriptor, F_GETFD)
    XCTAssertGreaterThanOrEqual(flags, 0)
    XCTAssertEqual(fcntl(descriptor, F_SETFD, flags & ~FD_CLOEXEC), 0)

    let runner = FoundationLocalAgentProcessRunner()
    let result = try await runner.run(
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [
          "-c",
          "if : <&$1 2>/dev/null; then echo inherited; else echo closed; fi",
          "riela-fd-test",
          String(descriptor)
        ]
      ),
      stdin: "",
      deadline: Date(timeIntervalSinceNow: 2)
    )

    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "closed")
  }

  func testFoundationRunnerTerminatesAfterDeadline() async throws {
    let runner = FoundationLocalAgentProcessRunner()

    do {
      _ = try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sleep"),
          arguments: ["5"]
        ),
        stdin: "",
        deadline: Date(timeIntervalSinceNow: 0.05)
      )
      XCTFail("Expected deadline timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }
  }

  func testFoundationRunnerTimeoutDoesNotWaitForPipeEOF() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let startedAt = Date()

    do {
      _ = try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "trap '' TERM; while :; do :; done"]
        ),
        stdin: "",
        deadline: Date(timeIntervalSinceNow: 0.05)
      )
      XCTFail("Expected deadline timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }
  }

  func testFoundationRunnerCancellationDoesNotAbortPipeReaders() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let task = Task {
      try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "while :; do sleep 1; done"]
        ),
        stdin: "",
        deadline: nil
      )
    }

    try await Task.sleep(nanoseconds: 100_000_000)
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  func testFoundationRunnerCancellationTerminatesSpawnedProcessGroup() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("riela-cancel-resistant-child-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    let script = """
    trap 'exit 0' TERM
    /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do :; done' child "$1" &
    wait
    """

    let task = Task {
      try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", script, "riela-test", pidFile.path]
        ),
        stdin: "",
        deadline: nil
      )
    }

    let childProcessId = try waitForPidFile(pidFile)
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    }

    let deadline = Date(timeIntervalSinceNow: 3)
    while Date() < deadline {
      if kill(childProcessId, 0) != 0 {
        return
      }
      usleep(50_000)
    }
    XCTFail("Expected cancellation to terminate the spawned child process group")
  }

  func testLocalProcessHandleCancelsDelayedKillAfterProcessReap() throws {
    let recorder = SignalRecorder()
    let handle = LocalProcessHandle(signalProcess: recorder.record(pid:signal:))
    handle.store(processId: 12_345)

    XCTAssertTrue(handle.terminateGroupOrProcess())
    XCTAssertTrue(handle.scheduleKillIfRunning(after: 0.05))
    handle.markExited()
    usleep(150_000)

    let signals = recorder.signals()
    XCTAssertEqual(signals.count, 1)
    XCTAssertEqual(signals.first?.pid, -12_345)
    XCTAssertEqual(signals.first?.signal, SIGTERM)
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
  }

  func testLocalProcessHandlePreservesDelayedKillAfterTimeoutReap() throws {
    let recorder = SignalRecorder()
    let handle = LocalProcessHandle(signalProcess: recorder.record(pid:signal:))
    handle.store(processId: 12_345)

    XCTAssertTrue(handle.terminateGroupOrProcess())
    XCTAssertTrue(handle.scheduleKillIfRunning(after: 0.05))
    handle.markExited(afterTimeout: true)
    usleep(150_000)

    let signals = recorder.signals()
    XCTAssertEqual(signals.map { $0.signal }, [SIGTERM, SIGKILL])
    XCTAssertEqual(signals.map { $0.pid }, [-12_345, -12_345])
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
  }

  func testLocalProcessHandleCancelsDelayedKillAfterTimeoutReapWhenGroupIsGone() throws {
    let recorder = SignalRecorder(liveProbeResults: [-1])
    let handle = LocalProcessHandle(signalProcess: recorder.record(pid:signal:))
    handle.store(processId: 12_345)

    XCTAssertTrue(handle.terminateGroupOrProcess())
    XCTAssertTrue(handle.scheduleKillIfRunning(after: 0.05))
    handle.markExited(afterTimeout: true)
    usleep(150_000)

    let signals = recorder.signals()
    XCTAssertEqual(signals.count, 1)
    XCTAssertEqual(signals.first?.pid, -12_345)
    XCTAssertEqual(signals.first?.signal, SIGTERM)
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
  }

  func testLocalProcessHandleCancelsDelayedKillWhenGroupDiesBeforeEscalation() throws {
    let recorder = SignalRecorder(liveProbeResults: [0, -1])
    let handle = LocalProcessHandle(signalProcess: recorder.record(pid:signal:))
    handle.store(processId: 12_345)

    XCTAssertTrue(handle.terminateGroupOrProcess())
    XCTAssertTrue(handle.scheduleKillIfRunning(after: 0.05))
    handle.markExited(afterTimeout: true)
    usleep(150_000)

    let signals = recorder.signals()
    XCTAssertEqual(signals.count, 1)
    XCTAssertEqual(signals.first?.pid, -12_345)
    XCTAssertEqual(signals.first?.signal, SIGTERM)
    XCTAssertFalse(handle.scheduleKillIfRunning(after: 0))
  }

  func testFoundationRunnerTimeoutKillsTermResistantDescendantAfterParentReap() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("riela-term-resistant-child-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    let script = """
    trap 'exit 0' TERM
    /bin/sh -c 'trap "" TERM; echo $$ > "$1"; while :; do :; done' child "$1" &
    wait
    """

    do {
      _ = try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", script, "riela-test", pidFile.path]
        ),
        stdin: "",
        deadline: Date(timeIntervalSinceNow: 0.2)
      )
      XCTFail("Expected deadline timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }

    let childProcessId = try waitForPidFile(pidFile)
    let deadline = Date(timeIntervalSinceNow: 3)
    while Date() < deadline {
      if kill(childProcessId, 0) != 0 {
        return
      }
      usleep(50_000)
    }
    XCTFail("Expected TERM-resistant child process group member to be killed after timeout")
  }

  func testFoundationRunnerDeadlineTerminatesSpawnedChildProcessGroup() async throws {
    let runner = FoundationLocalAgentProcessRunner()
    let pidFile = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("riela-child-\(UUID().uuidString).pid")
    defer { try? FileManager.default.removeItem(at: pidFile) }

    do {
      _ = try await runner.run(
        configuration: LocalAgentProcessConfiguration(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", "sleep 5 & echo $! > \"$1\"; wait", "riela-test", pidFile.path]
        ),
        stdin: "",
        deadline: Date(timeIntervalSinceNow: 0.2)
      )
      XCTFail("Expected deadline timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
    }

    let pidText = try String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines)
    let childProcessId = try XCTUnwrap(pid_t(pidText))
    let deadline = Date(timeIntervalSinceNow: 2)
    while Date() < deadline {
      if kill(childProcessId, 0) != 0 {
        return
      }
      usleep(50_000)
    }
    XCTFail("Expected spawned child process group member to be terminated")
  }

  private func waitForPidFile(_ pidFile: URL) throws -> pid_t {
    let deadline = Date(timeIntervalSinceNow: 2)
    while Date() < deadline {
      if let pidText = try? String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines),
         let processId = pid_t(pidText) {
        return processId
      }
      usleep(50_000)
    }
    let missingProcessId: pid_t? = nil
    return try XCTUnwrap(missingProcessId, "Expected child pid file at \(pidFile.path)")
  }

  func testCodexDefaultReadinessOperationsProbeToolsAuthAndModels() async throws {
    let codex = try createTestExecutable(
      name: "fake-codex-ok.sh",
      body: """
      if [ "${CODEX_AGENT_TEST_ENV:-}" != "ready" ]; then
        echo "missing env" 1>&2
        exit 13
      fi
      case "$1:${2:-}" in
        "--version:")
          printf 'codex %s\\n' "${CODEX_AGENT_TEST_VERSION:-missing}"
          ;;
        "login:status")
          printf 'Logged in using ChatGPT\\n'
          ;;
        "exec:--skip-git-repo-check")
          if [ "${3:-}" = "--ephemeral" ] && [ "${4:-}" = "--model" ] && [ "${5:-}" = "gpt-5.4" ]; then
            printf 'OK\\n'
          else
            echo "missing model probe args: $*" 1>&2
            exit 8
          fi
          ;;
        *)
          echo "unexpected args: $*" 1>&2
          exit 1
          ;;
      esac
      """
    )
    let git = try createTestExecutable(
      name: "fake-git-ok.sh",
      body: "printf 'git version 2.50.1\\n'"
    )
    let operations = CodexAgentDefaultReadinessOperations(codexBinary: codex.path, gitBinary: git.path)
    let options = AgentBackendProbeOptions(environment: ["CODEX_AGENT_TEST_ENV": "ready", "CODEX_AGENT_TEST_VERSION": "from-env"])

    let versions = await operations.getToolVersions(options: options)
    XCTAssertEqual(versions.codex, AgentBackendToolInfo(name: "codex", command: codex.path, version: "codex from-env", status: .available))
    XCTAssertEqual(versions.git, AgentBackendToolInfo(name: "git", command: git.path, version: "git version 2.50.1", status: .available))
    let loginStatus = await operations.getLoginStatus(options: options)
    XCTAssertEqual(loginStatus, CodexBackendLoginStatus(ok: true, status: "Logged in using ChatGPT", exitCode: 0))
    let availability = await operations.checkModelAvailability(model: "gpt-5.4", options: options)
    XCTAssertEqual(
      availability,
      CodexBackendModelAvailability(
        ok: true,
        model: "gpt-5.4",
        auth: CodexBackendLoginStatus(ok: true, status: "Logged in using ChatGPT", exitCode: 0),
        probe: CodexBackendModelProbe(ok: true, model: "gpt-5.4", output: "OK", exitCode: 0)
      )
    )

    let failingCodex = try createTestExecutable(
      name: "fake-codex-fail.sh",
      body: """
      case "$1:${2:-}" in
        "--version:")
          printf 'codex 1.0.0\\n'
          ;;
        "login:status")
          printf 'Not logged in\\n'
          ;;
        "exec:--skip-git-repo-check")
          echo 'Reading additional input from stdin...' 1>&2
          echo 'ERROR: {"type":"error","status":400,"error":{"message":"The gpt-5 model is not supported for this account."}}' 1>&2
          exit 11
          ;;
        *)
          echo "unexpected args: $*" 1>&2
          exit 1
          ;;
      esac
      """
    )
    let failingOperations = CodexAgentDefaultReadinessOperations(codexBinary: failingCodex.path, gitBinary: git.path)
    let login = await failingOperations.getLoginStatus()
    XCTAssertEqual(login, CodexBackendLoginStatus(ok: false, status: "Not logged in", error: "Not logged in", exitCode: 0))
    let unavailable = await failingOperations.checkModelAvailability(model: "gpt-5")
    XCTAssertFalse(unavailable.ok)
    XCTAssertTrue(unavailable.probe.error?.contains("The gpt-5 model is not supported for this account.") == true)
  }

  func testReadinessSummariesAndValidationMirrorRuntimeAgentProbeCategories() {
    let codexRequirement = CodexAgentReadiness.runtimeRequirement(
      candidate: AgentBackendRequirementCandidate(backend: .codexAgent, models: ["gpt-5.5"], sourceStepIds: ["worker"]),
      toolVersions: CodexBackendToolVersions(
        codex: AgentBackendToolInfo(name: "codex", command: "codex", version: "codex-cli 0.135.0", status: .available),
        git: AgentBackendToolInfo(name: "git", command: "git", status: .unavailable, error: "missing")
      )
    )
    XCTAssertEqual(codexRequirement.status, .unavailable)
    XCTAssertTrue(codexRequirement.detail.contains("bundled sdk=codex-agent"))
    XCTAssertEqual(codexRequirement.sourceStepIds, ["worker"])

    let codexCandidate = AgentBackendPreflightCandidate(backend: .codexAgent, models: ["gpt-5.5"], nodeIds: ["worker"], stepIds: ["worker"])
    let codexAuth = CodexAgentReadiness.authValidation(
      candidate: codexCandidate,
      status: CodexBackendLoginStatus(ok: false, error: "not logged in", exitCode: 1)
    )
    XCTAssertEqual(codexAuth.status, .invalid)
    XCTAssertTrue(codexAuth.message.contains("authentication is unavailable"))

    let claudeCandidate = AgentBackendPreflightCandidate(backend: .claudeCodeAgent, models: ["claude-sonnet-4"], nodeIds: ["manager"], stepIds: ["manager"])
    let claudeModel = ClaudeCodeAgentReadiness.modelValidation(
      candidate: claudeCandidate,
      model: "claude-sonnet-4",
      readiness: ClaudeBackendReadiness(
        ready: false,
        auth: ClaudeBackendAuthReadiness(state: .expired, available: false, verified: true, message: "Stored credentials are expired."),
        cli: ClaudeBackendCliReadiness(checked: false, available: false),
        model: ClaudeBackendModelReadiness(requested: "claude-sonnet-4", checked: false, available: false, timedOut: false)
      )
    )
    XCTAssertEqual(claudeModel.status, .invalid)
    XCTAssertTrue(claudeModel.message.contains("authentication failure"))

    let cursorCandidate = AgentBackendPreflightCandidate(backend: .cursorCliAgent, models: ["claude-sonnet-4-5"], nodeIds: ["cursor"], stepIds: ["cursor"])
    let cursorAuth = CursorCLIAgentReadiness.authValidation(candidate: cursorCandidate)
    XCTAssertEqual(cursorAuth.status, .unknown)
    XCTAssertTrue(cursorAuth.message.contains("no stable local auth-status command"))

    let cursorModel = CursorCLIAgentReadiness.modelValidation(
      candidate: cursorCandidate,
      availability: CursorBackendModelAvailability(
        model: "claude-sonnet-4-5",
        binary: AgentBackendToolInfo(name: "cursor-agent", command: "cursor-agent", status: .available),
        auth: CursorBackendAuthAvailability(status: .unavailable, detail: "login expired"),
        modelReachability: CursorBackendModelReachability(status: .unavailable, probed: true, error: "permission denied")
      )
    )
    XCTAssertEqual(cursorModel.status, .invalid)
    XCTAssertTrue(cursorModel.message.contains("authentication failure"))
  }

  func testReadinessAPIsUseInjectedProbeOperations() async {
    let codexCandidate = AgentBackendRequirementCandidate(backend: .codexAgent, models: ["gpt-5.5"], sourceStepIds: ["worker"])
    let codexRequirement = await CodexAgentReadiness.runtimeRequirement(
      candidate: codexCandidate,
      operations: MockCodexReadinessOperations()
    )
    XCTAssertEqual(codexRequirement.status, .available)
    XCTAssertTrue(codexRequirement.detail.contains("codex=codex-cli 0.135.0"))

    let claudeCandidate = AgentBackendPreflightCandidate(backend: .claudeCodeAgent, models: ["claude-sonnet-4"], nodeIds: ["manager"], stepIds: ["manager"])
    let claudeModel = await ClaudeCodeAgentReadiness.modelValidation(
      candidate: claudeCandidate,
      model: "claude-sonnet-4",
      operations: MockClaudeReadinessOperations()
    )
    XCTAssertEqual(claudeModel.status, .valid)

    let cursorCandidate = AgentBackendPreflightCandidate(backend: .cursorCliAgent, models: ["claude-sonnet-4-5"], nodeIds: ["cursor"], stepIds: ["cursor"])
    let cursorRequirement = await CursorCLIAgentReadiness.runtimeRequirement(
      candidate: AgentBackendRequirementCandidate(backend: .cursorCliAgent, models: ["claude-sonnet-4-5"], sourceStepIds: ["cursor"]),
      operations: MockCursorReadinessOperations()
    )
    XCTAssertEqual(cursorRequirement.status, .available)
    let cursorModel = await CursorCLIAgentReadiness.modelValidation(
      candidate: cursorCandidate,
      model: "claude-sonnet-4-5",
      operations: MockCursorReadinessOperations()
    )
    XCTAssertEqual(cursorModel.status, .valid)
  }

  private func createTestExecutable(name: String, body: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/agent-adapter-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    let url = root.appendingPathComponent(name)
    try "#!/bin/sh\nset -eu\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
  }

  func input(
    backend: NodeExecutionBackend,
    promptText: String = "hello",
    output: NodeOutputContract? = nil,
    model: String = "model",
    effort: NodeReasoningEffort? = nil,
    workingDirectory: String? = nil,
    systemPromptText: String? = nil,
    variables: JSONObject = [:],
    arguments: JSONObject = [:],
    mergedVariables: JSONObject = [:],
    agentEnvironment: [String: String] = [:],
    agentSandbox: AgentSandboxMode? = nil,
    agentToolPolicy: AgentToolPolicy? = nil
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: "worker",
        executionBackend: backend,
        model: model,
        effort: effort,
        workingDirectory: workingDirectory,
        agentSandbox: agentSandbox,
        agentToolPolicy: agentToolPolicy,
        variables: variables,
        output: output
      ),
      promptText: promptText,
      systemPromptText: systemPromptText,
      arguments: arguments,
      mergedVariables: mergedVariables,
      agentEnvironment: agentEnvironment
    )
  }
}
