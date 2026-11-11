import Foundation
import XCTest
@testable import RielaAppSupport

final class RielaAppInstanceCancelContractTests: XCTestCase {
  func testStrictRequest() throws {
    let request = try RielaAppInstanceCancelRequest.decodeStrict(Data(#"{"expectedProfile":"p","reason":"  duplicate  "}"#.utf8))
    XCTAssertEqual(request.reason, "duplicate")
    let invalid = [#"{"expectedProfile":"p","reason":"r","extra":1}"#, #"{"expectedProfile":"p"}"#,
                   #"{"expectedProfile":"p","reason":"  "}"#, #"{"expectedProfile":"p","reason":"a\u0000b"}"#,
                   "{\"expectedProfile\":\"p\",\"reason\":\"" + String(repeating: "a", count: 513) + "\"}",
                   String(repeating: " ", count: 65_537)]
    for body in invalid {
      XCTAssertThrowsError(try RielaAppInstanceCancelRequest.decodeStrict(Data(body.utf8))) {
        XCTAssertEqual(($0 as? RielaAppInstanceCancelError)?.code, .invalidCancelRequest)
      }
    }
  }

  func testCodesAndResponse() throws {
    let expected: [String: Int] = ["invalid_cancel_request": 400, "instance_not_found": 404, "session_not_found": 404,
      "configuration_conflict": 409, "not_running": 409, "session_not_owned": 409, "cancel_unavailable": 409,
      "instance_busy": 409, "no_running_execution": 409, "ambiguous_running_sessions": 409]
    XCTAssertEqual(RielaAppInstanceCancelCode.allCases.count, expected.count)
    for code in RielaAppInstanceCancelCode.allCases { XCTAssertEqual(code.httpStatus, expected[code.rawValue]) }
    let response = RielaAppInstanceCancelResponse(identity: "i", profile: "p", sessionId: "s", owner: "app", outcome: "cancelRequested")
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["identity", "profile", "sessionId", "owner", "outcome"]))
    XCTAssertEqual(RielaAppInstanceCancelActor.actor(profile: "p"), "rielaapp-api:p")
  }
}
