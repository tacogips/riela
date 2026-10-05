import Foundation
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class APIKeyGraphQLAuthorizationTests: XCTestCase {
  func testNativeTaskReadsRequireLiveClientKeyAndObservePolicyChanges() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = serverAPIKeyStore(homeDirectory: root)
    let client = try store.issue(name: "Task client")
    let worker = try store.issue(name: "Worker", purpose: .worker, workerID: "worker")
    let adapter = try adapter(root: root)
    let query = "{ tasksAwaitingHandover { tasks { taskId } } }"

    for token in [nil, "invalid", worker.token] as [String?] {
      let rejected = try await response(adapter, query: query, token: token)
      XCTAssertEqual(errorCode(rejected), "UNAUTHENTICATED")
    }
    let accepted = try await response(adapter, query: query, token: client.token)
    XCTAssertNil(accepted["errors"])
    let data = try XCTUnwrap(accepted["data"] as? [String: Any])
    let tasks = try XCTUnwrap(data["tasksAwaitingHandover"] as? [String: Any])
    XCTAssertEqual((tasks["tasks"] as? [Any])?.count, 0)

    try store.revoke(id: client.record.id)
    let revoked = try await response(adapter, query: query, token: client.token)
    XCTAssertEqual(errorCode(revoked), "UNAUTHENTICATED")
    try store.setRequireClientKey(false)
    let anonymous = try await response(adapter, query: query)
    XCTAssertNil(anonymous["errors"])
    let stillRevoked = try await response(adapter, query: query, token: client.token)
    XCTAssertEqual(errorCode(stillRevoked), "UNAUTHENTICATED")
  }

  func testNativeSessionMutationsAuthenticateBeforeInputValidation() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let token = try serverAPIKeyStore(homeDirectory: root).issue(name: "Session client").token
    let adapter = try adapter(root: root)
    let mutation = "mutation { stopSession(input: {}) { sessionId } }"
    let rejected = try await response(adapter, query: mutation)
    XCTAssertEqual(errorCode(rejected), "UNAUTHENTICATED")
    let dispatched = try await response(adapter, query: mutation, token: token)
    XCTAssertEqual(errorCode(dispatched), "SESSION_CONTROL_FAILURE")
  }

  func testServeHostAdmitsNativeClientButRejectsBrowserOriginWithSameKey() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let token = try serverAPIKeyStore(homeDirectory: root).issue(name: "Native client").token
    let host = ServeWebHost(
      homeDirectory: root, workingDirectory: root, sessionStoreRoot: root.appendingPathComponent("sessions").path,
      host: "127.0.0.1", port: 8787, fallback: try adapter(root: root), environment: ["HOME": root.path]
    )
    let query = "{ tasksAwaitingHandover { tasks { taskId } } }"
    var request = RielaHTTPRequest(
      method: "POST", path: "/graphql",
      headers: ["host": "127.0.0.1:8787", "content-type": "application/json", "authorization": "Bearer " + token],
      body: try JSONSerialization.data(withJSONObject: ["query": query])
    )
    let accepted = await host.response(for: request)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: accepted.body) as? [String: Any])
    XCTAssertNotNil((json["data"] as? [String: Any])?["tasksAwaitingHandover"])
    request.headers["origin"] = "https://untrusted.example"
    let hostileBrowser = await host.response(for: request)
    XCTAssertEqual(hostileBrowser.status, 403)
    request.headers.removeValue(forKey: "origin")
    request.headers.removeValue(forKey: "authorization")
    let anonymous = await host.response(for: request)
    XCTAssertEqual(anonymous.status, 401)
  }

  private func adapter(root: URL) throws -> DeterministicServerHTTPAdapter {
    let parsed = try ParsedParityOptions(["--working-dir", root.path, "--session-store", root.appendingPathComponent("sessions").path])
    return serveMachineGraphQLAdapter(parsed: parsed, environment: ["HOME": root.path], workingDirectory: root.path)
  }

  private func response(
    _ adapter: DeterministicServerHTTPAdapter, query: String, token: String? = nil
  ) async throws -> [String: Any] {
    var headers = ["content-type": "application/json"]
    if let token { headers["authorization"] = "Bearer " + token }
    let request = RielaHTTPRequest(method: "POST", path: "/graphql", headers: headers,
                                   body: try JSONSerialization.data(withJSONObject: ["query": query]))
    let response = await adapter.response(for: request)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
  }

  private func errorCode(_ response: [String: Any]) -> String? {
    let errors = response["errors"] as? [[String: Any]]
    return (errors?.first?["extensions"] as? [String: Any])?["code"] as? String
  }

  private func fixture() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/api-key-graphql-tests/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
