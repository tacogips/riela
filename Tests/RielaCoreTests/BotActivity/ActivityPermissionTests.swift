import Foundation
import XCTest
@testable import RielaCore

final class ActivityPermissionTests: XCTestCase {
  func testSelectsOfferedOptionAndPublishesOnce() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let recorder = fixture.recorder { _ in
      let pending = try? fixture.pending()
      guard let request = pending?.first else { return }
      _ = try? fixture.store.answerActivityRequest(requestId: request.requestId, optionId: "native:allow")
    }
    await fixture.start(recorder)
    let outcome = await fixture.request(recorder)
    XCTAssertEqual(outcome, .selected(optionId: "native:allow"))
    let events = try fixture.events()
    XCTAssertEqual(events.map(\.kind), [.stepStarted, .permissionRequested, .permissionResolved])
    XCTAssertEqual(events.last?.payload["resolvedBy"], .string("user"))
    XCTAssertEqual(events.last?.payload["optionId"], .string("native:allow"))
    XCTAssertTrue(try fixture.pending().isEmpty)
  }

  func testUserAnswerHonorsSessionJournalRetention() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let recorder = SQLiteWorkflowActivityRecorder(
      sessionStoreRoot: fixture.root.path, limits: .init(maxEventsPerSession: 2),
      sleep: { _ in
        if let id = try? fixture.pendingId() {
          _ = try? fixture.store.answerActivityRequest(requestId: id, decline: true)
        }
      }
    )
    await fixture.start(recorder)
    let outcome = await fixture.request(recorder)
    let page = try fixture.store.activityPage(sessionId: "session")
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(page.firstRetainedSequence, 2)
    XCTAssertEqual(page.events.map(\.kind), [.permissionRequested, .permissionResolved])
  }

  func testDeclineReturnsCancelledAndFirstAnswerWins() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let evidence = PermissionPollEvidence()
    let recorder = fixture.recorder { _ in
      do {
        let id = try fixture.pendingId()
        let answer = try fixture.store.answerActivityRequest(requestId: id, decline: true)
        await evidence.record(answer.resolvedBy?.rawValue)
        _ = try fixture.store.answerActivityRequest(requestId: id, optionId: "native:allow")
      } catch let error as BotStoreError {
        await evidence.record(error.code)
      } catch {
        await evidence.record(String(describing: error))
      }
    }
    await fixture.start(recorder)
    let outcome = await fixture.request(recorder)
    let observations = await evidence.observations
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(observations, ["user", "request_already_resolved"])
    XCTAssertEqual(try fixture.events().last?.payload["outcome"], .string("cancelled"))
  }

  func testUnknownOptionLeavesRequestPending() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let evidence = PermissionPollEvidence()
    let recorder = fixture.recorder { _ in
      do {
        let id = try fixture.pendingId()
        _ = try fixture.store.answerActivityRequest(requestId: id, optionId: "unknown")
      } catch let error as BotStoreError {
        await evidence.record(error.code)
        if let pending = try? fixture.pending(), pending.count == 1 {
          await evidence.record(pending.first?.status.rawValue)
          if let request = pending.first {
            _ = try? fixture.store.answerActivityRequest(requestId: request.requestId, decline: true)
          }
        }
      } catch {
        await evidence.record(String(describing: error))
      }
    }
    await fixture.start(recorder)
    let outcome = await fixture.request(recorder)
    let observations = await evidence.observations
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(observations, ["request_option_unknown", "pending"])
  }

  func testExpiryHonorsDeadlineAndRejectsLateAnswer() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let evidence = PermissionPollEvidence()
    let recorder = fixture.recorder { _ in
      do {
        let id = try fixture.pendingId()
        _ = try fixture.store.answerActivityRequest(requestId: id, decline: true, now: .distantFuture)
      } catch let error as BotStoreError {
        await evidence.record(error.code)
      } catch {
        await evidence.record(String(describing: error))
      }
    }
    await fixture.start(recorder)
    let deadline = Date().addingTimeInterval(10)
    let outcome = await fixture.request(recorder, waitMs: 30_000, deadline: deadline)
    let observations = await evidence.observations
    let events = try fixture.events()
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertFalse(observations.isEmpty)
    XCTAssertEqual(Set(observations), ["request_expired"])
    XCTAssertEqual(events.first { $0.kind == .permissionRequested }?.payload["expiresAt"], .string(RoutineStore.timestamp(deadline)))
    XCTAssertEqual(events.last?.payload["resolvedBy"], .string("timeout"))
  }

  func testZeroWaitResolvesWithoutSleeping() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let evidence = PermissionPollEvidence()
    let recorder = fixture.recorder { _ in await evidence.record("slept") }
    await fixture.start(recorder)
    let outcome = await fixture.request(recorder, waitMs: 0)
    let observations = await evidence.observations
    let events = try fixture.events()
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertTrue(observations.isEmpty)
    XCTAssertEqual(events.map(\.kind), [.stepStarted, .permissionRequested, .permissionResolved])
    XCTAssertEqual(events.last?.payload["resolvedBy"], .string("policy"))
    XCTAssertTrue(try fixture.pending().isEmpty)
  }

  func testProcessSettlementReleasesPendingPermission() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let (polls, polling) = AsyncStream<Void>.makeStream()
    let (releases, release) = AsyncStream<Void>.makeStream()
    let recorder = fixture.recorder { _ in
      polling.yield(())
      var iterator = releases.makeAsyncIterator()
      _ = await iterator.next()
    }
    await fixture.start(recorder)
    let pending = Task {
      defer { polling.finish() }
      return await fixture.request(recorder)
    }
    var iterator = polls.makeAsyncIterator()
    guard await iterator.next() != nil else {
      _ = await pending.result
      return XCTFail("Permission handler did not begin polling")
    }
    let settled = Result { try fixture.store.settleOpenActivity(sessionId: "session", reason: .processExit, at: Date()) }
    release.finish()
    let outcome = await pending.value
    polling.finish()
    XCTAssertTrue(try settled.get())
    XCTAssertEqual(outcome, .cancelled)
    let events = try fixture.events()
    XCTAssertEqual(events.map(\.kind), [.stepStarted, .permissionRequested, .permissionResolved, .stepFinished, .settled])
    XCTAssertEqual(events.first { $0.kind == .permissionResolved }?.payload["resolvedBy"], .string("settlement"))
    guard case let .object(closed) = events.last?.payload["closed"] else {
      return XCTFail("Missing settlement counts")
    }
    XCTAssertEqual(closed["permissionRequests"], .integer(1))
    XCTAssertTrue(try fixture.pending().isEmpty)
  }

  func testCancellingDuringWaitResolvesBySettlement() async throws {
    let fixture = PermissionFixture()
    defer { fixture.cleanUp() }
    let (polls, signal) = AsyncStream<Void>.makeStream()
    let recorder = fixture.recorder { _ in
      signal.yield(())
      await ActivityLimits.sleep(nanoseconds: 1_000_000_000)
    }
    await fixture.start(recorder)
    let pending = Task {
      defer { signal.finish() }
      return await fixture.request(recorder)
    }
    var iterator = polls.makeAsyncIterator()
    guard await iterator.next() != nil else {
      _ = await pending.result
      return XCTFail("Permission handler did not begin polling")
    }
    pending.cancel()
    let outcome = await pending.value
    signal.finish()
    XCTAssertEqual(outcome, .cancelled)
    XCTAssertEqual(try fixture.events().last?.payload["resolvedBy"], .string("settlement"))
    XCTAssertTrue(try fixture.pending().isEmpty)
  }
}

private actor PermissionPollEvidence {
  private(set) var observations: [String] = []

  func record(_ observation: String?) {
    if let observation { observations.append(observation) }
  }
}

private struct PermissionFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  var store: BotStore { BotStore(sessionStoreRoot: root.path) }

  func cleanUp() {
    try? FileManager.default.removeItem(at: root)
  }

  func recorder(sleep: @escaping @Sendable (UInt64) async -> Void) -> SQLiteWorkflowActivityRecorder {
    SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path, limits: .init(requestPollIntervalMs: 1_000), sleep: sleep)
  }

  func start(_ recorder: SQLiteWorkflowActivityRecorder) async {
    await recorder.stepStarted(
      sessionId: "session", executionId: "execution", stepId: "step", nodeId: "node",
      backend: "codex", requestedModel: nil, at: Date()
    )
  }

  func request(
    _ recorder: SQLiteWorkflowActivityRecorder, waitMs: Int = 10_000, deadline: Date? = nil
  ) async -> AdapterPermissionOutcome {
    await recorder.requestPermission(
      sessionId: "session", executionId: "execution",
      request: .init(options: [.init(optionId: "native:allow", name: "Allow", kind: "allow_once")]),
      waitMs: waitMs, deadline: deadline
    )
  }

  func pending() throws -> [ActivityRequestRecord] { try store.pendingActivityRequests(sessionIds: ["session"]) }
  func pendingId() throws -> String { try XCTUnwrap(pending().first?.requestId) }
  func events() throws -> [ActivityEvent] { try store.activityPage(sessionId: "session").events }
}
