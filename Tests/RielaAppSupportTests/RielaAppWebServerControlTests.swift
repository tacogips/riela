#if os(macOS) && canImport(Network)
import Foundation
@testable import RielaApp
@testable import RielaAppSupport
import RielaGraphQL
@testable import RielaServer
import XCTest

/// Console Settings start/stop replaced the menu-bar server items, so the
/// configuration mutation is the only place a listener failure can surface.
@MainActor
final class RielaAppWebServerControlTests: XCTestCase {
  func testStartFailsWithListenerReasonWhenPortIsOccupied() async throws {
    let (app, root) = try isolatedApp()
    let occupant = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .json(.object([:])) })
    let port = try await occupant.startForTesting()
    addTeardownBlock { await occupant.stop() }
    let controller = try installController(app: app, root: root, port: port)
    let provider = RielaAppConfigurationGraphQLProvider(app: app)
    let revision = app.webRevision
    do {
      _ = try await provider.updateHTTPServer(input: .init(expectedRevision: revision, isEnabled: true))
      XCTFail("Start must fail while another listener owns the port")
    } catch let error as RielaConfigurationGraphQLError {
      XCTAssertEqual(error.code, "SERVER_START_FAILED")
      XCTAssertFalse(error.message.isEmpty)
    }
    guard case .failed = controller.state else { return XCTFail("state is \(controller.state)") }
    XCTAssertEqual(app.webRevision, revision, "a failed start changes no configuration")
  }

  func testStartAndStopSucceedOnAFreePort() async throws {
    let (app, root) = try isolatedApp()
    let probe = RielaLocalHTTPServer(routeHandler: AnyRielaHTTPRouteHandler { _ in .json(.object([:])) })
    let port = try await probe.startForTesting()
    await probe.stop()
    let controller = try installController(app: app, root: root, port: port)
    addTeardownBlock { @MainActor in await controller.shutdownForTermination() }
    let provider = RielaAppConfigurationGraphQLProvider(app: app)
    let started = try await provider.updateHTTPServer(input: .init(expectedRevision: app.webRevision, isEnabled: true))
    XCTAssertEqual(started.server.state, "running")
    XCTAssertEqual(started.server.boundPort, port)
    let stopped = try await provider.updateHTTPServer(input: .init(expectedRevision: app.webRevision, isEnabled: false))
    XCTAssertEqual(stopped.server.state, "stopped")
    XCTAssertFalse(stopped.server.isEnabled)
  }

  func testServerMutationsFailWithoutAController() async throws {
    let (app, _) = try isolatedApp()
    app.webServerController = nil
    app.webServerSetupError = "Web assets are missing. Run bun run build in web/."
    let provider = RielaAppConfigurationGraphQLProvider(app: app)
    for input in [GraphQLUpdateHTTPServerConfigInput(expectedRevision: app.webRevision, isEnabled: true),
                  GraphQLUpdateHTTPServerConfigInput(expectedRevision: app.webRevision, configuredPort: 9999)] {
      do {
        _ = try await provider.updateHTTPServer(input: input)
        XCTFail("A missing controller must not report success")
      } catch let error as RielaConfigurationGraphQLError {
        XCTAssertEqual(error.code, "SERVER_UNAVAILABLE")
        XCTAssertTrue(error.message.contains("Web assets are missing"))
      }
    }
  }

  func testOpenInBrowserRejectsWrongMethodAndStoppedServer() async throws {
    let (app, root) = try isolatedApp()
    let wrongMethod = await app.webAPIResponse(for: .init(method: "GET", path: "/api/v1/settings/server/open"), csrfToken: "t")
    XCTAssertEqual(wrongMethod.status, 405)
    let missing = await app.webAPIResponse(for: .init(method: "POST", path: "/api/v1/settings/server/open"), csrfToken: "t")
    XCTAssertEqual(missing.status, 409)
    _ = try installController(app: app, root: root, port: 1)
    let stopped = await app.webAPIResponse(for: .init(method: "POST", path: "/api/v1/settings/server/open"), csrfToken: "t")
    XCTAssertEqual(stopped.status, 409)
  }

  private func isolatedApp() throws -> (RielaApp, URL) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("tmp/app-web-server-control/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = RielaApp()
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    app.appHomeDirectory = root.appendingPathComponent("home")
    return (app, root)
  }

  private func installController(app: RielaApp, root: URL, port: Int) throws -> RielaAppWebServerController {
    let store = RielaAppWebServerSettingsStore(appRootURL: root)
    try store.save(.init(isEnabled: false, port: port))
    let controller = RielaAppWebServerController(app: app, settingsStore: store, assetRoot: root, onStateChange: {})
    app.webServerController = controller
    return controller
  }
}
#endif
