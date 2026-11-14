#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import RielaCore
import XCTest

private struct CapturedEventSourceRegistration {
  var identity: String
  var sourceJSON: String
  var bindingJSON: String
}

@MainActor
final class RielaAppSettingsEditorNavigationTests: XCTestCase {
  func testInstanceDetailRowsNavigateToInlineConfigurationEditorsAtRuntime() throws {
    var capturedEventSourceRegistration: CapturedEventSourceRegistration?
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
      onRegisterEventSource: { identity, sourceJSON, bindingJSON in
        capturedEventSourceRegistration = CapturedEventSourceRegistration(
          identity: identity,
          sourceJSON: sourceJSON,
          bindingJSON: bindingJSON
        )
        return nil
      },
      configuredEnvironmentValues: { _ in [
        RielaAppConfiguredEnvironmentValue(
          name: "DUPLICATE_TOKEN",
          value: "inline-value",
          source: "inline override"
        ),
        RielaAppConfiguredEnvironmentValue(name: "FILE_ONLY", value: "file-value", source: ".env")
      ] },
      onSaveAssistantAssistance: { _ in nil },
      environmentSummary: { _ in ".env file demo.env, 1 environment variables, all required environment variables set" },
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:chat",
      workflowId: "chat",
      displayName: "Chat",
      sourceDescription: "user workflow",
      workflowDirectory: "/workflows/chat",
      workingDirectory: "/workflows",
      eventRoot: "/workflows/chat/.riela-events",
      eventSources: [RielaAppDaemonEventSourceSummary(id: "telegram", kind: "telegram-gateway")]
    )
    var state = RielaAppDaemonWorkflowState()
    state.preferences["chat-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "chat-instance",
      sourceIdentity: source.id,
      available: true,
      active: true,
      environmentFilePath: "/workflows/chat/demo.env",
      environmentVariables: ["DUPLICATE_TOKEN": "inline-value"],
      defaultVariables: ["persona": .string("yuki")]
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

    let root = try XCTUnwrap(controller.window?.contentView)
    let table = try XCTUnwrap(firstSubview(of: NSTableView.self, in: root))
    controller.tableClicked(table)
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(try XCTUnwrap(selectableRow(accessibilityLabel: "Environment Variables", in: root)).accessibilityPerformPress())
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Variable Settings" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Current Lines" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Effective Configured Environment" })
    XCTAssertTrue(visibleTextFields(in: root).contains {
      $0.stringValue.contains("Saving while this instance is active restarts its workflow process.")
    })
    XCTAssertTrue(visibleButtons(in: root).contains { $0.title == "Save & Restart Instance" })
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains("DUPLICATE_TOKEN=•••••••• (inline override)") })
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains("FILE_ONLY=•••••••• (.env)") })
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains("DUPLICATE_TOKEN=inline-value") })

    controller.inlineEnvironmentTextView?.string.append("\nNEW_TOKEN=value")
    controller.cancelConfigurationEditor()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("Unsaved changes") })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Environment Variables" })

    controller.cancelConfigurationEditor()
    XCTAssertTrue(try XCTUnwrap(selectableRow(accessibilityLabel: "Workflow Variables", in: root)).accessibilityPerformPress())
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Variable Settings" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Current Lines" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Effective Workflow Variables" })
    XCTAssertTrue(visibleButtons(in: root).contains { $0.title == "Save & Restart Instance" })
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains("persona=yuki") })

    controller.workflowVariablesTextView?.string.append("\nmode=test")
    controller.goBack()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("Unsaved changes") })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Workflow Variables" })
    controller.goBack()

    XCTAssertTrue(try XCTUnwrap(selectableRow(accessibilityLabel: "Event Sources", in: root)).accessibilityPerformPress())
    controller.window?.layoutIfNeeded()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Source ID" })
    XCTAssertTrue(visibleButtons(in: root).contains { $0.title == "Register & Restart Instance" })
    XCTAssertTrue(visibleTextFields(in: root).contains {
      $0.stringValue.contains("event input")
    })

    controller.eventSourceIdField?.stringValue = "telegram-main"
    controller.cancelConfigurationEditor()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("Unsaved changes") })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Event Sources" })
    controller.eventSourceIdField?.stringValue = "telegram-main-updated"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.eventSourceIdField))
    controller.cancelConfigurationEditor()
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue.contains("Unsaved changes") })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Event Sources" })
    controller.eventSourceIdField?.stringValue = "telegram-main"
    controller.eventSourceModeControl?.selectedSegment = 1
    controller.eventSourceModeChanged()
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.eventSourceFormView?.isHidden, true)
    XCTAssertEqual(controller.eventSourceJSONView?.isHidden, false)
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains(#""id" : "telegram-main""#) })
    XCTAssertTrue(textViews(in: root).contains { $0.string.contains(#""sourceId" : "telegram-main""#) })

    controller.saveEventSourceEditor()
    XCTAssertEqual(capturedEventSourceRegistration?.identity, "chat-instance")
    XCTAssertTrue(capturedEventSourceRegistration?.sourceJSON.contains(#""kind" : "telegram-gateway""#) == true)
    XCTAssertTrue(capturedEventSourceRegistration?.bindingJSON.contains(#""workflowName" : "chat""#) == true)
  }

  func testAssistantSidebarPaneShowsOnlyVendorAndModelSettingsAtRuntime() throws {
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
      onSaveAssistantAssistance: { _ in
        XCTFail("Assistant assistance is not edited from the settings pane")
        return nil
      },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
    let state = RielaAppDaemonWorkflowState(
      assistant: RielaAppAssistantSettings(assistance: "Use short direct answers.")
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [],
      workflowSources: [],
      state: state,
      snapshots: [:],
      assistantAssistance: state.assistant.assistance,
      statusMessage: ""
    )

    let root = try XCTUnwrap(controller.window?.contentView)
    let assistantButton = try XCTUnwrap(button(accessibilityLabel: "Assistant", in: root))
    XCTAssertNotNil(assistantButton.image)
    controller.showAssistantPane()
    controller.window?.layoutIfNeeded()

    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Assistant" })
    XCTAssertTrue(visibleTextFields(in: root).contains { $0.stringValue == "Custom guidance configured" })
    XCTAssertFalse(textViews(in: root).contains { $0.string.contains("Use short direct answers.") })
    XCTAssertNil(selectableRow(accessibilityLabel: "Save Assistance", in: root))
    XCTAssertFalse(controller.assistantSettingsVendorPopup.itemTitles.contains("Automatic"))
    XCTAssertEqual(controller.assistantSettingsVendorPopup.selectedItem?.title, RielaAppAssistantVendor.openAIAPI.displayName)
    XCTAssertEqual(controller.assistantSettingsModelPopup.itemTitles, RielaAppAssistantVendor.openAIAPI.modelSuggestions)
    XCTAssertEqual(controller.assistantSettingsModelPopup.selectedItem?.title, RielaAppAssistantVendor.openAIAPI.defaultModel)
  }

  func testAssistantSidebarPaneDefaultsToFirstModelAndSavesSelectedModelPerVendor() throws {
    var savedSettings: RielaAppAssistantSettings?
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
      onSaveAssistantSettings: { settings in
        savedSettings = settings
        return nil
      },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
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
    controller.showAssistantPane()
    controller.window?.layoutIfNeeded()

    controller.assistantSettingsVendorPopup.selectItem(withTitle: RielaAppAssistantVendor.anthropicAPI.displayName)
    controller.assistantVendorChanged()
    XCTAssertEqual(controller.assistantSettingsModelPopup.itemTitles, RielaAppAssistantVendor.anthropicAPI.modelSuggestions)
    XCTAssertEqual(savedSettings?.vendor, .anthropicAPI)
    XCTAssertEqual(savedSettings?.normalizedModel, RielaAppAssistantVendor.anthropicAPI.defaultModel)

    controller.assistantSettingsModelPopup.selectItem(withTitle: "claude-sonnet-4-5")
    controller.assistantModelChanged()
    XCTAssertEqual(savedSettings?.modelsByVendor[RielaAppAssistantVendor.anthropicAPI.rawValue], "claude-sonnet-4-5")
    XCTAssertEqual(savedSettings?.normalizedModel, "claude-sonnet-4-5")
  }

  func testAssistantPanelPersistsAcrossPaneNavigationAndSubmitsSelectedWorkingDirectory() throws {
    var savedSettings: RielaAppAssistantSettings?
    var submittedMessage: String?
    var submittedWorkingDirectory: String?
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
      onSaveAssistantSettings: { settings in
        savedSettings = settings
        return nil
      },
      onSubmitAssistantMessage: { message, workingDirectory in
        submittedMessage = message
        submittedWorkingDirectory = workingDirectory
      },
      environmentSummary: { _ in "Ready" },
      environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}
    )
    let source = RielaAppDaemonWorkflowCandidate(
      id: "user-workflow:ops",
      workflowId: "ops",
      displayName: "Ops",
      sourceDescription: "project workflow",
      workflowDirectory: "/workflows/ops",
      workingDirectory: "/projects/ops",
      eventRoot: nil,
      eventSources: []
    )
    var state = RielaAppDaemonWorkflowState(
      assistant: RielaAppAssistantSettings(
        vendor: .openAIAPI,
        model: "gpt-5",
        isFolded: false,
        messages: [RielaAppAssistantMessage(role: .assistant, content: "Ready.")]
      )
    )
    state.preferences["ops-instance"] = RielaAppDaemonWorkflowPreference(
      identity: "ops-instance",
      sourceIdentity: source.id,
      workingDirectory: "/projects/ops/profile-a"
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
    controller.selectCandidate(identity: "ops-instance")
    controller.window?.layoutIfNeeded()

    XCTAssertEqual(controller.assistantTranscriptTextView?.string.contains("Ready."), true)
    controller.showSourcesPane()
    controller.window?.layoutIfNeeded()
    XCTAssertEqual(controller.assistantPromptField.hasHiddenAncestor, false)
    let assistantHost = try XCTUnwrap(controller.settingsRootView?.assistantPanelHost)
    let promptFrame = controller.assistantPromptField.convert(controller.assistantPromptField.bounds, to: assistantHost)
    let foldFrame = controller.assistantFoldButton.convert(controller.assistantFoldButton.bounds, to: assistantHost)
    XCTAssertGreaterThanOrEqual(promptFrame.width, 420)
    XCTAssertGreaterThanOrEqual(foldFrame.maxX, assistantHost.bounds.width - 60)

    controller.assistantPromptField.stringValue = "Create a second workflow instance"
    controller.sendAssistantMessage()

    XCTAssertEqual(submittedMessage, "Create a second workflow instance")
    XCTAssertEqual(submittedWorkingDirectory, "/projects/ops/profile-a")

    controller.toggleAssistantFolded()
    XCTAssertEqual(savedSettings?.isFolded, true)
    XCTAssertEqual(controller.assistantTranscriptScrollView?.isHidden, true)
  }

  func testEventSourceRegistrationWritesSourceAndBindingFiles() throws {
    let temp = try scratchRoot(name: "riela-app-event-source-registration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let workflowDirectory = temp.appendingPathComponent("workflow", isDirectory: true)
    try FileManager.default.createDirectory(at: workflowDirectory, withIntermediateDirectories: true)
    let app = RielaApp()
    app.daemonCandidates = [
      RielaAppDaemonWorkflowCandidate(
        id: "user-workflow:chat",
        workflowId: "chat",
        displayName: "Chat",
        sourceDescription: "user workflow",
        workflowDirectory: workflowDirectory.path,
        workingDirectory: temp.path,
        eventRoot: nil,
        eventSources: []
      )
    ]

    let error = app.registerDaemonWorkflowEventSource(
      identity: "user-workflow:chat",
      sourceJSON: #"{"id":"telegram-chat","kind":"telegram-gateway","provider":"telegram"}"#,
      bindingJSON: #"{"id":"telegram-chat-to-workflow","sourceId":"telegram-chat","workflowName":"chat","inputMapping":{"mode":"event-input"}}"#
    )

    XCTAssertNil(error)
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: workflowDirectory.appendingPathComponent(".riela-events/sources/telegram-chat.json").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: workflowDirectory.appendingPathComponent(".riela-events/bindings/telegram-chat-to-workflow.json").path
    ))
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

  private func visibleButtons(in root: NSView) -> [NSButton] {
    allSubviews(of: NSButton.self, in: root).filter { !$0.hasHiddenAncestor }
  }

  private func textViews(in root: NSView) -> [NSTextView] {
    allSubviews(of: NSTextView.self, in: root).filter { !$0.hasHiddenAncestor }
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

  private func scratchRoot(name: String) throws -> URL {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scratch = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    return scratch
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
