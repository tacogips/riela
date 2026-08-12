#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import RielaCore
import XCTest

@MainActor
final class RielaAppControllerLayoutTests: XCTestCase {
  func testWorkflowInstanceListHeaderAndRowsStayPinnedToTopAtRuntime() throws {
    let controller = makeController()
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 720, height: 640), display: false)
    window.layoutIfNeeded()

    let root = try XCTUnwrap(window.contentView)
    let listView = try XCTUnwrap(firstSubview(of: DaemonWorkflowInstanceListView.self, in: root))
    listView.layoutSubtreeIfNeeded()

    XCTAssertEqual(listView.header.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(listView.header.frame.height, 28, accuracy: 0.1)
    XCTAssertEqual(listView.scrollView.frame.minY, 40, accuracy: 0.1)
    XCTAssertGreaterThan(listView.scrollView.frame.height, 0)
  }

  func testNeedsSourceDetailShowsOnlyRecoverableActionsAtRuntime() throws {
    let controller = makeController()
    var state = RielaAppDaemonWorkflowState()
    state.preferences["lost-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "lost-instance",
      sourceIdentity: "missing-source",
      displayName: "Lost Instance",
      available: true,
      active: false
    )

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [],
      workflowSources: [],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "lost-instance")

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let visibleTexts = Set(visibleTextFields(in: root).map(\.stringValue))
    XCTAssertTrue(visibleTexts.contains("Lost Instance"))
    XCTAssertTrue(visibleTexts.contains("Missing source, missing-source"))
    XCTAssertTrue(visibleTexts.contains("Relink Source"))
    XCTAssertTrue(visibleTexts.contains("Remove Instance"))
    XCTAssertFalse(visibleTexts.contains("Start"))
    XCTAssertFalse(visibleTexts.contains("Stop"))
    XCTAssertFalse(visibleTexts.contains("Restart"))
    XCTAssertFalse(visibleTexts.contains("Env File"))
    XCTAssertFalse(visibleTexts.contains("Inline Env"))
    XCTAssertFalse(visibleTexts.contains("Working Directory"))

    let relinkRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Relink Source", in: root))
    XCTAssertEqual(relinkRow.accessibilityRole(), .button)
    XCTAssertEqual(relinkRow.accessibilityHelp(), "Choose a workflow source for this saved instance.")
    XCTAssertEqual(relinkRow.toolTip, "Choose a workflow source for this saved instance.")
    XCTAssertTrue(relinkRow.acceptsFirstResponder)
    let removeRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Remove Instance", in: root))
    XCTAssertEqual(removeRow.accessibilityRole(), .button)
    XCTAssertEqual(removeRow.toolTip, "Delete only this instance.")
    XCTAssertTrue(removeRow.acceptsFirstResponder)
  }

  func testInstanceDetailShowsOnlyStateRelevantRuntimeActionsAtRuntime() throws {
    let controller = makeController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "workflows/daily-summary",
      workingDirectory: "workflows",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = RielaAppDaemonWorkflowPreference(
      identity: "morning-summary",
      sourceIdentity: source.id,
      displayName: "Morning Summary",
      available: true,
      active: false
    )

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "morning-summary")

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    var visibleTexts = Set(visibleTextFields(in: root).map(\.stringValue))
    XCTAssertTrue(visibleTexts.contains("Environment Variables"))
    XCTAssertTrue(visibleTexts.contains("Workflow Variables"))
    XCTAssertFalse(visibleTexts.contains("Inline Env"))
    XCTAssertFalse(visibleTexts.contains("Variables"))
    XCTAssertTrue(visibleTexts.contains("Start"))
    XCTAssertFalse(visibleTexts.contains("Stop"))
    XCTAssertFalse(visibleTexts.contains("Restart"))
    let detailScroll = try XCTUnwrap(allSubviews(of: NSScrollView.self, in: root).first {
      !$0.hasHiddenAncestor && $0.documentView is FlippedDocumentView
    })
    let nameRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Name", in: root))
    let workflowVariablesRow = try XCTUnwrap(allSubviews(of: RielaAppSettingsRow.self, in: root).first {
      $0.accessibilityLabel() == "Workflow Variables"
    })
    XCTAssertNil(selectableRow(accessibilityLabel: "Workflow Variables", in: root))
    let startRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Start", in: root))
    XCTAssertEqual(nameRow.frame.width, detailScroll.contentView.bounds.width, accuracy: 1)
    XCTAssertEqual(startRow.frame.width, detailScroll.contentView.bounds.width, accuracy: 1)
    XCTAssertEqual(nameRow.accessibilityValue() as? String, "Morning Summary")
    XCTAssertEqual(workflowVariablesRow.accessibilityValue() as? String, "0 values")

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [
        "morning-summary": RielaAppDaemonWorkflowRuntime.RuntimeSnapshot(status: .running, detail: "Running")
      ],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.window?.layoutIfNeeded()

    visibleTexts = Set(visibleTextFields(in: root).map(\.stringValue))
    XCTAssertFalse(visibleTexts.contains("Start"))
    XCTAssertTrue(visibleTexts.contains("Stop"))
    XCTAssertTrue(visibleTexts.contains("Restart"))
  }

  func testInstanceListRowsAreAccessibleButtonsAtRuntime() throws {
    let controller = makeController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = RielaAppDaemonWorkflowPreference(
      identity: "morning-summary",
      sourceIdentity: source.id,
      displayName: "Morning Summary",
      available: true,
      active: false
    )

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    window.layoutIfNeeded()
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? RielaAppTableSelectionCellView)
    XCTAssertEqual(cell.accessibilityRole(), NSAccessibility.Role.button)
    XCTAssertEqual(cell.accessibilityLabel(), "Morning Summary")
    XCTAssertEqual(cell.accessibilityValue() as? String, "Stopped")
    XCTAssertEqual(cell.accessibilityHelp(), "Show instance details")
    XCTAssertTrue(cell.accessibilityPerformPress())
    controller.window?.layoutIfNeeded()

    let visibleTexts = Set(visibleTextFields(in: root).map(\.stringValue))
    XCTAssertTrue(visibleTexts.contains("Current Settings"))
    XCTAssertTrue(visibleTexts.contains("Morning Summary"))
  }

  func testTransitionalInstanceStateShowsNativeProgressIndicatorsAtRuntime() throws {
    let controller = makeController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/daily-summary",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = RielaAppDaemonWorkflowPreference(
      identity: "morning-summary",
      sourceIdentity: source.id,
      displayName: "Morning Summary",
      available: true,
      active: true
    )

    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [
        "morning-summary": RielaAppDaemonWorkflowRuntime.RuntimeSnapshot(
          status: .starting,
          detail: "Preparing event sources"
        )
      ],
      assistantAssistance: "",
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    window.layoutIfNeeded()
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    let listIndicator = try XCTUnwrap(allSubviews(of: NSProgressIndicator.self, in: cell).first)
    XCTAssertEqual(listIndicator.accessibilityLabel(), "Starting instance progress")
    XCTAssertTrue(listIndicator.isIndeterminate)
    XCTAssertFalse(listIndicator.hasHiddenAncestor)

    controller.selectCandidate(identity: "morning-summary")
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let detailIndicator = try XCTUnwrap(allSubviews(of: NSProgressIndicator.self, in: root).first {
      $0.accessibilityLabel() == "Instance status progress"
    })
    XCTAssertTrue(detailIndicator.isIndeterminate)
    XCTAssertFalse(detailIndicator.hasHiddenAncestor)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Starting - Preparing event sources" })
  }

  func testProfileRowsAreAccessibleChoicesAtRuntime() throws {
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
    let scrollView = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: root))
    XCTAssertEqual(scrollView.contentCompressionResistancePriority(for: .vertical), .defaultLow)
    XCTAssertFalse(hasHeightConstraint(scrollView, relation: .greaterThanOrEqual, constant: 220))
    let preferredHeight = try XCTUnwrap(heightConstraint(scrollView, relation: .equal, constant: 220))
    XCTAssertEqual(preferredHeight.priority, .defaultLow)

    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? RielaAppTableSelectionCellView)
    XCTAssertEqual(cell.accessibilityRole(), .radioButton)
    XCTAssertEqual(cell.accessibilityLabel(), "work")
    XCTAssertEqual(cell.accessibilityValue() as? String, "Profile")
    XCTAssertEqual(cell.accessibilityHelp(), "Use work profile")
    XCTAssertTrue(cell.accessibilityPerformPress())
    XCTAssertEqual(table.selectedRow, 1)
  }

  func testProfileSelectorDoesNotExposeProfileConfigurationActions() throws {
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
    XCTAssertNil(selectableRow(accessibilityLabel: "Add Profile", in: root))
    XCTAssertNil(selectableRow(accessibilityLabel: "Remove Profile", in: root))
    XCTAssertNotNil(selectableRow(accessibilityLabel: "Use Profile", in: root))
  }

  func testDaemonInstancePromptFactoryUsesCompressibleSettingsRowsAtRuntime() {
    let factory = DaemonInstancePromptViewFactory()
    let idField = NSTextField(string: "demo-instance")
    let nameField = NSTextField(string: "Demo Instance")
    let nameStack = factory.nameEditorStack(idField: idField, nameField: nameField)
    nameStack.layoutSubtreeIfNeeded()

    XCTAssertEqual(nameStack.frame.size.width, DaemonInstancePromptViewFactory.nameEditorSize.width, accuracy: 0.1)
    XCTAssertTrue(
      hasWidthConstraint(
        nameStack,
        relation: .lessThanOrEqual,
        constant: DaemonInstancePromptViewFactory.nameEditorSize.width
      )
    )
    XCTAssertEqual(idField.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    XCTAssertEqual(nameField.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    XCTAssertTrue(visibleTextFields(in: nameStack).contains { $0.stringValue == "Instance Settings" })
    XCTAssertTrue(visibleTextFields(in: nameStack).contains { $0.stringValue == "Instance ID" })
    XCTAssertTrue(visibleTextFields(in: nameStack).contains { $0.stringValue == "Display Name" })

    let nameRows = allSubviews(of: RielaAppSettingsRow.self, in: nameStack)
    XCTAssertEqual(nameRows.count, 2)
    for row in nameRows {
      XCTAssertEqual(row.edgeInsets.left, 12)
      XCTAssertEqual(row.layer?.cornerRadius, 12)
    }
    for label in settingsTitleLabels(in: nameStack) {
      XCTAssertTrue(hasWidthConstraint(label, relation: .lessThanOrEqual, constant: 130))
      XCTAssertEqual(label.contentCompressionResistancePriority(for: .horizontal), .defaultLow)
    }

    let editorView = NSScrollView()
    let variableStack = factory.variableEditorStack(currentValue: "TOKEN=one\n\nCOUNT:=2", editorView: editorView)
    variableStack.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      variableStack.frame.size.width,
      DaemonInstancePromptViewFactory.variableEditorSize.width,
      accuracy: 0.1
    )
    XCTAssertTrue(
      hasWidthConstraint(
        variableStack,
        relation: .lessThanOrEqual,
        constant: DaemonInstancePromptViewFactory.variableEditorSize.width
      )
    )
    XCTAssertTrue(
      hasHeightConstraint(
        editorView,
        relation: .equal,
        constant: DaemonInstancePromptViewFactory.editorTextSize.height
      )
    )
    XCTAssertEqual(editorView.contentCompressionResistancePriority(for: .vertical), .defaultLow)
    XCTAssertFalse(
      hasHeightConstraint(
        editorView,
        relation: .greaterThanOrEqual,
        constant: DaemonInstancePromptViewFactory.editorTextSize.height
      )
    )
    let preferredHeight = heightConstraint(
      editorView,
      relation: .equal,
      constant: DaemonInstancePromptViewFactory.editorTextSize.height
    )
    XCTAssertEqual(preferredHeight?.priority, .defaultLow)
    XCTAssertTrue(visibleTextFields(in: variableStack).contains { $0.stringValue == "Variable Settings" })
    XCTAssertTrue(visibleTextFields(in: variableStack).contains { $0.stringValue == "2 configured" })
    XCTAssertEqual(allSubviews(of: RielaAppSettingsRow.self, in: variableStack).count, 2)
  }

  func testPromptAccessoryFactoriesUseBoundedWidthsAtRuntime() throws {
    let addViews = [
      NSTextField(labelWithString: "Choose Workflow"),
      NSTextField(labelWithString: "Workflow Sources")
    ]
    let addStack = AddInstancePromptViewFactory().accessoryStack(
      views: addViews,
      size: AddInstancePromptLayout.workflowSelectionSize
    )
    addStack.layoutSubtreeIfNeeded()

    XCTAssertEqual(addStack.orientation, .vertical)
    XCTAssertEqual(addStack.spacing, 10)
    XCTAssertEqual(addStack.frame.size.width, AddInstancePromptLayout.windowWidth, accuracy: 0.1)
    XCTAssertTrue(
      hasWidthConstraint(
        addStack,
        relation: .lessThanOrEqual,
        constant: AddInstancePromptLayout.workflowSelectionSize.width
      )
    )

    let parameterTitle = NSTextField(labelWithString: "Configure Instance")
    let parameterStack = AddInstancePromptViewFactory().scrollingParameterStack(
      title: parameterTitle,
      rows: [
        RielaAppSettingsRow(views: [NSTextField(labelWithString: "Workflow")]),
        RielaAppSettingsRow(views: [NSTextField(labelWithString: "Instance ID")])
      ]
    )
    parameterStack.layoutSubtreeIfNeeded()
    let parameterScroll = try XCTUnwrap(firstSubview(of: NSScrollView.self, in: parameterStack))
    XCTAssertEqual(parameterScroll.contentCompressionResistancePriority(for: .vertical), .defaultLow)
    XCTAssertEqual(
      heightConstraint(parameterScroll, relation: .equal, constant: AddInstancePromptLayout.parameterRowsPreferredHeight)?
        .priority,
      .defaultLow
    )
    XCTAssertTrue(
      hasWidthConstraint(parameterStack, relation: .lessThanOrEqual, constant: AddInstancePromptLayout.parameterSize.width)
    )

    let profileStack = ProfilePromptViewFactory().accessoryStack(
      views: [
        NSTextField(labelWithString: "Profile Name"),
        RielaAppSettingsRow(views: [NSTextField(labelWithString: "Name")])
      ],
      size: ProfilePromptLayout.nameSize
    )
    profileStack.layoutSubtreeIfNeeded()
    XCTAssertEqual(profileStack.orientation, .vertical)
    XCTAssertEqual(profileStack.spacing, 8)
    XCTAssertEqual(profileStack.frame.size.width, ProfilePromptLayout.nameSize.width, accuracy: 0.1)
    XCTAssertTrue(
      hasWidthConstraint(profileStack, relation: .lessThanOrEqual, constant: ProfilePromptLayout.nameSize.width)
    )

  }

  func testWorkflowSourceSelectionTargetUpdatesCheckmarksAtRuntime() {
    let selectionTarget = WorkflowSourceSelectionTarget()
    let checkmarks = (0..<3).map { _ in NSImageView(image: NSImage()) }
    let rowTargets = (0..<3).map { WorkflowSourceSelectionRowTarget(selectionTarget: selectionTarget, index: $0) }

    selectionTarget.attach(checkmarks: checkmarks, rowTargets: rowTargets)
    XCTAssertEqual(selectionTarget.selectedIndex, 0)
    XCTAssertFalse(checkmarks[0].isHidden)
    XCTAssertTrue(checkmarks[1].isHidden)
    XCTAssertTrue(checkmarks[2].isHidden)

    rowTargets[2].select()
    XCTAssertEqual(selectionTarget.selectedIndex, 2)
    XCTAssertTrue(checkmarks[0].isHidden)
    XCTAssertTrue(checkmarks[1].isHidden)
    XCTAssertFalse(checkmarks[2].isHidden)

    selectionTarget.updateSelection(index: 99)
    XCTAssertEqual(selectionTarget.selectedIndex, 2)
    XCTAssertFalse(checkmarks[2].isHidden)

    selectionTarget.updateSelection(index: -1)
    XCTAssertEqual(selectionTarget.selectedIndex, 0)
    XCTAssertFalse(checkmarks[0].isHidden)
    XCTAssertTrue(checkmarks[2].isHidden)

    var didConfirm = false
    let confirmingTarget = WorkflowSourceSelectionTarget(onConfirm: { didConfirm = true })
    let confirmingCheckmarks = (0..<2).map { _ in NSImageView(image: NSImage()) }
    let confirmingRowTargets = (0..<2).map { WorkflowSourceSelectionRowTarget(selectionTarget: confirmingTarget, index: $0) }
    confirmingTarget.attach(checkmarks: confirmingCheckmarks, rowTargets: confirmingRowTargets)
    confirmingRowTargets[1].select()
    XCTAssertTrue(didConfirm)
    XCTAssertEqual(confirmingTarget.selectedIndex, 1)
  }

  func testSharedFlippedDocumentViewKeepsScrollContentTopAnchored() {
    XCTAssertTrue(FlippedDocumentView().isFlipped)
  }
}

private extension RielaAppControllerLayoutTests {
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

  private func visiblePopUpButtons(in root: NSView) -> [NSPopUpButton] {
    allSubviews(of: NSPopUpButton.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    allSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .button
    }
  }

  private func settingsGroupRow(accessibilityLabel: String, in root: NSView) -> RielaAppSettingsRow? {
    allSubviews(of: RielaAppSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .group
    }
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

  private func settingsTitleLabels(in root: NSView) -> [NSTextField] {
    visibleTextFields(in: root).filter { label in
      ["Instance ID", "Display Name", "Current Lines", "Editor"].contains(label.stringValue)
    }
  }

  private func scratchRoot(name: String) throws -> URL {
    let root = try repositoryRoot().appendingPathComponent("tmp", isDirectory: true)
    let scratch = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
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
      domain: "RielaAppControllerLayoutTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
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
