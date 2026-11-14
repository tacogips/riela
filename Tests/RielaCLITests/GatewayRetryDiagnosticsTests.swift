import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class GatewayRetryDiagnosticsTests: XCTestCase {
  func testFailedSDKTransportEvidenceSurvivesWithoutProviderText() {
    let error = #"{"error":{"code":"RATE_LIMITED","httpStatus":429,"retryable":true,"requestAttempts":3,"retryAttempts":2,"backoffMs":450,"retryStopReason":"retry-exhausted","details":"PRIVATE_BODY_TOKEN"}}"#
    let suffix = GatewayFailureDiagnostics.suffix(stdout: "", stderr: error)
    XCTAssertEqual(suffix, " (code=RATE_LIMITED, httpStatus=429, retryable=true, requestAttempts=3, retryAttempts=2, backoffMs=450, retryStopReason=retry-exhausted)")
    XCTAssertFalse(suffix.contains("PRIVATE"))
  }

  func testActualNativeSDKPreflightFailureKeepsSafeDiagnostics() {
    XCTAssertThrowsError(try xGatewayReaderQuery(document: "query { accountMe { id } }", environment: [:], deadline: nil)) { error in
      guard let error = error as? AdapterExecutionError else { return XCTFail("wrong error") }
      XCTAssertTrue(error.message.contains("code=AUTH_MISSING"))
      XCTAssertTrue(error.message.contains("requestAttempts=0"))
      XCTAssertTrue(error.message.contains("retryStopReason=not-started"))
      XCTAssertFalse(error.message.contains("consumer"))
    }
  }

  func testArbitraryRetryFieldsAreRejected() {
    for value in ["true", "-1", "6000001", "1.5", #""PRIVATE""#, "{}", "[]"] {
      let error = "{\"error\":{\"code\":\"RATE_LIMITED\",\"requestAttempts\":\(value),\"retryAttempts\":\(value),\"backoffMs\":\(value),\"retryStopReason\":\(value)}}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: error), " (code=RATE_LIMITED)")
    }
  }
}
