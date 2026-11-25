import Foundation
import XCTest
@testable import RielaServer

struct PairingTestFixture {
  let store: RielaAPIKeyStore
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  let address = "http://192.168.1.5:8787"
  let identity = RielaServerIdentity(serverId: "test-id", name: "Test server")

  init() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-08-pairing-server/fixtures/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    store = RielaAPIKeyStore(root: root)
  }

  func remove() { try? FileManager.default.removeItem(at: store.root) }

  struct Code: Decodable {
    let address: String
    let serverId: String
    let secret: String
  }

  func mint(scope: RielaAPIKeyStore.Scope = .operate) throws -> Code {
    let code = try store.mintPairingCode(address: address, scope: scope, serverId: identity.serverId, now: now)
    return try decode(code)
  }

  func decode(_ code: String) throws -> Code {
    XCTAssertTrue(code.hasPrefix("rp1."))
    let base64URL = code.dropFirst(4)
    let padding = (4 - base64URL.count % 4) % 4
    let base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: padding)
    let data = try XCTUnwrap(Data(base64Encoded: base64))
    return try JSONDecoder().decode(Code.self, from: data)
  }
}

@MainActor
final class PairingCodeTests: XCTestCase {
  func testCredentialBearingClientNameIsRejectedWithoutConsumingCode() throws {
    try assertRejectedClientName { secret, _ in "Phone \(secret)" }
    try assertRejectedClientName { _, envelope in "Phone \(envelope)" }
  }

  private func assertRejectedClientName(_ name: (String, String) -> String) throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let store = fixture.store
    let envelope = try store.mintPairingCode(
      address: fixture.address, scope: .read, serverId: fixture.identity.serverId, now: fixture.now
    )
    let secret = try fixture.decode(envelope).secret
    let audit = RielaPairingAudit(root: store.root)

    let clientName = name(secret, envelope)
    XCTAssertLessThanOrEqual(clientName.utf8.count, 200)
    let body = try JSONEncoder().encode(["secret": secret, "clientName": clientName])
    let request = RielaHTTPRequest(
      method: "POST", path: RielaPairingHTTP.redeemRoute.path,
      headers: ["Content-Type": "application/json"], body: body
    )
    let response = RielaPairingHTTP.response(
      for: request, store: store, identity: fixture.identity, audit: audit, now: fixture.now
    )
    XCTAssertEqual(response?.status, 403)
    XCTAssertTrue(try store.pairingGrants().isEmpty)
    for file in ["api-keys.json", "pairing-audit.jsonl"] {
      let persisted = try String(contentsOf: store.root.appendingPathComponent(file), encoding: .utf8)
      XCTAssertFalse(persisted.contains(secret))
      XCTAssertFalse(persisted.contains(envelope))
    }
    let issued = try? store.redeemPairingCode(secret: secret, clientName: "Phone", now: fixture.now)
    XCTAssertEqual(issued?.record.name, "Phone")
  }

  func testScopedClientKeyAuthenticatesAndRevokes() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let store = fixture.store
    let code = try fixture.mint(scope: .read)
    XCTAssertEqual(code.address, fixture.address)
    XCTAssertEqual(code.serverId, fixture.identity.serverId)
    XCTAssertEqual(code.secret.count, 43)

    let issued = try store.redeemPairingCode(secret: code.secret, clientName: " Phone ", now: fixture.now)
    XCTAssertEqual(issued.record.scope, .read)
    XCTAssertEqual(issued.record.purpose, .client)
    XCTAssertEqual(issued.record.pairing, .init(clientName: "Phone", pairedAt: fixture.now))
    XCTAssertEqual(try store.authenticate(issued.token, purpose: .client, now: fixture.now), issued.record)
    XCTAssertNil(try store.authenticate(issued.token, purpose: .worker, now: fixture.now))
    XCTAssertEqual(try store.pairingGrants(), [issued.record])

    let persisted = try String(contentsOf: store.root.appendingPathComponent("api-keys.json"), encoding: .utf8)
    XCTAssertFalse(persisted.contains(code.secret))
    XCTAssertFalse(persisted.contains(issued.token))
    XCTAssertFalse(persisted.contains(issued.token.dropFirst(6)))

    try store.revoke(id: issued.record.id, now: fixture.now)
    XCTAssertNil(try store.authenticate(issued.token, purpose: .client, now: fixture.now))
    XCTAssertEqual(try store.pairingGrants().first?.revokedAt, fixture.now)
  }

  func testReplacementExpiryAndSingleUse() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let first = try fixture.mint()
    let replacement = try fixture.mint()
    assertInvalid(try fixture.store.redeemPairingCode(secret: first.secret, clientName: "One", now: fixture.now))
    let expiresAt = fixture.now.addingTimeInterval(600)
    assertInvalid(try fixture.store.redeemPairingCode(secret: replacement.secret, clientName: "Two", now: expiresAt))

    let current = try fixture.mint()
    _ = try fixture.store.redeemPairingCode(secret: current.secret, clientName: "Three", now: fixture.now)
    assertInvalid(try fixture.store.redeemPairingCode(secret: current.secret, clientName: "Three", now: fixture.now))
    XCTAssertEqual(try fixture.store.pairingGrants().count, 1)
  }

  func testFifthIncorrectSecretInvalidatesCodeAcrossStoreInstances() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let code = try fixture.mint()
    for _ in 0..<5 {
      let reopened = RielaAPIKeyStore(root: fixture.store.root)
      assertInvalid(try reopened.redeemPairingCode(secret: "wrong", clientName: "Phone", now: fixture.now))
    }
    assertInvalid(try fixture.store.redeemPairingCode(secret: code.secret, clientName: "Phone", now: fixture.now))
    XCTAssertTrue(try fixture.store.pairingGrants().isEmpty)

    let reissued = try fixture.mint()
    for _ in 0..<4 {
      assertInvalid(try fixture.store.redeemPairingCode(secret: "wrong", clientName: "Phone", now: fixture.now))
    }
    _ = try fixture.store.redeemPairingCode(secret: reissued.secret, clientName: "Phone", now: fixture.now)
  }

  func testConcurrentRedeemsCreateOnlyOneGrant() async throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let secret = try fixture.mint().secret
    let root = fixture.store.root
    let now = fixture.now
    let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
      for index in 0..<20 {
        group.addTask {
          let store = RielaAPIKeyStore(root: root)
          do {
            _ = try store.redeemPairingCode(secret: secret, clientName: "Client \(index)", now: now)
            return true
          } catch RielaAPIKeyStore.StoreError.pairingCodeInvalid {
            return false
          }
        }
      }
      var successes = 0
      for try await succeeded in group where succeeded { successes += 1 }
      return successes
    }
    XCTAssertEqual(successes, 1)
    XCTAssertEqual(try fixture.store.pairingGrants().count, 1)
  }

  func testVersionOneKeyRetainsAdminAndTouchIsThrottled() throws {
    let fixture = try PairingTestFixture()
    defer { fixture.remove() }
    let store = fixture.store
    let file = store.root.appendingPathComponent("api-keys.json")
    let digest = String(repeating: "0", count: 64)
    try Data("""
      {"version":1,"requireClientKey":true,"keys":[{"record":{"id":"old","name":"Old","purpose":"client","createdAt":0},"digest":"\(digest)"}]}
      """.utf8).write(to: file)
    let record = try XCTUnwrap(store.list().first)
    XCTAssertEqual(record.effectiveScope, .admin)
    XCTAssertNil(record.scope)
    XCTAssertNil(record.pairing)
    XCTAssertNil(record.lastUsedAt)

    try store.touch(id: record.id, now: fixture.now)
    let first = try Data(contentsOf: file)
    let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
    try store.touch(id: record.id, now: fixture.now.addingTimeInterval(59))
    XCTAssertEqual(try Data(contentsOf: file), first)
    XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber, inode)
    XCTAssertEqual(try store.list().first?.lastUsedAt, fixture.now)
    let next = fixture.now.addingTimeInterval(60)
    try store.touch(id: record.id, now: next)
    XCTAssertEqual(try store.list().first?.lastUsedAt, next)
  }

  private func assertInvalid(_ issued: @autoclosure () throws -> RielaAPIKeyStore.IssuedKey) {
    XCTAssertThrowsError(try issued()) { error in
      XCTAssertEqual((error as? RielaAPIKeyStore.StoreError)?.code, "pairing_code_invalid")
    }
  }
}
