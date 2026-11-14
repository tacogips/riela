import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import RielaServer
import XCTest

final class RielaLocalHTTPServerTests: XCTestCase {
  func testLiveHealthRequestStopAndImmediateRebind() async throws {
    let handler = AnyRielaHTTPRouteHandler { request in
      await DeterministicServerHTTPAdapter().response(for: request)
    }
    let server = RielaLocalHTTPServer(routeHandler: handler)
    let firstPort = try await server.startForTesting()
    XCTAssertGreaterThan(firstPort, 0)
    let firstURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(firstPort)/healthz"))
    let (data, response) = try await URLSession.shared.data(from: firstURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"status\":\"ok\""))
    await server.stop()
    XCTAssertEqual(server.currentState, .stopped)

    let reboundPort = try await server.start(host: "127.0.0.1", port: firstPort)
    XCTAssertEqual(reboundPort, firstPort)
    await server.stop()
    XCTAssertEqual(server.currentState, .stopped)
  }

  func testLocalhostBindsRequestedExplicitPort() async throws {
    let handler = AnyRielaHTTPRouteHandler { request in
      await DeterministicServerHTTPAdapter().response(for: request)
    }
    let portProbe = RielaLocalHTTPServer(routeHandler: handler)
    let explicitPort = try await portProbe.startForTesting()
    await portProbe.stop()

    let server = RielaLocalHTTPServer(routeHandler: handler)
    let boundPort = try await server.start(host: "localhost", port: explicitPort)
    XCTAssertEqual(boundPort, explicitPort)

    let url = try XCTUnwrap(URL(string: "http://localhost:\(explicitPort)/healthz"))
    let (_, response) = try await URLSession.shared.data(from: url)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    await server.stop()
  }
}
