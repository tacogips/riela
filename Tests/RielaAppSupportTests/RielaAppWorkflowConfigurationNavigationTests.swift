#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppWorkflowNavigationTests: XCTestCase {
  func testWorkflowRootOffersDefaultWithoutCreatingOrStartingPreferences() throws {
    let controller = makeController()
    let source = candidate("daily")
    update(controller, sources: [source])

    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "ワークフロー")
    XCTAssertFalse(controller.isBackNavigationAvailable)
    XCTAssertNil(controller.sidebarSourcesButton.superview)
    XCTAssertTrue(controller.state.preferences.isEmpty)
    XCTAssertEqual(controller.workflowConfigurationRows(for: source).map(\.instanceName), ["標準設定"])
    XCTAssertEqual(controller.workflowConfigurationRows(for: source).map(\.state), [.stopped])

    controller.selectedWorkflowSourceId = source.id
    controller.showWorkflowSourceDetail()
    let pane = try XCTUnwrap(controller.workflowSourceDetailView)
    XCTAssertNotNil(findRow("標準設定", in: pane))
    XCTAssertNotNil(findRow("実行設定を追加", in: pane))
    XCTAssertTrue(controller.state.preferences.isEmpty)
  }

  func testConfigurationSelectionAndBackPreserveWorkflowAndScopedRoutes() throws {
    var openedPaths: [String] = []
    let controller = makeController(onOpenWebUI: { openedPaths.append($0) })
    let daily = candidate("daily")
    let other = candidate("other")
    var state = RielaAppDaemonWorkflowState()
    state.preferences["named/日本語"] = .init(
      identity: "named/日本語", sourceIdentity: daily.id, displayName: "Production", available: true, active: false
    )
    update(controller, sources: [daily, other], state: state)
    XCTAssertEqual(controller.workflowConfigurationRows(for: daily).map(\.instanceName), ["標準設定", "Production"])
    XCTAssertEqual(controller.workflowConfigurationRows(for: other).map(\.instanceName), ["標準設定"])

    controller.selectedWorkflowSourceId = daily.id
    controller.showWorkflowSourceDetail()
    let pane = try XCTUnwrap(controller.workflowSourceDetailView)
    let namedRow = try XCTUnwrap(findRow("Production", in: pane))
    XCTAssertTrue(namedRow.accessibilityPerformPress())
    XCTAssertTrue(controller.isShowingInstanceDetail)
    XCTAssertEqual(controller.selectedRow()?.localIdentity, "named/日本語")
    XCTAssertEqual(controller.navigationTitleLabel.stringValue, "daily › Production")
    controller.openSelectedInstanceInWebUI()
    controller.openSelectedConfigurationHistory()
    XCTAssertEqual(openedPaths, [
      "#/workflows/user-workflow%3Adaily/configurations/named%2F%E6%97%A5%E6%9C%AC%E8%AA%9E/settings",
      "#/workflows/user-workflow%3Adaily/configurations/named%2F%E6%97%A5%E6%9C%AC%E8%AA%9E/history"
    ])
    controller.goBack()
    XCTAssertTrue(controller.isShowingWorkflowSourceDetail)
    XCTAssertEqual(controller.selectedWorkflowSourceId, daily.id)
    controller.goBack()
    XCTAssertTrue(controller.sourcesOverviewView?.isHidden == false)
    XCTAssertFalse(controller.isBackNavigationAvailable)
  }

  func testDefaultConfigurationCannotBeRemovedAndNamedConfigurationCan() {
    let controller = makeController()
    let source = candidate("daily")
    update(controller, sources: [source])
    controller.selectCandidate(identity: source.id)
    controller.showInstanceDetail()
    XCTAssertEqual(controller.removeInstanceActionRow?.isHidden, true)

    var state = RielaAppDaemonWorkflowState()
    state.preferences[source.id] = .init(identity: source.id, displayName: "Custom default")
    state.preferences["named"] = .init(identity: "named", sourceIdentity: source.id, displayName: "Named")
    update(controller, sources: [source], state: state)
    controller.selectCandidate(identity: source.id)
    controller.showInstanceDetail()
    XCTAssertEqual(controller.removeInstanceActionRow?.isHidden, true)
    controller.selectCandidate(identity: "named")
    XCTAssertEqual(controller.removeInstanceActionRow?.isHidden, false)
  }

  func testConfigurationsAreScopedToSelectedProfile() {
    let controller = makeController()
    let source = candidate("daily")
    let defaultInstance = WorkflowInstance.unconfigured(source: source)
    controller.update(
      profileName: .default, profileNames: [.default, .init("other")],
      candidates: [], workflowSources: [source],
      profileInstances: [
        .init(profileName: .default, instance: defaultInstance),
        .init(profileName: .init("other"), instance: defaultInstance)
      ], state: .init(), snapshots: [:], assistantAssistance: "", statusMessage: ""
    )
    XCTAssertEqual(controller.workflowConfigurationRows(for: source).count, 1)
    XCTAssertEqual(controller.workflowConfigurationRows(for: source).first?.profileName, .default)
  }

  private func update(
    _ controller: DaemonWorkflowWindowController,
    sources: [RielaAppDaemonWorkflowCandidate],
    state: RielaAppDaemonWorkflowState = .init()
  ) {
    controller.update(
      profileName: .default, profileNames: [.default], candidates: sources,
      workflowSources: sources, state: state, snapshots: [:], assistantAssistance: "", statusMessage: ""
    )
  }

  private func candidate(_ id: String) -> RielaAppDaemonWorkflowCandidate {
    .init(
      id: "user-workflow:\(id)", workflowId: id, displayName: id, sourceDescription: "user workflow",
      workflowDirectory: "/workflows/\(id)", workingDirectory: "/workflows", eventRoot: nil, eventSources: []
    )
  }

  private func findRow(_ label: String, in view: NSView) -> RielaAppSelectableSettingsRow? {
    if let row = view as? RielaAppSelectableSettingsRow, row.accessibilityLabel() == label { return row }
    return view.subviews.lazy.compactMap { self.findRow(label, in: $0) }.first
  }

  private func makeController(onOpenWebUI: @escaping (String) -> Void = { _ in }) -> DaemonWorkflowWindowController {
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
      onOpenWebUI: onOpenWebUI,
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

}
#endif
