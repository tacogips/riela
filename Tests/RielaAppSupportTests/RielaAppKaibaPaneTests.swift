#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import RielaKaibaSupport
import XCTest

@MainActor
final class RielaAppKaibaPaneTests: XCTestCase {
  private struct SavedKaibaBinding: Equatable {
    var identity: String
    var nodeID: String
    var instanceID: String?
  }

  func testEmptyKaibaPaneOffersFirstInstanceActionAtRuntime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = makeController(kaiba: .init(homeURL: root, bindingScanRoots: roots))

    controller.showKaibaPane()
    controller.window?.layoutIfNeeded()
    let content = try XCTUnwrap(controller.window?.contentView)

    XCTAssertTrue(allSubviews(of: NSButton.self, in: content).contains {
      $0.accessibilityLabel() == "Add Kaiba API instance"
    })
  }

  func testKaibaPaneRendersSafeManagementActionsAtRuntime() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let scanRoots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let kaiba = RielaAppKaibaInstanceController(homeURL: root, bindingScanRoots: scanRoots)
    _ = try kaiba.add(.init(name: "Local", endpoint: "http://127.0.0.1:8787", authentication: .unauthenticated, allowInsecureHTTP: true))
    let controller = makeController(kaiba: kaiba)

    controller.showKaibaPane()
    controller.window?.layoutIfNeeded()
    let content = try XCTUnwrap(controller.window?.contentView)
    let buttons = allSubviews(of: NSButton.self, in: content)

    XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "Add Kaiba API instance" })
    XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "Test Kaiba instance Local" })
    XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "Edit Kaiba instance Local" })
    XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "Disable Kaiba instance Local" })
    XCTAssertTrue(buttons.contains { $0.accessibilityLabel() == "Remove Kaiba instance Local" })
    XCTAssertFalse(allSubviews(of: NSTextField.self, in: content).contains { $0.stringValue.contains("TOKEN") })

    controller.window?.setContentSize(NSSize(width: 360, height: 520))
    controller.window?.layoutIfNeeded()
    let actionLabels = [
      "Add Kaiba API instance",
      "Test Kaiba instance Local",
      "Edit Kaiba instance Local",
      "Disable Kaiba instance Local",
      "Remove Kaiba instance Local"
    ]
    for button in buttons where actionLabels.contains(button.accessibilityLabel() ?? "") {
      XCTAssertTrue(button.title.isEmpty, "Kaiba actions must remain compact at constrained widths")
      XCTAssertNotNil(button.image)
    }
  }

  func testInstanceDetailRendersKaibaNodeBindingsAndSavesNamedSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let scanRoots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let kaiba = RielaAppKaibaInstanceController(homeURL: root, bindingScanRoots: scanRoots)
    let local = try kaiba.add(.init(name: "Local", endpoint: "http://127.0.0.1:8787", authentication: .unauthenticated, allowInsecureHTTP: true))
    var savedBinding: SavedKaibaBinding?
    let controller = makeController(kaiba: kaiba, onSaveKaibaNodeBinding: { identity, nodeID, instanceID, _ in
      savedBinding = SavedKaibaBinding(identity: identity, nodeID: nodeID, instanceID: instanceID)
      return true
    })
    let workflowDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("examples/note-agent", isDirectory: true)
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "note-agent",
      workflowId: "note-agent",
      displayName: "Note Agent",
      sourceDescription: "test workflow",
      workflowDirectory: workflowDirectory.path,
      workingDirectory: workflowDirectory.deletingLastPathComponent().path,
      eventRoot: nil,
      eventSources: []
    )
    let state = RielaAppDaemonWorkflowState(preferences: [
      "instance": .init(identity: "instance", sourceIdentity: candidate.id, available: true)
    ])
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [candidate],
      workflowSources: [],
      state: state,
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "instance")
    controller.tableClicked(controller.instanceTable)
    let content = try XCTUnwrap(controller.window?.contentView)
    let popup = try await kaibaBindingPopup(in: content, accessibilityLabel: "Kaiba instance for node retrieve-notes")

    XCTAssertEqual(Array(popup.itemTitles.prefix(2)), ["Default instance", "Local (Default)"])
    popup.selectItem(at: 1)
    XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
    XCTAssertEqual(savedBinding?.identity, "instance")
    XCTAssertEqual(savedBinding?.nodeID, "retrieve-notes")
    XCTAssertEqual(savedBinding?.instanceID, local.id)
  }

  func testBlockedKaibaReadinessDisablesStartWithRecoveryGuidance() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = makeController(
      kaiba: .init(homeURL: root, bindingScanRoots: roots),
      onCheckKaibaWorkflowReadiness: { _ in .blocked(.configureWorkflowEnvironment) }
    )
    let candidate = RielaAppDaemonWorkflowCandidate(
      id: "kaiba-readiness",
      workflowId: "kaiba-readiness",
      displayName: "Kaiba Readiness",
      sourceDescription: "test workflow",
      workflowDirectory: root.path,
      workingDirectory: root.path,
      eventRoot: nil,
      eventSources: []
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [candidate],
      workflowSources: [],
      state: .init(preferences: ["instance": .init(identity: "instance", sourceIdentity: candidate.id, available: true)]),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "instance")
    controller.tableClicked(controller.instanceTable)
    let recoveryMessage = "Kaiba is not ready. Configure the required credential environment variable for this workflow."
    for _ in 0 ..< 20 where (controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)?.accessibilityHelp() != recoveryMessage {
      try await Task.sleep(for: .milliseconds(25))
    }

    let startRow = try XCTUnwrap(controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)
    XCTAssertFalse(startRow.rielaAccessibilityEnabled)
    XCTAssertEqual(startRow.accessibilityHelp(), recoveryMessage)
  }

  func testKaibaStatusUsesClosedSafeCopyForAccessibility() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let controller = makeController(kaiba: .init(homeURL: root, bindingScanRoots: roots))

    controller.presentKaibaStatus(.readinessFailed)

    let content = try XCTUnwrap(controller.window?.contentView)
    let banner = try XCTUnwrap(allSubviews(of: RielaAppStatusBannerView.self, in: content).first)
    XCTAssertEqual(
      banner.accessibilityLabel(),
      "Kaiba readiness could not be completed. Check the configured instance and credential environment variable."
    )
    XCTAssertFalse(banner.accessibilityLabel()?.contains("kaiba-redaction-sentinel-token") == true)
  }

  func testStaleKaibaReadinessResultDoesNotOverrideNewSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let gate = KaibaReadinessGate()
    let controller = makeController(
      kaiba: .init(homeURL: root, bindingScanRoots: roots),
      onCheckKaibaWorkflowReadiness: { identity in
        if identity == "first" {
          await gate.wait()
          return .blocked(.configureWorkflowEnvironment)
        }
        return .notApplicable
      }
    )
    let first = RielaAppDaemonWorkflowCandidate(
      id: "first-source", workflowId: "first", displayName: "First",
      sourceDescription: "test", workflowDirectory: root.path, workingDirectory: root.path,
      eventRoot: nil, eventSources: []
    )
    let second = RielaAppDaemonWorkflowCandidate(
      id: "second-source", workflowId: "second", displayName: "Second",
      sourceDescription: "test", workflowDirectory: root.path, workingDirectory: root.path,
      eventRoot: nil, eventSources: []
    )
    controller.update(
      profileName: .default,
      profileNames: [.default],
      candidates: [first, second],
      workflowSources: [],
      state: .init(preferences: [
        "first": .init(identity: "first", sourceIdentity: first.id, available: true),
        "second": .init(identity: "second", sourceIdentity: second.id, available: true)
      ]),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "first")
    controller.tableClicked(controller.instanceTable)
    await gate.waitUntilStarted()
    controller.selectCandidate(identity: "second")
    controller.tableClicked(controller.instanceTable)

    let expectedHelp = "Run this instance and include it in future app launches."
    for _ in 0 ..< 20 where (controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)?.accessibilityHelp() != expectedHelp {
      try await Task.sleep(for: .milliseconds(25))
    }
    await gate.release()
    try await Task.sleep(for: .milliseconds(50))

    let startRow = try XCTUnwrap(controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)
    XCTAssertTrue(startRow.rielaAccessibilityEnabled)
    XCTAssertEqual(startRow.accessibilityHelp(), expectedHelp)
  }

  func testStaleKaibaReadinessResultDoesNotOverrideProfileChange() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let roots = KaibaBindingScanRoots(projectRootURL: root, homeURL: root, appRootURL: root)
    let gate = KaibaReadinessGate()
    let controller = makeController(
      kaiba: .init(homeURL: root, bindingScanRoots: roots),
      onCheckKaibaWorkflowReadiness: { identity in
        if identity == "first" {
          await gate.wait()
          return .blocked(.configureWorkflowEnvironment)
        }
        return .notApplicable
      }
    )
    let first = RielaAppDaemonWorkflowCandidate(
      id: "first-source", workflowId: "first", displayName: "First",
      sourceDescription: "test", workflowDirectory: root.path, workingDirectory: root.path,
      eventRoot: nil, eventSources: []
    )
    let second = RielaAppDaemonWorkflowCandidate(
      id: "second-source", workflowId: "second", displayName: "Second",
      sourceDescription: "test", workflowDirectory: root.path, workingDirectory: root.path,
      eventRoot: nil, eventSources: []
    )
    controller.update(
      profileName: .default,
      profileNames: [.default, RielaAppProfileName("secondary")],
      candidates: [first],
      workflowSources: [],
      state: .init(preferences: ["first": .init(identity: "first", sourceIdentity: first.id, available: true)]),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )
    controller.selectCandidate(identity: "first")
    controller.tableClicked(controller.instanceTable)
    await gate.waitUntilStarted()

    controller.update(
      profileName: RielaAppProfileName("secondary"),
      profileNames: [.default, RielaAppProfileName("secondary")],
      candidates: [second],
      workflowSources: [],
      state: .init(preferences: ["second": .init(identity: "second", sourceIdentity: second.id, available: true)]),
      snapshots: [:],
      assistantAssistance: "",
      statusMessage: ""
    )

    let expectedHelp = "Run this instance and include it in future app launches."
    for _ in 0 ..< 20 where (controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)?.accessibilityHelp() != expectedHelp {
      try await Task.sleep(for: .milliseconds(25))
    }
    await gate.release()
    try await Task.sleep(for: .milliseconds(50))

    let startRow = try XCTUnwrap(controller.startInstanceActionRow as? RielaAppSelectableSettingsRow)
    XCTAssertTrue(startRow.rielaAccessibilityEnabled)
    XCTAssertEqual(startRow.accessibilityHelp(), expectedHelp)
  }

  private func makeController(
    kaiba: RielaAppKaibaInstanceController,
    onSaveKaibaNodeBinding: @escaping (String, String, String?, Bool) -> Bool = { _, _, _, _ in false },
    onCheckKaibaWorkflowReadiness: @escaping (String) async -> RielaAppKaibaWorkflowReadiness = { _ in .notApplicable }
  ) -> DaemonWorkflowWindowController {
    DaemonWorkflowWindowController(
      onRefresh: {}, onSelectProfile: { _ in }, onCreateProfile: { RielaAppProfileName($0) },
      onRemoveProfile: { _ in true }, onAddDirectory: {}, onAddURL: { _ in }, onAddInstance: { _ in },
      onRevealSelectedSource: { _ in }, onRelinkInstance: { _, _ in }, onRenameWorkflow: { _ in },
      onRemoveInstance: { _ in }, onStartInstance: { _ in }, onStopInstance: { _ in }, onRestartInstance: { _ in },
      onSaveKaibaNodeBinding: onSaveKaibaNodeBinding,
      onCheckKaibaWorkflowReadiness: onCheckKaibaWorkflowReadiness,
      onSetEnvironment: { _ in }, onSetWorkingDirectory: { _ in }, onSaveEnvironmentVariables: { _, _ in nil },
      onSaveWorkflowVariables: { _, _ in nil }, onRegisterEventSource: { _, _, _ in nil },
      configuredEnvironmentValues: { _ in [] }, onSaveAssistantAssistance: { _ in nil },
      environmentSummary: { _ in "Ready" }, environmentColumnStatus: { _ in "Ready" },
      onWindowWillClose: {}, kaibaInstanceController: kaiba
    )
  }

  private func allSubviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
    view.subviews.flatMap { subview in
      (subview as? T).map { [$0] } ?? [] + allSubviews(of: type, in: subview)
    }
  }

  private func kaibaBindingPopup(
    in content: NSView,
    accessibilityLabel: String
  ) async throws -> NSPopUpButton {
    for _ in 0 ..< 40 {
      content.window?.layoutIfNeeded()
      if let popup = allSubviews(of: NSPopUpButton.self, in: content).first(where: {
        $0.accessibilityLabel() == accessibilityLabel
      }) {
        return popup
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("Kaiba binding rows did not finish loading")
    throw NSError(domain: "RielaAppKaibaPaneTests", code: 1)
  }
}

private actor KaibaReadinessGate {
  private var didStart = false
  private var startContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func wait() async {
    didStart = true
    startContinuation?.resume()
    startContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilStarted() async {
    guard !didStart else { return }
    await withCheckedContinuation { continuation in
      startContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
#endif
