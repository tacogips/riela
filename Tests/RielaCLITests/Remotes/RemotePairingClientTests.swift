import Foundation
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

@MainActor
final class RemotePairingClientTests: XCTestCase {
  func testRedeemedRemoteAppearsInListWithoutBecomingActiveOrExposingSecrets() async throws {
    let server = try RemoteTestFixture(test: self).serve()
    let client = try RemoteTestFixture(test: self)
    let transport = RemoteTestFixture.transport(to: server.host)
    let minted = try server.pairing.mint(address: "https://riela.example", scope: .read)

    let added = await client.run(
      ["remote", "add", "--name", "srv", "--code", minted.code, "--client-name", "fixture-client"],
      transport: transport
    )
    XCTAssertEqual(added.exitCode, .success)
    let listed = await client.run(["remote", "list", "--output", "json"], transport: transport)
    let payload = try client.decode(RemoteListPayload.self, listed)
    XCTAssertEqual(payload.active, "local")
    XCTAssertEqual(payload.remotes.map(\.name), ["srv"])
    XCTAssertEqual(payload.remotes.first?.serverName, "Test Server")
    XCTAssertEqual(try client.registry.record(name: "srv").serverId, server.pairing.identity.serverId)
    let token = try client.registry.token(name: "srv")
    XCTAssertNotNil(try server.pairing.store.authenticate(token, purpose: .client))
    XCTAssertEqual(try server.pairing.grants().grants.map(\.clientName), ["fixture-client"])
    for output in [added.stdout, added.stderr, listed.stdout, listed.stderr] {
      XCTAssertFalse(output.contains(minted.code))
      XCTAssertFalse(output.contains(token))
    }
  }

  func testCodeReuseDoesNotCreateSecondRecord() async throws {
    let server = try RemoteTestFixture(test: self).serve()
    let client = try RemoteTestFixture(test: self)
    let transport = RemoteTestFixture.transport(to: server.host)
    let minted = try server.pairing.mint(address: "https://riela.example", scope: .read)

    let first = await client.run(["remote", "add", "--name", "srv", "--code", minted.code], transport: transport)
    XCTAssertEqual(first.exitCode, .success)
    let second = await client.run(["remote", "add", "--name", "reused", "--code", minted.code], transport: transport)
    XCTAssertNotEqual(second.exitCode, .success)
    XCTAssertTrue(second.stderr.contains("pairing_code_invalid"))
    XCTAssertEqual(try client.registry.list().remotes.map(\.name), ["srv"])
    XCTAssertEqual(try server.pairing.grants().grants.count, 1)
  }

  func testServerIdentityMismatchLeavesNoClientRecordOrToken() async throws {
    let server = try RemoteTestFixture(test: self).serve()
    let client = try RemoteTestFixture(test: self)
    let transport = RemoteTestFixture.transport(to: server.host)
    let minted = try server.pairing.mint(address: "https://riela.example", scope: .read)

    let result = await client.run(["remote", "add", "--name", "srv", "--code", minted.code]) { request in
      let (data, status) = try await transport(request)
      var response = try JSONDecoder().decode(JSONObject.self, from: data)
      response["serverId"] = .string("different-server")
      return (try JSONEncoder().encode(response), status)
    }
    XCTAssertNotEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.contains("pairing_server_mismatch"))
    XCTAssertTrue(try client.registry.list().remotes.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: client.root.appendingPathComponent("credentials/remotes/srv.token").path
    ))
  }

  func testMalformedCodeFailsBeforeTransport() async throws {
    let client = try RemoteTestFixture(test: self)
    let result = await client.run(["remote", "add", "--name", "srv", "--code", "malformed"]) { _ in
      XCTFail("Malformed pairing code initiated an HTTP request")
      throw URLError(.notConnectedToInternet)
    }
    XCTAssertNotEqual(result.exitCode, .success)
    XCTAssertTrue(result.stderr.contains("pairing_code_invalid"))
    XCTAssertTrue(try client.registry.list().remotes.isEmpty)
  }
}
