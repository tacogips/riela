import Foundation
import XCTest
@testable import RielaServer

@MainActor
final class PairingHTTPTests: XCTestCase {
  func testSuccessfulRedeemHasIdentityGrantAndNonCacheableToken() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let secret = try fixture.mint().secret
    let audit = RielaPairingAudit(root: fixture.store.root)
    let success = try XCTUnwrap(RielaPairingHTTP.response(
      for: request(body: #"{"secret":"\#(secret)","clientName":"Phone"}"#),
      store: fixture.store, identity: fixture.identity, audit: audit, now: fixture.now
    ))
    XCTAssertEqual(success.status, 200)
    XCTAssertEqual(success.headers["Cache-Control"], "no-store")
    let body = try JSONDecoder().decode([String: String].self, from: success.body)
    let token = try XCTUnwrap(body["token"])
    let grant = try XCTUnwrap(fixture.store.authenticate(token, purpose: .client, now: fixture.now))
    XCTAssertEqual(body["grantId"], grant.id)
    XCTAssertEqual(body["scope"], "operate")
    XCTAssertEqual(body["serverId"], fixture.identity.serverId)
    XCTAssertEqual(body["serverName"], fixture.identity.name)

    let replay = RielaPairingHTTP.response(
      for: request(body: #"{"secret":"\#(secret)","clientName":"Phone"}"#),
      store: fixture.store, identity: fixture.identity, audit: audit, now: fixture.now
    )
    XCTAssertEqual(replay?.status, 403)
    let log = fixture.store.root.appendingPathComponent("pairing-audit.jsonl")
    let text = try String(contentsOf: log, encoding: .utf8)
    let lines = try text.split(separator: "\n").map {
      try JSONDecoder().decode([String: String].self, from: Data($0.utf8))
    }
    XCTAssertEqual(lines.map { $0["action"] }, ["redeem", "redeem_failed"])
    XCTAssertEqual(lines.first?["grantId"], grant.id)
    XCTAssertEqual(lines.first?["clientName"], "Phone")
    XCTAssertEqual(lines.first?["scope"], "operate")
    XCTAssertNotNil(lines.first?["time"])
    XCTAssertNil(lines.first?["digest"])
    XCTAssertFalse(text.contains(secret))
    XCTAssertFalse(text.contains(token))
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? Int, 0o600)
  }

  func testRejectedRequestsShareOneErrorAndDoNotIssueGrant() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let secret = try fixture.mint().secret
    let audit = RielaPairingAudit(root: fixture.store.root)
    let validBody = #"{"secret":"\#(secret)","clientName":"Phone"}"#
    let rejected = [
      request(body: "{"),
      request(body: #"{"clientName":"Phone"}"#),
      request(body: validBody, headers: ["Content-Type": "application/json", "Origin": "https://example.com"]),
      request(body: validBody, headers: ["Content-Type": "text/plain"]),
      request(body: validBody + String(repeating: " ", count: 4_096)),
      request(body: #"{"secret":"wrong","clientName":"Phone"}"#)
    ]
    for input in rejected {
      let response = try XCTUnwrap(RielaPairingHTTP.response(
        for: input, store: fixture.store, identity: fixture.identity, audit: audit, now: fixture.now
      ))
      XCTAssertEqual(response.status, 403)
      XCTAssertEqual(response.headers["Cache-Control"], "no-store")
      XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: response.body), ["error": "pairing_code_invalid"])
    }
    XCTAssertTrue(try fixture.store.pairingGrants().isEmpty)
    for other in [RielaHTTPRequest(method: "GET", path: RielaPairingHTTP.redeemRoute.path),
                  RielaHTTPRequest(method: "POST", path: "/graphql")] {
      XCTAssertNil(RielaPairingHTTP.response(
        for: other, store: fixture.store, identity: fixture.identity, audit: audit, now: fixture.now
      ))
    }
  }

  private func request(body: String, headers: [String: String] = ["Content-Type": "application/json"]) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "POST", path: RielaPairingHTTP.redeemRoute.path, headers: headers, body: Data(body.utf8))
  }
}
