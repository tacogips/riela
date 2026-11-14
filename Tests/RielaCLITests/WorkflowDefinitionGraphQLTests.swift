import Foundation
import XCTest
import RielaAdapters
import RielaCore
import RielaGraphQL
import RielaSQLite
@testable import RielaCLI

final class WorkflowDefinitionGraphQLTests: XCTestCase {
  func testImportPromptAuditHistoryAndSafeExportThroughCompositeExecutor() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let commandResultCapture = CLICommandResultCapture()
    var runCommand = WorkflowRunCommand()
    runCommand.taskNodeAdapterOverride = ScenarioNodeAdapter(scenario: WorkflowMockScenario(responses: [
      "worker": [
        MockNodeResponse(payload: ["ok": .bool(true)]),
        MockNodeResponse(payload: ["ok": .bool(true)])
      ]
    ]))
    var workflowExecutionProvider = WorkflowExecutionProvider(
      workingDirectory: fixture.root.path,
      sessionStoreRoot: fixture.store.path,
      environment: ["HOME": fixture.root.path],
      command: runCommand
    )
#if DEBUG
    workflowExecutionProvider.testCommandResultOverride = { result in
      commandResultCapture.record(result)
      return result
    }
#endif
    let executor = CompositeGraphQLDocumentExecutor(
      workflowRegistry: WorkflowRegistryGraphQLDocumentExecutor(),
      fallback: WorkflowExecutionGraphQLDocumentExecutor(
        provider: workflowExecutionProvider,
        next: WorkflowDefinitionGraphQLDocumentExecutor(
          provider: WorkflowDefinitionGraphQLProvider(
            workingDirectory: fixture.root.path,
            sessionStoreRoot: fixture.store.path,
            environment: ["HOME": fixture.root.path]
          )
        )
      )
    )

    let rejectedActor = await execute(executor, """
    mutation { importWorkflowDefinition(input: {workflowName: "w", workflowDefinitionDir: "\(fixture.workflow.path)", actorKind: "addon"}) { outcome } }
    """)
    XCTAssertEqual(errorCode(rejectedActor), "INVALID_DEFINITION_INPUT")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.path))

    let seeded = await execute(executor, """
    mutation { importWorkflowDefinition(input: {workflowName: "w", workflowDefinitionDir: "\(fixture.workflowRoot.path)", force: false}) { outcome version { versionId } } }
    """)
    XCTAssertNil(errorCode(seeded), String(describing: seeded.body))
    XCTAssertEqual(dataObject(seeded)?["importWorkflowDefinition"].flatMap(field("outcome")), .string("seeded"))
    let seedVersion = try XCTUnwrap(dataObject(seeded)?["importWorkflowDefinition"].flatMap(field("version"))?.flatMap(field("versionId")).flatMap(stringValue))
    let initialCounts = try rowCounts(store: fixture.store)

    let unchanged = await importDefinition(executor, fixture: fixture, force: false)
    XCTAssertEqual(dataObject(unchanged)?["importWorkflowDefinition"].flatMap(field("outcome")), .string("unchanged"))
    try "file changed".write(to: fixture.prompt, atomically: true, encoding: .utf8)
    let differs = await importDefinition(executor, fixture: fixture, force: false)
    XCTAssertEqual(dataObject(differs)?["importWorkflowDefinition"].flatMap(field("outcome")), .string("differs"))
    XCTAssertEqual(try rowCounts(store: fixture.store), initialCounts)

    let forceMissingReason = await importDefinition(executor, fixture: fixture, force: true)
    XCTAssertEqual(errorCode(forceMissingReason), "DEFINITION_REASON_REQUIRED")
    let restoreMissingReason = await execute(executor, "mutation { restoreWorkflowDefinition(input: {workflowName: \"w\", versionId: \"\(seedVersion)\"}) { version { versionId } } }")
    XCTAssertEqual(errorCode(restoreMissingReason), "DEFINITION_REASON_REQUIRED")
    let updateMissingReason = await execute(executor, "mutation { updateWorkflowDefinition(input: {workflowName: \"w\", patchJSON: \"[]\"}) { outcome } }")
    XCTAssertEqual(errorCode(updateMissingReason), "DEFINITION_REASON_REQUIRED")
    let noSource = await execute(executor, "mutation { updateWorkflowDefinition(input: {workflowName: \"w\", reason: \"r\"}) { outcome } }")
    XCTAssertEqual(errorCode(noSource), "INVALID_DEFINITION_INPUT")
    let bothSources = await execute(executor, """
    mutation {
      updateWorkflowDefinition(input: {
        workflowName: "w", patchJSON: "[]",
        authoredFiles: [{path: "prompts/a.md", content: "x"}], reason: "r"
      }) { outcome }
    }
    """)
    XCTAssertEqual(errorCode(bothSources), "INVALID_DEFINITION_INPUT")
    let disallowedActor = await execute(executor, "mutation { updateWorkflowDefinition(input: {workflowName: \"w\", patchJSON: \"[]\", reason: \"r\", actorKind: \"improvementNode\"}) { outcome } }")
    XCTAssertEqual(errorCode(disallowedActor), "INVALID_DEFINITION_INPUT")
    XCTAssertEqual(try rowCounts(store: fixture.store), initialCounts)

    let missingReason = await execute(executor, """
    mutation { updateWorkflowDefinitionPrompt(input: {workflowName: "w", nodeId: "worker", field: "promptTemplate", text: "ignored"}) { version { versionId } } }
    """)
    XCTAssertEqual(errorCode(missingReason), "DEFINITION_REASON_REQUIRED")
    XCTAssertEqual(try rowCounts(store: fixture.store), initialCounts)

    let promptUpdate = await execute(executor, """
    mutation {
      updateWorkflowDefinitionPrompt(input: {
        workflowName: "w", nodeId: "worker", field: "promptTemplate", text: "stored prompt",
        reason: "r", evidence: ["session:s1"], actorKind: "user"
      }) {
        version { versionId actor { kind } }
        audit { auditId reason evidence actor { kind } }
      }
    }
    """)
    XCTAssertNil(errorCode(promptUpdate), String(describing: promptUpdate.body))
    let audit = try XCTUnwrap(dataObject(promptUpdate)?["updateWorkflowDefinitionPrompt"].flatMap(field("audit")).flatMap(objectValue))
    XCTAssertEqual(audit["reason"], .string("r"))
    XCTAssertEqual(audit["actor"].flatMap(field("kind")), .string("user"))
    XCTAssertEqual(audit["evidence"], .array([.string("session:s1")]))
    let promptVersion = try XCTUnwrap(dataObject(promptUpdate)?["updateWorkflowDefinitionPrompt"].flatMap(field("version"))?.flatMap(field("versionId")).flatMap(stringValue))
    let promptAuditId = try XCTUnwrap(audit["auditId"].flatMap(stringValue))

    let history = await execute(executor, "{ workflowDefinitionHistory(workflowName: \"w\", nodeId: \"worker\") { auditId reason targetNodeId } }")
    XCTAssertNil(errorCode(history), String(describing: history.body))
    guard case let .array(records)? = dataObject(history)?["workflowDefinitionHistory"] else { return XCTFail("missing history") }
    XCTAssertEqual(records.first.flatMap(field("reason")), .string("r"))
    XCTAssertEqual(records.first.flatMap(field("targetNodeId")), .string("worker"))
    let diff = await execute(executor, "{ workflowDefinitionDiff(workflowName: \"w\", fromVersionId: \"\(seedVersion)\", toVersionId: \"\(promptVersion)\") { path } }")
    guard case let .array(diffEntries)? = dataObject(diff)?["workflowDefinitionDiff"] else { return XCTFail("missing diff") }
    XCTAssertTrue(diffEntries.contains { field("path")($0) == .string("/authoredFiles/prompts~1a.md") })

    let show = await execute(executor, "{ workflowDefinition(workflowName: \"w\") { versionId documentJSON } }")
    XCTAssertEqual(dataObject(show)?["workflowDefinition"].flatMap(field("versionId")), dataObject(promptUpdate)?["updateWorkflowDefinitionPrompt"].flatMap(field("version"))?.flatMap(field("versionId")))
    let shownDocument = try XCTUnwrap(dataObject(show)?["workflowDefinition"].flatMap(field("documentJSON")).flatMap(stringValue))

    let export = await execute(executor, "mutation { exportWorkflowDefinition(input: {workflowName: \"w\", writeToSource: false}) { wroteToSource files { path content } } }")
    XCTAssertNil(errorCode(export), String(describing: export.body))
    XCTAssertEqual(dataObject(export)?["exportWorkflowDefinition"].flatMap(field("wroteToSource")), .bool(false))
    XCTAssertEqual(try String(contentsOf: fixture.prompt, encoding: .utf8), "file changed")

    let promptValue = try XCTUnwrap(String(bytes: JSONEncoder().encode("patched prompt"), encoding: .utf8))
    let patchJSON = """
    [{"op":"replace","path":"/workflow.json/steps/0/transitions/0/toStepId","value":"finish"},
     {"op":"replace","path":"/workflow.json/steps/1/id","value":"finish"},
     {"op":"replace","path":"/prompts~1a.md","value":\(promptValue)}]
    """
    let patchMutation = """
    mutation($input: UpdateWorkflowDefinitionInput!) {
      updateWorkflowDefinition(input: $input) {
        outcome audit { operation reason actor { kind } evidence }
        version { documentJSON }
        diff { path after }
      }
    }
    """
    let patch = await execute(executor, patchMutation, variables: [
      "input": .object([
        "workflowName": .string("w"), "patchJSON": .string(patchJSON), "reason": .string("whole workflow"),
        "evidence": .array([.string("session:s1")])
      ])
    ])
    XCTAssertNil(errorCode(patch), String(describing: patch.body))
    XCTAssertEqual(dataObject(patch)?["updateWorkflowDefinition"].flatMap(field("outcome")), .string("updated"))
    let patchResult = try XCTUnwrap(dataObject(patch)?["updateWorkflowDefinition"].flatMap(objectValue))
    XCTAssertEqual(patchResult["audit"].flatMap(field("actor"))?.flatMap(field("kind")), .string("api"))
    let patchedDocument = try XCTUnwrap(patchResult["version"].flatMap(field("documentJSON")).flatMap(stringValue))
    XCTAssertTrue(patchedDocument.contains("finish"))
    guard case let .array(workflowDiff)? = patchResult["diff"] else { return XCTFail("missing whole-workflow diff") }
    XCTAssertTrue(workflowDiff.contains { field("path")($0) == .string("/authoredFiles/workflow.json") })

    let run = await execute(executor, "mutation { executeWorkflow(input: {workflowName: \"w\"}) { sessionId status } }")
    let commandResult = commandResultCapture.value
    XCTAssertNil(errorCode(run), "\(run.body); CLI stderr=\(commandResult?.stderr ?? ""); stdout=\(commandResult?.stdout ?? "")")
    let sessionId = try XCTUnwrap(dataObject(run)?["executeWorkflow"].flatMap(field("sessionId")).flatMap(stringValue))
    let persisted = try CLIWorkflowSessionStore(rootDirectory: fixture.store.path).loadStrictReadOnly(sessionId: sessionId)
    XCTAssertEqual(persisted.session.executions.first?.inputSnapshot?["promptText"]?.stringValue, "patched prompt")

    try "force source prompt".write(to: fixture.prompt, atomically: true, encoding: .utf8)
    let force = await importDefinition(executor, fixture: fixture, force: true, reason: "sync")
    XCTAssertNil(errorCode(force), String(describing: force.body))
    XCTAssertEqual(dataObject(force)?["importWorkflowDefinition"].flatMap(field("outcome")), .string("forceUpdated"))
    let forceAudit = try XCTUnwrap(dataObject(force)?["importWorkflowDefinition"].flatMap(field("audit")).flatMap(objectValue))
    let overwritten = try XCTUnwrap(forceAudit["overwrittenChanges"].flatMap(objectValue))
    guard case let .array(overwrittenAuditIds)? = overwritten["auditIds"] else { return XCTFail("missing overwritten audit ids") }
    XCTAssertTrue(overwrittenAuditIds.contains(.string(promptAuditId)))

    let restore = await execute(executor, "mutation { restoreWorkflowDefinition(input: {workflowName: \"w\", versionId: \"\(promptVersion)\", reason: \"restore prompt\"}) { version { documentJSON } } }")
    XCTAssertNil(errorCode(restore), String(describing: restore.body))
    let restoredDocument = dataObject(restore)?["restoreWorkflowDefinition"].flatMap(field("version"))?.flatMap(field("documentJSON"))
    XCTAssertEqual(restoredDocument, .string(shownDocument))

    let exportToSource = await execute(executor, "mutation { exportWorkflowDefinition(input: {workflowName: \"w\", writeToSource: true}) { wroteToSource } }")
    XCTAssertEqual(dataObject(exportToSource)?["exportWorkflowDefinition"].flatMap(field("wroteToSource")), .bool(true))
    XCTAssertEqual(try String(contentsOf: fixture.prompt, encoding: .utf8), "stored prompt")
    let unchangedAfterExport = await importDefinition(executor, fixture: fixture, force: false)
    XCTAssertEqual(dataObject(unchangedAfterExport)?["importWorkflowDefinition"].flatMap(field("outcome")), .string("unchanged"))

    let authoredFiles: [JSONValue] = [
      .object(["path": .string("workflow.json"), "content": .string(try String(contentsOf: fixture.workflow, encoding: .utf8))]),
      .object(["path": .string("nodes/worker.json"), "content": .string(try String(contentsOf: fixture.workflow.deletingLastPathComponent().appendingPathComponent("nodes/worker.json"), encoding: .utf8))]),
      .object(["path": .string("prompts/a.md"), "content": .string("authored file update")])
    ]
    let authored = await execute(executor, "mutation($input: UpdateWorkflowDefinitionInput!) { updateWorkflowDefinition(input: $input) { outcome } }", variables: [
      "input": .object(["workflowName": .string("w"), "authoredFiles": .array(authoredFiles), "reason": .string("authored edit"), "actorKind": .string("user")])
    ])
    XCTAssertNil(errorCode(authored), String(describing: authored.body))
    XCTAssertEqual(dataObject(authored)?["updateWorkflowDefinition"].flatMap(field("outcome")), .string("updated"))

    let stale = await execute(executor, """
    mutation { updateWorkflowDefinition(input: {workflowName: "w", patchJSON: "[]", reason: "stale", expectedVersionId: "\(seedVersion)"}) { outcome } }
    """)
    XCTAssertEqual(errorCode(stale), "DEFINITION_STALE")
  }

  private struct Fixture {
    var root: URL
    var workflowRoot: URL
    var workflow: URL
    var prompt: URL
    var store: URL
  }

  private func makeFixture() throws -> Fixture {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/ds179/graphql-definition-\(UUID().uuidString)", isDirectory: true)
    let workflowRoot = root.appendingPathComponent("workflows", isDirectory: true)
    let workflow = workflowRoot.appendingPathComponent("w", isDirectory: true)
    let nodes = workflow.appendingPathComponent("nodes", isDirectory: true)
    let prompts = workflow.appendingPathComponent("prompts", isDirectory: true)
    let store = root.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: nodes, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
    let workflowJSON = #"""
    {"workflowId":"w","defaults":{"maxLoopIterations":1,"nodeTimeoutMs":30000},
     "entryStepId":"work","nodeRegistry":[{"id":"worker","nodeFile":"nodes/worker.json"}],
     "steps":[{"id":"work","nodeId":"worker","role":"worker","transitions":[{"toStepId":"end"}]},
               {"id":"end","nodeId":"worker","role":"worker"}],
     "nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}]}
    """#
    try workflowJSON
      .write(to: workflow.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try #"{"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"test-model","promptTemplateFile":"prompts/a.md","variables":{}}"#
      .write(to: nodes.appendingPathComponent("worker.json"), atomically: true, encoding: .utf8)
    let prompt = prompts.appendingPathComponent("a.md")
    try "original prompt".write(to: prompt, atomically: true, encoding: .utf8)
    return Fixture(root: root, workflowRoot: workflowRoot, workflow: workflow.appendingPathComponent("workflow.json"), prompt: prompt, store: store)
  }

  private func execute(_ executor: any GraphQLDocumentExecuting, _ query: String, variables: JSONObject = [:]) async -> GraphQLDocumentExecutionResponse {
    await executor.execute(GraphQLDocumentRequest(query: query, variables: variables, operationName: nil,
      environment: [:], isLocallyTrusted: true, localWorkingDirectory: FileManager.default.currentDirectoryPath))
  }

  private func importDefinition(_ executor: any GraphQLDocumentExecuting, fixture: Fixture, force: Bool, reason: String? = nil) async -> GraphQLDocumentExecutionResponse {
    let reasonArgument = reason.map { ", reason: \"\($0)\"" } ?? ""
    return await execute(executor, """
    mutation {
      importWorkflowDefinition(input: {
        workflowName: "w", workflowDefinitionDir: "\(fixture.workflowRoot.path)",
        force: \(force)\(reasonArgument)
      }) {
        outcome audit { overwrittenChanges { auditIds } }
      }
    }
    """)
  }

  private func errorCode(_ response: GraphQLDocumentExecutionResponse) -> String? {
    guard case let .array(errors)? = response.body["errors"],
          case let .object(error)? = errors.first,
          case let .object(extensions)? = error["extensions"],
          case let .string(code)? = extensions["code"] else { return nil }
    return code
  }

  private func dataObject(_ response: GraphQLDocumentExecutionResponse) -> JSONObject? {
    guard case let .object(data)? = response.body["data"] else { return nil }; return data
  }
  private func field(_ key: String) -> (JSONValue) -> JSONValue? {
    { value in guard case let .object(object) = value else { return nil }; return object[key] }
  }
  private func objectValue(_ value: JSONValue) -> JSONObject? { guard case let .object(object) = value else { return nil }; return object }
  private func stringValue(_ value: JSONValue) -> String? { guard case let .string(text) = value else { return nil }; return text }

  private func rowCounts(store: URL) throws -> [Int] {
    let database = try SQLiteDatabase.open(
      path: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(rootDirectory: store.path),
      mode: .strictReadOnly, options: .readOnlyDefault
    )
    return try ["definition_blobs", "definition_versions", "definition_heads", "definition_change_audit"].map { table in
      Int(try XCTUnwrap(database.query("SELECT COUNT(*) AS count FROM \(table)").first?["count"])) ?? -1
    }
  }
}

private final class CLICommandResultCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var result: CLICommandResult?

  var value: CLICommandResult? {
    lock.lock()
    defer { lock.unlock() }
    return result
  }

  func record(_ newValue: CLICommandResult) {
    lock.lock()
    defer { lock.unlock() }
    result = newValue
  }
}
