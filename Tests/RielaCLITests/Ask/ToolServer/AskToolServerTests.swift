import Foundation
import RielaCore
import RielaWorkflowRegistry
import XCTest
@testable import RielaCLI

@MainActor
final class AskToolServerTests: XCTestCase {
  func testStdioNegotiatesListsAndCallsTools() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    let requests = [
      try request(1, method: "initialize", params: ["protocolVersion": .string("2024-11-05")]),
      #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
      try request(2, method: "tools/list"),
      try call(3, name: "session_status", arguments: ["sessionId": .string(fixture.session.sessionId)]),
      try call(4, name: "missing_tool"),
      try request(5, method: "removed"),
      #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":[]}"#
    ]
    let process = try launch(requests, fixture: fixture, run: run)
    XCTAssertEqual(process.status, 0, process.stderr)
    XCTAssertTrue(process.stderr.isEmpty, process.stderr)
    let replies = try responses(process.stdout)
    guard replies.count == 6 else { return XCTFail("Expected six responses: \(process.stdout)") }
    XCTAssertEqual(replies.compactMap { $0["id"] }, (1...6).map { .integer(Int64($0)) })
    XCTAssertTrue(replies.allSatisfy { $0["jsonrpc"] == .string("2.0") })
    let initialization = try object(replies[0]["result"])
    XCTAssertEqual(initialization["protocolVersion"], .string("2024-11-05"))
    XCTAssertEqual(initialization["capabilities"], .object(["tools": .object([:])]))
    XCTAssertEqual(initialization["serverInfo"], .object([
      "name": .string("riela-ask"), "version": .string(rielaSwiftMigrationVersion)
    ]))

    let listing = try object(replies[1]["result"])
    let tools = try array(listing["tools"]).map { try object($0) }
    XCTAssertEqual(tools.count, 17)
    XCTAssertEqual(tools.compactMap { $0["name"] }, AskToolSet.all.map { .string($0.name) })
    for tool in tools {
      let schema = try object(tool["inputSchema"])
      XCTAssertEqual(schema["type"], .string("object"))
      XCTAssertEqual(schema["additionalProperties"], .bool(false))
    }
    let status = try XCTUnwrap(tools.first { $0["name"] == .string("session_status") })
    let schema = try object(status["inputSchema"])
    XCTAssertEqual(schema["required"], .array([.string("sessionId")]))
    XCTAssertEqual(schema["properties"], .object(["sessionId": .object(["type": .string("string")])]))
    XCTAssertTrue(try toolResult(replies[2]).ok)
    XCTAssertEqual(try toolResult(replies[3]).error?.code, "tool_unknown")
    XCTAssertEqual(try object(replies[4]["error"])["code"], .integer(-32601))
    XCTAssertEqual(try object(replies[5]["error"])["code"], .integer(-32600))

    let events = try fixture.store.activityPage(sessionId: AskActivityKey.sessionId(run.conversationId)).events
      .filter { $0.kind == .toolCall }
    XCTAssertEqual(events.map { $0.payload["status"] }, [.string("inProgress"), .string("completed")])
    XCTAssertEqual(events.map { $0.payload["title"] }, [.string("session_status"), .string("session_status")])
    let identifier = try XCTUnwrap(events.first?.payload["toolCallId"])
    XCTAssertEqual(events.last?.payload["toolCallId"], identifier)
    let stored = try fixture.store.askConversation(id: run.conversationId)
    XCTAssertTrue(stored?.knownRefs?.contains(.init(kind: .session, id: fixture.session.sessionId)) == true)
  }

  func testToolBudgetIsSharedWithHostExecutor() async throws {
    let fixture = try await AskToolFixture(test: self)
    var limits = AskLimits.standard
    limits.toolCallsPerTurn = 1
    let run = try await fixture.makeExecutor(limits: limits)
    let arguments: JSONObject = ["sessionId": .string(fixture.session.sessionId)]
    let first = await run.executor.execute(
      conversationId: run.conversationId, turnId: run.turnId, toolCallId: "in-process",
      name: "session_status", arguments: arguments
    )
    XCTAssertTrue(first.ok)

    var requests = [try call(1, name: "session_status", arguments: arguments)].makeIterator()
    var output = Data()
    try await AskToolServer.run(
      options: AskToolServerArguments.parseCLI(flags(fixture, run: run)),
      environment: subprocessEnvironment(fixture), limits: limits,
      nextLine: { requests.next() }, write: { output.append($0) }
    )
    let raw = try XCTUnwrap(String(data: output, encoding: .utf8))
    let reply = try XCTUnwrap(responses(raw).first)
    XCTAssertEqual(try toolResult(reply).error?.code, "budget_exceeded")
    XCTAssertEqual(try fixture.store.askConversation(id: run.conversationId)?.usage.toolCalls, 1)
  }

  func testStdioUsesHostRegistryRootAndScope() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    let source = fixture.root.appendingPathComponent(".riela/workflows/\(AskToolFixture.workflowId)")
    let bundle = fixture.root.appendingPathComponent("host-workflow")
    try FileManager.default.copyItem(at: source, to: bundle)
    let manifest = bundle.appendingPathComponent("workflow.json")
    var definition = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: manifest))
    definition["workflowId"] = .string("host-workflow")
    try JSONEncoder().encode(definition).write(to: manifest)
    _ = try CLIRuntimeEnvironment.$captured.withValue(fixture.environment) {
      try WorkflowRegistryService().register(input: bundle, overwrite: false, workingDirectory: fixture.root.path)
    }
    let process = try launch([call(1, name: "workflow_list")], fixture: fixture, run: run, options: ["--scope", "user"])
    XCTAssertEqual(process.status, 0, process.stderr)
    let result = try toolResult(XCTUnwrap(responses(process.stdout).first))
    XCTAssertTrue(result.ok, String(describing: result.error))
    XCTAssertEqual(result.refs, [.init(kind: .workflow, id: "host-workflow")])
  }

  func testStdioRedactsSecretFromFileLikeHostExecutor() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    let secret = AskToolFixture.environmentSecret
    let runtime = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: fixture.store.sessionStoreRoot)
    var snapshot = try runtime.load(sessionId: fixture.session.sessionId)
    let index = try XCTUnwrap(snapshot.session.executions.indices.last)
    // Use an unlabelled value so the generic credential regex cannot mask a missing host binding.
    snapshot.session.executions[index].failureReason = "Log marker [\(secret)]"
    try runtime.save(snapshot)
    let file = fixture.root.appendingPathComponent("values.json")
    let values = try JSONEncoder().encode([secret: "TEST_API_TOKEN"])
    XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: values, attributes: [.posixPermissions: 0o600]))
    let arguments: JSONObject = ["sessionId": .string(fixture.session.sessionId)]
    let hostResult = await run.executor.execute(
      conversationId: run.conversationId, turnId: run.turnId, toolCallId: "in-process",
      name: "session_logs", arguments: arguments
    )
    XCTAssertTrue(hostResult.ok)
    let process = try launch(
      [call(1, name: "session_logs", arguments: arguments)], fixture: fixture, run: run,
      options: ["--redaction-values", file.path]
    )
    XCTAssertEqual(process.status, 0, process.stderr)
    XCTAssertFalse(process.stdout.contains(secret))
    XCTAssertFalse(process.stderr.contains(secret))
    XCTAssertTrue(process.stdout.contains("<redacted:TEST_API_TOKEN>"))
    XCTAssertEqual(try toolResult(XCTUnwrap(responses(process.stdout).first)), hostResult)
  }

  func testStdioStartupRejectsNonRunningTurn() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    try fixture.store.finishAskTurn(conversationId: run.conversationId, turnId: run.turnId, status: .cancelled)
    let process = try launch([request(1, method: "tools/list")], fixture: fixture, run: run)
    XCTAssertNotEqual(process.status, 0)
    XCTAssertTrue(process.stderr.contains("turn_not_running"), process.stderr)
    XCTAssertTrue(process.stdout.isEmpty, process.stdout)
  }

  func testStdioStartupRejectsMissingRedactionValues() async throws {
    let fixture = try await AskToolFixture(test: self)
    let run = try await fixture.makeExecutor()
    let process = try launch(
      [request(1, method: "tools/list")], fixture: fixture, run: run,
      options: ["--redaction-values", fixture.root.appendingPathComponent("absent.json").path]
    )
    XCTAssertNotEqual(process.status, 0)
    XCTAssertTrue(process.stderr.contains("redaction_values_unavailable"), process.stderr)
    XCTAssertTrue(process.stdout.isEmpty, process.stdout)
  }

  private func launch(
    _ lines: [String], fixture: AskToolFixture, run: AskToolFixture.RunningTurn, options: [String] = []
  ) throws -> CapturedWorkflowTestProcess {
    #if os(Linux)
    let products = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    #else
    let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
    #endif
    let executable = products.appendingPathComponent("riela").resolvingSymlinksInPath()
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), executable.path)
    let outURL = fixture.root.appendingPathComponent("stdio-\(UUID()).stdout")
    let errURL = fixture.root.appendingPathComponent("stdio-\(UUID()).stderr")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let stdout = try FileHandle(forWritingTo: outURL)
    let stderr = try FileHandle(forWritingTo: errURL)
    defer { try? stdout.close(); try? stderr.close() }
    let stdin = Pipe()
    let input = Data((lines.joined(separator: "\n") + "\n").utf8)
    // Small request batches fit in the pipe buffer before starting the child.
    try stdin.fileHandleForWriting.write(contentsOf: input)
    try stdin.fileHandleForWriting.close()
    let process = Process()
    process.executableURL = executable
    process.arguments = ["ask", "tool-server"] + flags(fixture, run: run) + options
    process.currentDirectoryURL = fixture.root
    process.environment = subprocessEnvironment(fixture)
    process.standardInput = stdin.fileHandleForReading
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    try WorkflowSubprocessTestSupport.waitForExit(process)
    return .init(
      status: process.terminationStatus, terminationReason: process.terminationReason,
      stdout: try String(contentsOf: outURL, encoding: .utf8), stderr: try String(contentsOf: errURL, encoding: .utf8)
    )
  }

  private func flags(_ fixture: AskToolFixture, run: AskToolFixture.RunningTurn) -> [String] {
    [
      "--session-store", fixture.sessions, "--working-dir", fixture.root.path,
      "--conversation", run.conversationId, "--turn", run.turnId
    ]
  }

  private func subprocessEnvironment(_ fixture: AskToolFixture) -> [String: String] {
    var environment = fixture.environment
    environment.removeValue(forKey: "TEST_API_TOKEN")
    return environment
  }

  private func request(_ id: Int64, method: String, params: JSONObject? = nil) throws -> String {
    var request: JSONObject = ["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string(method)]
    request["params"] = params.map(JSONValue.object)
    return try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
  }

  private func call(_ id: Int64, name: String, arguments: JSONObject = [:]) throws -> String {
    try request(id, method: "tools/call", params: ["name": .string(name), "arguments": .object(arguments)])
  }

  private func responses(_ output: String) throws -> [JSONObject] {
    try output.split(separator: "\n").map { try JSONDecoder().decode(JSONObject.self, from: Data($0.utf8)) }
  }

  private func toolResult(_ reply: JSONObject) throws -> AskToolResult {
    let body = try object(reply["result"])
    let content = try array(body["content"])
    XCTAssertEqual(content.count, 1)
    let item = try object(content.first)
    XCTAssertEqual(item["type"], .string("text"))
    let text: String? = if case let .string(body)? = item["text"] { body } else { nil }
    let result = try JSONDecoder().decode(AskToolResult.self, from: Data(XCTUnwrap(text, "Expected a text content item").utf8))
    XCTAssertEqual(body["isError"], .bool(!result.ok))
    return result
  }

  private func object(_ value: JSONValue?) throws -> JSONObject {
    let object: JSONObject? = if case let .object(object)? = value { object } else { nil }
    return try XCTUnwrap(object, "Expected a JSON object, found \(String(describing: value))")
  }

  private func array(_ value: JSONValue?) throws -> [JSONValue] {
    let array: [JSONValue]? = if case let .array(array)? = value { array } else { nil }
    return try XCTUnwrap(array, "Expected a JSON array, found \(String(describing: value))")
  }
}
