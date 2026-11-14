#if os(macOS)
import AppKit
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWorkflowViewerSurfaceTests: XCTestCase {
  func testWorkflowViewerTextSurfacesUseGroupedNoBorderTreatment() throws {
    let controller = WorkflowViewerWindowController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let tabView = try XCTUnwrap(firstSubview(of: NSTabView.self, in: root))

    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 2)
    try selectTab(named: "Run Log", in: tabView)
    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 1)
    try selectTab(named: "Structure", in: tabView)
    try assertVisibleTextScrollsAreGrouped(in: root, minimumCount: 1)
  }

  private func assertVisibleTextScrollsAreGrouped(in root: NSView, minimumCount: Int) throws {
    let scrolls = allSubviews(of: NSScrollView.self, in: root).filter { scroll in
      !hasHiddenAncestor(scroll) && scroll.documentView is NSTextView
    }
    XCTAssertGreaterThanOrEqual(scrolls.count, minimumCount)
    for scroll in scrolls {
      XCTAssertTrue(scroll.borderType == NSBorderType.noBorder)
      XCTAssertEqual(scroll.layer?.cornerRadius, 8)
      XCTAssertEqual(scroll.layer?.masksToBounds, true)
    }
  }

  private func selectTab(named label: String, in tabView: NSTabView) throws {
    guard let item = tabView.tabViewItems.first(where: { $0.label == label }) else {
      throw NSError(
        domain: "RielaAppWorkflowViewerSurfaceTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Tab not found: \(label)"]
      )
    }
    tabView.selectTabViewItem(item)
  }

  private func firstSubview<T: NSView>(of type: T.Type, in root: NSView) -> T? {
    if let typed = root as? T {
      return typed
    }
    for subview in root.subviews {
      if let found = firstSubview(of: type, in: subview) {
        return found
      }
    }
    return nil
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    var matches: [T] = []
    if let typed = root as? T {
      matches.append(typed)
    }
    for subview in root.subviews {
      matches.append(contentsOf: allSubviews(of: type, in: subview))
    }
    return matches
  }

  private func hasHiddenAncestor(_ view: NSView) -> Bool {
    if view.isHidden {
      return true
    }
    guard let superview = view.superview else {
      return false
    }
    return hasHiddenAncestor(superview)
  }
}
#endif
