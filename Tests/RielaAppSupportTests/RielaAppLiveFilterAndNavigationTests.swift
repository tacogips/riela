#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppLiveFilterAndNavigationTests: XCTestCase {
  func testInstanceSearchActionNarrowsAndClearsVisibleRows() throws {
    let controller = makeControllerWithInstances()
    let window = try XCTUnwrap(controller.window)

    XCTAssertEqual(controller.instanceRows.count, 4)
    XCTAssertEqual(controller.instanceTable.numberOfRows, 4)
    XCTAssertEqual(controller.instanceSearchField.action, #selector(DaemonWorkflowWindowController.instanceSearchChanged))
    XCTAssertNil(controller.instanceSearchField.delegate)

    XCTAssertTrue(window.makeFirstResponder(controller.instanceSearchField))
    XCTAssertTrue(window.firstResponder === controller.instanceSearchField.currentEditor())

    controller.instanceSearchField.stringValue = "morning"
    XCTAssertTrue(controller.instanceSearchField.sendAction(
      controller.instanceSearchField.action,
      to: controller.instanceSearchField.target
    ))
    XCTAssertEqual(controller.instanceRows.map(\.instanceName), ["Morning Summary"])
    XCTAssertEqual(controller.instanceTable.numberOfRows, 1)
    XCTAssertEqual(controller.selectedRow()?.instanceName, "Morning Summary")
    XCTAssertTrue(window.firstResponder === controller.instanceSearchField.currentEditor())

    controller.instanceSearchField.stringValue = ""
    XCTAssertTrue(controller.instanceSearchField.sendAction(
      controller.instanceSearchField.action,
      to: controller.instanceSearchField.target
    ))
    XCTAssertEqual(controller.instanceRows.count, 4)
    XCTAssertEqual(controller.instanceTable.numberOfRows, 4)
    XCTAssertEqual(controller.selectedRow()?.instanceName, "Morning Summary")
    XCTAssertTrue(window.firstResponder === controller.instanceSearchField.currentEditor())
  }

  func testBackAvailabilityMatchesEveryNavigationState() {
    let controller = makeControllerWithInstances()
    controller.showSourcesPane()
    assertBackState(controller, available: false, state: "workflow root")
    controller.goBack()
    assertBackDestination(controller, expected: .sourcesRoot, state: "workflow root")

    let availableStates: [BackStateCase] = [
      BackStateCase("add configuration", .sourcesRoot) { $0.isShowingAddInstanceSelection = true },
      BackStateCase("configuration overview", .sourcesRoot) { $0.isShowingInstanceDetail = true },
      BackStateCase("configuration removal", .instanceOverview) {
        $0.isShowingInstanceDetail = true
        $0.instanceDetailPane = .removalConfirmation
      },
      BackStateCase("workflow detail", .sourcesRoot) { $0.isShowingWorkflowSourceDetail = true },
      BackStateCase("marketplace detail", .marketplaceRoot) { $0.isShowingMarketplaceWorkflowDetail = true },
      BackStateCase("marketplace root", .sourcesRoot) { $0.activeSidebarPane = .marketplace },
      BackStateCase("profiles root", .sourcesRoot) { $0.activeSidebarPane = .profiles },
      BackStateCase("assistant root", .sourcesRoot) { $0.activeSidebarPane = .assistant }
    ]
    for testCase in availableStates {
      controller.showSourcesPane()
      testCase.configure(controller)
      controller.updateNavigationState()
      assertBackState(controller, available: true, state: testCase.name)
      controller.goBack()
      assertBackDestination(controller, expected: testCase.expectedDestination, state: testCase.name)
    }
  }

  func testBackButtonUsesProportionalSquareLayout() {
    let controller = makeController()
    controller.showProfilesPane()
    controller.window?.layoutIfNeeded()
    let button = controller.navigationBackButton

    XCTAssertEqual(button.imageScaling, .scaleProportionallyDown)
    XCTAssertFalse(button.isHidden)
    XCTAssertFalse(button.superview?.isHidden ?? true)
    XCTAssertTrue(button.constraints.contains {
      $0.isActive
        && $0.firstAttribute == .width
        && $0.relation == .equal
        && $0.secondItem == nil
        && $0.constant == 20
    })
    XCTAssertTrue(button.constraints.contains {
      $0.isActive
        && $0.firstAttribute == .height
        && $0.secondItem as? NSButton === button
        && $0.secondAttribute == .width
    })
    XCTAssertEqual(button.accessibilityLabel(), "Back")
    XCTAssertEqual(button.toolTip, "Back")
  }

  private func assertBackState(
    _ controller: DaemonWorkflowWindowController,
    available: Bool,
    state: String
  ) {
    XCTAssertEqual(controller.isBackNavigationAvailable, available, state)
    XCTAssertEqual(controller.navigationBackButton.isEnabled, available, state)
    XCTAssertEqual(controller.navigationBackButton.isHidden, !available, state)
    XCTAssertEqual(controller.navigationBackButton.superview?.isHidden, !available, state)
  }

  private func assertBackDestination(
    _ controller: DaemonWorkflowWindowController,
    expected: BackDestination,
    state: String
  ) {
    switch expected {
    case .instancesRoot:
      XCTAssertEqual(controller.activeSidebarPane, .instances, state)
      XCTAssertFalse(controller.isBackNavigationAvailable, state)
    case .instanceOverview:
      XCTAssertTrue(controller.isShowingInstanceDetail, state)
      XCTAssertEqual(controller.instanceDetailPane, .overview, state)
    case .sourcesRoot:
      XCTAssertEqual(controller.activeSidebarPane, .sources, state)
      XCTAssertFalse(controller.isShowingWorkflowSourceDetail, state)
    case .marketplaceRoot:
      XCTAssertEqual(controller.activeSidebarPane, .marketplace, state)
      XCTAssertFalse(controller.isShowingMarketplaceWorkflowDetail, state)
    case .profilesRoot:
      XCTAssertEqual(controller.activeSidebarPane, .profiles, state)
    }
  }

  private func makeControllerWithInstances() -> DaemonWorkflowWindowController {
    let controller = makeController()
    let daily = candidate(id: "daily-summary", displayName: "Daily Summary")
    let chat = candidate(id: "chat-reply", displayName: "Chat Reply")
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = preference(
      identity: "morning-summary",
      sourceIdentity: daily.id,
      displayName: "Morning Summary"
    )
    state.preferences["support-chat"] = preference(
      identity: "support-chat",
      sourceIdentity: chat.id,
      displayName: "Support Chat"
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [daily, chat],
      workflowSources: [daily, chat],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    return controller
  }

  private func candidate(id: String, displayName: String) -> RielaAppDaemonWorkflowCandidate {
    RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:\(id)",
      workflowId: id,
      displayName: displayName,
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/\(id)",
      workingDirectory: "/workflows",
      eventRoot: nil,
      eventSources: []
    )
  }

  private func preference(
    identity: String,
    sourceIdentity: String,
    displayName: String
  ) -> RielaAppDaemonWorkflowPreference {
    RielaAppDaemonWorkflowPreference(
      identity: identity,
      sourceIdentity: sourceIdentity,
      displayName: displayName,
      available: true,
      active: false
    )
  }

  private func makeController() -> DaemonWorkflowWindowController {
    let controller = DaemonWorkflowWindowController(
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
    controller.showInstancesList()
    return controller
  }

  private enum BackDestination {
    case instancesRoot
    case instanceOverview
    case sourcesRoot
    case marketplaceRoot
    case profilesRoot
  }

  private struct BackStateCase {
    let name: String
    let expectedDestination: BackDestination
    let configure: (DaemonWorkflowWindowController) -> Void

    init(
      _ name: String,
      _ expectedDestination: BackDestination,
      configure: @escaping (DaemonWorkflowWindowController) -> Void
    ) {
      self.name = name
      self.expectedDestination = expectedDestination
      self.configure = configure
    }
  }
}
#endif
