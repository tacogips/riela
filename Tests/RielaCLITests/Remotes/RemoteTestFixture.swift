import Foundation
import RielaCore
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
struct RemoteTestFixture {
  let root: URL
  let sessionRoot: String
  let environment: [String: String]

  init(test: XCTestCase) throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    root = repository.appendingPathComponent("tmp/bots-overview/bots-19-remote-surfaces/test-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let scratchRoot = root
    test.addTeardownBlock { try FileManager.default.removeItem(at: scratchRoot) }
    sessionRoot = root.appendingPathComponent(".riela/sessions").path
    environment = [
      "HOME": root.path,
      "XDG_STATE_HOME": root.appendingPathComponent("state").path,
      "RIELA_CREDENTIAL_DIR": root.appendingPathComponent("credentials").path,
      "RIELA_MEMORY_ROOT": root.appendingPathComponent("memory").path,
      RoutineStore.rootDirectoryEnvironmentKey: root.appendingPathComponent("routines").path
    ]
  }

  var registry: RemoteRegistry { RemoteRegistry(environment: environment) }

  var botStore: BotStore {
    BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionRoot))
  }

  func createBot(_ id: String) throws {
    let at = "2026-11-25T00:00:00Z"
    try botStore.create(BotRecord(botId: id, name: id.capitalized, createdAt: at, updatedAt: at))
  }

  func startSession() throws {
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: botStore.sessionStoreRoot)
    let at = Date()
    try runtime.save(.init(session: WorkflowSession(
      workflowId: "flow", sessionId: "session", status: .running, entryStepId: "step",
      currentStepId: "step", createdAt: at, updatedAt: at
    )))
  }

  func serve(name: String = "Test Server") throws -> (host: ServeWebHost, pairing: PairingService) {
    let pairing = try PairingService(store: serverAPIKeyStore(homeDirectory: root), serverName: name)
    let parsed = try ParsedParityOptions(["--working-dir", root.path, "--session-store", sessionRoot])
    let adapter = serveMachineGraphQLAdapter(parsed: parsed, environment: environment, workingDirectory: root.path, pairing: pairing)
    let host = ServeWebHost(
      homeDirectory: root, workingDirectory: root, sessionStoreRoot: sessionRoot,
      host: "0.0.0.0", port: 8787, fallback: adapter,
      environment: environment.merging(["RIELA_WEB_ORIGIN": "https://riela.example"]) { _, new in new },
      pairing: pairing
    )
    return (host, pairing)
  }

  static func transport(to host: ServeWebHost) -> RemoteHTTP.Transport {
    { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      let url = try XCTUnwrap(request.url)
      let headers = (request.allHTTPHeaderFields ?? [:]).reduce(into: [String: String]()) { result, header in
        result[header.key.lowercased()] = header.value
      }
      let response = await host.response(for: RielaHTTPRequest(
        method: request.httpMethod ?? "GET", path: url.path, headers: headers, body: request.httpBody ?? Data()
      ))
      return (response.body, response.status)
    }
  }

  func run(_ arguments: [String], transport: @escaping RemoteHTTP.Transport) async -> CLICommandResult {
    let app = RielaCLIApplication(scopedCommandRunner: ScopedParityCommandRunner(remoteTransport: transport))
    return await app.run(arguments, environment: environment)
  }

  func botArguments(_ arguments: [String]) -> [String] {
    ["bot"] + arguments + ["--working-dir", root.path, "--session-store", sessionRoot]
  }

  func decode<T: Decodable>(_ type: T.Type, _ result: CLICommandResult) throws -> T {
    XCTAssertEqual(result.exitCode, .success, result.stderr)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(result.stdout.utf8))
  }
}
