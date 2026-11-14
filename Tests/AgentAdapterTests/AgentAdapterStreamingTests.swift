import XCTest
@testable import CodexAgent
@testable import CursorCLIAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  func testCodexAndCursorAdaptersStreamContentBearingBackendEvents() async throws {
    let recorder = BackendEventRecorder()
    let context = AdapterExecutionContext { event in
      await recorder.append(event)
    }

    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(
        output: #"{"type":"item.completed","item":{"type":"agent_message","text":"codex text"}}"#
      ),
      authPreflight: false
    ).execute(input(backend: .codexAgent), context: context)
    _ = try await CursorCLIAgentAdapter(
      runner: StreamingRecordingRunner(
        output: [
          #"{"type":"thinking","subtype":"delta","text":"think"}"#,
          #"{"type":"assistant","message":{"content":[{"type":"text","text":"cursor text"}]}}"#
        ].joined(separator: "\n")
      ),
      authPreflight: false
    ).execute(input(backend: .cursorCliAgent), context: context)

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.channel), [.assistant, .thinking, .assistant])
    XCTAssertEqual(events.map(\.contentSnapshot), ["codex text", nil, "cursor text"])
    XCTAssertEqual(events.map(\.contentDelta), [nil, "think", nil])
    XCTAssertEqual(events.map(\.isDelta), [false, true, false])
  }

  func testStreamedBackendEventContentRedactsConfiguredEnvironmentSecrets() async throws {
    let recorder = BackendEventRecorder()
    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(
        output: #"{"type":"assistant.snapshot","content":"token is supersecret"}"#
      ),
      environment: ["TEST_SECRET_TOKEN": "supersecret"],
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.channel, .assistant)
    XCTAssertEqual(event.contentSnapshot, "token is <redacted>")
  }

  func testStreamedBackendEventContentTruncatesToByteCapWithoutSplittingCharacters() async throws {
    let recorder = BackendEventRecorder()
    let oversizedContent = String(repeating: "あ", count: 6_000)
    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(
        output: #"{"type":"assistant.snapshot","content":"\#(oversizedContent)"}"#
      ),
      authPreflight: false
    ).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    let event = try XCTUnwrap(events.first)
    let content = try XCTUnwrap(event.contentSnapshot)
    XCTAssertLessThanOrEqual(content.utf8.count, 16 * 1024)
    XCTAssertTrue(oversizedContent.hasPrefix(content))
  }

  func testCursorThinkingDeltasAreCoalescedBeforeBackendEventHandler() async throws {
    let recorder = BackendEventRecorder()
    let lines = (0..<300).map { _ in
      #"{"type":"thinking","subtype":"delta","text":"x"}"#
    }.joined(separator: "\n")

    let adapter = LocalAgentCommandAdapter(
      commandBuilder: CursorCLIAgentCommandBuilder(),
      runner: StreamingRecordingRunner(output: lines),
      backendEventCoalescingTimeThreshold: 2.0
    )

    _ = try await adapter.execute(
      input(backend: .cursorCliAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.channel), [.thinking, .thinking])
    XCTAssertEqual(events.compactMap(\.contentDelta).joined(), String(repeating: "x", count: 300))
  }

  func testThinkingDeltasUseProductionCoalescingLatencyByDefault() async throws {
    let recorder = BackendEventRecorder()
    let lines = Array(repeating: #"{"type":"thinking","subtype":"delta","text":"x"}"#, count: 3)
      .joined(separator: "\n")

    _ = try await CursorCLIAgentAdapter(
      runner: DelayedStreamingRecordingRunner(output: lines, delay: 0.3),
      authPreflight: false
    ).execute(
      input(backend: .cursorCliAgent),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.channel), [.thinking, .thinking])
    XCTAssertEqual(events.map(\.contentDelta), ["xx", "x"])
  }

  func testStreamBackendContentFalseFallsBackToTypeOnlyEvents() async throws {
    let recorder = BackendEventRecorder()
    _ = try await CodexAgentAdapter(
      runner: StreamingRecordingRunner(
        output: #"{"type":"assistant.snapshot","content":"hidden"}"#
      ),
      authPreflight: false
    ).execute(
      input(
        backend: .codexAgent,
        variables: ["streamBackendContent": .bool(false)]
      ),
      context: AdapterExecutionContext { event in
        await recorder.append(event)
      }
    )

    let events = await recorder.recordedEvents()
    let event = try XCTUnwrap(events.first)
    XCTAssertEqual(event.eventType, "assistant.snapshot")
    XCTAssertNil(event.channel)
    XCTAssertNil(event.contentSnapshot)
  }

  func testBackendEventHandlerLatencyDoesNotBlockOutputLineReplay() async throws {
    let runner = TimedStreamingReplayRunner(
      output: [
        #"{"type":"assistant.snapshot","content":"first"}"#,
        #"{"type":"assistant.snapshot","content":"second"}"#
      ].joined(separator: "\n")
    )

    _ = try await CodexAgentAdapter(runner: runner, authPreflight: false).execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { _ in
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    )

    let maybeReplayElapsed = await runner.replayElapsed()
    let replayElapsed = try XCTUnwrap(maybeReplayElapsed)
    XCTAssertLessThan(replayElapsed, 0.1)
  }
}

private actor TimedStreamingReplayStore {
  private var elapsed: TimeInterval?

  func setElapsed(_ elapsed: TimeInterval) {
    self.elapsed = elapsed
  }

  func replayElapsed() -> TimeInterval? {
    elapsed
  }
}

private final class TimedStreamingReplayRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming, @unchecked Sendable {
  private let output: String
  private let store = TimedStreamingReplayStore()

  init(output: String) {
    self.output = output
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration _: LocalAgentProcessConfiguration,
    stdin _: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    let start = Date()
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: line))
    }
    await store.setElapsed(Date().timeIntervalSince(start))
    return LocalAgentProcessResult(stdout: output, stderr: "", terminationStatus: 0)
  }

  func replayElapsed() async -> TimeInterval? {
    await store.replayElapsed()
  }
}

private final class DelayedStreamingRecordingRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming, @unchecked Sendable {
  private let output: String
  private let delay: TimeInterval

  init(output: String, delay: TimeInterval) {
    self.output = output
    self.delay = delay
  }

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration _: LocalAgentProcessConfiguration,
    stdin _: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    for line in output.split(whereSeparator: \.isNewline).map(String.init) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: line))
      try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    return LocalAgentProcessResult(stdout: output, stderr: "", terminationStatus: 0)
  }
}
