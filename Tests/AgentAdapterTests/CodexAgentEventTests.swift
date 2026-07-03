import XCTest
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testCodexItemStartedAndUpdatedToolEventsAreRecorded() async throws {
    let codexJSONL = """
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"sed -n '1,80p' Sources/CodexAgent/CodexAgentAdapter.swift","status":"in_progress"}}
    {"type":"item.updated","item":{"id":"item_2","type":"tool_call","name":"write_stdin","text":"polling unified exec session","status":"in_progress"}}
    """
    let recorder = BackendEventRecorder()

    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: codexJSONL),
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.eventType), ["item.started", "item.updated"])
    XCTAssertEqual(events.map(\.channel), [.tool, .tool])
    XCTAssertEqual(events.map(\.toolName), ["command_execution", "write_stdin"])
    XCTAssertEqual(
      events.map(\.contentSnapshot),
      [
        "sed -n '1,80p' Sources/CodexAgent/CodexAgentAdapter.swift",
        "polling unified exec session"
      ]
    )
  }

  func testCodexItemStartedDoesNotBecomeAssistantOutput() async throws {
    let codexJSONL = """
    {"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"swift test","status":"in_progress"}}
    {"type":"item.completed","item":{"id":"item_2","type":"agent_message","text":"final assistant text"}}
    """

    let output = try await CodexAgentAdapter(
      runner: CapturingRunner(output: codexJSONL),
      authPreflight: false
    ).execute(input(backend: .codexAgent), context: AdapterExecutionContext())

    XCTAssertEqual(output.payload["text"], .string("final assistant text"))
  }

  func testCodexUnknownItemStartedFallsBackToLifecycleEvent() async throws {
    let codexJSONL = """
    {"type":"item.started","item":{"id":"item_1","type":"unknown_future_item","status":"in_progress"}}
    """
    let recorder = BackendEventRecorder()

    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: codexJSONL),
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.eventType, "item.started")
    XCTAssertEqual(event.channel, .lifecycle)
  }

  func testCodexNonToolItemProgressFallsBackToLifecycleEvent() async throws {
    let codexJSONL = """
    {"type":"item.started","item":{"id":"item_1","type":"agent_message","text":"draft assistant text"}}
    {"type":"item.updated","item":{"id":"item_2","type":"reasoning","text":"draft reasoning text"}}
    """
    let recorder = BackendEventRecorder()

    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(output: codexJSONL),
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.eventType), ["item.started", "item.updated"])
    XCTAssertEqual(events.map(\.channel), [.lifecycle, .lifecycle])
    XCTAssertEqual(events.map(\.contentSnapshot), [nil, nil])
  }

  func testCodexUnifiedExecFalseAddsDisableArgument() async throws {
    let runner = RecordingRunner(output: "done")

    _ = try await CodexAgentAdapter(runner: runner, authPreflight: false).execute(
      input(
        backend: .codexAgent,
        variables: [
          "codexUnifiedExec": .bool(false),
          "codexAdditionalArgs": .array([.string("--skip-git-repo-check")])
        ]
      ),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    let args = try XCTUnwrap(runs.last?.configuration.arguments)
    XCTAssertTrue(args.containsSubsequence(["--disable", "unified_exec"]))
    XCTAssertTrue(args.containsSubsequence(["--disable", "unified_exec", "--skip-git-repo-check"]))
  }
}
