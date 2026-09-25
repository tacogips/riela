import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import RielaCore
import RielaSQLite
@testable import RielaServer
import XCTest
@testable import RielaCLI

final class ServeHTTPCommandTests: XCTestCase {
  func testLongRunningInvocationMatchesOnlyBareServeForms() {
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve"]))
    XCTAssertTrue(ServeHTTPCommand.isLongRunningInvocation(["serve", "--host", "127.0.0.1", "--port", "8787"]))

    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "status"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "health"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "overview"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["serve", "graphql"]))
    XCTAssertFalse(ServeHTTPCommand.isLongRunningInvocation(["workflow", "list"]))
  }

  func testWebRootValidationRequiresReadableIndex() throws {
    var parsed = try ParsedParityOptions(["--web-root", "/definitely/missing/riela-web"])
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    parsed = try ParsedParityOptions(["--web-root", root.path])
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("index.html"),
      withIntermediateDirectories: false
    )
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.removeItem(at: root.appendingPathComponent("index.html"))
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("index.html"),
      withDestinationURL: outside
    )
    XCTAssertThrowsError(try resolvedServeWebRoot(parsed: parsed))
    try FileManager.default.removeItem(at: root.appendingPathComponent("index.html"))
    try Data("app".utf8).write(to: root.appendingPathComponent("index.html"))
    XCTAssertEqual(try resolvedServeWebRoot(parsed: parsed)?.path, root.resolvingSymlinksInPath().path)
  }

  func testServeOneShotCommandsStillReturnSuccessfully() async throws {
    let app = RielaCLIApplication()
    for subcommand in ["status", "health", "overview", "graphql"] {
      let result = await app.run(["serve", subcommand, "--output", "json"])
      XCTAssertEqual(result.exitCode, .success, "\(subcommand): \(result.stderr)")
      let decoded = try JSONDecoder().decode(ScopedParityCommandResult.self, from: Data(result.stdout.utf8))
      XCTAssertEqual(decoded.status, "ok", subcommand)
    }
  }

  func testMachineHTTPExecutesAndReadsPersistedWorkflowWithBearer() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/http-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/remote-fixture")
    let store = root.appendingPathComponent("sessions")
    let effect = root.appendingPathComponent("effect")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {
        "workflowId": "remote-fixture",
        "defaults": {"nodeTimeoutMs": 30000, "maxLoopIterations": 1},
        "entryStepId": "work",
        "nodes": [
          {"id": "work", "nodeFile": "nodes/work.json"},
          {"id": "finish", "nodeFile": "nodes/finish.json"}
        ],
        "steps": [
          {"id": "work", "nodeId": "work", "role": "worker", "transitions": [{"toStepId": "finish"}]},
          {"id": "finish", "nodeId": "finish", "role": "worker"}
        ]
      }
      """#.utf8)
      .write(to: workflow.appendingPathComponent("workflow.json"))
    let node: [String: Any] = [
      "id": "work", "nodeType": "command", "modelFreeze": false,
      "command": [
        "executable": "/bin/sh",
        "arguments": ["-c", "test -z \"$RIELA_MANAGER_AUTH_TOKEN\" || exit 9; printf effect >> \"$1\"; printf '{\"ok\":true}\\n'", "work", effect.path]
      ]
    ]
    try JSONSerialization.data(withJSONObject: node).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let finish: [String: Any] = [
      "id": "finish", "nodeType": "command", "modelFreeze": false,
      "command": ["executable": "/bin/echo", "arguments": ["{\"finished\":true}"]]
    ]
    try JSONSerialization.data(withJSONObject: finish).write(to: workflow.appendingPathComponent("nodes/finish.json"))
    let parsed = try ParsedParityOptions(["--working-dir", root.path, "--session-store", store.path])
    let adapter = serveMachineGraphQLAdapter(
      parsed: parsed,
      environment: ["RIELA_MANAGER_AUTH_TOKEN": "test-operator", "HOME": root.path],
      workingDirectory: root.path
    )
    let server = RielaLocalHTTPServer(routeHandler: adapter)
    let port = try await server.startForTesting()
    do {
      let endpoint = "http://127.0.0.1:\(port)/graphql"
      let mutation = "mutation($input: ExecuteWorkflowInput!) { executeWorkflow(input: $input) { sessionId status exitCode } }"

      let missing = try await postGraphQL(endpoint, query: mutation, input: ["workflowName": "remote-fixture"])
      XCTAssertEqual(errorCode(missing), "UNAUTHENTICATED")
      let wrong = try await postGraphQL(endpoint, query: mutation, input: ["workflowName": "remote-fixture"], bearer: "wrong")
      XCTAssertEqual(errorCode(wrong), "UNAUTHENTICATED")
      let spoofed = try await postGraphQLDocument(
        endpoint, query: mutation,
        variables: ["input": ["workflowName": "remote-fixture"]],
        headers: ["X-Riela-Manager-Session-Id": "manager", "X-Riela-Client-Id": "client"]
      )
      XCTAssertEqual(errorCode(spoofed), "UNAUTHENTICATED")
      let unknown = try await postGraphQL(
        endpoint, query: mutation,
        input: ["workflowName": "remote-fixture", "unknownOption": false], bearer: "test-operator"
      )
      XCTAssertEqual(errorCode(unknown), "INVALID_EXECUTION_INPUT")
      let malformed = try await postGraphQLDocument(
        endpoint, query: mutation, variables: ["input": false], bearer: "test-operator"
      )
      XCTAssertEqual(errorCode(malformed), "INVALID_EXECUTION_INPUT")
      for key in ["autoImprove", "nestedSuperviser"] {
        for value: Any in [false, NSNull(), true, ["enabled": false]] {
          let rejected = try await postGraphQL(
            endpoint, query: mutation,
            input: ["workflowName": "remote-fixture", key: value], bearer: "test-operator"
          )
          XCTAssertEqual(errorCode(rejected), "INVALID_EXECUTION_INPUT", "\(key)=\(value)")
        }
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

      for body in [Data(), Data("{".utf8), Data("[]".utf8), Data(#"{"variables":{}}"#.utf8)] {
        let response = try await postRawGraphQL(endpoint, body: body)
        XCTAssertEqual(response.status, 400)
        XCTAssertNotNil(response.body["error"])
      }
      let oversizedStatus = try postOversizedContentLength(endpoint)
      XCTAssertEqual(oversizedStatus, 413)
      XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

      let unconfigured = RielaLocalHTTPServer(routeHandler: serveMachineGraphQLAdapter(
        parsed: parsed, environment: ["HOME": root.path], workingDirectory: root.path
      ))
      let unconfiguredPort = try await unconfigured.startForTesting()
      let unconfiguredResponse = try await postGraphQL(
        "http://127.0.0.1:\(unconfiguredPort)/graphql", query: mutation,
        input: ["workflowName": "remote-fixture"], bearer: "test-operator"
      )
      await unconfigured.stop()
      XCTAssertEqual(errorCode(unconfiguredResponse), "UNAUTHENTICATED")
      XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))

      let remote = try await URLSessionWorkflowGraphQLRunTransport().executeWorkflow(
        endpoint: endpoint,
        request: WorkflowRemoteRunRequest(
          workflowName: "remote-fixture",
          instanceIdentity: "default",
          runtimeVariables: ["sample": .string("value")],
          nodePatch: [:],
          maxSteps: 4,
          maxConcurrency: 1,
          maxLoopIterations: 2,
          disableDefaultLoopGuard: true,
          defaultTimeoutMs: 10_000,
          authToken: "test-operator"
        )
      )
      XCTAssertEqual(remote.status, "completed")
      XCTAssertEqual(remote.exitCode, 0)
      XCTAssertEqual(remote.workflowName, "remote-fixture")
      XCTAssertEqual(remote.workflowId, "remote-fixture")
      XCTAssertGreaterThan(remote.nodeExecutions, 0)
      XCTAssertGreaterThan(remote.transitions, 0)
      XCTAssertTrue(FileManager.default.fileExists(atPath: effect.path))

      let fresh = WorkflowExecutionProvider(
        workingDirectory: root.path, sessionStoreRoot: store.path,
        environment: ["HOME": root.path]
      )
      let persistedValue = try await fresh.workflowExecution(workflowExecutionId: remote.sessionId)
      let persisted = try XCTUnwrap(persistedValue)
      XCTAssertEqual(persisted.session.workflowName, "remote-fixture")
      XCTAssertEqual(persisted.nodeExecutions.count, remote.nodeExecutions)
      XCTAssertEqual(persisted.session.transitions.count, remote.transitions)

      let budgetFailure = try await URLSessionWorkflowGraphQLRunTransport().executeWorkflow(
        endpoint: endpoint,
        request: WorkflowRemoteRunRequest(
          workflowName: "remote-fixture", maxSteps: 1, authToken: "test-operator"
        )
      )
      XCTAssertEqual(budgetFailure.status, "failed")
      XCTAssertNotEqual(budgetFailure.exitCode, 0)
      let failedRecord = try CLIWorkflowSessionStore(rootDirectory: store.path)
        .loadStrictReadOnly(sessionId: budgetFailure.sessionId)
      let failedSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)
      ).loadStrictReadOnly(sessionId: budgetFailure.sessionId)
      XCTAssertEqual(failedRecord.session.status, .failed)
      XCTAssertEqual(failedSnapshot.session.status, .failed)
      XCTAssertEqual(failedSnapshot.session.failureKind, .maxStepsExceeded)
      let failedSummary = try await fresh.workflowExecution(workflowExecutionId: budgetFailure.sessionId)
      XCTAssertEqual(failedSummary?.session.workflowId, "remote-fixture")

      let summaryQuery = "query($id: String!) { workflowExecution(workflowExecutionId: $id) { session { sessionId } } }"
      let deniedRead = try await postGraphQLDocument(
        endpoint, query: summaryQuery, variables: ["id": remote.sessionId]
      )
      XCTAssertEqual(errorCode(deniedRead), "UNAUTHENTICATED")
      var corruptSnapshot = try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)
      ).loadStrictReadOnly(sessionId: remote.sessionId)
      corruptSnapshot.session.sessionId = "shape-session"
      corruptSnapshot.workflowMessages = []
      try SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)
      ).save(corruptSnapshot)
      let database = try SQLiteDatabase.open(path: CLIWorkflowSessionStore.defaultDatabasePath(rootDirectory: store.path))
      try database.execute(
        "INSERT INTO cli_workflow_sessions (session_id, record_json, updated_at) VALUES (?, jsonb(?), ?)",
        bindings: [
          .text("shape-session"),
          .text(#"{"workflowName":"remote-fixture","session":{"workflowId":"remote-fixture","status":"completed"}}"#),
          .text("2026-09-25T00:00:00Z")
        ]
      )
      let corrupt = try await postGraphQLDocument(
        endpoint, query: summaryQuery, variables: ["id": "shape-session"], bearer: "test-operator"
      )
      XCTAssertEqual(errorCode(corrupt), "WORKFLOW_EXECUTION_FAILED")
      let absent = try await postGraphQLDocument(
        endpoint, query: summaryQuery, variables: ["id": "absent-session"], bearer: "test-operator"
      )
      XCTAssertNil(errorCode(absent))
      XCTAssertTrue(((absent["data"] as? [String: Any])?["workflowExecution"]) is NSNull)
    } catch {
      await server.stop()
      throw error
    }
    await server.stop()
  }

  func testServerStopCancelsAndPersistsActiveExecution() async throws {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/native-remote-implementation/NRE-03/cancel-\(UUID().uuidString)")
    let workflow = root.appendingPathComponent(".riela/workflows/cancel-fixture")
    let store = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: workflow.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"""
      {"workflowId":"cancel-fixture","entryStepId":"work",
       "defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":1},
       "nodes":[{"id":"work","nodeFile":"nodes/work.json"}],
       "steps":[{"id":"work","nodeId":"work","role":"worker"}]}
      """#.utf8).write(to: workflow.appendingPathComponent("workflow.json"))
    try Data(#"""
      {"id":"work","nodeType":"command","modelFreeze":false,
       "command":{"executable":"/bin/sleep","arguments":["60"]}}
      """#.utf8).write(to: workflow.appendingPathComponent("nodes/work.json"))
    let parsed = try ParsedParityOptions(["--working-dir", root.path, "--session-store", store.path])
    let server = RielaLocalHTTPServer(routeHandler: serveMachineGraphQLAdapter(
      parsed: parsed,
      environment: ["RIELA_MANAGER_AUTH_TOKEN": "test-operator", "HOME": root.path],
      workingDirectory: root.path
    ))
    let port = try await server.startForTesting()
    let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/graphql"))
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer test-operator", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "query": "mutation { executeWorkflow(input: {workflowName: \"cancel-fixture\"}) { sessionId status } }"
    ])
    let responseTask = Task { try? await URLSession.shared.data(for: request) }
    let sessionStore = CLIWorkflowSessionStore(rootDirectory: store.path)
    var running: PersistedCLIWorkflowSession?
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      running = try? sessionStore.loadAll().first(where: { $0.workflowName == "cancel-fixture" && $0.session.status == .running })
      if running != nil { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard let sessionId = running?.session.sessionId else {
      await server.stop()
      let response = await responseTask.value
      let body = response.flatMap { String(data: $0.0, encoding: .utf8) } ?? "no HTTP response"
      XCTFail("workflow did not persist an active session: \(body)")
      return
    }
    responseTask.cancel()
    _ = await responseTask.value
    let afterDisconnect = try sessionStore.loadStrictReadOnly(sessionId: sessionId)
    XCTAssertEqual(afterDisconnect.session.status, .running)
    await server.stop()
    let record = try sessionStore.loadStrictReadOnly(sessionId: sessionId)
    let snapshot = try SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)
    ).loadStrictReadOnly(sessionId: sessionId)
    XCTAssertEqual(record.session.status, .failed)
    XCTAssertEqual(snapshot.session.status, .failed)
    XCTAssertEqual(snapshot.session.failureKind, .cancelled)
  }

  private func postGraphQL(
    _ endpoint: String,
    query: String,
    input: [String: Any],
    bearer: String? = nil
  ) async throws -> [String: Any] {
    try await postGraphQLDocument(
      endpoint, query: query, variables: ["input": input], bearer: bearer
    )
  }

  private func postRawGraphQL(
    _ endpoint: String,
    body: Data
  ) async throws -> (status: Int, body: [String: Any]) {
    var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    return (status, object)
  }

  private func postOversizedContentLength(_ endpoint: String) throws -> Int {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    process.arguments = [
      "--silent", "--show-error", "--max-time", "5", "--request", "POST",
      "--header", "Content-Type: application/json",
      "--header", "Content-Length: \(RielaHTTPRequestParser.maximumBodyBytes + 1)",
      "--header", "Expect:", "--data-binary", "", "--output", "/dev/null",
      "--write-out", "%{http_code}", endpoint
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, text)
    return try XCTUnwrap(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func postGraphQLDocument(
    _ endpoint: String,
    query: String,
    variables: [String: Any],
    bearer: String? = nil,
    headers: [String: String] = [:]
  ) async throws -> [String: Any] {
    var request = URLRequest(url: try XCTUnwrap(URL(string: endpoint)))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
    let (data, response) = try await URLSession.shared.data(for: request)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func errorCode(_ response: [String: Any]) -> String? {
    let errors = response["errors"] as? [[String: Any]]
    return (errors?.first?["extensions"] as? [String: Any])?["code"] as? String
  }

  private func availablePort() async throws -> Int {
    let handler = AnyRielaHTTPRouteHandler { request in
      await DeterministicServerHTTPAdapter().response(for: request)
    }
    let server = RielaLocalHTTPServer(routeHandler: handler)
    let port = try await server.startForTesting()
    await server.stop()
    return port
  }

  private func curl(
    _ url: String,
    method: String = "GET",
    headers: [String: String] = [:],
    body: String? = nil
  ) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    var arguments = ["--fail", "--silent", "--show-error", "--max-time", "5"]
    if method != "GET" {
      arguments.append(contentsOf: ["--request", method])
    }
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
      arguments.append(contentsOf: ["--header", "\(name): \(value)"])
    }
    if let body {
      arguments.append(contentsOf: ["--data-binary", body])
    }
    arguments.append(url)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let body = String(data: data, encoding: .utf8) ?? ""
    XCTAssertEqual(process.terminationStatus, 0, body)
    return body
  }
}

private final class ReadyOutputBox: @unchecked Sendable {
  private let lock = NSLock()
  private var output = ""

  func store(_ value: String) {
    lock.withLock {
      output = value
    }
  }

  func load() -> String {
    lock.withLock { output }
  }
}
