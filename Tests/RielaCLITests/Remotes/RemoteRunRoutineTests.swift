import Foundation
import RielaCore
import RielaServer
import XCTest
@testable import RielaCLI

@MainActor
final class RemoteForwardingTestsForRunAndRoutine: XCTestCase {
  func testWorkflowRunTargetsNamedServerAndLinksItsBot() async throws {
    let fixture = try RemoteSelectorFixture(test: self, scope: .operate)
    try fixture.installWorkflow()
    try fixture.createServerBot()

    let run = await fixture.app.run([
      "workflow", "run", fixture.workflowName, "--remote", "work", "--bot", "b1", "--output", "json",
      "--working-dir", fixture.client.path, "--session-store", fixture.localSessionRoot
    ], environment: fixture.environment)
    XCTAssertEqual(run.exitCode, .success, run.stderr)
    let result = try JSONDecoder().decode(WorkflowRemoteRunResult.self, from: Data(run.stdout.utf8))
    XCTAssertEqual(result.status, "completed")
    let persisted = try CLIWorkflowSessionStore(rootDirectory: fixture.serverSessionRoot).load(sessionId: result.sessionId)
    XCTAssertEqual(persisted.session.sessionId, result.sessionId)
    XCTAssertEqual(try fixture.serverBots.links(botId: "b1").map(\.sessionId), [result.sessionId])
    XCTAssertTrue(try CLIWorkflowSessionStore(rootDirectory: fixture.localSessionRoot).list().isEmpty)
  }

  func testWorkflowRunResolvesActiveAndRejectsConflictingSelectors() async throws {
    let fixture = try RemoteSelectorFixture(test: self, scope: .operate)
    try fixture.registry.use(name: "work")
    let cases: [([String], String?)] = [
      ([], "https://riela.example/graphql"),
      (["--remote", "local"], nil)
    ]
    for (flags, endpoint) in cases {
      let command = try CLIRuntimeEnvironment.$overrides.withValue(fixture.environment) {
        try RielaArgumentParser().parse(["workflow", "run", fixture.workflowName] + flags)
      }
      guard case let .workflow(.run(options)) = command else {
        return XCTFail("Expected parsed workflow run")
      }
      XCTAssertEqual(options.endpoint, endpoint)
      XCTAssertEqual(options.pairedRemote, endpoint != nil)
    }
    let conflict = await fixture.app.run(
      ["workflow", "run", fixture.workflowName, "--remote", "work", "--endpoint", "https://other.example/graphql"],
      environment: fixture.environment
    )
    XCTAssertNotEqual(conflict.exitCode, .success)
    let diagnostic = conflict.stderr + conflict.stdout
    XCTAssertTrue(diagnostic.contains("--remote cannot be combined"), diagnostic)
    let session = await fixture.app.run(["session", "rerun", "s", "step", "--remote", "work"],
                                        environment: fixture.environment)
    XCTAssertNotEqual(session.exitCode, .success)
    XCTAssertTrue((session.stderr + session.stdout).contains("--remote is supported only by workflow run"))
  }

  func testRoutineCreateUsesServerStoreAndEnforcesReadScope() async throws {
    let operate = try RemoteSelectorFixture(test: self, scope: .operate)
    try operate.createServerBot()
    let created = await operate.app.run(operate.routineArguments, environment: operate.environment)
    XCTAssertEqual(created.exitCode, .success, created.stderr)
    XCTAssertTrue(created.stdout.contains("botId=b1"), created.stdout)
    let records = try operate.serverRoutines.list()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records.first?.botId, "b1")
    XCTAssertTrue(try operate.localRoutines.list().isEmpty)

    let read = try RemoteSelectorFixture(test: self, scope: .read)
    let denied = await read.app.run(read.routineArguments, environment: read.environment)
    XCTAssertNotEqual(denied.exitCode, .success)
    XCTAssertTrue(denied.stderr.contains("scope_insufficient"), denied.stderr)
    XCTAssertTrue(try read.serverRoutines.list().isEmpty)
  }

  func testMachineRoutineRejectsUnauthenticatedAndExplicitStoreRoots() async throws {
    let fixture = try RemoteSelectorFixture(test: self, scope: .operate)
    let query = """
    mutation {
      createRoutine(input: {
        name: "Routine", task: "Check", workflowName: "fixture", every: "30m",
        eventRoot: "override"
      }) { accepted }
    }
    """
    let unauthorized = try await fixture.graphQL(query: query, authenticate: false)
    XCTAssertEqual(unauthorized["error"], .string("invalid_api_key"))
    let override = try await fixture.graphQL(query: query)
    XCTAssertEqual(errorCode(override), "INVALID_ROUTINE")
    XCTAssertTrue(try fixture.serverRoutines.list().isEmpty)
  }

  private func errorCode(_ body: JSONObject) -> String? {
    guard case let .array(errors)? = body["errors"],
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }
}

@MainActor
private struct RemoteSelectorFixture {
  let server: URL
  let client: URL
  let repository: URL
  let environment: [String: String]
  let registry: RemoteRegistry
  let host: ServeWebHost
  let token: String
  let app: RielaCLIApplication
  let workflowName = "workflow-call-live-echo-callee"

  var serverSessionRoot: String { server.appendingPathComponent("sessions").path }
  var localSessionRoot: String { client.appendingPathComponent("sessions").path }
  var serverBots: BotStore {
    BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: serverSessionRoot))
  }
  var serverRoutines: RoutineStore { RoutineStore(rootDirectory: server.appendingPathComponent("routines").path) }
  var localRoutines: RoutineStore { RoutineStore(rootDirectory: client.appendingPathComponent("routines").path) }

  var routineArguments: [String] {
    [
      "routine", "create", "--remote", "work", "--name", "Check", "--task", "Check progress",
      "--workflow", workflowName, "--every", "30m", "--working-dir", client.path, "--bot", "b1",
      "--output", "text"
    ]
  }

  init(test: XCTestCase, scope: RielaAPIKeyStore.Scope) throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-19-remote-surfaces/selectors-\(UUID())")
    let server = root.appendingPathComponent("server")
    let client = root.appendingPathComponent("client")
    try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
    test.addTeardownBlock { try FileManager.default.removeItem(at: root) }
    self.repository = repository
    self.server = server
    self.client = client
    let serverEnvironment = Self.isolatedEnvironment(root: server)
    let environment = Self.isolatedEnvironment(root: client)
    self.environment = environment

    let pairing = try PairingService(store: serverAPIKeyStore(homeDirectory: server), serverName: "Routine test server")
    let credential = try pairing.store.issue(name: "test client", scope: scope)
    let registry = RemoteRegistry(environment: environment)
    try registry.add(record: RemoteRecord(
      name: "work", address: "https://riela.example",
      serverId: pairing.identity.serverId, serverName: pairing.identity.name,
      grantId: credential.record.id, scope: scope, addedAt: Date()
    ), token: credential.token)
    self.registry = registry
    token = credential.token

    let sessionRoot = server.appendingPathComponent("sessions").path
    let parsed = try ParsedParityOptions(["--working-dir", server.path, "--session-store", sessionRoot])
    let adapter = serveMachineGraphQLAdapter(
      parsed: parsed, environment: serverEnvironment, workingDirectory: server.path, pairing: pairing
    )
    let host = ServeWebHost(
      homeDirectory: server, workingDirectory: server, sessionStoreRoot: sessionRoot,
      host: "127.0.0.1", port: 8787, fallback: adapter, environment: serverEnvironment, pairing: pairing
    )
    self.host = host
    let transport: RemoteHTTP.Transport = { request in
      let response = await host.response(for: RielaHTTPRequest(
        method: request.httpMethod ?? "GET", path: request.url?.path ?? "/",
        headers: request.allHTTPHeaderFields ?? [:], body: request.httpBody ?? Data()
      ))
      return (response.body, response.status)
    }
    app = RielaCLIApplication(
      runCommand: WorkflowRunCommand(graphQLTransport: URLSessionWorkflowGraphQLRunTransport(pairedTransport: transport)),
      scopedCommandRunner: ScopedParityCommandRunner(remoteTransport: transport)
    )
  }

  func installWorkflow() throws {
    let workspace = server.appendingPathComponent(".riela/workflows")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: repository.appendingPathComponent("examples/\(workflowName)"),
      to: workspace.appendingPathComponent(workflowName)
    )
  }

  func createServerBot() throws {
    let at = "2026-11-25T00:00:00Z"
    try serverBots.create(BotRecord(botId: "b1", name: "Remote bot", createdAt: at, updatedAt: at))
  }

  func graphQL(query: String, authenticate: Bool = true) async throws -> JSONObject {
    var headers = ["content-type": "application/json"]
    if authenticate { headers["authorization"] = "Bearer " + token }
    let result = await host.response(for: RielaHTTPRequest(
      method: "POST", path: "/graphql", headers: headers,
      body: try JSONEncoder().encode(["query": query])
    ))
    return try JSONDecoder().decode(JSONObject.self, from: result.body)
  }

  private static func isolatedEnvironment(root: URL) -> [String: String] {
    [
      "HOME": root.path, "XDG_STATE_HOME": root.appendingPathComponent("state").path,
      "RIELA_CREDENTIAL_DIR": root.appendingPathComponent("credentials").path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user-riela").path,
      RoutineStore.rootDirectoryEnvironmentKey: root.appendingPathComponent("routines").path,
      "RIELA_MEMORY_ROOT": root.appendingPathComponent("memory").path
    ]
  }
}
