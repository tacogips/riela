import Foundation
import XCTest
@testable import RielaCore

final class ActivityWaitTests: XCTestCase {
  func testWaitReturnsWhenNewEventArrives() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BotStore(sessionStoreRoot: root.path)
    let recorder = SQLiteWorkflowActivityRecorder(sessionStoreRoot: root.path)
    let page = try await BotStore.waitForActivity(
      store: store, sessionId: "session", afterSequence: 0, waitMs: 1_000,
      sleep: { _ in
        await recorder.stepStarted(
          sessionId: "session", executionId: "execution", stepId: "step", nodeId: "node",
          backend: nil, requestedModel: nil, at: Date()
        )
      }
    )
    XCTAssertEqual(page.events.map(\.kind), [.stepStarted])
    XCTAssertEqual(page.lastSequence, 1)
  }

  func testWaitReturnsEmptyPageAfterTimeout() async throws {
    let root = temporaryRoot()
    let page = try await BotStore.waitForActivity(
      store: BotStore(sessionStoreRoot: root.path), sessionId: "session", afterSequence: 0, waitMs: 2, pollMs: 1
    )
    XCTAssertTrue(page.events.isEmpty)
    XCTAssertEqual(page.activitySource, "session")
    XCTAssertNil(page.state)
  }

  func testWaitChecksAuthorizationAgainAfterPolling() async throws {
    let root = temporaryRoot()
    let authorization = ActivityTestAuthorization()
    do {
      _ = try await BotStore.waitForActivity(
        store: BotStore(sessionStoreRoot: root.path), sessionId: "session", afterSequence: 0, waitMs: 1_000,
        sleep: { _ in await authorization.revoke() },
        isStillAuthorized: { await authorization.allowed }
      )
      XCTFail("Expected revoked access")
    } catch let error as BotStoreError {
      XCTAssertEqual(error.code, "activity_wait_revoked")
    }
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
}

private actor ActivityTestAuthorization {
  private(set) var allowed = true

  func revoke() { allowed = false }
}
