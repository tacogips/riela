#if os(macOS)
import AppKit
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppPromptSurfaceTests: XCTestCase {
  func testGroupedTextScrollHelperUsesNoBorderRoundedSurface() {
    let textView = NSTextView()
    let scroll = NSScrollView()
    scroll.documentView = textView

    rielaAppConfigureGroupedTextScroll(scroll)

    XCTAssertTrue(scroll.borderType == NSBorderType.noBorder)
    XCTAssertFalse(scroll.drawsBackground)
    XCTAssertEqual(scroll.layer?.cornerRadius, 12)
    XCTAssertEqual(scroll.layer?.masksToBounds, true)
  }
}
#endif
