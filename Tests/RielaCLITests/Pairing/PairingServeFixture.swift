import Foundation
import RielaCore
import RielaServer
import XCTest
@testable import RielaCLI

struct PairingServeFixture {
  let root: URL
  let sessionRoot: String
  let environment: [String: String]
  let pairing: PairingService
  let adapter: DeterministicServerHTTPAdapter

  init(test: XCTestCase) throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-18-pairing-surfaces/test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    test.addTeardownBlock { try FileManager.default.removeItem(at: root) }
    self.root = root
    sessionRoot = root.appendingPathComponent(".riela/sessions").path
    environment = [
      "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
      RoutineStore.rootDirectoryEnvironmentKey: root.appendingPathComponent("routines").path,
      "RIELA_MEMORY_ROOT": root.appendingPathComponent("memory").path
    ]
    pairing = try PairingService(store: serverAPIKeyStore(homeDirectory: root), serverName: "Pairing Test Server")
    let parsed = try ParsedParityOptions(["--working-dir", root.path, "--session-store", sessionRoot])
    adapter = serveMachineGraphQLAdapter(parsed: parsed, environment: environment, workingDirectory: root.path, pairing: pairing)
  }

  @MainActor
  func host(publicAccess: Bool) -> ServeWebHost {
    var environment = environment
    if publicAccess { environment["RIELA_WEB_ORIGIN"] = "https://riela.example" }
    return ServeWebHost(
      homeDirectory: root, workingDirectory: root, sessionStoreRoot: sessionRoot,
      host: publicAccess ? "0.0.0.0" : "127.0.0.1", port: 8787, fallback: adapter,
      environment: environment, pairing: pairing
    )
  }

  func graphql(_ query: String, token: String? = nil) async throws -> JSONObject {
    try json(await adapter.response(for: Self.graphQLRequest(query, token: token)))
  }

  static func graphQLRequest(_ query: String, token: String? = nil, headers: [String: String] = [:]) throws -> RielaHTTPRequest {
    var headers = headers
    headers["content-type"] = "application/json"
    if let token { headers["authorization"] = "Bearer " + token }
    return RielaHTTPRequest(method: "POST", path: "/graphql", headers: headers,
                           body: try JSONEncoder().encode(["query": query]))
  }

  func json(_ response: RielaHTTPResponse) throws -> JSONObject {
    try JSONDecoder().decode(JSONObject.self, from: response.body)
  }

  static func errorCode(_ body: JSONObject) -> String? {
    body["errors"]?.pairingArray?.first?.pairingObject?["extensions"]?.pairingObject?["code"]?.pairingString
  }

  static func pairingEnvelope(_ code: String) throws -> [String: String] {
    let header = "rp" + "1."
    XCTAssertTrue(code.hasPrefix(header))
    var encoded = String(code.dropFirst(header.count)).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
    return try JSONDecoder().decode([String: String].self, from: bytes)
  }

  func createBot() throws {
    try BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot)).create(
      BotRecord(botId: "alpha", name: "Alpha", createdAt: "2026-11-25T00:00:00Z", updatedAt: "2026-11-25T00:00:00Z")
    )
  }

  func startSession() throws {
    let at = Date()
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
    try runtime.save(.init(session: WorkflowSession(
      workflowId: "flow", sessionId: "session", status: .running, entryStepId: "step",
      currentStepId: "step", createdAt: at, updatedAt: at
    )))
  }
}

extension JSONValue {
  var pairingObject: JSONObject? {
    if case let .object(object) = self { return object }
    return nil
  }

  var pairingArray: [JSONValue]? {
    if case let .array(array) = self { return array }
    return nil
  }

  var pairingString: String? {
    if case let .string(string) = self { return string }
    return nil
  }
}
