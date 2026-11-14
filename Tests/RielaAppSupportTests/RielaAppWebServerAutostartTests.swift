#if os(macOS)
import Foundation
@testable import RielaAppSupport
import XCTest

final class RielaAppWebServerAutostartTests: XCTestCase {
  func testLaunchDecisionTruthTable() {
    for enabled in [false, true] {
      for flag in [false, true] {
        let settings = RielaAppWebServerSettings(isEnabled: enabled)
        XCTAssertEqual(settings.shouldStartAtLaunch(launchFlag: flag), enabled || flag)
      }
    }
  }

  func testPersistedEnabledSettingsStartWithoutFlag() throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    try Data("{\"version\":1,\"isEnabled\":true,\"port\":19091}".utf8).write(to: store.settingsURL)
    XCTAssertTrue(store.load().settings.shouldStartAtLaunch(launchFlag: false))
  }

  func testMissingSettingsDoNotStartWithoutFlag() {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    XCTAssertFalse(store.load().settings.shouldStartAtLaunch(launchFlag: false))
  }

  private func temporaryRoot() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/web-server-autostart/\(UUID().uuidString)")
  }
}
#endif
