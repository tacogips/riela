import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import RielaCore
@testable import RielaCLI
import WebHooky
import XCTest

/// Child-side runtime-environment behavior of `riela events serve`: listener
/// polls follow reloads, streams reconnect on a new generation, the channel
/// lives off fd 0/1, and channel EOF after bootstrap stops serving.
final class RuntimeEnvironmentListenerTests: XCTestCase {
  private func frame(_ generation: Int, _ values: [String: String], names: [String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["generation": generation, "managedNames": names, "values": values])
  }

  private let slackBase = [
    "TEST_SLACK_BOT_USER_ID": "U999",
    "TEST_SLACK_RIELA_TOKEN": "riela-token",
    "TEST_SLACK_YUI_TOKEN": "yui-token",
    "TEST_SLACK_MIKA_TOKEN": "mika-token",
    "TEST_SLACK_RINA_TOKEN": "rina-token"
  ]

  func testSlackPollUsesLatestAcceptedGenerationAfterReload() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let runtime = EventRuntimeEnvironment(base: slackBase, requiresBootstrap: true)
    let accepted = await runtime.replace(try frame(1, ["TEST_SLACK_TOKEN": "gen1-token"], names: ["TEST_SLACK_TOKEN"]))
    XCTAssertTrue(accepted.accepted)
    let reload = try frame(2, ["TEST_SLACK_TOKEN": "gen2-token"], names: ["TEST_SLACK_TOKEN"])
    // The first poll triggers a reload, as the App would between two polls.
    let api = ReloadingSlackGatewayAPI(onFirstPoll: { _ = await runtime.replace(reload) })
    let server = DefaultEventLiveServer(slackAPI: api, workflowRunner: FakeEventWorkflowRunner(failureMessage: "unused"))

    let result = try await server.serve(
      eventRoot: eventRoot, target: nil,
      parsed: try ParsedParityOptions(["--workflow-definition-dir", eventRoot.deletingLastPathComponent().path,
                                       "--limit", "2"]),
      runtime: runtime, required: [], stopsOnChannelClose: false
    )

    XCTAssertEqual(result.status, "ok")
    let tokens = await api.tokens
    XCTAssertEqual(tokens, ["gen1-token", "gen2-token"])
  }

  func testChannelEOFAfterBootstrapStopsServingWithSafeCode() async throws {
    let eventRoot = try temporaryDirectory()
    try writeSlackEventConfig(eventRoot: eventRoot)
    let runtime = EventRuntimeEnvironment(base: slackBase, requiresBootstrap: true)
    _ = await runtime.replace(try frame(1, ["TEST_SLACK_TOKEN": "gen1-token"], names: ["TEST_SLACK_TOKEN"]))
    // The parent disappears while the listener is serving without a limit.
    let api = ReloadingSlackGatewayAPI(onFirstPoll: { await runtime.close() })
    let server = DefaultEventLiveServer(slackAPI: api, workflowRunner: FakeEventWorkflowRunner(failureMessage: "unused"))
    let started = Date()
    do {
      _ = try await server.serve(
        eventRoot: eventRoot, target: nil,
        parsed: try ParsedParityOptions(["--workflow-definition-dir", eventRoot.deletingLastPathComponent().path]),
        runtime: runtime, required: [], stopsOnChannelClose: true
      )
      XCTFail("serving must stop when the channel closes")
    } catch let error as CLIUsageError {
      XCTAssertEqual(error.message, "environment_channel_closed")
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testChannelEOFIsIgnoredWithoutAManagedChannel() async throws {
    let runtime = EventRuntimeEnvironment(base: [:])
    await runtime.close()
    let captured = try await runtime.capture()
    XCTAssertEqual(captured, [:])
    let closed = await runtime.isClosed
    XCTAssertTrue(closed)
  }

  func testGenerationWaiterIsCancellable() async throws {
    let runtime = EventRuntimeEnvironment(base: [:], requiresBootstrap: true)
    let waiter = Task { try await runtime.awaitGeneration(after: 0) }
    waiter.cancel()
    do {
      try await waiter.value
      XCTFail("cancelled waiter must throw")
    } catch is CancellationError {}
    let next = Task { try await runtime.awaitGeneration(after: 0) }
    _ = await runtime.replace(try frame(1, ["A": "1"], names: ["A"]))
    try await next.value
  }

  func testWebhookyStreamReconnectsWithReloadedCredential() async throws {
    let eventRoot = try temporaryDirectory()
    let runtime = EventRuntimeEnvironment(base: ["HOOKY_URL": "http://127.0.0.1:9", "HOOKY_FETCH": "fetch"],
                                          requiresBootstrap: true)
    _ = await runtime.replace(try frame(1, ["HOOKY_CREDENTIAL": "key:gen1"], names: ["HOOKY_CREDENTIAL"]))
    let streamer = GenerationRecordingWebhookyStreamer()
    var server = DefaultEventLiveServer(webhookyStreamer: streamer)
    server.runtimeEnvironment = runtime
    let source = WebhookyStreamSource(id: "hooky", baseUrlEnv: "HOOKY_URL", credentialEnv: "HOOKY_CREDENTIAL",
                                      fetchUuidEnv: "HOOKY_FETCH")
    let buffer = WebhookyRecordBuffer()
    let tasks = server.startWebhookyStreams(sources: [source], buffer: buffer, eventRoot: eventRoot)
    defer { tasks.forEach { $0.cancel() } }

    try await waitUntil { streamer.credentials.count == 1 }
    _ = await runtime.replace(try frame(2, ["HOOKY_CREDENTIAL": "key:gen2"], names: ["HOOKY_CREDENTIAL"]))
    try await waitUntil { streamer.credentials.count == 2 }
    for task in tasks { await task.value }

    XCTAssertEqual(streamer.credentials, ["key:gen1", "key:gen2"])
    XCTAssertTrue(streamer.firstStreamTerminated)
    let finished = await buffer.allFinished(sourceIds: ["hooky"])
    XCTAssertTrue(finished)
  }

  func testDetachMovesChannelOffStandardDescriptorsCloseOnExec() throws {
    let standardIn = Pipe(), standardOut = Pipe()
    let inputDescriptor = standardIn.fileHandleForReading.fileDescriptor
    let outputDescriptor = standardOut.fileHandleForWriting.fileDescriptor

    let detached = try RuntimeEnvironmentChannelDescriptors.detach(input: inputDescriptor, output: outputDescriptor)

    for descriptor in [inputDescriptor, outputDescriptor] {
      XCTAssertTrue(isNullDevice(descriptor), "fd \(descriptor) must point at /dev/null")
    }
    for descriptor in [detached.input.fileDescriptor, detached.output.fileDescriptor] {
      XCTAssertGreaterThan(descriptor, 2)
      XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0, "fd \(descriptor) must be close-on-exec")
    }
    // The private descriptors still carry the original pipes.
    try standardIn.fileHandleForWriting.write(contentsOf: Data("frame\n".utf8))
    XCTAssertEqual(try detached.input.read(upToCount: 6), Data("frame\n".utf8))
    try detached.output.write(contentsOf: Data("ack\n".utf8))
    XCTAssertEqual(try standardOut.fileHandleForReading.read(upToCount: 4), Data("ack\n".utf8))

    // A subprocess sees neither private descriptor.
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/bin/sh")
    probe.arguments = ["-c", "for fd in \"$@\"; do if [ -e /dev/fd/$fd ]; then echo open; fi; done", "sh",
                       String(detached.input.fileDescriptor), String(detached.output.fileDescriptor)]
    let probeOutput = Pipe()
    probe.standardOutput = probeOutput
    probe.standardInput = FileHandle.nullDevice
    try probe.run()
    probe.waitUntilExit()
    let inherited = String(data: probeOutput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertFalse(inherited.contains("open"))
  }

  func testOnlySafeCodesAreReportedOnStderr() {
    XCTAssertEqual(RuntimeEnvironmentChannelDescriptors.safeCodeLine("environment_channel_closed"),
                   "environment_channel_closed\n")
    XCTAssertEqual(RuntimeEnvironmentChannelDescriptors.safeCodeLine("environment_required_missing"),
                   "environment_required_missing\n")
    for unsafe in ["", "Token sk-secret rejected", "environment_value=secret", "error: environment_x",
                   String(repeating: "a", count: 97)] {
      XCTAssertNil(RuntimeEnvironmentChannelDescriptors.safeCodeLine(unsafe), unsafe)
    }
  }

  // MARK: - Helpers

  private func isNullDevice(_ descriptor: Int32) -> Bool {
    var actual = stat(), null = stat()
    guard fstat(descriptor, &actual) == 0, stat("/dev/null", &null) == 0 else { return false }
    return actual.st_rdev == null.st_rdev && (actual.st_mode & S_IFMT) == S_IFCHR
  }

  private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      guard Date() < deadline else { throw CLIUsageError("timed out waiting for condition") }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-runtime-environment-listener-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent(".riela-events", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return url
  }

  private func writeSlackEventConfig(eventRoot: URL) throws {
    let sources = eventRoot.appendingPathComponent("sources", isDirectory: true)
    let bindings = eventRoot.appendingPathComponent("bindings", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bindings, withIntermediateDirectories: true)
    try """
    {
      "id": "slack-live", "kind": "slack-gateway", "provider": "slack",
      "tokenEnv": "TEST_SLACK_TOKEN", "botUserIdEnv": "TEST_SLACK_BOT_USER_ID",
      "channels": [{"id": "C200"}], "polling": {"limit": 1},
      "replyBots": {"riela": {"tokenEnv": "TEST_SLACK_RIELA_TOKEN"}}
    }
    """.write(to: sources.appendingPathComponent("slack-live.json"), atomically: true, encoding: .utf8)
    try """
    {
      "id": "slack-to-workflow", "sourceId": "slack-live", "workflowName": "slack-flow",
      "match": {"eventType": "chat.message"},
      "inputMapping": {"mode": "template", "template": {"request": "{{event.input.text}}"}}
    }
    """.write(to: bindings.appendingPathComponent("slack-to-workflow.json"), atomically: true, encoding: .utf8)
  }
}

/// Returns one bot-self message per poll (counted, never dispatched) and
/// records the token each poll presented.
private actor ReloadingSlackGatewayAPI: SlackGatewayAPI {
  private(set) var tokens: [String] = []
  private var onFirstPoll: (@Sendable () async -> Void)?

  init(onFirstPoll: @escaping @Sendable () async -> Void) {
    self.onFirstPoll = onFirstPoll
  }

  func getMessages(request: SlackGetMessagesRequest) async throws -> [SlackMessage] {
    tokens.append(request.token)
    if let hook = onFirstPoll {
      onFirstPoll = nil
      await hook()
    }
    let timestamp = String(format: "1780000000.%06d", tokens.count)
    return [try SlackMessage.fixture(ts: timestamp, user: "U999", text: "self")]
  }

  func sendMessage(request: SlackSendMessageRequest) async throws {}
}

/// First stream stays open until terminated; later streams finish at once.
private final class GenerationRecordingWebhookyStreamer: WebhookyRecordStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  private var terminated = false

  var credentials: [String] { lock.withLock { recorded } }
  var firstStreamTerminated: Bool { lock.withLock { terminated } }

  func stream(source: WebhookyStreamSource, environment: [String: String]) throws
    -> AsyncThrowingStream<WebhookRecord, Error> {
    let isFirst = lock.withLock { () -> Bool in
      recorded.append(environment[source.credentialEnv] ?? "missing")
      return recorded.count == 1
    }
    return AsyncThrowingStream { continuation in
      if isFirst {
        continuation.onTermination = { [weak self] _ in
          guard let self else { return }
          self.lock.withLock { self.terminated = true }
        }
      } else {
        continuation.finish()
      }
    }
  }
}
