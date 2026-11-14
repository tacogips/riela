#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppSettingsTableSelectionTests: XCTestCase {
  func testProfileTableUsesSettingsRowSelectionInsteadOfSystemHighlight() throws {
    let controller = ProfileSelectWindowController(
      onSelectProfile: { _ in },
      onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: { _ in true }
    )
    controller.show(
      currentProfile: .default,
      profileNames: [.default, RielaAppProfileName("work")],
      parentWindow: nil
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    XCTAssertEqual(table.selectionHighlightStyle, .none)
    XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
    XCTAssertEqual(table.gridStyleMask, [])

    let currentCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    let currentRow = try XCTUnwrap(firstSubview(of: RielaAppSettingsRow.self, in: currentCell))
    XCTAssertTrue(currentRow.isSettingsRowSelected)

    let workCell = try XCTUnwrap(
      table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? RielaAppTableSelectionCellView
    )
    XCTAssertTrue(workCell.accessibilityPerformPress())
    let workRow = try XCTUnwrap(firstSubview(of: RielaAppSettingsRow.self, in: workCell))
    XCTAssertTrue(workRow.isSettingsRowSelected)
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
}
#endif
