#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import RielaCore
import XCTest

final class RielaAppStatusMessageTests: XCTestCase {
  func testClassifiesInfoAndErrorMessages() {
    XCTAssertEqual(RielaAppStatusMessage.classified("Created instance demo").severity, .info)
    XCTAssertEqual(RielaAppStatusMessage.classified("Failed to import URL").severity, .error)
    XCTAssertEqual(RielaAppStatusMessage.classified("Instance ID already exists: demo").severity, .error)
    XCTAssertEqual(RielaAppStatusMessage.classified("Workflow source could not be found").severity, .error)
    XCTAssertEqual(RielaAppStatusMessage.classified("Invalid environment variables").severity, .error)
  }
}

final class RielaAppEnvironmentValueFormatterTests: XCTestCase {
  func testMasksValuesWithCappedBulletsUntilRevealed() {
    let values = [
      RielaAppConfiguredEnvironmentValue(name: "TOKEN", value: "example-value", source: "inline"),
      RielaAppConfiguredEnvironmentValue(name: "EMPTY", value: "", source: ".env")
    ]

    XCTAssertEqual(
      RielaAppEnvironmentValueFormatter.text(values: values, revealsValues: false),
      "EMPTY=• (.env)\nTOKEN=•••••••• (inline)"
    )
    XCTAssertEqual(
      RielaAppEnvironmentValueFormatter.text(values: values, revealsValues: true),
      "EMPTY= (.env)\nTOKEN=example-value (inline)"
    )
  }
}

@MainActor
final class RielaAppUXOnboardingControllerTests: XCTestCase {
  func testStatusBannerRendersTypedMessagesAndToolbarHasNoForwardButton() throws {
    let controller = makeController()
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [],
      workflowSources: [],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: SequencedRielaAppStatusMessage(
        sequence: 1,
        message: .classified("Failed to import URL")
      )
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Failed to import URL" })
    XCTAssertTrue(visibleButtons(in: root).contains { $0.accessibilityLabel() == "Dismiss Status Message" })
    XCTAssertFalse(visibleButtons(in: root).contains { $0.accessibilityLabel() == "Forward" })
  }

  func testEmptyInstanceGuideAndFilteredEmptyStateUseSeparateMessages() throws {
    let controller = makeController()
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [],
      workflowSources: [],
      state: RielaAppDaemonWorkflowState(),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    let root = try XCTUnwrap(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    XCTAssertFalse(controller.emptyInstancesGuideView.isHidden)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Set up your first instance" })
    try XCTUnwrap(visibleButtons(in: root).first { $0.title == "View Workflow Sources" }).performClick(nil)
    XCTAssertEqual(controller.activeSidebarPane, .sources)

    let source = workflowSource()
    var state = RielaAppDaemonWorkflowState()
    state.preferences["morning-summary"] = RielaAppDaemonWorkflowPreference(
      identity: "morning-summary",
      sourceIdentity: source.id,
      displayName: "Morning Summary"
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
    controller.showInstancesPane()
    controller.instanceSearchField.stringValue = "does-not-match"
    controller.instanceSearchChanged()
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(controller.emptyInstancesGuideView.isHidden)
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "No instances match the current filter." })
  }

  func testInstanceDetailShowsSnapshotDetailAndCanOpenViewer() throws {
    var openedIdentity: String?
    let controller = makeController(onOpenViewer: { openedIdentity = $0 })
    let source = workflowSource(requiredEnvironment: [
      RielaAppEnvRequirement(name: "TOKEN", description: nil, secret: true)
    ])
    var state = RielaAppDaemonWorkflowState()
    state.preferences["chat-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "chat-instance",
      sourceIdentity: source.id,
      displayName: "Chat Instance"
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [source],
      workflowSources: [source],
      state: state,
      snapshots: [
        "chat-instance": RielaAppDaemonWorkflowRuntime.RuntimeSnapshot(
          status: .failed,
          detail: "event source failed"
        )
      ],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "chat-instance")
    controller.tableClicked(controller.instanceTable)
    let root = try XCTUnwrap(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(controller.instanceRows.first?.stateDetail, "event source failed")
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Failed - event source failed" })
    XCTAssertTrue(try XCTUnwrap(selectableRow(accessibilityLabel: "Open in Viewer", in: root)).accessibilityPerformPress())
    XCTAssertEqual(openedIdentity, "chat-instance")
  }

  func testInstanceRemovalRequiresConfirmationAndKeepsSourceScopeVisible() throws {
    var removedIdentity: String?
    let controller = makeController(onRemoveInstance: { removedIdentity = $0 })
    let source = workflowSource()
    var state = RielaAppDaemonWorkflowState()
    state.preferences["daily-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "daily-instance",
      sourceIdentity: source.id,
      displayName: "Daily Instance"
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
    controller.selectCandidate(identity: "daily-instance")
    controller.tableClicked(controller.instanceTable)
    controller.removeSelectedInstance()
    let root = try XCTUnwrap(controller.window?.contentView)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Confirm Removal" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("The workflow source is not deleted.") })
    XCTAssertNil(removedIdentity)

    controller.confirmRemoveSelectedInstance()
    XCTAssertEqual(removedIdentity, "daily-instance")
  }

  func testEventSourceFormRegistersGeneratedSourceAndBindingJSON() throws {
    var capturedIdentity: String?
    var capturedSourceJSON: String?
    var capturedBindingJSON: String?
    let controller = makeController(onRegisterEventSource: {
      capturedIdentity = $0
      capturedSourceJSON = $1
      capturedBindingJSON = $2
      return nil
    })
    let source = workflowSource(eventRoot: "/workflows/chat/.riela-events")
    var state = RielaAppDaemonWorkflowState()
    state.preferences["chat-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "chat-instance",
      sourceIdentity: source.id,
      displayName: "Chat Instance"
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
    controller.selectCandidate(identity: "chat-instance")
    controller.tableClicked(controller.instanceTable)
    controller.setSelectedEventSources()
    controller.eventSourceIdField?.stringValue = "telegram-custom"
    controller.saveEventSourceEditor()

    XCTAssertEqual(capturedIdentity, "chat-instance")
    XCTAssertTrue(try XCTUnwrap(capturedSourceJSON).contains("\"id\" : \"telegram-custom\""))
    XCTAssertTrue(try XCTUnwrap(capturedSourceJSON).contains("\"kind\" : \"telegram-gateway\""))
    XCTAssertTrue(try XCTUnwrap(capturedBindingJSON).contains("\"sourceId\" : \"telegram-custom\""))
  }

  private func makeController(
    onRemoveInstance: @escaping (String) -> Void = { _ in },
    onOpenViewer: @escaping (String) -> Void = { _ in },
    onRegisterEventSource: @escaping (String, String, String) -> String? = { _, _, _ in nil }
  ) -> DaemonWorkflowWindowController {
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
      onRemoveInstance: onRemoveInstance,
      onOpenViewer: onOpenViewer,
      onOpenWorkflowSourceViewer: { _ in },
      defaultInstanceId: { "\($0)-instance" },
      onStartInstance: { _ in },
      onStopInstance: { _ in },
      onRestartInstance: { _ in },
      onSetEnvironment: { _ in },
      onSetWorkingDirectory: { _ in },
      onSaveEnvironmentVariables: { _, _ in nil },
      onSaveWorkflowVariables: { _, _ in nil },
      onRegisterEventSource: onRegisterEventSource,
      configuredEnvironmentValues: { _ in [] },
      onSaveAssistantAssistance: { _ in nil },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: { _ in "Missing TOKEN" },
      onWindowWillClose: {}
    )
  }

  private func workflowSource(
    requiredEnvironment: [RielaAppEnvRequirement] = [],
    eventRoot: String? = nil
  ) -> RielaAppDaemonWorkflowCandidate {
    RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:chat",
      workflowId: "chat",
      displayName: "Chat",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/chat",
      workingDirectory: "/workflows",
      eventRoot: eventRoot,
      eventSources: [],
      requiredEnvironment: requiredEnvironment
    )
  }

  private func visibleTextFields(in root: NSView) -> [NSTextField] {
    allSubviews(of: NSTextField.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func visibleButtons(in root: NSView) -> [NSButton] {
    allSubviews(of: NSButton.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func selectableRow(accessibilityLabel: String, in root: NSView) -> RielaAppSelectableSettingsRow? {
    allSubviews(of: RielaAppSelectableSettingsRow.self, in: root).first { row in
      !row.hasHiddenAncestor &&
        row.accessibilityLabel() == accessibilityLabel &&
        row.accessibilityRole() == .button
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
