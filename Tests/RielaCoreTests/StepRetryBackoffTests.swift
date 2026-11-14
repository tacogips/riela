import Foundation
import XCTest
@testable import RielaCore

final class StepRetryBackoffTests: XCTestCase {
  func testBackoffAndJitter() {
    func delay(_ policy: WorkflowStepRetryPolicy, _ attempt: Int, _ execution: String = "one") -> Int {
      StepRetryBackoff.delayMs(policy: policy, failedAttempt: attempt, sessionId: "session", executionId: execution)
    }
    let standard = WorkflowStepRetryPolicy(maxAttempts: 4)
    XCTAssertEqual((1...3).map { delay(standard, $0) }, [1_000, 2_000, 4_000])
    let capped = WorkflowStepRetryPolicy(maxAttempts: 4, initialDelayMs: 2_000, multiplier: 2, maxDelayMs: 5_000)
    XCTAssertEqual((1...3).map { delay(capped, $0) }, [2_000, 4_000, 5_000])
    XCTAssertEqual(delay(capped, 60), 5_000)
    XCTAssertEqual(delay(.init(maxAttempts: 3, multiplier: 1), 3), 1_000)
    XCTAssertEqual(delay(.init(maxAttempts: 3, initialDelayMs: 0), 3), 0)
    XCTAssertEqual(delay(.init(maxAttempts: 3, initialDelayMs: 0), 10_000), 0)
    let jitter = WorkflowStepRetryPolicy(maxAttempts: 4, jitter: .deterministic)
    let value = delay(jitter, 2)
    XCTAssertEqual(value, delay(jitter, 2))
    XCTAssertTrue((1_000...2_000).contains(value))
    XCTAssertNotEqual(value, delay(jitter, 2, "two"))
  }

  func testContracts() throws {
    let decoder = JSONDecoder()
    let step = try decoder.decode(WorkflowStepRef.self, from: Data(#"{"id":"a","nodeId":"b","deadlineMs":600000,"retry":{"maxAttempts":4,"jitter":"deterministic"}}"#.utf8))
    XCTAssertEqual(step.deadlineMs, 600_000)
    XCTAssertEqual(step.retry?.jitter, .deterministic)
    XCTAssertEqual(try decoder.decode(WorkflowStepRef.self, from: JSONEncoder().encode(step)), step)
    let old = try decoder.decode(WorkflowStepRef.self, from: Data(#"{"id":"a","nodeId":"b"}"#.utf8))
    XCTAssertNil(old.deadlineMs)
    XCTAssertNil(old.retry)
    let error = AdapterExecutionError(.providerError, "x")
    XCTAssertNil(error.effectOutcome)
    XCTAssertEqual(error, AdapterExecutionError(.providerError, "x"))
    XCTAssertEqual(StepRetryDiagnostics.suffix(attempts: 2, stopReason: .stepDeadline, elapsedMs: 10,
      timeoutKind: .stepDeadline, effectOutcome: .unknown, queueWaitMs: 3),
      " [rielaRetry attempts=2 stopReason=step-deadline elapsedMs=10 timeoutKind=step-deadline effectOutcome=unknown queueWaitMs=3]")
    XCTAssertEqual(StepRetryDiagnostics.suffix(attempts: 0, stopReason: .cancelled, elapsedMs: 0,
      timeoutKind: nil, effectOutcome: nil, queueWaitMs: nil), " [rielaRetry attempts=0 stopReason=cancelled elapsedMs=0]")
  }

  func testManualClockAdvanceAndCancellation() async throws {
    let clock = ManualWorkflowRetryClock()
    let first = Task { try await clock.sleep(until: clock.now().addingTimeInterval(1)) }
    await clock.waitForSleepers(count: 1)
    clock.advance(byMs: 1_000)
    try await first.value
    let second = Task { try await clock.sleep(until: clock.now().addingTimeInterval(1)) }
    await clock.waitForSleepers(count: 1)
    second.cancel()
    do {
      try await second.value
      XCTFail("expected cancellation")
    } catch is CancellationError { }
  }
}
