#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppAddInstanceLayoutTests: XCTestCase {
  func testWorkflowInstanceWindowUsesCompactAccessibleControlsAtRuntime() throws {
    let controller = makeController()
    let window = try XCTUnwrap(controller.window)
    window.layoutIfNeeded()

    XCTAssertEqual(window.minSize, NSSize(width: 760, height: 520))
    XCTAssertEqual(window.frame.size.width, 920, accuracy: 0.1)

    let root = try XCTUnwrap(window.contentView)
    let listScroll = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: root))
    XCTAssertEqual(listScroll.contentCompressionResistancePriority(for: .vertical), .defaultLow)
    XCTAssertFalse(hasHeightConstraint(listScroll, relation: .greaterThanOrEqual, constant: 260))
    XCTAssertNil(heightConstraint(listScroll, relation: .equal, constant: 260))

    let profilePopup = try XCTUnwrap(firstSubview(of: NSPopUpButton.self, in: root))
    XCTAssertEqual(profilePopup.accessibilityLabel(), "Profile")
    XCTAssertEqual(profilePopup.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    XCTAssertTrue(hasWidthConstraint(profilePopup, relation: .lessThanOrEqual, constant: 220))
    XCTAssertFalse(hasWidthConstraint(profilePopup, relation: .equal, constant: 160))

    let addButton = try XCTUnwrap(button(accessibilityLabel: "Add Instance", in: root))
    XCTAssertEqual(addButton.title, "")
    XCTAssertNotNil(addButton.image)
    let listView = try XCTUnwrap(firstSubview(of: DaemonWorkflowInstanceListView.self, in: root))
    listView.layoutSubtreeIfNeeded()
    XCTAssertTrue(addButton.isDescendant(of: listView.footer))
    XCTAssertFalse(addButton.isDescendant(of: listView.header))

    let refreshButton = try XCTUnwrap(button(accessibilityLabel: "Refresh Instances", in: root))
    XCTAssertEqual(refreshButton.title, "")
    XCTAssertNotNil(refreshButton.image)

    let emptyState = try XCTUnwrap(visibleTextFields(in: root).first {
      $0.stringValue == "No instances. Press + to select a workflow and create one."
    })
    XCTAssertEqual(emptyState.textColor, .secondaryLabelColor)
    XCTAssertEqual(emptyState.accessibilityLabel(), "No instances. Press Add Instance to select a workflow and create one.")
  }

  func testAddInstanceButtonShowsInlineWorkflowSelectionPaneAtRuntime() throws {
    let controller = makeController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: [],
      requiredEnvironment: [
        RielaAppEnvRequirement(name: "OPENAI_API_KEY", description: nil, secret: true)
      ]
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let addButton = try XCTUnwrap(button(accessibilityLabel: "Add Instance", in: root))
    addButton.performClick(nil)
    controller.window?.layoutIfNeeded()

    XCTAssertNil(controller.activeAddInstanceWindow)
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "Choose Workflow")
    XCTAssertEqual(controller.instancesListView?.isHidden, true)
    XCTAssertEqual(controller.addInstanceSelectionView?.isHidden, false)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Choose Workflow" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Daily Summary" })
    XCTAssertTrue(visibleTextFields(in: root).contains {
      $0.stringValue.contains("1 required environment variable")
    })

    controller.goBack()
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "Instances")
    XCTAssertEqual(controller.instancesListView?.isHidden, false)
    XCTAssertEqual(controller.addInstanceSelectionView?.isHidden, true)
  }

  func testAddInstanceWorkflowSelectionCanFilterSourcesAtRuntime() throws {
    let controller = makeController()
    let daily = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    let slack = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:slack-chat",
      workflowId: "slack-chat",
      displayName: "Slack Chat",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/slack-chat",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [daily, slack],
      workflowSources: [daily, slack],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    try XCTUnwrap(button(accessibilityLabel: "Add Instance", in: root)).performClick(nil)
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Daily Summary" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Slack Chat" })

    let searchField = try XCTUnwrap(
      allSubviews(of: NSSearchField.self, in: root).first {
        !$0.hasHiddenAncestor && $0.accessibilityLabel() == "Filter Workflows"
      }
    )
    let selectedTarget = try XCTUnwrap(controller.inlineAddInstanceSourceSelectionTarget)
    selectedTarget.updateSelection(index: 1)
    XCTAssertEqual(
      controller.inlineAddInstanceSourceOptions[selectedTarget.selectedIndex].candidate.id,
      slack.id
    )
    let window = try XCTUnwrap(controller.window)
    XCTAssertTrue(window.makeFirstResponder(searchField))
    XCTAssertTrue(window.firstResponder === searchField.currentEditor())
    XCTAssertNil(searchField.delegate)

    searchField.stringValue = "slack"
    XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
    controller.window?.layoutIfNeeded()

    XCTAssertFalse(visibleTextFields(in: root).contains { $0.stringValue == "Daily Summary" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Slack Chat" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "1 of 2 workflow sources" })
    let filteredTarget = try XCTUnwrap(controller.inlineAddInstanceSourceSelectionTarget)
    XCTAssertEqual(
      controller.inlineAddInstanceSourceOptions[filteredTarget.selectedIndex].candidate.id,
      slack.id
    )
    XCTAssertTrue(window.firstResponder === searchField.currentEditor())

    searchField.stringValue = "does-not-match"
    XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains {
      $0.stringValue == "No workflows match the current filter."
    })
    XCTAssertTrue(window.firstResponder === searchField.currentEditor())

    searchField.stringValue = ""
    XCTAssertTrue(searchField.sendAction(searchField.action, to: searchField.target))
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Daily Summary" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Slack Chat" })
    XCTAssertTrue(window.firstResponder === searchField.currentEditor())
  }

  private func makeController() -> DaemonWorkflowWindowController {
    DaemonWorkflowWindowController(
      onRefresh: {},
      onSelectProfile: { _ in },
      onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: { _ in true },
      onAddDirectory: {},
      onAddURL: { _ in },
      onAddInstance: { _ in },
      onRevealSelectedSource: { _ in },
      onRelinkInstance: { _, _ in },
      onRenameWorkflow: { _ in },
      onRemoveInstance: { _ in },
      onStartInstance: { _ in },
      onStopInstance: { _ in },
      onRestartInstance: { _ in },
      onSetEnvironment: { _ in },
      onSetWorkingDirectory: { _ in },
      onSaveEnvironmentVariables: { _, _ in nil },
      onSaveWorkflowVariables: { _, _ in nil },
      onRegisterEventSource: { _, _, _ in nil },
      configuredEnvironmentValues: { _ in [] },
      onSaveAssistantAssistance: { _ in nil },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
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

  private func button(accessibilityLabel: String, in root: NSView) -> NSButton? {
    allSubviews(of: NSButton.self, in: root).first { button in
      button.accessibilityLabel() == accessibilityLabel
    }
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }

  private func hasWidthConstraint(
    _ view: NSView,
    relation: NSLayoutConstraint.Relation,
    constant: CGFloat
  ) -> Bool {
    view.constraints.contains { constraint in
      constraint.firstItem === view &&
        constraint.firstAttribute == .width &&
        constraint.relation == relation &&
        abs(constraint.constant - constant) < 0.1
    }
  }

  private func hasHeightConstraint(
    _ view: NSView,
    relation: NSLayoutConstraint.Relation,
    constant: CGFloat
  ) -> Bool {
    heightConstraint(view, relation: relation, constant: constant) != nil
  }

  private func heightConstraint(
    _ view: NSView,
    relation: NSLayoutConstraint.Relation,
    constant: CGFloat
  ) -> NSLayoutConstraint? {
    view.constraints.first { constraint in
      constraint.firstItem === view &&
        constraint.firstAttribute == .height &&
        constraint.relation == relation &&
        abs(constraint.constant - constant) < 0.1
    }
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
