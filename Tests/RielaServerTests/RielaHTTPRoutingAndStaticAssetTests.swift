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
    XCTAssertEqual(resolver.response(for: .init(method: "GET", path: "/escape.txt"))?.status, 404)
  }

  func testHeadSerializesContentLengthWithoutBody() {
    let response = RielaHTTPResponse.text(status: 200, "hello")
    let serialized = try? XCTUnwrap(String(data: response.serialized(forMethod: "HEAD"), encoding: .utf8))
    XCTAssertTrue(serialized?.contains("Content-Length: 5") == true)
    XCTAssertFalse(serialized?.hasSuffix("hello") == true)
  }
}
