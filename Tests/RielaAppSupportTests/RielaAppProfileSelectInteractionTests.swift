#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppProfileSelectInteractionTests: XCTestCase {
  func testUseProfileRowIsDisabledForCurrentProfileAndEnabledForOtherProfiles() throws {
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
    let useRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Use Profile", in: root))
    XCTAssertFalse(useRow.rielaAccessibilityEnabled)
    XCTAssertEqual(useRow.alphaValue, 0.55, accuracy: 0.01)
    XCTAssertFalse(useRow.acceptsFirstResponder)
    XCTAssertEqual(useRow.accessibilityHelp(), "This profile is already current.")

    let workCell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? RielaAppTableSelectionCellView)
    XCTAssertTrue(workCell.accessibilityPerformPress())

    XCTAssertTrue(useRow.rielaAccessibilityEnabled)
    XCTAssertEqual(useRow.alphaValue, 1, accuracy: 0.01)
    XCTAssertTrue(useRow.acceptsFirstResponder)
    XCTAssertEqual(useRow.accessibilityHelp(), "Show this profile's workflow instances.")
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

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    allSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .button
    }
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
}

private extension NSView {
  var hasHiddenAncestor: Bool {
    if isHidden {
      return true
    }
    return superview?.hasHiddenAncestor ?? false
  }
}
#endif
