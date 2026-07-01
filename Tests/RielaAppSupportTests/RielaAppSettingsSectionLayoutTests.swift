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

    let sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertGreaterThanOrEqual(sections.count, 2)
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).allSatisfy(\.isGroupedSettingsRow))
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: sections[1]).allSatisfy(\.isGroupedSettingsRow))
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

  func testSidebarOverviewPanesUseInstanceRightPaneLayoutAtRuntime() throws {
    let controller = makeController()
    let window = try XCTUnwrap(controller.window)
    window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 640), display: false)
    let root = try XCTUnwrap(window.contentView)

    controller.showSourcesPane()
    window.layoutIfNeeded()
    var overview = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowOverviewPaneView.self, in: root).first)
    overview.layoutSubtreeIfNeeded()
    XCTAssertEqual(overview.header.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(overview.header.frame.height, 28, accuracy: 0.1)
    XCTAssertEqual(overview.contentView.frame.minY, 40, accuracy: 0.1)
    XCTAssertEqual((overview.contentView as? NSScrollView)?.hasVerticalScroller, false)
    XCTAssertEqual(visibleSubviews(of: RielaAppSettingsSectionView.self, in: overview).count, 1)

    controller.showProfilesPane()
    window.layoutIfNeeded()
    overview = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowOverviewPaneView.self, in: root).first)
    overview.layoutSubtreeIfNeeded()
    XCTAssertEqual(overview.contentView.frame.minY, 40, accuracy: 0.1)
    XCTAssertEqual((overview.contentView as? NSScrollView)?.hasVerticalScroller, false)

    controller.showAssistantPane()
    window.layoutIfNeeded()
    overview = try XCTUnwrap(visibleSubviews(of: DaemonWorkflowOverviewPaneView.self, in: root).first)
    overview.layoutSubtreeIfNeeded()
    XCTAssertEqual(overview.contentView.frame.minY, 40, accuracy: 0.1)
  }

  func testSidebarOverviewActionRowsUseGroupedSettingsSectionsAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()
    var sections = visibleSubviews(of: RielaAppSettingsSectionView.self, in: root)
    XCTAssertEqual(sections.count, 1)
    XCTAssertEqual(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).count, 2)
    XCTAssertTrue(allSubviews(of: RielaAppSettingsRow.self, in: sections[0]).allSatisfy(\.isGroupedSettingsRow))

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

  func testSidebarOverviewActionRowsUseInstanceListTypographyAtRuntime() throws {
    let controller = makeController()
    let root = try XCTUnwrap(controller.window?.contentView)

    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()

    let titleLabel = try XCTUnwrap(
      visibleSubviews(of: NSTextField.self, in: root)
        .first { $0.stringValue == "Import Workflow or Package" }
    )
    let detailLabel = try XCTUnwrap(
      visibleSubviews(of: NSTextField.self, in: root)
        .first { $0.stringValue == "Add a workflow, package directory, or archive to this profile." }
    )

    XCTAssertEqual(titleLabel.font?.pointSize, 14)
    XCTAssertEqual(detailLabel.font?.pointSize, 11)
  }

  private func makeController() -> DaemonWorkflowWindowController {
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

  private func configuredInstanceDetailController() -> DaemonWorkflowWindowController {
    let controller = configuredInstanceListController()
    controller.selectCandidate(identity: "morning-summary")
    return controller
  }

  private func configuredInstanceListController() -> DaemonWorkflowWindowController {
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
    return controller
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
