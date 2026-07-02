#if os(macOS)
import AppKit
import Foundation
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppSettingsSectionLayoutTests: XCTestCase {
  func testInstanceDetailRowsUseGroupedSettingsSectionsAtRuntime() throws {
    let controller = configuredInstanceDetailController()

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let overview = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowOverviewPaneView.self, in: root).first)
    overview.layoutSubtreeIfNeeded()
    XCTAssertTrue(controller.instanceDetailView === overview)
    XCTAssertEqual(overview.header.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(overview.header.frame.height, 28, accuracy: 0.1)
    XCTAssertEqual(overview.contentView.frame.minY, 40, accuracy: 0.1)
    XCTAssertEqual((overview.contentView as? NSScrollView)?.drawsBackground, false)

    let sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertGreaterThanOrEqual(sections.count, 2)
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).allSatisfy(\.isGroupedSettingsRow))
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: sections[1]).allSatisfy(\.isGroupedSettingsRow))
  }

  func testInstanceDetailShowsReadOnlyWorkflowGraphCanvasAtRuntime() throws {
    let scratch = try scratchRoot(name: "riela-app-workflow-graph-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let workflowDirectory = scratch.appendingPathComponent("graph-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try writeGraphWorkflowFixture(to: workflowDirectory)
    let controller = configuredInstanceDetailController(workflowDirectory: workflowDirectory.path)

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let graphPane = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowGraphPaneView.self, in: root).first)
    graphPane.layoutSubtreeIfNeeded()
    let graphImageData = try renderedPNGData(for: graphPane)
    XCTAssertGreaterThan(graphImageData.count, 6_000)
    if let snapshotPath = ProcessInfo.processInfo.environment["RIELAAPP_WORKFLOW_GRAPH_SNAPSHOT_PATH"] {
      try graphImageData.write(to: URL(fileURLWithPath: snapshotPath))
    }
    XCTAssertEqual(graphPane.summaryLabel.stringValue, "3 nodes, 2 transitions")
    XCTAssertEqual(graphPane.canvasView.model?.nodes.map(\.id), ["start", "review", "finish"])
    XCTAssertTrue(graphPane.canvasView.model?.edges.contains {
      $0.from == "start" && $0.to == "review" && $0.label == "accepted"
    } ?? false)
    XCTAssertTrue(graphPane.scrollView.hasHorizontalScroller)
    XCTAssertTrue(graphPane.scrollView.hasVerticalScroller)

    let canvas = graphPane.canvasView
    canvas.frame.size = canvas.contentSize(minVisibleSize: NSSize(width: 420, height: 220))
    guard let event = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: canvas.convert(NSPoint(x: 42, y: 42), to: nil),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: controller.window?.windowNumber ?? 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ) else {
      return XCTFail("expected mouse event")
    }
    canvas.mouseDown(with: event)

    XCTAssertEqual(canvas.selectedNodeIdForTesting, "start")
    XCTAssertTrue(canvas.hasNodePopoverForTesting)
  }

  func testInstanceDetailDoesNotShowInlineBackButtonAtRuntime() throws {
    let controller = configuredInstanceDetailController()

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let visibleButtons = visibleSubviews(of: NSButton.self, in: root)
    XCTAssertFalse(visibleButtons.contains { $0.accessibilityLabel() == "Back to Instances" })
  }

  func testGroupedSettingsWindowRendersNonBlankAtRuntime() throws {
    let controller = configuredInstanceDetailController()
    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    let imageData = try renderedPNGData(for: root)
    XCTAssertGreaterThan(imageData.count, 10_000)
    if let snapshotPath = ProcessInfo.processInfo.environment["RIELAAPP_SETTINGS_SNAPSHOT_PATH"] {
      try imageData.write(to: URL(fileURLWithPath: snapshotPath))
    }
  }

  func testGroupedInstanceListRendersNonBlankAtRuntime() throws {
    let controller = configuredInstanceListController()
    let root = try XCTUnwrap(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    let imageData = try renderedPNGData(for: root)
    XCTAssertGreaterThan(imageData.count, 10_000)
    if let snapshotPath = ProcessInfo.processInfo.environment["RIELAAPP_INSTANCE_LIST_SNAPSHOT_PATH"] {
      try imageData.write(to: URL(fileURLWithPath: snapshotPath))
    }
  }

  func testInstanceListUsesGroupedListRowsAtRuntime() throws {
    let controller = configuredInstanceListController()
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    window.layoutIfNeeded()

    let root = try XCTUnwrap(window.contentView)
    let listView = try XCTUnwrap(firstSubview(of: DaemonWorkflowInstanceListView.self, in: root))
    listView.layoutSubtreeIfNeeded()
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? RielaAppTableSelectionCellView)

    XCTAssertEqual(table.rowHeight, 62, accuracy: 0.1)
    XCTAssertEqual(table.intercellSpacing, .zero)
    XCTAssertEqual(table.backgroundColor, .clear)
    XCTAssertEqual(listView.scrollView.layer?.cornerRadius, 14)
    XCTAssertEqual(listView.scrollView.layer?.masksToBounds, true)
    XCTAssertNotNil(listView.scrollView.layer?.backgroundColor)
    XCTAssertEqual(
      listView.scrollView.contentInsets.bottom,
      DaemonWorkflowInstanceListView.listBottomPadding,
      accuracy: 0.1
    )
    XCTAssertEqual(
      listView.scrollView.frame.height,
      table.rowHeight + DaemonWorkflowInstanceListView.listBottomPadding,
      accuracy: 1
    )
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: cell).isEmpty)
    XCTAssertNotNil(firstSubview(of: RielaAppSymbolTileView.self, in: cell))
  }

  func testSettingsShellSidebarUsesRoundedPanelAtRuntime() throws {
    let controller = configuredInstanceListController()
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    window.layoutIfNeeded()

    let root = try XCTUnwrap(window.contentView)
    let sidebar = try XCTUnwrap(root.subviews.compactMap { $0 as? NSVisualEffectView }.first)

    XCTAssertEqual(sidebar.frame.minX, 8, accuracy: 0.1)
    XCTAssertEqual(sidebar.frame.minY, 8, accuracy: 0.1)
    XCTAssertEqual(sidebar.frame.height, root.bounds.height - 16, accuracy: 0.1)
    XCTAssertEqual(sidebar.layer?.cornerRadius, 22)
    XCTAssertEqual(sidebar.layer?.masksToBounds, true)
    XCTAssertEqual(sidebar.layer?.borderWidth, 1)
    XCTAssertNotNil(sidebar.layer?.borderColor)
  }

  func testContentHostKeepsOnlyActivePaneVisibleAtRuntime() throws {
    let controller = configuredInstanceListController()
    let contentHost = try XCTUnwrap(controller.contentHost)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(contentHost.subviews.contains { $0 === controller.instancesListView })
    XCTAssertEqual(contentHost.subviews.filter { !$0.isHidden }.count, 1)
    XCTAssertTrue(contentHost.subviews.first { !$0.isHidden } === controller.instancesListView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(contentHost.subviews.contains { $0 === controller.instancesListView })
    XCTAssertTrue(contentHost.subviews.contains { $0 === controller.sourcesOverviewView })
    XCTAssertEqual(contentHost.subviews.filter { !$0.isHidden }.count, 1)
    XCTAssertTrue(contentHost.subviews.first { !$0.isHidden } === controller.sourcesOverviewView)

    controller.showInstancesPane()
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(contentHost.subviews.filter { !$0.isHidden }.count, 1)
    XCTAssertTrue(contentHost.subviews.first { !$0.isHidden } === controller.instancesListView)
  }

  func testSidebarOverviewPanesUseInstanceRightPaneLayoutAtRuntime() throws {
    let controller = makeController()
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    let root = try XCTUnwrap(window.contentView)

    controller.showSourcesPane()
    window.layoutIfNeeded()
    let sourcesPane = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowSourcesPaneView.self, in: root).first)
    sourcesPane.layoutSubtreeIfNeeded()
    XCTAssertEqual(sourcesPane.header.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(sourcesPane.header.frame.height, 72, accuracy: 0.1)
    XCTAssertEqual(sourcesPane.listScrollView.frame.minY, 84, accuracy: 0.1)
    XCTAssertEqual(sourcesPane.listScrollView.frame.width, sourcesPane.bounds.width, accuracy: 0.1)
    XCTAssertEqual(sourcesPane.listScrollView.layer?.cornerRadius, 14)

    controller.showProfilesPane()
    window.layoutIfNeeded()
    let profileList = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowInstanceListView.self, in: root).first)
    profileList.layoutSubtreeIfNeeded()
    XCTAssertEqual(profileList.header.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(profileList.scrollView.layer?.cornerRadius, 14)
    XCTAssertEqual(profileList.footer.frame.height, 44, accuracy: 0.1)
    XCTAssertLessThan(profileList.scrollView.frame.height, 140)
    XCTAssertGreaterThan(profileList.scrollView.frame.height, 50)

    controller.showAssistantPane()
    window.layoutIfNeeded()
    let overview = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowOverviewPaneView.self, in: root).first)
    overview.layoutSubtreeIfNeeded()
    XCTAssertEqual(overview.contentView.frame.minY, 40, accuracy: 0.1)
  }

  func testSidebarOverviewActionRowsUseGroupedSettingsSectionsAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()
    var sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertEqual(sections.count, 0)
    let fileImportAccessibilityLabel = "Import Package File or Directory"
    XCTAssertTrue(visibleSubviews(of: NSButton.self, in: root).contains {
      $0.accessibilityLabel() == fileImportAccessibilityLabel
    })
    XCTAssertTrue(visibleSubviews(of: NSButton.self, in: root).contains {
      $0.accessibilityLabel() == "Import from URL"
    })

    controller.showProfilesPane()
    controller.window?.layoutIfNeeded()
    sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).count, 1)

    controller.showAssistantPane()
    controller.window?.layoutIfNeeded()
    sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).count, 2)
  }

  func testSourcesPaneUsesButtonsForImportActionsAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()

    let fileImportAccessibilityLabel = "Import Package File or Directory"
    let fileButton = try XCTUnwrap(
      visibleSubviews(of: NSButton.self, in: root)
        .first { $0.accessibilityLabel() == fileImportAccessibilityLabel }
    )
    let urlButton = try XCTUnwrap(
      visibleSubviews(of: NSButton.self, in: root)
        .first { $0.accessibilityLabel() == "Import from URL" }
    )

    XCTAssertEqual(fileButton.title, "Import File/Directory")
    XCTAssertEqual(urlButton.title, "Import URL")
    XCTAssertFalse(visibleSubviews(of: RielaAppSelectableSettingsRow.self, in: root).contains {
      $0.accessibilityLabel() == fileImportAccessibilityLabel || $0.accessibilityLabel() == "Import from URL"
    })
  }

  func testSourcesPaneFiltersWorkflowListByPartialTextAtRuntime() throws {
    let controller = configuredInstanceListController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()

    let searchField = try XCTUnwrap(visibleSubviews(of: NSSearchField.self, in: root).first)
    XCTAssertEqual(searchField.accessibilityLabel(), "Filter Workflow Sources")
    XCTAssertNotNil(selectableRow(accessibilityLabel: "Daily Summary", in: root))

    searchField.stringValue = "daily"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.workflowSourceFilterText, "daily")
    XCTAssertNotNil(selectableRow(accessibilityLabel: "Daily Summary", in: root))

    searchField.stringValue = "does-not-match"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
    controller.window?.layoutIfNeeded()
    XCTAssertNil(selectableRow(accessibilityLabel: "Daily Summary", in: root))
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: root).contains {
      $0.stringValue == "No workflow sources match the current filter."
    })
  }

  func testSourcesPaneOpensWorkflowSourceDetailWithGraphAtRuntime() throws {
    let scratch = try scratchRoot(name: "riela-app-sources-graph-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let workflowDirectory = scratch.appendingPathComponent("graph-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    try writeGraphWorkflowFixture(to: workflowDirectory)
    let controller = configuredInstanceListController(workflowDirectory: workflowDirectory.path)
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()

    let sourcesPane = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowSourcesPaneView.self, in: root).first)
    sourcesPane.layoutSubtreeIfNeeded()
    let sourceRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Daily Summary", in: root))
    XCTAssertFalse(sourceRow.isSettingsRowSelected)
    XCTAssertTrue(sourcesPane.emptyLabel.isHidden)
    XCTAssertTrue(visibleSubviews(of: DaemonWorkflowGraphPaneView.self, in: root).isEmpty)

    XCTAssertTrue(sourceRow.accessibilityPerformPress())
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(controller.isShowingWorkflowSourceDetail)
    XCTAssertEqual(controller.selectedWorkflowSourceId, "user-workflow:daily-summary")
    XCTAssertTrue(controller.workflowSourceDetailView?.isHidden == false)
    XCTAssertTrue(controller.sourcesOverviewView?.isHidden == true)

    let graphPane = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowGraphPaneView.self, in: root).first)
    graphPane.layoutSubtreeIfNeeded()
    XCTAssertEqual(graphPane.summaryLabel.stringValue, "3 nodes, 2 transitions")
    XCTAssertEqual(graphPane.canvasView.model?.nodes.map(\.id), ["start", "review", "finish"])
    XCTAssertTrue(graphPane.canvasView.model?.edges.contains {
      $0.from == "start" && $0.to == "review" && $0.label == "accepted"
    } ?? false)
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: root).contains { $0.stringValue == workflowDirectory.path })

    controller.goBack()
    controller.window?.layoutIfNeeded()
    XCTAssertFalse(controller.isShowingWorkflowSourceDetail)
    XCTAssertTrue(controller.sourcesOverviewView?.isHidden == false)
    let selectedSourceRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Daily Summary", in: root))
    XCTAssertTrue(selectedSourceRow.isSettingsRowSelected)
  }

  func testProfilesPaneShowsProfileListBeforeProfileActionsAtRuntime() throws {
    let controller = makeController()
    controller.update(
      profileName: .default,
      profileNames: [.default, RielaAppProfileName("work")],
      candidates: [],
      workflowSources: [],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showProfilesPane()
    controller.window?.layoutIfNeeded()

    let sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertEqual(sections.count, 1)
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: sections[0]).contains { $0.stringValue == "default" })
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: sections[0]).contains { $0.stringValue == "work" })
    XCTAssertTrue(visibleSubviews(of: NSButton.self, in: root).contains { $0.accessibilityLabel() == "Add Profile" })
    XCTAssertFalse(visibleSubviews(of: NSTextField.self, in: root).contains { $0.stringValue == "Edit Profiles" })
  }

  func testProfileRowsOpenInlineDetailAndBackReturnsToProfilesAtRuntime() throws {
    var selectedProfile: String?
    let controller = makeController(onSelectProfile: { selectedProfile = $0 })
    controller.update(
      profileName: .default,
      profileNames: [.default, RielaAppProfileName("work")],
      candidates: [],
      workflowSources: [],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showProfilesPane()
    controller.window?.layoutIfNeeded()
    let workRow = try XCTUnwrap(selectableRow(accessibilityLabel: "work", in: root))
    XCTAssertTrue(workRow.accessibilityPerformPress())
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(controller.isShowingProfileDetail)
    XCTAssertTrue(controller.profileDetailView?.isHidden == false)
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: root).contains { $0.stringValue == "Use Profile" })
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: root).contains { $0.stringValue == "Remove Profile" })

    let useRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Use Profile", in: root))
    XCTAssertTrue(useRow.accessibilityPerformPress())
    XCTAssertEqual(selectedProfile, "work")

    controller.goBack()
    controller.window?.layoutIfNeeded()
    XCTAssertFalse(controller.isShowingProfileDetail)
    XCTAssertTrue(controller.profilesOverviewView?.isHidden == false)
  }

  func testProfileRemovalUsesInlineConfirmationPaneAtRuntime() throws {
    var removedProfile: RielaAppProfileName?
    let controller = makeController(onRemoveProfile: {
      removedProfile = $0
      return true
    })
    let workProfile = RielaAppProfileName("work")
    controller.update(
      profileName: .default,
      profileNames: [.default, workProfile],
      candidates: [],
      workflowSources: [],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showProfileDetail(workProfile)
    controller.window?.layoutIfNeeded()
    let removeReviewRow = try XCTUnwrap(selectableRow(accessibilityLabel: "Remove Profile", in: root))
    XCTAssertTrue(removeReviewRow.accessibilityPerformPress())
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(controller.profileDetailMode, .removalConfirmation)
    XCTAssertTrue(visibleSubviews(of: NSTextField.self, in: root).contains { $0.stringValue == "Confirm Removal" })
    let confirmedRemoveRow = try XCTUnwrap(
      visibleSubviews(of: RielaAppSelectableSettingsRow.self, in: root)
        .first { $0.accessibilityLabel() == "Remove Profile" && $0.accessibilityHelp() == "Remove this profile. Other profiles are unchanged." }
    )
    XCTAssertTrue(confirmedRemoveRow.accessibilityPerformPress())
    XCTAssertEqual(removedProfile, workProfile)
  }

  private func makeController(
    onSelectProfile: @escaping (String) -> Void = { _ in },
    onRemoveProfile: @escaping (RielaAppProfileName) -> Bool = { _ in true }
  ) -> DaemonWorkflowWindowController {
    DaemonWorkflowWindowController(
      onRefresh: {},
      onSelectProfile: onSelectProfile,
      onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: onRemoveProfile,
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

  private func configuredInstanceDetailController(workflowDirectory: String = "workflows/daily-summary") -> DaemonWorkflowWindowController {
    let controller = configuredInstanceListController(workflowDirectory: workflowDirectory)
    controller.selectCandidate(identity: "morning-summary")
    return controller
  }

  private func configuredInstanceListController(workflowDirectory: String = "workflows/daily-summary") -> DaemonWorkflowWindowController {
    let controller = makeController()
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:daily-summary",
      workflowId: "daily-summary",
      displayName: "Daily Summary",
      sourceDescription: "user workflow",
      workflowDirectory: workflowDirectory,
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
    return controller
  }

  private func writeGraphWorkflowFixture(to workflowDirectory: URL) throws {
    let workflowJSON = """
    {
      "workflowId": "graph-demo",
      "description": "A workflow graph fixture.",
      "defaults": {
        "nodeTimeoutMs": 1000,
        "maxLoopIterations": 1
      },
      "entryStepId": "start",
      "nodes": [
        { "id": "start-node", "addon": { "name": "test/start" } },
        { "id": "review-node", "addon": { "name": "test/review" } },
        { "id": "finish-node", "addon": { "name": "test/finish" } }
      ],
      "steps": [
        {
          "id": "start",
          "nodeId": "start-node",
          "description": "Collect the initial workflow input.",
          "role": "manager",
          "transitions": [
            { "toStepId": "review", "label": "accepted" }
          ]
        },
        {
          "id": "review",
          "nodeId": "review-node",
          "description": "Review the collected input.",
          "role": "worker",
          "transitions": [
            { "toStepId": "finish" }
          ]
        },
        {
          "id": "finish",
          "nodeId": "finish-node",
          "description": "Publish the final output.",
          "role": "worker"
        }
      ]
    }
    """
    try workflowJSON.write(
      to: workflowDirectory.appendingPathComponent("workflow.json"),
      atomically: true,
      encoding: .utf8
    )
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
      domain: "RielaAppSettingsSectionLayoutTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Package.swift not found"]
    )
  }

  private func renderedPNGData(for view: NSView) throws -> Data {
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw NSError(
        domain: "RielaAppSettingsSectionLayoutTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not create bitmap representation"]
      )
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    XCTAssertGreaterThan(sampledColorCount(in: representation), 3)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw NSError(
        domain: "RielaAppSettingsSectionLayoutTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Could not encode PNG representation"]
      )
    }
    return data
  }

  private func sampledColorCount(in representation: NSBitmapImageRep) -> Int {
    guard
      let bitmapData = representation.bitmapData,
      representation.samplesPerPixel >= 3
    else {
      return 0
    }
    let xStride = max(1, representation.pixelsWide / 16)
    let yStride = max(1, representation.pixelsHigh / 16)
    var colors = Set<Int>()
    for yPosition in stride(from: 0, to: representation.pixelsHigh, by: yStride) {
      for xPosition in stride(from: 0, to: representation.pixelsWide, by: xStride) {
        let offset = yPosition * representation.bytesPerRow + xPosition * representation.samplesPerPixel
        let red = Int(bitmapData[offset])
        let green = Int(bitmapData[offset + 1])
        let blue = Int(bitmapData[offset + 2])
        colors.insert(red << 16 | green << 8 | blue)
      }
    }
    return colors.count
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

  private func visibleSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    allSubviews(of: type, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    visibleSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      row.accessibilityLabel() == accessibilityLabel
    }
  }

  private func allSubviews<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    let current = (root as? T).map { [$0] } ?? []
    return current + root.subviews.flatMap { allSubviews(of: type, in: $0) }
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
