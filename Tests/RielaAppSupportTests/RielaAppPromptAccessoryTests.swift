#if os(macOS)
import AppKit
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppPromptAccessoryTests: XCTestCase {
  func testEmptyWorkflowSelectionAccessoryUsesSecondarySettingsStyleState() throws {
    let sourceActions = NSStackView(views: [
      RielaAppSelectableSettingsRow(views: [NSTextField(labelWithString: "Import Package File or Directory")]),
      RielaAppSelectableSettingsRow(views: [NSTextField(labelWithString: "Import from URL")])
    ])
    let stack = AddInstancePromptViewFactory().emptyWorkflowSelectionStack(
      message: "No workflows. Import a workflow or package source.",
      sourceActions: sourceActions,
      size: AddInstancePromptLayout.relinkSize
    )
    stack.layoutSubtreeIfNeeded()

    let emptyText = try XCTUnwrap(visibleTextFields(in: stack).first {
      $0.stringValue == "No workflows. Import a workflow or package source."
    })
    XCTAssertEqual(emptyText.textColor, .secondaryLabelColor)
    XCTAssertEqual(emptyText.alignment, .center)
    XCTAssertEqual(emptyText.accessibilityLabel(), "No workflows. Import a workflow or package source.")
    XCTAssertTrue(visibleTextFields(in: stack).contains { $0.stringValue == "Manage Sources" })
    XCTAssertTrue(
      hasWidthConstraint(stack, relation: .lessThanOrEqual, constant: AddInstancePromptLayout.relinkSize.width)
    )
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root)
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

  private func hasWidthConstraint(_ view: NSView, relation: NSLayoutConstraint.Relation, constant: CGFloat) -> Bool {
    view.constraints.contains { constraint in
      constraint.firstAttribute == .width &&
        constraint.relation == relation &&
        abs(constraint.constant - constant) < 0.1
    }
  }
}
#endif
