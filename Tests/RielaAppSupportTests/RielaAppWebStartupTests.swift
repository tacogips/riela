#if os(macOS) && canImport(Network)
import Foundation
import RielaAppSupport
@testable import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWebStartupTests: XCTestCase {
  func testExplicitStartupUsesPersistedPortAndNormalControllerShutdown() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/app-web-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .json(.object([:])) })
    let port = try await probe.startForTesting()
    await probe.stop()
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    try store.save(.init(isEnabled: true, port: port))
    let app = RielaApp()
    let controller = RielaAppWebServerController(app: app, settingsStore: store,
      assetRoot: root, onStateChange: {})

    await controller.startIfRequested(by: .init(arguments: ["--open-desktop"], environment: [:]))
    XCTAssertEqual(controller.state, .stopped, "saved enabled state must not silently opt into HTTP startup")
    await controller.startIfRequested(by: .init(arguments: ["--start-web-server"], environment: [:]))
    XCTAssertEqual(controller.state.boundPort, port)
    XCTAssertEqual(controller.endpointURL?.port, port)
    XCTAssertEqual(store.load().settings, .init(isEnabled: true, port: port))
    await controller.startIfRequested(by: .init(arguments: ["--start-web-server"], environment: [:]))
    XCTAssertEqual(controller.state.boundPort, port, "repeated request uses the same controller")
    await controller.shutdownForTermination()
    XCTAssertEqual(controller.state, .stopped)
    XCTAssertTrue(store.load().settings.isEnabled, "termination preserves user settings")
  }
}
#endif
