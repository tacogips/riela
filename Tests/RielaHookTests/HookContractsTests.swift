import XCTest
@testable import RielaCore
@testable import RielaHook

final class HookContractsTests: XCTestCase {
  func testHookContextDecodesPreTask006MinimalShapeWithDefaults() throws {
    let context = try JSONDecoder().decode(HookContext.self, from: Data(#"{"agentSessionId":"session-a","agentBackend":"codex"}"#.utf8))

    XCTAssertEqual(context.vendor, .codex)
    XCTAssertEqual(context.eventName, "unknown")
    XCTAssertEqual(context.agentSessionId, "session-a")
    XCTAssertEqual(context.agentBackend, "codex")
    XCTAssertEqual(context.workingDirectory, "")
    XCTAssertEqual(context.backendMetadata, [:])
    XCTAssertEqual(context.inferredFields, ["eventName", "vendor"])

    let encoded = try encodedObject(context)
    XCTAssertEqual(encoded["inferredFields"], .array([.string("eventName"), .string("vendor")]))
  }

  func testHookContextOmitsInferredFieldsWhenExplicit() throws {
    let context = HookContext(
      vendor: .claudeCode,
      eventName: "PostToolUse",
      agentSessionId: "session-a",
      workingDirectory: "/tmp/project"
    )
    let encoded = try encodedObject(context)
    let decoded = try JSONDecoder().decode(HookContext.self, from: try JSONEncoder().encode(context))

    XCTAssertEqual(decoded.inferredFields, [])
    XCTAssertNil(encoded["inferredFields"])
    XCTAssertEqual(encoded["vendor"], .string("claude-code"))
    XCTAssertEqual(encoded["eventName"], .string("PostToolUse"))
  }

  func testHookPayloadParsingNormalizesKnownEventsAndValidatesFields() throws {
    let parsed = try HookParsing.parse([
      "session_id": .string("session-a"),
      "hook_event_name": .string("post_tool_use"),
      "cwd": .string("/tmp/project"),
      "transcript_path": .null,
      "model": .string("gpt-5")
    ], vendor: .codex)

    XCTAssertEqual(parsed.context.vendor, .codex)
    XCTAssertEqual(parsed.context.eventName, "PostToolUse")
    XCTAssertEqual(parsed.context.agentSessionId, "session-a")
    XCTAssertEqual(parsed.context.workingDirectory, "/tmp/project")
    XCTAssertNil(parsed.context.transcriptPath)
  }

  func testHookPayloadParsingRedactsBackendMetadata() throws {
    let parsed = try HookParsing.parse([
      "session_id": .string("session-a"),
      "hook_event_name": .string("post_tool_use"),
      "cwd": .string("/tmp/project"),
      "api_key": .string("secret"),
      "nested": .object([
        "authorization": .string("Bearer token"),
        "stdout": .string("tool output"),
        "safe": .string("ok")
      ])
    ], vendor: .codex)

    XCTAssertEqual(parsed.context.backendMetadata["api_key"], .string("[REDACTED]"))
    XCTAssertEqual(parsed.context.backendMetadata["nested"], .object([
      "authorization": .string("[REDACTED]"),
      "stdout": .string("[REDACTED]"),
      "safe": .string("ok")
    ]))
  }

  func testHookPayloadParsingPreservesUnknownEventsAndRejectsMalformedOptionalFields() {
    XCTAssertNoThrow(try HookParsing.parse([
      "session_id": .string("session-a"),
      "hook_event_name": .string("FutureEvent"),
      "cwd": .string("/tmp/project")
    ]))

    XCTAssertThrowsError(try HookParsing.parse([
      "session_id": .string("session-a"),
      "hook_event_name": .string("PostToolUse"),
      "cwd": .string("/tmp/project"),
      "model": .number(1)
    ]))
  }

  func testHookPayloadParsingNormalizesFullKnownEventCatalogVariants() throws {
    let cases: [(String, String)] = [
      ("session-start", "SessionStart"),
      ("permission_denied", "PermissionDenied"),
      ("task completed", "TaskCompleted"),
      ("session_end", "SessionEnd"),
      ("pre-compact", "PreCompact"),
      ("post compact", "PostCompact")
    ]

    for (raw, expected) in cases {
      let parsed = try HookParsing.parse([
        "session_id": .string("session-a"),
        "hook_event_name": .string(raw),
        "cwd": .string("/tmp/project")
      ])

      XCTAssertEqual(parsed.context.eventName, expected)
    }
  }

  func testRedactionSafeRecorderRedactsSensitiveKeysByDefault() async {
    let context = HookContext(vendor: .codex, eventName: "PostToolUse", agentSessionId: "session-a", workingDirectory: "/tmp/project")
    let result = await RedactionSafeHookRecorder().record(.init(
      context: context,
      payload: [
        "api_key": .string("secret"),
        "nested": .object(["stdout": .string("tool output"), "safe": .string("ok")])
      ],
      controls: .init(recording: .auto, captureRaw: .redacted)
    ))

    XCTAssertTrue(result.recorded)
    XCTAssertNotNil(result.payloadHash)
    XCTAssertEqual(result.redactedPayload?["api_key"], .string("[REDACTED]"))
    XCTAssertEqual(result.redactedPayload?["nested"], .object(["stdout": .string("[REDACTED]"), "safe": .string("ok")]))
  }

  func testRedactionSafeRecorderPayloadHashIsStableAcrossDictionaryOrder() async {
    let context = HookContext(vendor: .codex, eventName: "PostToolUse", agentSessionId: "session-a", workingDirectory: "/tmp/project")
    let first = await RedactionSafeHookRecorder().record(.init(
      context: context,
      payload: [
        "z": .string("last"),
        "nested": .object(["b": .number(2), "a": .number(1)]),
        "a": .string("first")
      ],
      controls: .init(recording: .auto, captureRaw: .metadataOnly)
    ))
    let second = await RedactionSafeHookRecorder().record(.init(
      context: context,
      payload: [
        "a": .string("first"),
        "nested": .object(["a": .number(1), "b": .number(2)]),
        "z": .string("last")
      ],
      controls: .init(recording: .auto, captureRaw: .metadataOnly)
    ))

    XCTAssertTrue(first.recorded)
    XCTAssertEqual(first.payloadHash, second.payloadHash)
  }

  func testRecordingControlsPreserveEnvironmentContract() throws {
    let controls = try HookRecordingControls(env: [
      "RIELA_HOOK_RECORDING": "required",
      "RIELA_HOOK_STRICT": "true",
      "RIELA_HOOK_CAPTURE_RAW": "metadata-only"
    ])

    XCTAssertEqual(controls.recording, .required)
    XCTAssertTrue(controls.strict)
    XCTAssertEqual(controls.captureRaw, .metadataOnly)
  }

  func testRecordingControlsRejectInvalidEnvironmentValues() {
    XCTAssertThrowsError(try HookRecordingControls(env: ["RIELA_HOOK_RECORDING": "always"]))
    XCTAssertThrowsError(try HookRecordingControls(env: ["RIELA_HOOK_CAPTURE_RAW": "plain"]))
  }

  func testRielaHookContextResolverUsesNodeAndManagerEnvAliases() throws {
    let context = try HookContextResolver.resolveRielaHookContext(
      payload: ["session_id": .string("agent-session")],
      env: [
        "RIELA_WORKFLOW_ID": "workflow-a",
        "RIELA_WORKFLOW_EXECUTION_ID": "session-a",
        "RIELA_MANAGER_STEP_ID": "step-a",
        "RIELA_MANAGER_NODE_EXEC_ID": "exec-a",
        "RIELA_MANAGER_SESSION_ID": "manager-session",
        "RIELA_AGENT_BACKEND": "codex"
      ],
      controls: .init(recording: .required)
    )

    XCTAssertEqual(context?.workflowId, "workflow-a")
    XCTAssertEqual(context?.workflowExecutionId, "session-a")
    XCTAssertEqual(context?.nodeId, "step-a")
    XCTAssertEqual(context?.nodeExecId, "exec-a")
    XCTAssertEqual(context?.agentSessionId, "agent-session")
    XCTAssertEqual(context?.managerSessionId, "manager-session")
    XCTAssertEqual(context?.agentBackend, "codex")
  }

  func testRequiredRielaHookContextFailsWhenIncomplete() {
    XCTAssertThrowsError(try HookContextResolver.resolveRielaHookContext(
      payload: ["session_id": .string("agent-session")],
      env: [
        "RIELA_WORKFLOW_ID": "workflow-a",
        "RIELA_WORKFLOW_EXECUTION_ID": "session-a",
        "RIELA_NODE_ID": "step-a"
      ],
      controls: .init(recording: .required)
    ))

    XCTAssertNoThrow(try HookContextResolver.resolveRielaHookContext(
      payload: ["session_id": .string("agent-session")],
      env: [:],
      controls: .init(recording: .auto)
    ))
  }

  private func encodedObject<T: Encodable>(_ value: T) throws -> JSONObject {
    let data = try JSONEncoder().encode(value)
    guard case let .object(object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
      return [:]
    }
    return object
  }
}
