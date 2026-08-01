import Foundation
import RielaAdapters
import RielaCore
import XCTest
@testable import RielaCLI

// swiftlint:disable:next type_body_length
final class WorkflowCommandTests: XCTestCase {
  func testTopLevelHelpReturnsSuccessfulSmokeOutput() async {
    let result = await RielaCLIApplication().run(["--help"])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    XCTAssertTrue(result.stdout.contains("workflow validate"))
    XCTAssertTrue(result.stdout.contains("workflow run <workflow> [--variables <json|@file>]"))
    XCTAssertTrue(result.stdout.contains("Swift CLI is the production Homebrew runtime"))
    XCTAssertFalse(result.stdout.contains("TypeScript/Bun"))
    XCTAssertFalse(result.stdout.contains("cutover gates pass"))
  }

  func testValidateInspectAndDeterministicRunWorkerFixture() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cli-worker-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let app = RielaCLIApplication()

    let validate = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])
    XCTAssertEqual(validate.exitCode, .success)
    XCTAssertTrue(validate.stderr.isEmpty)
    let validation = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(validation.valid)
    XCTAssertEqual(validation.workflowId, "worker-only-single-step")
    XCTAssertEqual(validation.sourceScope, .direct)

    let inspect = await app.run([
      "workflow", "inspect", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json",
      "--structure"
    ])
    XCTAssertEqual(inspect.exitCode, .success)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: inspect.stdout)
    XCTAssertEqual(summary.entryStepId, "main-worker")
    XCTAssertEqual(summary.stepIds, ["main-worker"])
    XCTAssertEqual(summary.counts.steps, 1)
    XCTAssertEqual(summary.counts.crossWorkflowDispatches, 0)

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--variables", #"{"workflowInput":{"request":"noop reproduction for CLI variables handling"}}"#,
      "--session-store", sessionStore.path,
      "--output", "json"
    ])
    XCTAssertEqual(run.exitCode, .success)
    let result = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.workflowId, "worker-only-single-step")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.nodeExecutions, 1)
    XCTAssertEqual(result.transitions, 0)
    XCTAssertEqual(result.rootOutput?["status"], .string("ready"))
  }

  func testWorkflowRunDefaultsToJSONLEventsWithImmediateSessionRecord() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-default-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let run = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--variables", #"{"workflowInput":{"request":"noop reproduction for CLI variables handling"}}"#,
      "--session-store", sessionStore.path
    ])

    XCTAssertEqual(run.exitCode, .success)
    XCTAssertTrue(run.stderr.isEmpty)
    let lines = run.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 6)

    let first = try decodeJSON(WorkflowRunEvent.self, from: lines[0])
    XCTAssertEqual(first.type, .sessionStarted)
    XCTAssertEqual(first.workflowId, "worker-only-single-step")
    XCTAssertTrue(first.sessionId.hasPrefix("worker-only-single-step-session-"))

    let context = try decodeJSON(WorkflowRunContextRecord.self, from: lines[1])
    XCTAssertEqual(context.type, "run_context")
    XCTAssertEqual(context.sessionId, first.sessionId)
    XCTAssertEqual(context.workflowName, "worker-only-single-step")
    XCTAssertEqual(context.sessionStore, sessionStore.path)

    let final = try decodeJSON(WorkflowRunResultRecord.self, from: lines[5])
    XCTAssertEqual(final.type, "run_result")
    XCTAssertEqual(final.result.status, .completed)
    XCTAssertEqual(final.result.rootOutput?["status"], .string("ready"))
  }

  func testWorkflowRunJSONLWriterPersistsSessionBeforeStartRecordIsEmitted() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-live-session-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let probe = JSONLWriterProbe(sessionStore: sessionStore)
    let app = RielaCLIApplication(
      runCommand: WorkflowRunCommand(jsonlRecordWriter: { line in
        probe.record(line)
      })
    )

    let run = await app.run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--session-store", sessionStore.path
    ])

    XCTAssertEqual(run.exitCode, .success)
    XCTAssertTrue(run.stdout.isEmpty)
    XCTAssertTrue(run.stderr.isEmpty)
    XCTAssertTrue(probe.persistedAtSessionStart())
    XCTAssertEqual(probe.lines().count, 6)
    let canonicalDatabasePath = SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    )
    XCTAssertEqual(CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: sessionStore.path), canonicalDatabasePath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: canonicalDatabasePath))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStore.appendingPathComponent("cli-workflow-sessions.sqlite").path))
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: sessionStore.path).allSatisfy { !$0.hasSuffix(".json") })
  }

  func testWorkflowRunJSONLFailureIncludesBufferedProgressRecords() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-jsonl-buffered-failure-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "recent-change-quality-loop",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "jsonl"
    ])

    XCTAssertEqual(run.exitCode, .failure)
    XCTAssertTrue(run.stderr.isEmpty)
    let lines = run.stdout.split(separator: "\n").map(String.init)
    XCTAssertGreaterThanOrEqual(lines.count, 4)

    let first = try decodeJSON(WorkflowRunEvent.self, from: lines[0])
    XCTAssertEqual(first.type, .sessionStarted)
    XCTAssertEqual(first.workflowId, "recent-change-quality-loop")

    let context = try decodeJSON(WorkflowRunContextRecord.self, from: lines[1])
    XCTAssertEqual(context.type, "run_context")
    XCTAssertEqual(context.sessionId, first.sessionId)
    XCTAssertEqual(context.workflowName, "recent-change-quality-loop")
    XCTAssertEqual(context.sessionStore, sessionStore.path)

    XCTAssertTrue(lines.contains { $0.contains(#""type":"session_completed""#) })
    let failure = try decodeJSON(WorkflowRunFailureResult.self, from: lines[lines.count - 1])
    XCTAssertEqual(failure.sessionId, first.sessionId)
    XCTAssertEqual(failure.failureKind, .maxStepsExceeded)
    XCTAssertEqual(failure.stepBudgetDiagnostic?.stepBudget, 1)
  }

  func testUsageSupportsAddonSmokeWorkflow() async throws {
    let root = repositoryRoot()
    let result = await RielaCLIApplication().run([
      "workflow", "usage", "matrix-chat-reply",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])

    XCTAssertEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.isEmpty)
    let summary = try decodeJSON(WorkflowInspectionSummary.self, from: result.stdout)
    XCTAssertEqual(summary.workflowId, "matrix-chat-reply")
    XCTAssertTrue(summary.addonSourceSummaries.contains("reply-to-matrix:riela/chat-reply-worker"))
  }

  func testBuiltinChatReplyWorkerRendersInboxTemplateAndPreservesHandoffFlags() async throws {
    let output = try await BuiltinWorkflowAddonResolver(environment: [:]).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "send-yui-reply",
        nodeId: "send-yui-reply",
        addon: WorkflowNodeAddonRef(
          name: "riela/chat-reply-worker",
          version: "1",
          config: [
            "textTemplate": .string("{{inbox.latest.output.payload.replyText}}"),
            "replyAsTemplate": .string("{{replyAs}}")
          ]
        ),
        variables: [:],
        resolvedInputPayload: [
          "replyAs": .string("yui"),
          "replyText": .string("Yui reply"),
          "handoff_mika": .bool(true),
          "handoff_rina": .bool(false)
        ]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["replyText"], .string("Yui reply"))
    XCTAssertEqual(output.payload["text"], .string("Yui reply"))
    XCTAssertEqual(output.payload["replyAs"], .string("yui"))
    XCTAssertEqual(output.payload["dispatchStatus"], .string("intent-only"))
    XCTAssertEqual(output.when["handoff_mika"], true)
    XCTAssertEqual(output.when["handoff_rina"], false)
  }

  func testBuiltinSDKWorkerExecutesInjectedLiveAdapter() async throws {
    let harness = RecordingSDKAddonHarness()
    let usage = AdapterUsage(inputTokens: 21, outputTokens: 8, totalTokens: 29)
    let output = try await BuiltinWorkflowAddonResolver(
      environment: ["CURSOR_API_KEY": "cursor-secret"],
      cursorAdapterFactory: { _ in
        return await harness.makeAdapter(
          provider: "cursor-cli-agent",
          text: "最近はいい感じ。短く試せる形で返すね。",
          usage: usage
        )
      }
    ).execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "rina-cursor-sdk",
        nodeId: "rina-cursor-sdk",
        addon: WorkflowNodeAddonRef(
          name: "riela/cursor-sdk-worker",
          version: "1",
          config: [
            "model": .string("gpt-5.5"),
            "systemPromptTemplate": .string("You are {{persona}}."),
            "promptTemplate": .string("Reply to {{event.input.text}} as {{persona}}."),
            "mockResponseTemplate": .string("this mock must not be used")
          ]
        ),
        variables: [
          "event": .object(["input": .object(["text": .string("SDK trio")])]),
          "persona": .string("Rina")
        ],
        resolvedInputPayload: ["text": .string("hello"), "inputFilterSkipped": .bool(true)]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "cursor-cli-agent")
    XCTAssertEqual(output.model, "gpt-5.5")
    XCTAssertEqual(output.promptText, "Reply to SDK trio as Rina.")
    XCTAssertEqual(output.payload["executionBackend"], .string("official/cursor-sdk"))
    XCTAssertEqual(output.payload["text"], .string("最近はいい感じ。短く試せる形で返すね。"))
    XCTAssertEqual(output.payload["replyText"], .string("最近はいい感じ。短く試せる形で返すね。"))
    XCTAssertEqual(output.payload["liveExecution"], .bool(true))
    XCTAssertNil(output.payload["inputFilterSkipped"])
    XCTAssertEqual(output.usage, usage)

    let inputs = await harness.recordedInputs()
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.systemPromptText, "You are Rina.")
    XCTAssertEqual(input.mergedVariables["input"], .object(["text": .string("hello"), "inputFilterSkipped": .bool(true)]))
  }

  func testScenarioBackedAddonResolverUsesMockResponseBeforeFallback() async throws {
    let root = repositoryRoot()
    let resolver = try await makeScenarioBackedAddonResolver(
      scenarioPath: "\(root)/examples/telegram-sdk-trio-chat/mock-scenario.json",
      workingDirectory: root
    )
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-sdk-trio-chat",
        stepId: "rina-cursor-sdk",
        nodeId: "rina-cursor-sdk",
        addon: WorkflowNodeAddonRef(name: "riela/cursor-sdk-worker", version: "1"),
        variables: [:]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.provider, "scenario-mock")
    XCTAssertEqual(output.model, "gpt-5.3-codex-spark")
    let expectedText = "問題ない。直前の流れを見る限り、Mikaの答えは文脈に沿っている。"
    XCTAssertEqual(output.payload["text"], .string(expectedText))
    XCTAssertEqual(output.when["always"], true)
  }

  func testBuiltinChatPersonaRouterSelectsNamedPersonas() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-persona-router",
      version: "1",
      config: [
        "defaultPersonaId": .string("yui"),
        "personas": .array([
          .object(["id": .string("yui"), "aliases": .array([.string("yui"), .string("codex")])]),
          .object(["id": .string("mika"), "aliases": .array([.string("mika"), .string("claude")])]),
          .object(["id": .string("rina"), "aliases": .array([.string("rina"), .string("cursor")])])
        ])
      ]
    )

    let rina = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["workflowInput": .object(["request": .string("Rina に技術観点を聞いて")])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(rina.payload["target"], .string("rina"))
    XCTAssertEqual(rina.when["target_rina"], true)
    XCTAssertEqual(rina.when["target_yui"], false)

    let maki = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "telegram-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["humanInput": .object(["request": .string("Maki の見え方も聞きたい")])]
      ),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(maki.payload["target"], .string("mika"))
    XCTAssertEqual(maki.when["target_mika"], true)
  }

  func testBuiltinChatPersonaRouterPrefersEarliestAliasMention() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])
    let addon = WorkflowNodeAddonRef(
      name: "riela/chat-persona-router",
      version: "1",
      config: [
        "defaultPersonaId": .string("yui"),
        "personas": .array([
          .object(["id": .string("yui"), "aliases": .array([.string("yui"), .string("codex")])]),
          .object(["id": .string("mika"), "aliases": .array([.string("mika"), .string("claude")])]),
          .object(["id": .string("rina"), "aliases": .array([.string("rina"), .string("cursor")])])
        ])
      ]
    )

    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "discord-trio",
        stepId: "route-message",
        nodeId: "route-message",
        addon: addon,
        variables: ["workflowInput": .object(["request": .string("Rina, what image did I just show Mika?")])]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["target"], .string("rina"))
    XCTAssertEqual(output.when["target_rina"], true)
    XCTAssertEqual(output.when["target_mika"], false)
  }

  func testBuiltinGeminiSDKWorkerResolvesEnvironmentAndRenderedPrompt() async throws {
    let harness = RecordingGeminiAddonHarness()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: ["USER_GEMINI_KEY": "gemini-secret"],
      geminiAdapterFactory: { configuration in
        await harness.makeAdapter(configuration: configuration)
      }
    )
    let output = try await resolver.execute(
      WorkflowAddonExecutionInput(
        workflowId: "gemini-demo",
        stepId: "ask-gemini",
        nodeId: "ask-gemini",
        addon: WorkflowNodeAddonRef(
          name: "riela/gemini-sdk-worker",
          version: "1",
          config: [
            "model": .string("gemini-3.5-flash"),
            "systemPromptTemplate": .string("System {{topic}}"),
            "promptTemplate": .string("Reply about {{topic}} from {{input.prior}} and {{userText}}."),
            "inlineDataParts": .array([
              .object([
                "mimeType": .string("image/png"),
                "dataBase64": .string("iVBORw0KGgo=")
              ])
            ])
          ],
          env: [
            "GEMINI_API_KEY": .object([
              "fromEnv": .string("USER_GEMINI_KEY"),
              "required": .bool(true)
            ])
          ],
          inputs: [
            "userText": .string("{{input.prior}} plus addon input")
          ]
        ),
        variables: ["topic": .string("weather")],
        resolvedInputPayload: ["prior": .string("rain")]
      ),
      context: AdapterExecutionContext()
    )

    XCTAssertEqual(output.payload["text"], .string("gemini reply"))
    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.apiKeyEnv, "GEMINI_API_KEY")
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "gemini-secret")
    let inputs = await harness.recordedInputs()
    let input = try XCTUnwrap(inputs.first)
    XCTAssertEqual(input.node.executionBackend, .officialGeminiSDK)
    XCTAssertEqual(input.node.model, "gemini-3.5-flash")
    XCTAssertEqual(input.promptText, "Reply about weather from rain and rain plus addon input.")
    XCTAssertEqual(input.systemPromptText, "System weather")
    XCTAssertEqual(
      input.mergedVariables["geminiInlineDataParts"],
      .array([
        .object([
          "mimeType": .string("image/png"),
          "dataBase64": .string("iVBORw0KGgo=")
        ])
      ])
    )
  }

  func testBuiltinGeminiSDKWorkerPrefersGoogleAPIKeyTargetWhenBothAreMapped() async throws {
    let harness = RecordingGeminiAddonHarness()
    let resolver = BuiltinWorkflowAddonResolver(
      environment: [
        "USER_GEMINI_KEY": "gemini-test-key",
        "USER_GOOGLE_KEY": "google-test-key"
      ],
      geminiAdapterFactory: { configuration in
        await harness.makeAdapter(configuration: configuration)
      }
    )

    _ = try await resolver.execute(
      geminiAddonExecutionInput(
        env: [
          "GEMINI_API_KEY": .object(["fromEnv": .string("USER_GEMINI_KEY")]),
          "GOOGLE_API_KEY": .object(["fromEnv": .string("USER_GOOGLE_KEY")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.apiKeyEnv, "GOOGLE_API_KEY")
    XCTAssertEqual(configuration.environment?["GOOGLE_API_KEY"], "google-test-key")
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "gemini-test-key")
  }

  func testBuiltinGeminiSDKWorkerReadsTaskLocalCLIEnvironmentOverrides() async throws {
    let harness = RecordingGeminiAddonHarness()
    let output = try await CLIRuntimeEnvironment.$overrides.withValue(["USER_GEMINI_KEY": "override-gemini-key"]) {
      try await BuiltinWorkflowAddonResolver(
        geminiAdapterFactory: { configuration in
          await harness.makeAdapter(configuration: configuration)
        }
      ).execute(
        geminiAddonExecutionInput(),
        context: AdapterExecutionContext()
      )
    }

    XCTAssertEqual(output.payload["text"], .string("gemini reply"))
    let configurations = await harness.recordedConfigurations()
    let configuration = try XCTUnwrap(configurations.first)
    XCTAssertEqual(configuration.environment?["GEMINI_API_KEY"], "override-gemini-key")
  }

  func testBuiltinGeminiSDKWorkerFailsClosedWhenRequiredAPIKeyEnvIsMissing() async throws {
    let resolver = BuiltinWorkflowAddonResolver(environment: [:])

    do {
      _ = try await resolver.execute(geminiAddonExecutionInput(), context: AdapterExecutionContext())
      XCTFail("Expected missing Gemini key failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "required environment variable 'USER_GEMINI_KEY' is unavailable for addon.env.GEMINI_API_KEY")
    }
  }

  func testNodePatchIsInMemoryOnly() async throws {
    let root = repositoryRoot()
    let nodePath = "\(root)/examples/worker-only-single-step/nodes/node-main-worker.json"
    let before = try String(contentsOfFile: nodePath, encoding: .utf8)
    let app = RielaCLIApplication()
    let result = await app.run([
      "workflow", "validate", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--node-patch", #"{"main-worker":{"model":"gpt-5-mini","effort":"low"}}"#,
      "--executable",
      "--output", "json"
    ])
    XCTAssertEqual(result.exitCode, .success)
    let after = try String(contentsOfFile: nodePath, encoding: .utf8)
    XCTAssertEqual(after, before)
  }

  func geminiAddonExecutionInput(
    env: JSONObject = [
      "GEMINI_API_KEY": .object([
        "fromEnv": .string("USER_GEMINI_KEY"),
        "required": .bool(true)
      ])
    ]
  ) -> WorkflowAddonExecutionInput {
    WorkflowAddonExecutionInput(
      workflowId: "gemini-demo",
      stepId: "ask-gemini",
      nodeId: "ask-gemini",
      addon: WorkflowNodeAddonRef(
        name: "riela/gemini-sdk-worker",
        version: "1",
        config: [
          "model": .string("gemini-3.5-flash"),
          "systemPromptTemplate": .string("System {{topic}}"),
          "promptTemplate": .string("Reply about {{topic}} from {{input.prior}} and {{userText}}.")
        ],
        env: env,
        inputs: [
          "userText": .string("{{input.prior}} plus addon input")
        ]
      ),
      variables: ["topic": .string("weather")],
      resolvedInputPayload: ["prior": .string("rain")]
    )
  }
}
