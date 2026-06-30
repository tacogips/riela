#if os(macOS)
import AppKit
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppPromptSurfaceTests: XCTestCase {
  func testMultilineInstancePromptUsesGroupedTextSurface() throws {
    let source = try String(
      contentsOf: repositoryRoot()
        .appendingPathComponent("Sources/RielaApp/EntryPoint+DaemonInstances.swift"),
      encoding: .utf8
    )
    XCTAssertTrue(source.contains("rielaAppConfigureGroupedTextScroll(scrollView)"))
    XCTAssertFalse(source.contains("scrollView.borderType = .bezelBorder"))
  }

  func testGroupedTextScrollHelperUsesNoBorderRoundedSurface() {
    let textView = NSTextView()
    let scroll = NSScrollView()
    scroll.documentView = textView

    rielaAppConfigureGroupedTextScroll(scroll)

    XCTAssertTrue(scroll.borderType == NSBorderType.noBorder)
    XCTAssertFalse(scroll.drawsBackground)
    XCTAssertEqual(scroll.layer?.cornerRadius, 8)
    XCTAssertEqual(scroll.layer?.masksToBounds, true)
  }

  private func repositoryRoot() throws -> URL {
    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    while current.path != "/" {
      if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
        return current
      }
      current.deleteLastPathComponent()
    }
    throw NSError(
      domain: "RielaAppPromptSurfaceTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }
}
#endif
