#if os(macOS) && canImport(Network)
import Foundation
import RielaAppSupport
@testable import RielaServer
@testable import RielaApp
import XCTest

@MainActor
final class RielaAppWebStartupTests: XCTestCase {
  func testStartupHonorsExplicitFlagAndPersistedAutostartOnThePersistedPort() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/app-web-startup-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .json(.object([:])) })
    let port = try await probe.startForTesting()
    await probe.stop()
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    // The persisted `isEnabled` is the desired launch state: disabled
    // settings start only on the explicit flag, and enabled settings start
    // on their own (covered at the end of this test).
    try store.save(.init(isEnabled: false, port: port))
    let app = RielaApp()
    let controller = RielaAppWebServerController(app: app, settingsStore: store,
      assetRoot: root, onStateChange: {})

    await controller.startIfRequested(by: .init(arguments: ["--open-desktop"], environment: [:]))
    XCTAssertEqual(controller.state, .stopped, "disabled settings must not start without the explicit flag")
    await controller.startIfRequested(by: .init(arguments: ["--start-web-server"], environment: [:]))
    XCTAssertEqual(controller.state.boundPort, port)
    XCTAssertEqual(controller.endpointURL?.port, port)
    XCTAssertEqual(store.load().settings, .init(isEnabled: true, port: port))
    await controller.startIfRequested(by: .init(arguments: ["--start-web-server"], environment: [:]))
    XCTAssertEqual(controller.state.boundPort, port, "repeated request uses the same controller")
    await controller.shutdownForTermination()
    XCTAssertEqual(controller.state, .stopped)
    XCTAssertTrue(store.load().settings.isEnabled, "termination preserves user settings")

    // The next launch honors the preserved autostart intent without the flag.
    let relaunched = RielaAppWebServerController(app: app, settingsStore: store,
      assetRoot: root, onStateChange: {})
    await relaunched.startIfRequested(by: .init(arguments: ["--open-desktop"], environment: [:]))
    XCTAssertEqual(relaunched.state.boundPort, port, "saved enabled state starts at launch")
    await relaunched.shutdownForTermination()
    XCTAssertEqual(relaunched.state, .stopped)
  }
}
#endif
