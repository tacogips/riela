import Foundation
import XCTest
import RielaCore
@testable import RielaCLI

final class GatewayRetryDiagnosticsTests: XCTestCase {
  func testInvalidXRequestRetainsOnlyFiniteParameterName() throws {
    let details = #"{"errors":[{"parameters":{"since_id":["PRIVATE_ID"]},"message":"PRIVATE_QUERY_TOKEN"}]}"#
    let envelope: [String: Any] = ["error": ["code": "UPSTREAM_FAILURE", "httpStatus": 400,
      "retryable": false, "details": details]]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    let suffix = GatewayFailureDiagnostics.suffix(stdout: text)
    XCTAssertEqual(suffix, " (code=UPSTREAM_FAILURE, httpStatus=400, xInvalidRequestParameter=since_id, retryable=false)")
    XCTAssertFalse(suffix.contains("PRIVATE"))
  }

  func testInvalidXParameterDoesNotParseMessagesOrUnknownNames() throws {
    for details in [#"{"errors":[{"message":"next_token PRIVATE"}]}"#,
      #"{"errors":[{"parameters":{"PRIVATE_TOKEN":["SECRET"]}}]}"#,
      String(repeating: "x", count: 65_537)] {
      let envelope: [String: Any] = ["error": ["code": "UPSTREAM_FAILURE", "httpStatus": 400, "details": details]]
      let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
      let expected = text.utf8.count > 65_536 ? "" : " (code=UPSTREAM_FAILURE, httpStatus=400)"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: text), expected)
    }
  }

  func testMultipleInvalidXParametersAreBounded() throws {
    let details = #"{"errors":[{"parameters":{"start_time":["PRIVATE"],"end_time":["PRIVATE"]}}]}"#
    let envelope: [String: Any] = ["error": ["code": "UPSTREAM_FAILURE", "httpStatus": 400, "details": details]]
    let text = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: text), " (code=UPSTREAM_FAILURE, httpStatus=400, xInvalidRequestParameter=multiple)")
  }
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

  func testMonthlySpendCapTypeSurvivesWithoutProviderText() {
    let error = #"{"error":{"code":"PERMISSION_DENIED","httpStatus":403,"providerProblem":"spend-cap-reached","details":"PRIVATE"}}"#
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: error),
      " (code=PERMISSION_DENIED, httpStatus=403, providerProblem=spend-cap-reached)")
  }

  func testSpendCapSurvivesLargeResourceUsageTelemetry() throws {
    let resource: [String: Any] = ["kind": "user", "idHash": String(repeating: "a", count: 64), "utcDay": "2026-10-24"]
    let usage: [String: Any] = ["version": 1, "basis": "upstream-response", "billingStatus": "not-reported",
      "httpResponses": 3, "successfulResponses": 2, "unclassifiedResources": 0,
      "resources": Array(repeating: resource, count: 1_000)]
    let envelope: [String: Any] = ["ok": false, "error": ["code": "PERMISSION_DENIED", "httpStatus": 403,
      "providerProblem": "spend-cap-reached", "details": "PRIVATE", "resourceUsage": usage]]
    let text = try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: envelope), encoding: .utf8))
    XCTAssertGreaterThan(text.utf8.count, GatewayFailureDiagnostics.maximumEnvelopeBytes)
    for (stdout, stderr) in [(text, ""), ("", text)] {
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: stdout, stderr: stderr),
        " (code=PERMISSION_DENIED, httpStatus=403, providerProblem=spend-cap-reached)")
    }
    // Only telemetry is exempt: the rest of the envelope keeps the plain bound.
    var padded = envelope
    padded["padding"] = String(repeating: "x", count: GatewayFailureDiagnostics.maximumEnvelopeBytes)
    let paddedText = try XCTUnwrap(String(bytes: JSONSerialization.data(withJSONObject: padded), encoding: .utf8))
    XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: paddedText), "")
  }

  func testArbitraryRetryFieldsAreRejected() {
    for value in ["true", "-1", "6000001", "1.5", #""PRIVATE""#, "{}", "[]"] {
      let error = "{\"error\":{\"code\":\"RATE_LIMITED\",\"requestAttempts\":\(value),\"retryAttempts\":\(value),\"backoffMs\":\(value),\"retryStopReason\":\(value)}}"
      XCTAssertEqual(GatewayFailureDiagnostics.suffix(stdout: error), " (code=RATE_LIMITED)")
    }
  }
}
