#if os(macOS)
import Foundation
@testable import RielaAppSupport
import RielaServer
import XCTest

final class RielaAppWebServerSettingsTests: XCTestCase {
  func testDefaultsAreIndependentFromRielaServerConfiguration() {
    XCTAssertEqual(RielaAppWebServerSettings().port, 19_091)
    XCTAssertFalse(RielaAppWebServerSettings().isEnabled)
    XCTAssertEqual(RielaServerConfiguration().port, 8_787)
  }

  func testRoundTripAndInvalidPortProtection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    let settings = RielaAppWebServerSettings(isEnabled: true, port: 20_000)
    try store.save(settings)
    XCTAssertEqual(store.load().settings, settings)
    XCTAssertThrowsError(try store.save(RielaAppWebServerSettings(port: 0)))
    XCTAssertEqual(store.load().settings, settings)
  }

  func testCorruptFileIsQuarantined() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: store.settingsURL)
    let result = store.load()
    XCTAssertEqual(result.settings, RielaAppWebServerSettings())
    XCTAssertNotNil(result.quarantinedURL)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.settingsURL.path))
  }
}
#endif
