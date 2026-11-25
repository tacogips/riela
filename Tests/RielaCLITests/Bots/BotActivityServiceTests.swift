import Foundation
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

final class BotActivityGraphQLTestsService: XCTestCase {
  func testLongPollClampsToTwentyFiveSecondsAcrossAnExecutionBoundary() async throws {
    var service = try fixture()
    let timeline = ActivityWaitTestClock()
    service.activityClock = { timeline.now }
    service.activitySleep = { timeline.advance(by: $0) }
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: service.store.sessionStoreRoot)
    let at = Date()
    await recorder.stepStarted(
      sessionId: "session", executionId: "step-1", stepId: "step", nodeId: "node",
      backend: nil, requestedModel: nil, at: at
    )
    await recorder.settle(sessionId: "session", executionId: "step-1", reason: .completed, stepStatus: "completed", at: at)
    let replay = try await service.activity(sessionId: "session")
    XCTAssertNil(replay.state?.currentExecutionId)
    XCTAssertFalse(replay.events.isEmpty)

    let page = try await service.activity(sessionId: "session", afterSequence: replay.lastSequence, waitMs: 60_000)
    XCTAssertTrue(page.events.isEmpty)
    XCTAssertEqual(page.sessionStatus, "running")
    XCTAssertEqual(timeline.sleeps, Array(repeating: .milliseconds(250), count: 100))
  }

  func testWaiterCapReleasesCancelledSlots() async throws {
    let fixture = try fixture()
    let held = expectation(description: "32 requests reached the poll timer")
    held.expectedFulfillmentCount = 32
    let service = waitingService(fixture, reportingTo: held)
    let tasks = (0..<32).map { _ in Task { try await service.activity(sessionId: "session", waitMs: 25_000) } }
    defer { tasks.forEach { $0.cancel() } }
    await fulfillment(of: [held], timeout: 10)

    var overflowProbe = service
    overflowProbe.activitySleep = { _ in throw UnexpectedActivityWait() }
    let overflow = try await overflowProbe.activity(sessionId: "session", waitMs: 25_000)
    XCTAssertTrue(overflow.events.isEmpty)
    XCTAssertEqual(overflow.sessionStatus, "running")
    let cancelled = try XCTUnwrap(tasks.first)
    cancelled.cancel()
    guard case let .failure(error) = await cancelled.result, error is CancellationError else {
      XCTFail("A cancelled activity wait must throw CancellationError")
      return
    }

    let replaced = expectation(description: "replacement wait reached the poll timer")
    let replacementService = waitingService(service, reportingTo: replaced)
    let replacement = Task { try await replacementService.activity(sessionId: "session", waitMs: 25_000) }
    defer { replacement.cancel() }
    await fulfillment(of: [replaced], timeout: 10)
    replacement.cancel()
    _ = await replacement.result
    for task in tasks {
      task.cancel()
      _ = await task.result
    }
  }

  func testGraphQLProviderMapsRevokedWaitToAuthenticationError() async throws {
    let service = try fixture()
    let authorization = ActivityWaitAuthorization()
    let provider = BotsGraphQLProvider(
      workingDirectory: service.workingDirectory, sessionStoreRoot: service.sessionStoreRoot, environment: service.environment,
      isStillAuthorized: { await authorization.check() }
    )
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let result = await executor.execute(GraphQLDocumentRequest(
      query: #"{ botActivity(sessionId: "session", waitMs: 2000) { events { seq } } }"#,
      environment: service.environment, isLocallyTrusted: true
    ))
    XCTAssertTrue(String(describing: result.body["errors"]).contains("UNAUTHENTICATED"), "\(result.body)")
    let checks = await authorization.checks
    XCTAssertEqual(checks, 2, "Revocation must be checked on the first re-poll")
  }

  func testGraphQLReplaysAndAnswersAStoredPermissionRequest() async throws {
    let service = try fixture()
    let waiting = expectation(description: "recorder is waiting on a stored permission request")
    let gate = AsyncStream<Void>.makeStream()
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: service.store.sessionStoreRoot, sleep: { _ in
      waiting.fulfill()
      for await _ in gate.stream { break }
    })
    await recorder.stepStarted(
      sessionId: "session", executionId: "step-1", stepId: "step", nodeId: "node",
      backend: nil, requestedModel: nil, at: Date()
    )
    let answerTask = Task {
      await recorder.requestPermission(
        sessionId: "session", executionId: "step-1", request: .init(options: [
          .init(optionId: "option/native-1", name: "Allow", kind: "allow_once")
        ]), waitMs: 60_000, deadline: nil
      )
    }
    defer {
      answerTask.cancel()
      gate.continuation.finish()
    }
    await fulfillment(of: [waiting], timeout: 10)

    let pending = try XCTUnwrap(service.store.pendingActivityRequests(sessionIds: ["session"]).first)
    let provider = BotsGraphQLProvider(
      workingDirectory: service.workingDirectory, sessionStoreRoot: service.sessionStoreRoot, environment: service.environment
    )
    let executor = BotsGraphQLDocumentExecutor(provider: provider)
    let activity = await executor.execute(GraphQLDocumentRequest(
      query: #"{ botActivity(sessionId: "session") { activitySource events { kind } } }"#,
      environment: service.environment, isLocallyTrusted: true
    ))
    XCTAssertNil(activity.body["errors"], "\(activity.body)")
    XCTAssertTrue(String(describing: activity.body["data"]).contains("permissionRequested"))

    let response = await executor.execute(GraphQLDocumentRequest(
      query: """
      mutation { answerBotRequest(input: {requestId: "\(pending.requestId)", optionId: "option/native-1"}) {
        status outcomeOptionId resolvedBy
      } }
      """, environment: service.environment, isLocallyTrusted: true
    ))
    XCTAssertNil(response.body["errors"], "\(response.body)")
    let expected: JSONValue = .object(["answerBotRequest": .object([
      "status": .string("answered"), "outcomeOptionId": .string("option/native-1"), "resolvedBy": .string("user")
    ])])
    XCTAssertEqual(response.body["data"], expected)
    if response.body["data"] != expected { answerTask.cancel() }
    gate.continuation.finish()
    let outcome = await answerTask.value
    XCTAssertEqual(outcome, .selected(optionId: "option/native-1"))
  }

  func testTerminalAndUnknownSessionsReturnWithoutWaiting() async throws {
    var service = try fixture(status: .completed)
    let timeline = ActivityWaitTestClock()
    service.activityClock = { timeline.now }
    service.activitySleep = { timeline.advance(by: $0) }
    let completed = try await service.activity(sessionId: "session", waitMs: 25_000)
    let missing = try await service.activity(sessionId: "removed-session", waitMs: 25_000)
    XCTAssertEqual(completed.sessionStatus, "completed")
    XCTAssertEqual(missing.sessionStatus, "unknown")
    XCTAssertTrue(timeline.sleeps.isEmpty)
  }

  private func waitingService(_ base: BotsService, reportingTo expectation: XCTestExpectation) -> BotsService {
    var service = base
    service.activitySleep = { _ in
      expectation.fulfill()
      try await Task.sleep(for: .seconds(20))
    }
    return service
  }

  private func fixture(status: WorkflowSessionStatus = .running) throws -> BotsService {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-12-activity-surfaces/service-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let service = BotsService(
      workingDirectory: root.path, sessionStoreRoot: root.appendingPathComponent(".riela/sessions").path,
      environment: ["HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path],
      activityWaiters: BotActivityWaiters()
    )
    let at = Date(timeIntervalSince1970: 1_790_000_000)
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: service.store.sessionStoreRoot)
    try runtime.save(.init(session: WorkflowSession(
      workflowId: "flow", sessionId: "session", status: status, entryStepId: "step",
      currentStepId: "step", createdAt: at, updatedAt: at
    )))
    return service
  }
}

private struct UnexpectedActivityWait: Error {}

private actor ActivityWaitAuthorization {
  private(set) var checks = 0

  func check() -> Bool {
    checks += 1
    return checks == 1
  }
}

private final class ActivityWaitTestClock: @unchecked Sendable {
  private let initial = ContinuousClock().now
  private let lock = NSLock()
  private var elapsed: Duration = .zero
  private var durations: [Duration] = []

  var now: ContinuousClock.Instant { lock.withLock { initial.advanced(by: elapsed) } }
  var sleeps: [Duration] { lock.withLock { durations } }

  func advance(by duration: Duration) {
    lock.withLock {
      durations.append(duration)
      elapsed += duration
    }
  }
}
