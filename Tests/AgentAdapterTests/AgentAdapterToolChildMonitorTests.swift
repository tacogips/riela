import XCTest
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

extension AgentAdapterTests {
  /// Wiring regression for the terminal tool-child monitor: the adapter
  /// starts the monitor, delivers the spawned pid, taps every stdout line,
  /// and awaits `stop()` on completion — with no hang and no leaked monitor.
  func testCommandAdapterDrivesToolChildMonitorLifecycle() async throws {
    let monitor = SpyToolChildMonitor()
    let lines = [
      #"{"type":"item.started","item":{"id":"call-1","type":"command_execution","command":"swift test"}}"#,
      #"{"type":"item.completed","item":{"id":"call-1","type":"command_execution"}}"#,
      #"{"type":"item.completed","item":{"type":"agent_message","text":"summary done"}}"#
    ].joined(separator: "\n")
    let adapter = LocalAgentCommandAdapter(
      commandBuilder: MonitoredCommandBuilder(monitor: monitor, output: lines),
      runner: SpawnObservingStreamingRunner(output: lines)
    )

    _ = try await adapter.execute(
      input(backend: .codexAgent),
      context: AdapterExecutionContext { _ in }
    )

    XCTAssertTrue(monitor.startedFlag(), "monitor starts before the process runs")
    XCTAssertEqual(monitor.spawnedProcessIds(), [4_242], "spawned pid is delivered for correlation")
    XCTAssertEqual(monitor.observedLines().count, 3, "every stdout line is tapped")
    XCTAssertTrue(monitor.stoppedFlag(), "stop() is awaited on completion — no leaked monitor")
  }

  func testCommandAdapterStopsMonitorOnFailure() async throws {
    let monitor = SpyToolChildMonitor()
    let adapter = LocalAgentCommandAdapter(
      commandBuilder: MonitoredCommandBuilder(monitor: monitor, output: ""),
      runner: SpawnObservingStreamingRunner(output: "", terminationStatus: 3)
    )

    do {
      _ = try await adapter.execute(
        input(backend: .codexAgent),
        context: AdapterExecutionContext { _ in }
      )
      XCTFail("expected provider failure")
    } catch {}
    XCTAssertTrue(monitor.stoppedFlag(), "stop() is awaited on the failure path too")
  }
}

private struct MonitoredCommandBuilder: LocalAgentCommandBuilding {
  var monitor: SpyToolChildMonitor
  var output: String
  var provider: String { "codex-agent" }

  func buildCommand(for input: AdapterExecutionInput) throws -> LocalAgentCommand {
    LocalAgentCommand(
      provider: provider,
      configuration: LocalAgentProcessConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["true"],
        environment: [:]
      ),
      stdin: "prompt",
      toolChildMonitor: monitor
    )
  }
}

private final class SpyToolChildMonitor: LocalAgentToolChildMonitoring, @unchecked Sendable {
  private let lock = NSLock()
  private var started = false
  private var stopped = false
  private var pids: [Int32] = []
  private var lines: [String] = []

  func start(emitBackendEvent: @escaping @Sendable (AdapterBackendEvent) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    started = true
  }

  func processSpawned(_ processId: Int32) {
    lock.lock()
    defer { lock.unlock() }
    pids.append(processId)
  }

  func observeStdoutLine(_ line: String) {
    lock.lock()
    defer { lock.unlock() }
    lines.append(line)
  }

  func stop() async {
    markStopped()
  }

  private func markStopped() {
    lock.lock()
    defer { lock.unlock() }
    stopped = true
  }

  func startedFlag() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func stoppedFlag() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  func spawnedProcessIds() -> [Int32] {
    lock.lock()
    defer { lock.unlock() }
    return pids
  }

  func observedLines() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}

private struct SpawnObservingStreamingRunner: LocalAgentProcessRunning, LocalAgentProcessEventStreaming, LocalAgentProcessSpawnObserving {
  var output: String
  var terminationStatus: Int32 = 0

  func run(configuration: LocalAgentProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalAgentProcessResult {
    try await run(configuration: configuration, stdin: stdin, deadline: deadline, outputEventHandler: nil, spawnHandler: nil)
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    try await run(
      configuration: configuration,
      stdin: stdin,
      deadline: deadline,
      outputEventHandler: outputEventHandler,
      spawnHandler: nil
    )
  }

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?,
    outputEventHandler: (@Sendable (LocalAgentProcessOutputEvent) -> Void)?,
    spawnHandler: (@Sendable (Int32) -> Void)?
  ) async throws -> LocalAgentProcessResult {
    spawnHandler?(4_242)
    for line in output.split(whereSeparator: \.isNewline) {
      outputEventHandler?(LocalAgentProcessOutputEvent(stream: .stdout, line: String(line)))
    }
    return LocalAgentProcessResult(stdout: output, stderr: "", terminationStatus: terminationStatus)
  }
}
