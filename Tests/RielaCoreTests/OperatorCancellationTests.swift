import XCTest
@testable import RielaCore

final class OperatorCancellationTests: XCTestCase {
  func testFirstRequestWins() {
    let box = OperatorCancellation()
    XCTAssertFalse(box.isRequested)
    XCTAssertNil(box.failureReason)
    XCTAssertTrue(box.request(reason: "duplicate", actor: "operator"))
    XCTAssertTrue(box.isRequested)
    XCTAssertEqual(box.failureReason, "operator_cancelled by operator: duplicate")
    XCTAssertFalse(box.request(reason: "later", actor: "other"))
    XCTAssertEqual(box.failureReason, "operator_cancelled by operator: duplicate")
  }
}
