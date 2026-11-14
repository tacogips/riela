import Foundation
import RielaCore
@testable import RielaServer
import XCTest

final class RielaHTTPRoutingAndStaticAssetTests: XCTestCase {
  func testDeterministicAdapterPreservesHealthRouteAndSortedJSON() async throws {
    let response = await DeterministicServerHTTPAdapter().response(for: RielaHTTPRequest(method: "GET", path: "/healthz"))
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8")
    XCTAssertEqual(
      try JSONDecoder().decode(JSONValue.self, from: response.body),
      .object(["service": .string("riela"), "status": .string("ok")])
    )
  }

  func testStaticResolverServesSPAAndRejectsConcreteAssetFallbackAndSymlinkEscape() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("assets"), withIntermediateDirectories: true)
    try Data("app".utf8).write(to: root.appendingPathComponent("index.html"))
    try Data("body{}".utf8).write(to: root.appendingPathComponent("assets/app.css"))
    try Data("secret".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    let resolver = RielaStaticAssetResolver(rootURL: root)
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/instances"))?.status, 200)
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/assets/app.css"))?.status, 200)
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/assets/missing.js"))?.status, 404)
    XCTAssertNil(resolver.response(for: .init(method: "GET", path: "/api/v1/bootstrap")))
    XCTAssertNil(resolver.response(for: .init(method: "GET", path: "/api")))
    XCTAssertNil(resolver.response(for: .init(method: "GET", path: "/graphql/unknown")))
    XCTAssertNil(resolver.response(for: .init(method: "GET", path: "/note/unknown")))
    let allSlash = resolver.response(for: .init(method: "GET", path: "//"))
    XCTAssertEqual(allSlash?.status, 200)
    XCTAssertEqual(allSlash?.headers["Content-Type"], "text/html; charset=utf-8")
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "///"))?.status, 200)
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/escape.txt"))?.status, 404)
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/bad\u{0}name"))?.status, 404)
    XCTAssertEqual(
      resolver.response(for: .init(
        method: "GET",
        path: "/../outside.txt",
        percentEncodedPath: "/%2e%2e/outside.txt"
      ))?.status,
      404
    )
  }

  func testStaticSPARouterPreservesServiceAndRegistrationMethodPrecedence() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("<main>Notes</main>".utf8).write(to: root.appendingPathComponent("index.html"))
    defer { try? FileManager.default.removeItem(at: root) }
    let service = AnyRielaHTTPRouteHandler { request in
      .json(status: request.path == "/unknown" ? 404 : 200, .object([
        "method": .string(request.method),
        "path": .string(request.path)
      ]))
    }
    let router = RielaStaticSPAHTTPRouter(service: service, webRoot: root)

    let rootResponse = await router.response(for: .init(method: "GET", path: "/"))
    XCTAssertEqual(rootResponse.headers["Content-Type"], "text/html; charset=utf-8")
    let bootstrap = await router.response(for: .init(
      method: "GET",
      path: "/note/register",
      query: "code=one-time"
    ))
    XCTAssertEqual(bootstrap.body, Data("<main>Notes</main>".utf8))
    let redemption = await router.response(for: .init(method: "POST", path: "/note/register"))
    XCTAssertTrue(String(data: redemption.body, encoding: .utf8)?.contains("\"method\":\"POST\"") == true)
    let graphql = await router.response(for: .init(method: "POST", path: "/graphql"))
    XCTAssertEqual(
      try JSONDecoder().decode(JSONValue.self, from: graphql.body),
      .object(["method": .string("POST"), "path": .string("/graphql")])
    )
    let missingAsset = await router.response(for: .init(method: "GET", path: "/missing.js"))
    XCTAssertEqual(missingAsset.status, 404)
    for path in [
      "/api",
      "/api/v1/missing",
      "/graphql/unknown",
      "/healthz/unknown",
      "/note/unknown",
      "/overview/unknown"
    ] {
      let response = await router.response(for: .init(method: "GET", path: path))
      XCTAssertEqual(response.headers["Content-Type"], "application/json; charset=utf-8", path)
      XCTAssertEqual(
        try JSONDecoder().decode(JSONValue.self, from: response.body),
        .object(["method": .string("GET"), "path": .string(path)]),
        path
      )
    }
  }

  func testHeadSerializesContentLengthWithoutBody() {
    let response = RielaHTTPResponse.text(status: 200, "hello")
    let serialized = try? XCTUnwrap(String(data: response.serialized(forMethod: "HEAD"), encoding: .utf8))
    XCTAssertTrue(serialized?.contains("Content-Length: 5") == true)
    XCTAssertFalse(serialized?.hasSuffix("hello") == true)
  }
}
