import Foundation
@testable import RielaNoteUI
import XCTest

final class RielaNoteTimestampTextTests: XCTestCase {
  func testRelativeTimestampUsesPastUnits() throws {
    let now = try XCTUnwrap(rielaNoteTestDate("2026-07-04T12:00:00Z"))

    XCTAssertEqual(rielaNoteRelativeTimestampText("2026-07-04T11:59:30Z", now: now), "just now")
    XCTAssertEqual(rielaNoteRelativeTimestampText("2026-07-04T11:55:00Z", now: now), "5 minutes ago")
    XCTAssertEqual(rielaNoteRelativeTimestampText("2026-07-04T09:00:00Z", now: now), "3 hours ago")
    XCTAssertEqual(rielaNoteRelativeTimestampText("2026-07-02T12:00:00Z", now: now), "2 days ago")
  }

  func testRelativeTimestampParsesFractionalSecondsAndFutureDates() throws {
    let now = try XCTUnwrap(rielaNoteTestDate("2026-07-04T12:00:00Z"))

    XCTAssertEqual(rielaNoteRelativeTimestampText("2026-07-04T12:30:00.123Z", now: now), "in 30 minutes")
  }

  func testRelativeTimestampFallsBackToOriginalTextWhenUnparseable() {
    XCTAssertEqual(rielaNoteRelativeTimestampText("not-a-date"), "not-a-date")
  }
}

private func rielaNoteTestDate(_ text: String) -> Date? {
  ISO8601DateFormatter().date(from: text)
}
