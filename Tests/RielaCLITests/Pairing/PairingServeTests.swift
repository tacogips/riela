import Foundation
import RielaCore
import RielaGraphQL
import RielaServer
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

@MainActor
final class PairingServeTests: XCTestCase {
  func testCLIMintRedeemListAndRevokeThroughServeRouting() async throws {
    let fixture = try PairingServeFixture(test: self)
    let store = fixture.pairing.store
    let app = RielaCLIApplication()
    let address = "http://192.168.1.5:8787"
    let minted = await app.run(["serve", "pairing", "mint", "--address", address], environment: fixture.environment)
    XCTAssertEqual(minted.exitCode, .success)
    XCTAssertTrue(minted.stderr.isEmpty)
    let lines = minted.stdout.split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
    let prefix = "pairing code (expires in 10 minutes): "
    let codeLine = try XCTUnwrap(lines.first)
    XCTAssertTrue(codeLine.hasPrefix(prefix))
    XCTAssertTrue(lines.contains("pairing address: \(address)"))
    let code = String(codeLine.dropFirst(prefix.count))
    let envelope = try PairingServeFixture.pairingEnvelope(code)
    XCTAssertEqual(envelope["serverId"], fixture.pairing.identity.serverId)
    let secret = try XCTUnwrap(envelope["secret"])

    let host = fixture.host(publicAccess: true)
    XCTAssertNotNil(host.passkeys)
    let redeem = RielaHTTPRequest(
      method: "POST", path: RielaPairingHTTP.redeemRoute.path, headers: ["content-type": "application/json"],
      body: try JSONEncoder().encode(["secret": secret, "clientName": "paired client"])
    )
    let response = await host.response(for: redeem)
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(response.headers["Cache-Control"], "no-store")
    let body = try fixture.json(response)
    let token = try XCTUnwrap(body["token"]?.pairingString)
    let grantId = try XCTUnwrap(body["grantId"]?.pairingString)
    XCTAssertEqual(body["scope"], .string("operate"))
    XCTAssertEqual(body["serverName"], .string("Pairing Test Server"))
    XCTAssertEqual(body["serverId"], .string(fixture.pairing.identity.serverId))

    let replay = await host.response(for: redeem)
    XCTAssertEqual(replay.status, 403)
    XCTAssertEqual(try fixture.json(replay)["error"], .string("pairing_code_invalid"))

    let query = "{ bots { groups } }"
    let queryRequest = try PairingServeFixture.graphQLRequest(query, token: token)
    let authorized = await host.response(for: queryRequest)
    XCTAssertNotNil(try fixture.json(authorized)["data"]?.pairingObject?["bots"])

    let listed = await app.run(["serve", "pairing", "list", "--output", "json"], environment: fixture.environment)
    let grants = try jsonGrants(listed)
    XCTAssertEqual(grants.map(\.grantId), [grantId])
    XCTAssertEqual(grants.first?.clientName, "paired client")
    XCTAssertEqual(grants.first?.scope, "operate")
    XCTAssertNotNil(grants.first?.lastUsedAt)
    XCTAssertNil(grants.first?.revokedAt)

    let ordinaryKey = try store.issue(name: "ordinary client")
    let unknown = await app.run(
      ["serve", "pairing", "revoke", "--grant", ordinaryKey.record.id], environment: fixture.environment
    )
    XCTAssertEqual(unknown.stderr, "pairing_grant_not_found")
    XCTAssertNotNil(try store.authenticate(ordinaryKey.token, purpose: .client))
    let revoked = await app.run(["serve", "pairing", "revoke", "--grant", grantId, "--output", "json"],
                                environment: fixture.environment)
    XCTAssertNotNil(try jsonGrants(revoked).first?.revokedAt)

    let denied = await host.response(for: queryRequest)
    XCTAssertEqual(denied.status, 401)
    XCTAssertEqual(try fixture.json(denied)["error"], .string("invalid_api_key"))
    let deniedByGraphQL = try await fixture.graphql(query, token: token)
    XCTAssertEqual(PairingServeFixture.errorCode(deniedByGraphQL), "UNAUTHENTICATED")

    let saved = try String(contentsOf: store.root.appendingPathComponent("api-keys.json"), encoding: .utf8)
    let audit = try String(contentsOf: store.root.appendingPathComponent("pairing-audit.jsonl"), encoding: .utf8)
    for sensitive in [code, secret, token] {
      XCTAssertFalse(saved.contains(sensitive))
      XCTAssertFalse(audit.contains(sensitive))
      XCTAssertFalse(listed.stdout.contains(sensitive))
      XCTAssertFalse(revoked.stdout.contains(sensitive))
    }
    XCTAssertTrue(audit.contains(#""action":"mint""#))
    XCTAssertTrue(audit.contains(#""action":"redeem""#))
    XCTAssertTrue(audit.contains(#""action":"redeem_failed""#))
    XCTAssertTrue(audit.contains(#""action":"revoke""#))
  }

  func testInvalidPairingAddressesFailBeforeStartupReadiness() async throws {
    let fixture = try PairingServeFixture(test: self)
    for (address, code) in [("http://127.0.0.1:8787", "pairing_address_not_routable"),
                            ("http://example.com", "pairing_address_requires_tls")] {
      let mint = await RielaCLIApplication().run(["serve", "pairing", "mint", "--address", address],
                                                environment: fixture.environment)
      XCTAssertEqual(mint.stderr, code)
      let start = await startWithInvalidPairing(["--pairing-address", address], fixture: fixture)
      XCTAssertEqual(start.stderr, code)
    }
    let noAddress = await startWithInvalidPairing(["--pairing-scope", "read"], fixture: fixture)
    XCTAssertEqual(noAddress.exitCode, .usage)
  }

  func testMachineAndBrowserServeReportThePersistedIdentity() async throws {
    let fixture = try PairingServeFixture(test: self)
    try fixture.createBot()
    let query = "{ bots { bots { bot { botId } origin { serverId serverName } } } }"
    let token = try fixture.pairing.store.issue(name: "reader", scope: .read).token
    let machine = try await fixture.graphql(query, token: token)
    let host = fixture.host(publicAccess: false)
    let request = try PairingServeFixture.graphQLRequest(query, headers: [
      "host": "127.0.0.1:8787", "origin": "http://127.0.0.1:8787",
      "x-riela-csrf": host.csrfToken, "x-riela-profile": host.profile.rawValue
    ])
    let response = await host.response(for: request)
    XCTAssertEqual(response.status, 200)
    let browser = try fixture.json(response)
    let persisted = try RielaServerIdentity.loadOrCreate(root: fixture.pairing.store.root, name: nil)
    for body in [machine, browser] {
      let row = body["data"]?.pairingObject?["bots"]?.pairingObject?["bots"]?.pairingArray?.first?.pairingObject
      XCTAssertEqual(row?["bot"]?.pairingObject?["botId"], .string("alpha"))
      XCTAssertEqual(row?["origin"]?.pairingObject?["serverId"], .string(persisted.serverId))
      XCTAssertEqual(row?["origin"]?.pairingObject?["serverName"], .string(persisted.name))
    }
  }

  private func startWithInvalidPairing(_ options: [String], fixture: PairingServeFixture) async -> CLICommandResult {
    let arguments = [
      "serve", "--working-dir", fixture.root.path, "--session-store", fixture.sessionRoot,
      "--web-root", fixture.root.appendingPathComponent("missing-web-root").path
    ] + options
    return await CLIRuntimeEnvironment.$captured.withValue(fixture.environment) {
      await ServeHTTPCommand().run(arguments: arguments) { _ in
        XCTFail("Invalid pairing options reached listener readiness")
      }
    }
  }

  private func jsonGrants(_ result: CLICommandResult) throws -> [PairingGrant] {
    XCTAssertEqual(result.exitCode, .success)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PairingGrantListPayload.self, from: Data(result.stdout.utf8)).grants
  }
}
