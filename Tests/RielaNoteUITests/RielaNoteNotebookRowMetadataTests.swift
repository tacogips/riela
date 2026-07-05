import XCTest
@testable import RielaNoteUI

final class RielaNoteNotebookRowMetadataTests: XCTestCase {
  func testNotebookNoteCountTextPluralizes() {
    XCTAssertEqual(rielaNoteNotebookNoteCountText(0), "0 notes")
    XCTAssertEqual(rielaNoteNotebookNoteCountText(1), "1 note")
    XCTAssertEqual(rielaNoteNotebookNoteCountText(2), "2 notes")
  }
}
