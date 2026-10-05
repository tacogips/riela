#if os(macOS)
import Foundation
@testable import RielaApp
import RielaAppSupport
import RielaServer
import XCTest

@MainActor
final class RielaAppAPIKeyTests: XCTestCase {
  func testDesktopIssuesExpiringKeyAndPersistsPolicyAndRevocation() async throws {
    let (app, root) = try fixture()
    let expiration = Date().addingTimeInterval(3600)
    let formatter = ISO8601DateFormatter()
    let response = await manage(app, method: "POST", input: [
      "expectedProfile": "default", "name": "automation", "purpose": "client",
      "expiresAt": formatter.string(from: expiration)
    ])
    XCTAssertEqual(response.status, 200)
    let issued = try object(response)
    let token = try XCTUnwrap(issued["token"] as? String)
    let record = try XCTUnwrap(issued["record"] as? [String: Any])
    let id = try XCTUnwrap(record["id"] as? String)
    XCTAssertNotNil(record["expiresAt"])
    let reopened = RielaAPIKeyStore(root: root.appendingPathComponent("api-auth"))
    XCTAssertTrue(try reopened.authorizeClient(token: token))
    XCTAssertFalse(try reopened.authorizeClient(token: token, now: expiration.addingTimeInterval(1)))
    let listed = await manage(app, method: "GET")
    XCTAssertFalse((String(data: listed.body, encoding: .utf8) ?? "").contains(token))
    let revoked = await manage(app, method: "DELETE", input: ["expectedProfile": "default", "id": id])
    XCTAssertEqual(revoked.status, 200)
    XCTAssertFalse(try reopened.authorizeClient(token: token))
    let disabled = await manage(app, method: "PUT", input: ["expectedProfile": "default", "requireClientKey": false])
    XCTAssertEqual(disabled.status, 200)
    XCTAssertTrue(try reopened.authorizeClient(token: nil))
    let stale = await manage(app, method: "PUT", input: ["expectedProfile": "other", "requireClientKey": true])
    XCTAssertEqual(stale.status, 409)
    XCTAssertFalse(try reopened.requireClientKey())
  }

  func testMachineGraphQLRequiresKeyButNeverGrantsKeyAdministration() async throws {
    let (app, root) = try fixture()
    let router = RielaAppWebRouter(app: app, assetRoot: root, configuredPort: 19_091)
    var request = RielaHTTPRequest(method: "POST", path: "/graphql", headers: [
      "host": "127.0.0.1:19091", "content-type": "application/json"
    ], body: Data(#"{"query":"{ configuration { profile } }"}"#.utf8))
    let missing = await router.response(for: request)
    XCTAssertEqual(missing.status, 401)
    let token = try app.apiKeyStore.issue(name: "client").token
    request.headers["authorization"] = "Bearer \(token)"
    let admitted = await router.response(for: request)
    XCTAssertEqual(admitted.status, 200)
    XCTAssertNotNil(try object(admitted)["data"])
    var administration = request
    administration.path = "/api/v1/settings/api-keys"
    administration.percentEncodedPath = administration.path
    administration.body = Data(#"{"expectedProfile":"default","name":"forbidden","purpose":"client"}"#.utf8)
    let rejected = await router.response(for: administration)
    XCTAssertNotEqual(rejected.status, 200)
    XCTAssertEqual(try app.apiKeyStore.list().count, 1)
    try app.apiKeyStore.revoke(id: try XCTUnwrap(app.apiKeyStore.list().first?.id))
    let revoked = await router.response(for: request)
    XCTAssertEqual(revoked.status, 401)
    try app.apiKeyStore.setRequireClientKey(false)
    request.headers.removeValue(forKey: "authorization")
    let anonymous = await router.response(for: request)
    XCTAssertEqual(anonymous.status, 200)
    request.headers["authorization"] = "Bearer \(token)"
    let invalid = await router.response(for: request)
    XCTAssertEqual(invalid.status, 401)
  }

  func testWorkerIssuanceBindsConfiguredWorkerAndRejectsPastExpiry() async throws {
    let (app, _) = try fixture()
    let configuration = DistributedControllerConfiguration(
      host: "127.0.0.1", port: 8788, storePath: "jobs.json",
      workers: [.init(id: "worker-1", groups: [], maxCapacity: 1)]
    )
    let url = app.distributedControllerConfigurationURL
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(configuration).write(to: url)
    let issued = await manage(app, method: "POST", input: [
      "expectedProfile": "default", "name": "worker", "purpose": "worker", "workerID": "worker-1"
    ])
    XCTAssertEqual(issued.status, 200)
    let token = try XCTUnwrap(object(issued)["token"] as? String)
    XCTAssertNotNil(try app.apiKeyStore.authenticate(token, purpose: .worker, workerID: "worker-1"))
    XCTAssertFalse(try app.apiKeyStore.authorizeClient(token: token))
    let unknown = await manage(app, method: "POST", input: [
      "expectedProfile": "default", "name": "unknown", "purpose": "worker", "workerID": "other"
    ])
    XCTAssertEqual(unknown.status, 400)
    let past = await manage(app, method: "POST", input: [
      "expectedProfile": "default", "name": "past", "purpose": "client", "expiresAt": "2020-01-01T00:00:00Z"
    ])
    XCTAssertEqual(past.status, 400)
  }

  private func fixture() throws -> (RielaApp, URL) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
      .appendingPathComponent("tmp/app-api-auth-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let app = RielaApp()
    app.profileStore = RielaAppProfileStore(appRootURL: root)
    app.appHomeDirectory = root.appendingPathComponent("home")
    return (app, root)
  }

  private func manage(_ app: RielaApp, method: String, input: [String: Any]? = nil) async -> RielaHTTPResponse {
    let body = input.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
    return await app.desktopAPIResponse(for: RielaDesktopRequest(
      method: method, path: "/api/v1/settings/api-keys", headers: [:], body: String(data: body, encoding: .utf8) ?? ""
    ), csrfToken: "native")
  }

  private func object(_ response: RielaHTTPResponse) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }
}
#endif
