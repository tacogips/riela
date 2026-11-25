import Foundation
import RielaAdapters
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

final class BotRunLinkageTests: XCTestCase {
  func testLocalMockRunLinksBotAndOmittingBotLeavesOutputShapeUnchanged() async throws {
    let fixture = try makeFixture()
    try fixture.createBot()
    let linked = await run(fixture, arguments: ["--output", "json", "--bot", "b1"])
    XCTAssertEqual(linked.exitCode, .success, linked.stderr + linked.stdout)
    let linkedSessionID = try decodeRun(linked).session.sessionId
    let links = try fixture.bots.links(botId: "b1")
    XCTAssertEqual(links.map(\.sessionId), [linkedSessionID])
    XCTAssertEqual(links.first?.source, "run")
    XCTAssertNil(links.first?.sourceRef)

    let unlinked = await run(fixture, arguments: ["--output", "json"])
    XCTAssertEqual(unlinked.exitCode, .success, unlinked.stderr + unlinked.stdout)
    let unlinkedSessionID = try decodeRun(unlinked).session.sessionId
    XCTAssertNotEqual(unlinkedSessionID, linkedSessionID)
    XCTAssertNil(try fixture.bots.link(forSession: unlinkedSessionID))
    XCTAssertEqual(try fixture.bots.links(botId: "b1"), links)
    XCTAssertEqual(try outputKeys(linked), try outputKeys(unlinked))
  }

  func testLocalMissingAndPausedBotsRejectBeforeSessionCreation() async throws {
    let fixture = try makeFixture()
    try fixture.createBot(paused: true)
    for (id, code) in [("missing", "bot_not_found"), ("b1", "bot_paused")] {
      let result = await run(fixture, arguments: ["--bot", id])
      XCTAssertNotEqual(result.exitCode, .success)
      XCTAssertTrue(result.stderr.contains("\(code): \(id)"), result.stderr)
      XCTAssertTrue(try fixture.sessions.list().isEmpty)
      XCTAssertTrue(try fixture.bots.links(botId: id).isEmpty)
    }
  }

  func testCrossWorkflowRunLinksOnlyTheRootSession() async throws {
    let fixture = try makeFixture()
    try fixture.createBot()
    let result = await RielaCLIApplication().run([
      "workflow", "run", "workflow-call-live-echo",
      "--workflow-definition-dir", fixture.examples.path,
      "--working-dir", fixture.root.path,
      "--session-store", fixture.store.path,
      "--artifact-root", fixture.artifacts.path,
      "--output", "json", "--bot", "b1"
    ], environment: fixture.environment)
    XCTAssertEqual(result.exitCode, .success, result.stderr + result.stdout)
    let session = try decodeRun(result).session
    let persistence = SQLiteWorkflowRuntimePersistenceStore(rootDirectory: fixture.bots.sessionStoreRoot)
    let sourceID = try XCTUnwrap(session.executions.first { $0.stepId == "produce-request" }?.executionId)
    let child = try XCTUnwrap(try persistence.nestedInvocationRecord(
      parentSessionId: session.sessionId, sourceStepExecutionId: sourceID, branchId: "cross-workflow"
    ).flatMap(\.childTerminalSnapshot))
    XCTAssertNotEqual(child.session.sessionId, session.sessionId)
    XCTAssertNil(try fixture.bots.link(forSession: child.session.sessionId))
    XCTAssertEqual(try fixture.bots.links(botId: "b1").map(\.sessionId), [session.sessionId])
  }

  func testEndpointForwardsBotWithoutLocalLookupOrSessionWrite() async throws {
    let fixture = try makeFixture()
    let transport = RecordingWorkflowGraphQLRunTransport()
    let app = RielaCLIApplication(runCommand: WorkflowRunCommand(graphQLTransport: transport))
    let arguments = [
      "workflow", "run", "w", "--endpoint", "http://127.0.0.1:1/graphql",
      "--working-dir", fixture.root.path, "--session-store", fixture.store.path
    ]
    let withBot = await app.run(arguments + ["--bot", "b1"], environment: fixture.environment)
    XCTAssertEqual(withBot.exitCode, .success, withBot.stderr)
    let recorded = await transport.recordedRequest()
    XCTAssertEqual(try XCTUnwrap(recorded).botId, "b1")
    XCTAssertNil(try fixture.bots.load(botId: "b1"))
    XCTAssertTrue(try fixture.bots.links(botId: "b1").isEmpty)
    XCTAssertTrue(try fixture.sessions.list().isEmpty)

    let withoutBot = await app.run(arguments, environment: fixture.environment)
    XCTAssertEqual(withoutBot.exitCode, .success, withoutBot.stderr)
    let untagged = await transport.recordedRequest()
    XCTAssertNil(try XCTUnwrap(untagged).botId)
    XCTAssertEqual(remoteRunInputObject(WorkflowRemoteRunRequest(workflowName: "w", botId: "b1"))["botId"], .string("b1"))
    XCTAssertNil(remoteRunInputObject(WorkflowRemoteRunRequest(workflowName: "w"))["botId"])
  }

  func testGraphQLExecutorRejectsInvalidBotInputsBeforeProviderExecution() async {
    let provider = RejectingBotWorkflowProvider(error: DeliberateWorkflowFailure.failed)
    let executor = WorkflowExecutionGraphQLDocumentExecutor(provider: provider)
    for literal in [#""""#, #""  ""#, "5"] {
      let response = await execute(executor, botLiteral: literal)
      XCTAssertEqual(errorFields(response)?.code, "INVALID_EXECUTION_INPUT", "\(response.body)")
    }
    let calls = await provider.executionCount
    XCTAssertEqual(calls, 0)
  }

  func testGraphQLExecutorProjectsTypedRejectionsAndMasksGenericFailures() async {
    let cases: [(any Error, (code: String, message: String))] = [
      (GraphQLWorkflowExecutionRejection(code: "BOT_PAUSED", message: "bot_paused: b1"), ("BOT_PAUSED", "bot_paused: b1")),
      (DeliberateWorkflowFailure.failed, ("WORKFLOW_EXECUTION_FAILED", "workflow execution failed"))
    ]
    for (error, expected) in cases {
      let provider = RejectingBotWorkflowProvider(error: error)
      let response = await execute(WorkflowExecutionGraphQLDocumentExecutor(provider: provider), botLiteral: #""b1""#)
      XCTAssertEqual(errorFields(response)?.code, expected.code, "\(response.body)")
      XCTAssertEqual(errorFields(response)?.message, expected.message, "\(response.body)")
      let calls = await provider.executionCount
      XCTAssertEqual(calls, 1)
    }
  }

  func testGraphQLProviderRejectsMissingAndPausedBotsWithoutCreatingSessions() async throws {
    let fixture = try makeFixture()
    try fixture.createBot(paused: true)
    let provider = fixture.executionProvider()
    let cases = [
      ("missing", GraphQLWorkflowExecutionRejection(code: "BOT_NOT_FOUND", message: "bot_not_found: missing")),
      ("b1", GraphQLWorkflowExecutionRejection(code: "BOT_PAUSED", message: "bot_paused: b1"))
    ]
    for (id, expected) in cases {
      do {
        _ = try await provider.executeWorkflow(GraphQLExecuteWorkflowInput(workflowName: fixture.workflowName, botId: id))
        XCTFail("Expected \(expected.code)")
      } catch let rejection as GraphQLWorkflowExecutionRejection {
        XCTAssertEqual(rejection, expected)
      }
      XCTAssertTrue(try fixture.sessions.list().isEmpty)
      XCTAssertTrue(try fixture.bots.links(botId: id).isEmpty)
    }
  }

  func testGraphQLExecutorRunsWithBotAndPersistsLinkInSelectedStore() async throws {
    let fixture = try makeFixture()
    try fixture.createBot()
    var runCommand = WorkflowRunCommand()
    runCommand.taskNodeAdapterOverride = ScenarioNodeAdapter(
      scenario: try WorkflowMockScenarioLoader().loadScenario(at: fixture.scenario.path),
      requiresScenarioResponse: true
    )
    let executor = WorkflowExecutionGraphQLDocumentExecutor(provider: fixture.executionProvider(command: runCommand))
    let response = await execute(executor, workflow: fixture.workflowName, botLiteral: #""b1""#)
    XCTAssertNil(response.body["errors"], "\(response.body)")
    guard case let .object(data)? = response.body["data"],
          case let .object(payload)? = data["executeWorkflow"],
          case let .string(sessionID)? = payload["sessionId"] else {
      return XCTFail("Missing execution session: \(response.body)")
    }
    XCTAssertEqual(payload["status"], .string("completed"))
    let links = try fixture.bots.links(botId: "b1")
    XCTAssertEqual(links.map(\.sessionId), [sessionID])
    XCTAssertEqual(links.first?.source, "run")
    XCTAssertNil(links.first?.sourceRef)
  }

  func testEndpointErrorMessageExposesOnlyNonemptyKnownBotErrors() {
    let fallback = "remote run returned GraphQL errors"
    XCTAssertEqual(remoteRunGraphQLErrorMessage([graphQLError(code: "BOT_NOT_FOUND", message: "bot_not_found: b1")]), "bot_not_found: b1")
    XCTAssertEqual(remoteRunGraphQLErrorMessage([graphQLError(code: "BOT_PAUSED", message: "bot_paused: b1")]), "bot_paused: b1")
    for errors in [
      [],
      [.null],
      [graphQLError(code: "WORKFLOW_EXECUTION_FAILED", message: "private failure")],
      [graphQLError(code: "BOT_NOT_FOUND", message: nil)],
      [graphQLError(code: "BOT_PAUSED", message: "")]
    ] {
      XCTAssertEqual(remoteRunGraphQLErrorMessage(errors), fallback)
    }
  }

  private func execute(
    _ executor: WorkflowExecutionGraphQLDocumentExecutor, workflow: String = "w", botLiteral: String
  ) async -> GraphQLDocumentExecutionResponse {
    await executor.execute(GraphQLDocumentRequest(
      query: "mutation { executeWorkflow(input: {workflowName: \"\(workflow)\", botId: \(botLiteral)}) { status sessionId } }",
      environment: [:],
      isLocallyTrusted: true
    ))
  }

  private func errorFields(_ response: GraphQLDocumentExecutionResponse) -> (code: String, message: String)? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"],
          case let .string(message)? = error["message"] else {
      return nil
    }
    return (code, message)
  }

  private func graphQLError(code: String, message: String?) -> JSONValue {
    var error: JSONObject = ["extensions": .object(["code": .string(code)])]
    error["message"] = message.map(JSONValue.string)
    return .object(error)
  }

  private func run(_ fixture: BotRunFixture, arguments: [String]) async -> CLICommandResult {
    await RielaCLIApplication().run([
      "workflow", "run", fixture.workflowName,
      "--working-dir", fixture.root.path,
      "--session-store", fixture.store.path,
      "--artifact-root", fixture.artifacts.path,
      "--mock-scenario", fixture.scenario.path
    ] + arguments, environment: fixture.environment)
  }

  private func decodeRun(_ result: CLICommandResult) throws -> WorkflowRunResult {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(WorkflowRunResult.self, from: Data(result.stdout.utf8))
  }

  private func outputKeys(_ result: CLICommandResult) throws -> Set<String> {
    let fields = try JSONDecoder().decode(JSONObject.self, from: Data(result.stdout.utf8))
    return Set(fields.keys)
  }

  private func makeFixture() throws -> BotRunFixture {
    let repository = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/bots-overview/bots-09-run-linkage/run-\(UUID().uuidString)")
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    let fixture = BotRunFixture(root: root, examples: repository.appendingPathComponent("examples"))
    let workflows = root.appendingPathComponent(".riela/workflows", isDirectory: true)
    try FileManager.default.createDirectory(at: workflows, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: fixture.examples.appendingPathComponent(fixture.workflowName),
      to: workflows.appendingPathComponent(fixture.workflowName)
    )
    return fixture
  }
}

private struct BotRunFixture {
  let root: URL
  let examples: URL
  let workflowName = "worker-only-single-step"

  var store: URL { root.appendingPathComponent("sessions") }
  var artifacts: URL { root.appendingPathComponent("artifacts") }
  var scenario: URL { root.appendingPathComponent(".riela/workflows/\(workflowName)/mock-scenario.json") }
  var bots: BotStore { BotStore(sessionStoreRoot: canonicalRuntimeStoreRoot(sessionStoreRoot: store.path)) }
  var sessions: CLIWorkflowSessionStore { CLIWorkflowSessionStore(rootDirectory: store.path) }
  var environment: [String: String] {
    [
      "HOME": root.path,
      "RIELA_WORKFLOW_HOME": root.appendingPathComponent("user-riela").path,
      "XDG_STATE_HOME": root.appendingPathComponent("user-state").path,
      "RIELA_API_KEY": "",
      "RIELA_MANAGER_SESSION_ID": ""
    ]
  }

  func createBot(paused: Bool = false) throws {
    let timestamp = "2026-01-01T00:00:00Z"
    try bots.create(BotRecord(botId: "b1", name: "Fixture bot", paused: paused, createdAt: timestamp, updatedAt: timestamp))
  }

  func executionProvider(command: WorkflowRunCommand = WorkflowRunCommand()) -> WorkflowExecutionProvider {
    WorkflowExecutionProvider(
      workingDirectory: root.path, sessionStoreRoot: store.path, environment: environment, command: command
    )
  }
}

private enum DeliberateWorkflowFailure: Error {
  case failed
}

private actor RejectingBotWorkflowProvider: WorkflowExecutionGraphQLProviding {
  let error: any Error
  private(set) var executionCount = 0

  init(error: any Error) {
    self.error = error
  }

  func executeWorkflow(_ input: GraphQLExecuteWorkflowInput) async throws -> GraphQLExecuteWorkflowPayload {
    executionCount += 1
    throw error
  }

  func workflowExecution(workflowExecutionId: String) async throws -> GraphQLWorkflowExecutionSummary? {
    nil
  }
}
