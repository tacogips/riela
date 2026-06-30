#if os(macOS)
import AppKit
@testable import RielaApp
@testable import RielaAppSupport
import XCTest

@MainActor
final class RielaAppWindowContentInsetTests: XCTestCase {
  func testWorkflowInstanceWindowUsesTightSettingsInsetsAtRuntime() throws {
    let controller = DaemonWorkflowWindowController(
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
    let window = try XCTUnwrap(controller.window)
    window.setContentSize(NSSize(width: 760, height: 620))
    window.layoutIfNeeded()

    let contentView = try XCTUnwrap(window.contentView)
    let listView = try XCTUnwrap(firstSubview(of: DaemonWorkflowInstanceListView.self, in: contentView))
    let contentHost = try XCTUnwrap(listView.superview)
    contentView.layoutSubtreeIfNeeded()

    XCTAssertEqual(listView.frame.minX, 0, accuracy: 0.1)
    XCTAssertEqual(listView.frame.minY, 0, accuracy: 0.1)
    XCTAssertEqual(listView.frame.width, contentHost.bounds.width, accuracy: 0.1)
    XCTAssertEqual(listView.frame.height, contentHost.bounds.height, accuracy: 0.1)
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
}
#endif
