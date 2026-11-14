import Foundation
import XCTest
import RielaCore
import RielaServer
@testable import RielaCLI

private final class CancelCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var storedOutcome: WorkflowServeSessionCancelOutcome?
  func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
  func record(_ outcome: WorkflowServeSessionCancelOutcome) { lock.lock(); defer { lock.unlock() }; storedOutcome = outcome }
  var outcome: WorkflowServeSessionCancelOutcome? { lock.lock(); defer { lock.unlock() }; return storedOutcome }
  var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class LiveSessionCancelRegistryTests: XCTestCase {
  func testCancellationAndInventory() {
    let registry = LiveSessionCancelRegistry()
    let counter = CancelCounter()
    registry.beginRun()
    registry.beginRun()
    registry.register(sessionId: "id", cancellation: OperatorCancellation()) { counter.increment() }
    XCTAssertEqual(registry.liveSnapshot().sessionIds, ["id"])
    XCTAssertEqual(registry.liveSnapshot().pendingRunCount, 1)
    XCTAssertEqual(registry.requestCancel(sessionId: "id", reason: "r", actor: "a"), .cancelRequested)
    XCTAssertEqual(registry.requestCancel(sessionId: "id", reason: "r", actor: "a"), .alreadyRequested)
    XCTAssertEqual(counter.value, 1)
    XCTAssertEqual(registry.requestCancel(sessionId: "unknown", reason: "r", actor: "a"), .notFound)
    registry.unregister(sessionId: "id")
    XCTAssertEqual(registry.requestCancel(sessionId: "id", reason: "r", actor: "a"), .notFound)
    registry.endRun()
    registry.endRun()
    registry.endRun()
    XCTAssertEqual(registry.liveSnapshot().pendingRunCount, 0)
  }

  func testUnregisterRacesCancellation() {
    for _ in 0..<1_000 {
      let registry = LiveSessionCancelRegistry()
      let counter = CancelCounter()
      registry.register(sessionId: "id", cancellation: OperatorCancellation()) { counter.increment() }
      DispatchQueue.concurrentPerform(iterations: 2) { index in
        if index == 0 { registry.unregister(sessionId: "id") } else { counter.record(registry.requestCancel(sessionId: "id", reason: "r", actor: "a")) }
      }
      if counter.outcome == .notFound { XCTAssertEqual(counter.value, 0) } else {
        XCTAssertEqual(counter.outcome, .cancelRequested)
        XCTAssertEqual(counter.value, 1)
      }
    }
  }
}
