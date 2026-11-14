import Foundation
import XCTest
@testable import RielaServer

@MainActor
final class RielaPasskeyTests: XCTestCase {
  private struct Registered {
    let user: RielaPasskeyStore.User
    let token: String
    let invitation: String
  }
  func testRegistrationLoginReplayLogoutAndRevocation() async throws {
    let (service, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let authenticator = PasskeyTestAuthenticator()
    let registered = try await register(authenticator, service: service, store: store)
    let user = registered.user
    let token = registered.token
    let invitation = registered.invitation
    XCTAssertEqual(try store.users().count, 1)
    let authenticated = await service.isAuthenticated(bearer(token))
    XCTAssertTrue(authenticated)
    let reused = await post(service, "register/options", ["invitation": invitation])
    XCTAssertEqual(reused.status, 410)
    let options = try object(await post(service, "login/options"))
    let finish: [String: Any] = ["ceremonyID": try XCTUnwrap(options["ceremonyID"]),
      "credential": try authenticator.assertion(options: options, userID: user.id)]
    let login = await post(service, "login/finish", finish)
    XCTAssertEqual(login.status, 200, String(data: login.body, encoding: .utf8) ?? "")
    let loginToken = try XCTUnwrap(try object(login)["token"] as? String)
    let replay = await post(service, "login/finish", finish)
    XCTAssertEqual(replay.status, 410)
    let logout = await post(service, "logout", headers: ["authorization": "Bearer \(loginToken)"])
    XCTAssertEqual(logout.status, 200)
    let loggedOut = await service.isAuthenticated(bearer(loginToken))
    XCTAssertFalse(loggedOut)
    try store.revokeCredential(id: user.credentials[0].id)
    let revoked = await service.isAuthenticated(bearer(token))
    XCTAssertFalse(revoked)
    let newOptions = try object(await post(service, "login/options"))
    let rejected = await post(service, "login/finish", ["ceremonyID": try XCTUnwrap(newOptions["ceremonyID"]),
      "credential": try authenticator.assertion(options: newOptions, userID: user.id, count: 2)])
    XCTAssertEqual(rejected.status, 401)
    let persisted = try RielaPasskeyStore(root: store.root, origin: store.origin).users()
    XCTAssertTrue(persisted[0].credentials[0].revoked)
    let contents = try String(contentsOf: store.root.appendingPathComponent("credentials.json"), encoding: .utf8)
    XCTAssertFalse(contents.contains(token))
    XCTAssertFalse(contents.contains(invitation))
  }

  func testRejectsSignedWrongOriginChallengeRelyingPartyUserAndVerificationFlags() async throws {
    let (service, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let authenticator = PasskeyTestAuthenticator()
    let user = try await register(authenticator, service: service, store: store).user
    for variation in 0..<8 {
      let options = try object(await post(service, "login/options"))
      let credential = try authenticator.assertion(options: options,
        userID: variation == 0 ? PasskeyEncoding.randomToken() : user.id,
        origin: variation == 1 ? "https://evil.example" : nil,
        rpID: variation == 2 ? "evil.example" : "riela.example",
        challenge: variation == 3 ? PasskeyEncoding.randomToken() : nil,
        flags: variation == 4 ? 1 : variation == 7 ? 0x15 : 5,
        crossOrigin: variation == 5, corruptSignature: variation == 6)
      let result = await post(service, "login/finish", ["ceremonyID": try XCTUnwrap(options["ceremonyID"]), "credential": credential])
      XCTAssertEqual(result.status, 401, "variation \(variation)")
      XCTAssertNil(try object(result)["token"])
    }
  }

  func testRegistrationRequiresVerificationAndMatchingCredentialID() async throws {
    for variation in 0..<2 {
      let (service, store) = try fixture()
      defer { try? FileManager.default.removeItem(at: store.root) }
      let invitation = String(try store.invite(name: "operator").split(separator: "/").last ?? "")
      let options = try object(await post(service, "register/options", ["invitation": invitation]))
      let credential = try PasskeyTestAuthenticator().registration(options: options, flags: variation == 0 ? 0x41 : 0x45, wrongID: variation == 1)
      let result = await post(service, "register/finish", ["ceremonyID": try XCTUnwrap(options["ceremonyID"]), "credential": credential])
      XCTAssertNotEqual(result.status, 200)
      XCTAssertTrue(try store.users()[0].credentials.isEmpty)
    }
  }

  func testDesktopGrantRequiresSecretAndIsSingleUseBoundToPasskey() async throws {
    let (service, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let authenticator = PasskeyTestAuthenticator()
    let user = try await register(authenticator, service: service, store: store).user
    let device = try object(await post(service, "device/start"))
    let deviceID = try XCTUnwrap(device["deviceID"] as? String)
    let secret = try XCTUnwrap(device["deviceSecret"] as? String)
    XCTAssertFalse((device["verificationURL"] as? String ?? "").contains(secret))
    let denied = await post(service, "device/poll", ["deviceID": deviceID, "deviceSecret": "wrong"])
    XCTAssertEqual(denied.status, 410)
    let pending = try object(await post(service, "device/poll", ["deviceID": deviceID, "deviceSecret": secret]))
    XCTAssertEqual(pending["status"] as? String, "pending")
    let options = try object(await post(service, "login/options", ["deviceID": deviceID]))
    let credential = try authenticator.assertion(options: options, userID: user.id)
    let approved = try object(await post(service, "login/finish", ["ceremonyID": try XCTUnwrap(options["ceremonyID"]), "credential": credential]))
    XCTAssertNil(approved["token"], "Desktop sessions must never go to the browser")
    XCTAssertEqual(approved["status"] as? String, "authorized")
    let grant = try object(await post(service, "device/poll", ["deviceID": deviceID, "deviceSecret": secret]))
    let token = try XCTUnwrap(grant["token"] as? String)
    let accepted = await service.isAuthenticated(bearer(token))
    XCTAssertTrue(accepted)
    let replay = await post(service, "device/poll", ["deviceID": deviceID, "deviceSecret": secret])
    XCTAssertEqual(replay.status, 410)
    try store.revokeUser(name: user.name)
    let revoked = await service.isAuthenticated(bearer(token))
    XCTAssertFalse(revoked)
  }

  func testInvalidHTTPBoundariesExpiredInvitationsAndCancelledDevices() async throws {
    let (service, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    for headers in [["host": "evil.example"], ["origin": "https://evil.example"], ["content-type": "text/plain"]] {
      let result = await post(service, "login/options", headers: headers)
      XCTAssertTrue([403, 415].contains(result.status))
    }
    let expired = String(try store.invite(name: "expired", now: Date().addingTimeInterval(-1000)).split(separator: "/").last ?? "")
    let denied = await post(service, "register/options", ["invitation": expired])
    XCTAssertEqual(denied.status, 410)
    let device = try object(await post(service, "device/start"))
    let cancelled = await post(service, "device/cancel", device)
    XCTAssertEqual(cancelled.status, 200)
    let poll = await post(service, "device/poll", device)
    XCTAssertEqual(poll.status, 410)
    for origin in ["http://riela.example", "https://riela.example/path", "https://user@riela.example"] {
      XCTAssertThrowsError(try RielaPasskeyConfiguration(origin: origin))
    }
  }

  func testExpiryRestartRateLimitAndStoreOriginBinding() async throws {
    let (_, store) = try fixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let clock = PasskeyTestClock()
    let configuration = try RielaPasskeyConfiguration(origin: store.origin)
    let service = RielaPasskeyService(configuration: configuration, root: store.root, now: { clock.read() })
    let registered = try await register(PasskeyTestAuthenticator(), service: service, store: store)
    let options = try object(await post(service, "login/options"))
    let device = try object(await post(service, "device/start"))
    clock.advance(301)
    let expiredDevice = await post(service, "device/poll", device)
    XCTAssertEqual(expiredDevice.status, 410)
    let credential = try PasskeyTestAuthenticator().assertion(options: options, userID: registered.user.id)
    let expiredCeremony = await post(service, "login/finish", ["ceremonyID": try XCTUnwrap(options["ceremonyID"]), "credential": credential])
    XCTAssertEqual(expiredCeremony.status, 410)
    let active = await service.isAuthenticated(bearer(registered.token))
    XCTAssertTrue(active)
    clock.advance(8 * 3600)
    let expiredSession = await service.isAuthenticated(bearer(registered.token))
    XCTAssertFalse(expiredSession)
    let restarted = RielaPasskeyService(configuration: configuration, root: store.root)
    let restartSession = await restarted.isAuthenticated(bearer(registered.token))
    XCTAssertFalse(restartSession)
    for _ in 0..<60 {
      let options = await post(restarted, "login/options")
      XCTAssertEqual(options.status, 200)
    }
    let limited = await post(restarted, "login/options")
    XCTAssertEqual(limited.status, 429)
    XCTAssertThrowsError(try RielaPasskeyStore(root: store.root, origin: "https://other.example").users())
  }

  private func fixture() throws -> (RielaPasskeyService, RielaPasskeyStore) {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/passkey-auth/unit/\(UUID().uuidString)")
    let configuration = try RielaPasskeyConfiguration(origin: "https://riela.example")
    return (RielaPasskeyService(configuration: configuration, root: root), RielaPasskeyStore(root: root, origin: configuration.origin))
  }

  private func register(
    _ authenticator: PasskeyTestAuthenticator, service: RielaPasskeyService, store: RielaPasskeyStore
  ) async throws -> Registered {
    let invitation = String(try store.invite(name: "operator").split(separator: "/").last ?? "")
    let options = try object(await post(service, "register/options", ["invitation": invitation]))
    let result = await post(service, "register/finish", ["ceremonyID": try XCTUnwrap(options["ceremonyID"]),
      "credential": try authenticator.registration(options: options)])
    XCTAssertEqual(result.status, 200, String(data: result.body, encoding: .utf8) ?? "")
    return Registered(user: try XCTUnwrap(store.users().first), token: try XCTUnwrap(try object(result)["token"] as? String), invitation: invitation)
  }

  private func post(_ service: RielaPasskeyService, _ path: String, _ body: [String: Any] = [:], headers: [String: String] = [:]) async -> RielaHTTPResponse {
    var all = ["host": "riela.example", "origin": "https://riela.example", "content-type": "application/json"]
    all.merge(headers) { _, value in value }
    return await service.response(for: RielaHTTPRequest(method: "POST", path: "/api/v1/auth/\(path)", headers: all,
      body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()))
  }

  private func object(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func bearer(_ token: String) -> RielaHTTPRequest {
    RielaHTTPRequest(method: "GET", path: "/api/v1/bootstrap", headers: ["authorization": "Bearer \(token)"])
  }
}

private final class PasskeyTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date = Date()
  func read() -> Date { lock.withLock { date } }
  func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
}
