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
    XCTAssertEqual(events.map(\.channel), [.thinking, .thinking, .thinking])
    XCTAssertEqual(events.map(\.contentDelta), ["x", "x", "x"])
  }

  func testCoalescerTimerFlushesIsolatedDeltaWithoutLaterOutput() {
    let scheduler = ManualBackendEventTimerScheduler()
    let recorder = LockedBackendEventRecorder()
    let coalescer = BackendEventCoalescer(
      timerScheduler: scheduler.schedule(delay:action:)
    )

    coalescer.absorb(thinkingDelta("isolated")) { recorder.append($0) }
    XCTAssertEqual(recorder.events, [])
    XCTAssertEqual(scheduler.scheduledDelays, [0.25])

    scheduler.fireNext()

    XCTAssertEqual(recorder.events.map(\.contentDelta), ["isolated"])
  }

  func testCoalescerImmediatelyFlushesInitialDeltaAtExactByteThresholdOnce() {
    assertInitialDeltaImmediatelyFlushesOnce(String(repeating: "x", count: 256))
  }

  func testCoalescerImmediatelyFlushesInitialDeltaAboveByteThresholdOnce() {
    assertInitialDeltaImmediatelyFlushesOnce(String(repeating: "é", count: 129))
  }

  func testCoalescerFlushesPendingDeltaBeforeChannelSwitchAndSameChannelSnapshot() {
    let scheduler = ManualBackendEventTimerScheduler()
    let recorder = LockedBackendEventRecorder()
    let coalescer = BackendEventCoalescer(
      timerScheduler: scheduler.schedule(delay:action:)
    )

    coalescer.absorb(thinkingDelta("thinking")) { recorder.append($0) }
    coalescer.absorb(assistantSnapshot("assistant")) { recorder.append($0) }
    coalescer.absorb(thinkingDelta("more thinking")) { recorder.append($0) }
    coalescer.absorb(thinkingSnapshot("snapshot")) { recorder.append($0) }

    XCTAssertEqual(recorder.events.map(\.channel), [.thinking, .assistant, .thinking, .thinking])
    XCTAssertEqual(
      recorder.events.map { $0.contentDelta ?? $0.contentSnapshot },
      ["thinking", "assistant", "more thinking", "snapshot"]
    )
  }

  func testCoalescerFinishDrainsPendingDeltaOnceAndRejectsLateTimerYield() {
    let scheduler = ManualBackendEventTimerScheduler()
    let recorder = LockedBackendEventRecorder()
    let coalescer = BackendEventCoalescer(
      timerScheduler: scheduler.schedule(delay:action:)
    )

    coalescer.absorb(thinkingDelta("tail")) { recorder.append($0) }
    coalescer.finish { recorder.append($0) }
    scheduler.fireAllIncludingCancelled()
    coalescer.finish { recorder.append($0) }

    XCTAssertEqual(recorder.events.map(\.contentDelta), ["tail"])
  }

  func testBackendEventBridgeDrainsPendingDeltaOnSuccessAndThrownError() async throws {
    for mode in [TerminalStreamingRunner.Mode.success, .failure] {
      let recorder = BackendEventRecorder()
      let adapter = LocalAgentCommandAdapter(
        commandBuilder: CursorCLIAgentCommandBuilder(),
        runner: TerminalStreamingRunner(mode: mode),
        backendEventCoalescingTimeThreshold: 60
      )

      do {
        _ = try await adapter.execute(
          input(backend: .cursorCliAgent),
          context: AdapterExecutionContext { event in await recorder.append(event) }
        )
        XCTAssertEqual(mode, .success)
      } catch is TerminalStreamingRunner.Failure {
        XCTAssertEqual(mode, .failure)
      }

      let events = await recorder.recordedEvents()
      XCTAssertEqual(events.map(\.contentDelta), ["tail"])
    }
  }

  func testBackendEventBridgeDrainsPendingDeltaOnCancellation() async throws {
    let recorder = BackendEventRecorder()
    let runner = TerminalStreamingRunner(mode: .waitForCancellation)
    let adapter = LocalAgentCommandAdapter(
      commandBuilder: CursorCLIAgentCommandBuilder(),
      runner: runner,
      backendEventCoalescingTimeThreshold: 60
    )
    let adapterInput = input(backend: .cursorCliAgent)
    let task = Task {
      try await adapter.execute(
        adapterInput,
        context: AdapterExecutionContext { event in await recorder.append(event) }
      )
    }
    await runner.waitUntilEventEmitted()

    task.cancel()
    do {
      _ = try await task.value
      XCTFail("expected cancellation")
    } catch is CancellationError {
      // Expected.
    }

    let events = await recorder.recordedEvents()
    XCTAssertEqual(events.map(\.contentDelta), ["tail"])
  }

  private func assertInitialDeltaImmediatelyFlushesOnce(
    _ delta: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let scheduler = ManualBackendEventTimerScheduler()
    let recorder = LockedBackendEventRecorder()
    let coalescer = BackendEventCoalescer(
      timerScheduler: scheduler.schedule(delay:action:)
    )

    coalescer.absorb(thinkingDelta(delta)) { recorder.append($0) }

    XCTAssertEqual(recorder.events.map(\.contentDelta), [delta], file: file, line: line)
    XCTAssertEqual(scheduler.scheduledDelays, [], file: file, line: line)

    scheduler.fireAllIncludingCancelled()
    coalescer.finish { recorder.append($0) }

    XCTAssertEqual(recorder.events.map(\.contentDelta), [delta], file: file, line: line)
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

private func thinkingDelta(_ text: String) -> AdapterBackendEvent {
  AdapterBackendEvent(
    provider: "cursor-cli-agent",
    eventType: "thinking",
    channel: .thinking,
    contentDelta: text,
    isDelta: true
  )
}

private func thinkingSnapshot(_ text: String) -> AdapterBackendEvent {
  AdapterBackendEvent(
    provider: "cursor-cli-agent",
    eventType: "thinking",
    channel: .thinking,
    contentSnapshot: text
  )
}

private func assistantSnapshot(_ text: String) -> AdapterBackendEvent {
  AdapterBackendEvent(
    provider: "cursor-cli-agent",
    eventType: "assistant",
    channel: .assistant,
    contentSnapshot: text
  )
}

private final class LockedBackendEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedEvents: [AdapterBackendEvent] = []

  var events: [AdapterBackendEvent] {
    lock.withLock { storedEvents }
  }

  func append(_ event: AdapterBackendEvent) {
    lock.withLock { storedEvents.append(event) }
  }
}

private final class ManualBackendEventTimerScheduler: @unchecked Sendable {
  private struct Entry {
    var delay: TimeInterval
    var action: @Sendable () -> Void
    var isCancelled = false
  }

  private let lock = NSLock()
  private var entries: [Entry] = []

  var scheduledDelays: [TimeInterval] {
    lock.withLock { entries.map(\.delay) }
  }

  func schedule(
    delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> BackendEventCoalescer.TimerCancellation {
    let index = lock.withLock {
      entries.append(Entry(delay: delay, action: action))
      return entries.index(before: entries.endIndex)
    }
    return { [weak self] in
      self?.lock.withLock {
        guard self?.entries.indices.contains(index) == true else {
          return
        }
        self?.entries[index].isCancelled = true
      }
    }
  }

  func fireNext() {
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard let index = entries.firstIndex(where: { !$0.isCancelled }) else {
        return nil
      }
      entries[index].isCancelled = true
      return entries[index].action
    }
    action?()
  }

  func fireAllIncludingCancelled() {
    let actions = lock.withLock { entries.map(\.action) }
    actions.forEach { $0() }
  }
}

private actor TerminalStreamingRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming {
  enum Mode: Equatable, Sendable {
    case success
    case failure
    case waitForCancellation
  }

  struct Failure: Error {}

  private let mode: Mode
  private var emitted = false
  private var emissionWaiters: [CheckedContinuation<Void, Never>] = []

  init(mode: Mode) {
    self.mode = mode
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil)
  }

  func run(
    configuration _: LocalAgentProcessConfiguration,
    stdin _: String,
    deadline _: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    let output = #"{"type":"thinking","subtype":"delta","text":"tail"}"#
    outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: output))
    emitted = true
    emissionWaiters.forEach { $0.resume() }
    emissionWaiters.removeAll()
    switch mode {
    case .success:
      return LocalAgentProcessResult(stdout: output, stderr: "", terminationStatus: 0)
    case .failure:
      throw Failure()
    case .waitForCancellation:
      try await Task.sleep(nanoseconds: 60_000_000_000)
      return LocalAgentProcessResult(stdout: output, stderr: "", terminationStatus: 0)
    }
  }

  func waitUntilEventEmitted() async {
    guard !emitted else {
      return
    }
    await withCheckedContinuation { continuation in
      emissionWaiters.append(continuation)
    }
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
