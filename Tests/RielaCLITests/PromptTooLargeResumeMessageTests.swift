import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class PromptTooLargeResumeMessageTests: XCTestCase {
  func testPromptTooLargeResumeMessageOffersExplicitRetry() {
    let message = SessionResumeCommand().nonBudgetFailureResumeMessage(session: session(failureKind: .promptTooLarge))
    XCTAssertTrue(message.contains("--retry-failed-step"))
  }

  func testInternalFailureResumeMessageDoesNotOfferExplicitRetry() {
    let message = SessionResumeCommand().nonBudgetFailureResumeMessage(session: session(failureKind: .internalFailure))
    XCTAssertFalse(message.contains("--retry-failed-step"))
  }

  private func session(failureKind: WorkflowSessionFailureKind) -> WorkflowSession {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return WorkflowSession(
      workflowId: "test-workflow",
      sessionId: "test-session",
      status: .failed,
      entryStepId: "agent",
      currentStepId: "agent",
      createdAt: now,
      updatedAt: now,
      failureKind: failureKind
    )
  }
}
