#if os(macOS)
import AppKit
import RielaAppSupport
import RielaCore
import RielaViewer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppBehaviorRegressionTests: XCTestCase {
  func testInstanceListDoesNotExposeLegacySourceColumnsAtRuntime() throws {
    let controller = makeDaemonController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let identifiers = Set(table.tableColumns.map(\.identifier.rawValue))

    XCTAssertTrue(identifiers.contains("instance"))
    XCTAssertFalse(identifiers.contains("source"))
    XCTAssertFalse(identifiers.contains("sources"))
    XCTAssertNil(table.headerView)
  }

  func testStatusMenuUsesCompactSummaryItemsAtRuntime() throws {
    let app = RielaApp()
    app.daemonProfileName = RielaAppProfileName("work")
    app.daemonState.preferences = [
      "running-one": RielaAppDaemonWorkflowPreference(
        identity: "running-one",
        sourceIdentity: "source-running",
        displayName: "Running One",
        available: true,
        active: true
      ),
      "missing-one": RielaAppDaemonWorkflowPreference(
        identity: "missing-one",
        sourceIdentity: "source-missing",
        displayName: "Missing One",
        available: true,
        active: false
      )
    ]
    app.daemonCandidates = [
      RielaAppDaemonWorkflowCandidate(
        id: "source-running",
        workflowId: "running",
        displayName: "Running",
        sourceDescription: "test source",
        workflowDirectory: "/tmp/running",
        workingDirectory: "/tmp",
        eventRoot: nil,
        eventSources: []
      )
    ]

    app.rebuildMenu()

    let menu = app.statusItem.menu
    XCTAssertEqual(menu?.items.first?.title, "Instances...")
    XCTAssertEqual(menu?.items.first?.target as? RielaApp, app)
    XCTAssertTrue(menu?.items.contains { $0.title == "Launch on Login" } == true)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Status:") } == true)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Profile:") } == true)
    XCTAssertFalse(menu?.items.contains { $0.title.hasPrefix("Instances:") } == true)

    let summaryItem = try XCTUnwrap(menu?.items.first { item in
      item.title.contains("Instances ") && item.title.contains("Profile work")
    })
    XCTAssertEqual(summaryItem.isEnabled, false)
    XCTAssertEqual(summaryItem.toolTip, summaryItem.title)
  }

  func testAddInstanceSelectionUsesInlinePaneAndNoWorkflowPopupAtRuntime() throws {
    let controller = makeDaemonController()
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

    controller.goBack()
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "Instances")
    XCTAssertEqual(controller.instancesListView?.isHidden, false)
    XCTAssertEqual(controller.addInstanceSelectionView?.isHidden, true)
  }

  func testInstanceDetailDoesNotRenderLegacyInlineBackButtonAtRuntime() throws {
    let controller = makeDaemonController()
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
    controller.selectCandidate(identity: "morning-summary")

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Current Settings" })
    XCTAssertNil(button(accessibilityLabel: "Back to Instances", in: root))
    XCTAssertFalse(visibleTextFields(in: root).contains { $0.stringValue == "< Instances" })
  }

  func testWorkflowViewerTabsAndEditableRowsAtRuntime() throws {
    let temp = try scratchRoot(name: "riela-app-behavior-viewer-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let runtimeRoot = sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try writeWorkflow(id: "viewer-contract", to: workflowDirectory)
    try saveSessions([
      workflowSession(id: "contract-session", stepId: "first", updatedAt: Date(timeIntervalSince1970: 10))
    ], runtimeRoot: runtimeRoot)

    let controller = WorkflowViewerWindowController()
    controller.show(
      workflowDirectory: workflowDirectory.path,
      sessionStoreRoot: sessionStoreRoot.path,
      onSetWorkingDirectory: { "/tmp/work" },
      onSetEnvironmentVariables: { "1 variable" },
      onSetWorkflowVariables: { "2 variables" }
    )
    let root = try XCTUnwrap(controller.window?.contentView)
    let tabView = try XCTUnwrap(firstSubview(of: NSTabView.self, in: root))
    XCTAssertEqual(tabView.tabViewItems.map(\.label), ["Edit", "Variables", "Run Log", "Structure"])
    XCTAssertEqual(controller.window?.minSize, NSSize(width: 420, height: 380))

    let popUpLabels = Set(visiblePopUpButtons(in: root).compactMap { $0.accessibilityLabel() })
    XCTAssertTrue(popUpLabels.contains("Session"))
    XCTAssertTrue(popUpLabels.contains("Template"))

    try selectTab(named: "Variables", in: tabView)
    controller.window?.layoutIfNeeded()
    let currentDirectoryRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Current Directory", in: root))
    XCTAssertEqual(currentDirectoryRow.accessibilityRole(), .button)
    XCTAssertEqual(currentDirectoryRow.accessibilityHelp(), "Change Current Directory")
    XCTAssertTrue(currentDirectoryRow.rielaAccessibilityEnabled)
  }

  func testWorkflowViewerTreeRowsExposeStateAndPressActionAtRuntime() throws {
    let temp = try scratchRoot(name: "riela-app-behavior-tree-\(UUID().uuidString)")
    let workflowDirectory = temp.appendingPathComponent("workflows/demo", isDirectory: true)
    let sessionStoreRoot = temp.appendingPathComponent(".riela/sessions", isDirectory: true)
    let runtimeRoot = sessionStoreRoot.appendingPathComponent("runtime-records", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }

    try writeWorkflow(id: "viewer-tree", to: workflowDirectory)
    try saveSessions([
      workflowSession(
        workflowId: "viewer-tree",
        id: "tree-session",
        stepId: "first",
        updatedAt: Date(timeIntervalSince1970: 12)
      )
    ], runtimeRoot: runtimeRoot)

    let controller = WorkflowViewerWindowController()
    controller.show(workflowDirectory: workflowDirectory.path, sessionStoreRoot: sessionStoreRoot.path)
    let root = try XCTUnwrap(controller.window?.contentView)
    let outlineView = try XCTUnwrap(firstSubview(of: NSOutlineView.self, in: root))
    let secondRow = try XCTUnwrap((0..<outlineView.numberOfRows).first { row in
      (outlineView.item(atRow: row) as? WorkflowViewerNode)?.nodeId == "second"
    })
    let cell = try XCTUnwrap(
      outlineView.view(atColumn: 0, row: secondRow, makeIfNecessary: true) as? RielaAppTableSelectionCellView
    )

    XCTAssertEqual(cell.accessibilityRole(), .button)
    XCTAssertEqual(cell.accessibilityLabel(), "second")
    XCTAssertEqual(cell.accessibilityValue() as? String, "Idle")
    XCTAssertEqual(cell.accessibilityHelp(), "Show workflow node details")
    XCTAssertTrue(cell.accessibilityPerformPress())
    XCTAssertEqual(outlineView.selectedRow, secondRow)
  }

  func testSelectableSettingsRowBaseSemanticsAtRuntime() {
    let target = SelectableSettingsRowTarget()
    let row = RielaAppSelectableSettingsRow(views: [NSTextField(labelWithString: "Relink Source")])
    rielaAppSelectableSettingsRow(
      row,
      target: target,
      action: #selector(SelectableSettingsRowTarget.press),
      accessibilityLabel: "Relink Source",
      accessibilityHelp: "Choose a workflow source"
    )

    XCTAssertEqual(row.accessibilityRole(), .button)
    XCTAssertEqual(row.accessibilityLabel(), "Relink Source")
    XCTAssertEqual(row.accessibilityHelp(), "Choose a workflow source")
    XCTAssertTrue(row.acceptsFirstResponder)
    XCTAssertTrue(row.accessibilityPerformPress())
    XCTAssertEqual(target.pressCount, 1)
    row.setRielaAccessibilityEnabled(false)
    XCTAssertFalse(row.accessibilityPerformPress())
    XCTAssertEqual(target.pressCount, 1)
  }

  private func makeDaemonController() -> DaemonWorkflowWindowController {
    DaemonWorkflowWindowController(
      onRefresh: {},
      onSelectProfile: { _ in },
      onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: { _ in true },
      onAddDirectory: {},
      onAddProject: {},
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

  private func writeWorkflow(id: String, to workflowDirectory: URL) throws {
    let workflow = WorkflowDefinition(
      workflowId: id,
      defaults: WorkflowDefaults(nodeTimeoutMs: 1_000, maxLoopIterations: 3),
      entryStepId: "first",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "first"), WorkflowNodeRegistryRef(id: "second")],
      steps: [
        WorkflowStepRef(id: "first", nodeId: "first", transitions: [WorkflowStepTransition(toStepId: "second")]),
        WorkflowStepRef(id: "second", nodeId: "second")
      ],
      nodes: [
        WorkflowNodeRef(id: "first", nodeFile: "nodes/first.json"),
        WorkflowNodeRef(id: "second", nodeFile: "nodes/second.json")
      ]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(workflow).write(to: workflowDirectory.appendingPathComponent("workflow.json"))
  }

  private func workflowSession(
    workflowId: String = "viewer-contract",
    id: String,
    stepId: String,
    updatedAt: Date
  ) -> WorkflowSession {
    WorkflowSession(
      workflowId: workflowId,
      sessionId: id,
      status: .running,
      entryStepId: "first",
      currentStepId: stepId,
      createdAt: updatedAt,
      updatedAt: updatedAt,
      executions: [WorkflowStepExecution(
        executionId: "exec-\(id)",
        stepId: stepId,
        nodeId: stepId,
        attempt: 1,
        status: .running,
        createdAt: updatedAt,
        updatedAt: updatedAt
      )]
    )
  }

  private func saveSessions(_ sessions: [WorkflowSession], runtimeRoot: URL) throws {
    let store = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: runtimeRoot.path)
    for session in sessions {
      try store.save(WorkflowRuntimePersistenceSnapshot(session: session))
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
      domain: "RielaAppBehaviorRegressionTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
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

  private func selectTab(named label: String, in tabView: NSTabView) throws {
    guard let item = tabView.tabViewItems.first(where: { $0.label == label }) else {
      throw NSError(
        domain: "RielaAppBehaviorRegressionTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Tab not found: \(label)"]
      )
    }
    tabView.selectTabViewItem(item)
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
  }
}

@MainActor
private final class SelectableSettingsRowTarget: NSObject {
  private(set) var pressCount = 0

  @objc func press() {
    pressCount += 1
  }
}

private extension NSView {
  var hasHiddenAncestor: Bool {
    isHidden || superview?.hasHiddenAncestor == true
  }
}
#endif
