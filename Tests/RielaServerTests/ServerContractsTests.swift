import Foundation
import RielaGraphQL
import RielaNote
import RielaObservability
import XCTest
@testable import RielaCore
@testable import RielaServer

final class ServerContractsTests: XCTestCase {
  func testServerConfigurationDefaultsKeepNoteAPIDisabledOnLocalhost() {
    let configuration = RielaServerConfiguration()

    XCTAssertEqual(configuration.host, "127.0.0.1")
    XCTAssertEqual(configuration.port, 8787)
    XCTAssertFalse(configuration.noteAPIEnabled)
    XCTAssertNil(configuration.noteRoot)
  }

  func testWorkflowServeStartRequestEncodesRuntimeConfigurationAsSinglePayload() throws {
    let request = WorkflowServeStartRequest(
      selection: .directDirectory("/workflows/demo", identifier: "demo"),
      workingDirectory: "/project",
      inheritedEnvironment: ["TOKEN": "value"],
      defaultVariables: ["persona": .string("assistant-a")],
      nodePatch: ["worker": .object(["model": .string("gpt-5-mini")])]
    )

    let data = try JSONEncoder().encode(request)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let configuration = try XCTUnwrap(object["configuration"] as? [String: Any])

    XCTAssertNil(object["workingDirectory"])
    XCTAssertNil(object["inheritedEnvironment"])
    XCTAssertNil(object["defaultVariables"])
    XCTAssertNil(object["nodePatch"])
    XCTAssertEqual(configuration["workingDirectory"] as? String, "/project")
    XCTAssertNotNil(configuration["inheritedEnvironment"])
    XCTAssertNotNil(configuration["defaultVariables"])
    XCTAssertNotNil(configuration["nodePatch"])
  }

  func testWorkflowServeStartRequestDecodesLegacyRuntimeFields() throws {
    let data = Data("""
    {
      "selection": {"kind": "direct-directory", "identifier": "demo", "path": "/workflows/demo"},
      "workingDirectory": "/legacy-project",
      "inheritedEnvironment": {"TOKEN": "value"},
      "defaultVariables": {"persona": "assistant-a"},
      "nodePatch": {"worker": {"model": "gpt-5-mini"}},
      "startsEventSources": true
    }
    """.utf8)

    let request = try JSONDecoder().decode(WorkflowServeStartRequest.self, from: data)

    XCTAssertEqual(request.workingDirectory, "/legacy-project")
    XCTAssertEqual(request.inheritedEnvironment["TOKEN"], "value")
    XCTAssertEqual(request.defaultVariables["persona"], .string("assistant-a"))
    XCTAssertEqual(request.nodePatch?["worker"], .object(["model": .string("gpt-5-mini")]))
  }

  func testWorkflowServeStartRequestDecodesLegacyPartialServerObject() throws {
    let data = Data("""
    {
      "selection": {"kind": "scoped-name", "identifier": "demo", "scope": "auto"},
      "server": {
        "host": "0.0.0.0"
      }
    }
    """.utf8)

    let request = try JSONDecoder().decode(WorkflowServeStartRequest.self, from: data)

    XCTAssertEqual(request.server.host, "0.0.0.0")
    XCTAssertEqual(request.server.port, 8787)
    XCTAssertFalse(request.server.noteAPIEnabled)
    XCTAssertNil(request.server.noteRoot)
    XCTAssertEqual(request.server.noteS3Profiles, [])
  }

  func testGraphQLRouteValidatesEnvelopeAndPropagatesContext() async throws {
    let body = Data(#"{"query":"  query Test { workflowSession }  ","variables":null,"operationName":"  Test  "}"#.utf8)
    let request = ServerRequestEnvelope(
      method: "POST",
      path: "/graphql",
      headers: [
        "Authorization": "Bearer token-1",
        "X-Riela-Manager-Session-Id": "manager-session"
      ],
      body: body
    )
    let context = ServerRequestContext(inheritedEnvironment: [
      "KEEP": "1",
      "RIELA_MANAGER_EXECUTION_ID": "exec-1",
      "RIELA_MANAGER_SESSION_ID": "manager-session",
      "RIELA_WORKFLOW_ID": "workflow-a",
      "RIELA_WORKFLOW_EXECUTION_ID": "session-a"
    ])

    let response = await DeterministicServerRouteHandler().route(request, context: context)

    XCTAssertEqual(response.status, 200)
    guard case let .object(graphql)? = response.body["graphql"] else {
      return XCTFail("expected graphql body")
    }
    XCTAssertEqual(graphql["delegated"], .bool(true))
    XCTAssertEqual(graphql["query"], .string("query Test { workflowSession }"))
    XCTAssertEqual(graphql["variables"], .object([:]))
    XCTAssertEqual(graphql["operationName"], .string("Test"))
    guard case let .string(schema)? = graphql["schema"] else {
      return XCTFail("expected schema string")
    }
    XCTAssertTrue(schema.contains("createNote(input: CreateNoteInput!)"))
    XCTAssertTrue(schema.contains("searchNotes(query: String!"))
    guard case let .object(contextObject)? = response.body["context"] else {
      return XCTFail("expected context body")
    }
    XCTAssertEqual(contextObject["bearerTokenPresent"], .bool(true))
    XCTAssertEqual(contextObject["managerSessionId"], .string("manager-session"))
    XCTAssertEqual(contextObject["sanitizedEnvironmentKeys"], .array([.string("KEEP")]))
  }

  func testGraphQLRouteExecutesNoteDocumentsWhenExecutorIsConfigured() async throws {
    let handler = DeterministicServerRouteHandler(
      graphQLExecutor: try makeNoteGraphQLDocumentExecutor(),
      allowUnauthenticatedNoteAPI: true
    )
    let createBody = Data(#"""
    {
      "query": "mutation CreateNote($input: CreateNoteInput!) { createNote(input: $input) { result { accepted status } note { noteId title } } }",
      "variables": {
        "input": {
          "bodyMarkdown": "# Server Note\n\nRoute executor body",
          "tags": [{"name": "server-doc"}]
        }
      },
      "operationName": "CreateNote"
    }
    """#.utf8)

    let create = await handler.route(
      .init(method: "POST", path: "/graphql", body: createBody),
      context: .init()
    )

    XCTAssertEqual(create.status, 200)
    let created = try graphQLPayload(create.body, field: "createNote")
    XCTAssertEqual(try resultObject(created)["accepted"], .bool(true))
    let noteId = try stringValue(
      try objectValue(created["note"], field: "createNote.note")["noteId"],
      field: "note.noteId"
    )

    let searchBody = Data(#"""
    {
      "query": "query SearchNotes($query: String!, $tagFilter: [String!]) { searchNotes(query: $query, tagFilter: $tagFilter) { result { accepted status } value { note { noteId } } } }",
      "variables": {
        "query": "Route",
        "tagFilter": ["server-doc"]
      },
      "operationName": "SearchNotes"
    }
    """#.utf8)
    let search = await handler.route(
      .init(method: "POST", path: "/graphql", body: searchBody),
      context: .init()
    )

    XCTAssertEqual(search.status, 200)
    let searchPayload = try graphQLPayload(search.body, field: "searchNotes")
    XCTAssertEqual(try resultObject(searchPayload)["accepted"], .bool(true))
    let values = try arrayValue(searchPayload["value"], field: "searchNotes.value")
    guard !values.isEmpty else {
      return XCTFail("expected at least one search result")
    }
    let firstNote = try objectValue(try objectValue(values[0], field: "search result")["note"], field: "search result.note")
    XCTAssertEqual(firstNote["noteId"], .string(noteId))

    let readOnlyBody = Data("""
    {
      "query": "mutation Lock($noteId: String!, $readOnly: Boolean!) { setNoteReadOnly(noteId: $noteId, readOnly: $readOnly) { result { accepted status } note { readOnly } } }",
      "variables": {
        "noteId": "\(noteId)",
        "readOnly": true
      },
      "operationName": "Lock"
    }
    """.utf8)
    let readOnly = await handler.route(
      .init(method: "POST", path: "/graphql", body: readOnlyBody),
      context: .init()
    )
    XCTAssertEqual(readOnly.status, 200)
    XCTAssertEqual(try resultObject(try graphQLPayload(readOnly.body, field: "setNoteReadOnly"))["accepted"], .bool(true))

    let rejectedUpdateBody = Data("""
    {
      "query": "mutation Update($input: UpdateNoteInput!) { updateNote(input: $input) { result { accepted status diagnostics } note { noteId } } }",
      "variables": {
        "input": {
          "noteId": "\(noteId)",
          "bodyMarkdown": "# Changed"
        }
      },
      "operationName": "Update"
    }
    """.utf8)
    let rejectedUpdate = await handler.route(
      .init(method: "POST", path: "/graphql", body: rejectedUpdateBody),
      context: .init()
    )
    XCTAssertEqual(rejectedUpdate.status, 200)
    let updateResult = try resultObject(try graphQLPayload(rejectedUpdate.body, field: "updateNote"))
    XCTAssertEqual(updateResult["accepted"], .bool(false))
    XCTAssertEqual(updateResult["status"], .string("rejected"))
    XCTAssertFalse(try arrayValue(updateResult["diagnostics"], field: "update diagnostics").isEmpty)
  }

  func testGraphQLRouteRejectsUnsupportedExecutorOperationsWithoutDebugEcho() async throws {
    let handler = DeterministicServerRouteHandler(
      graphQLExecutor: try makeNoteGraphQLDocumentExecutor(),
      allowUnauthenticatedNoteAPI: true
    )
    let body = Data(#"{"query":"query Unknown { workflowSession { sessionId } }"}"#.utf8)

    let response = await handler.route(
      .init(method: "POST", path: "/graphql", body: body),
      context: .init(inheritedEnvironment: ["SECRET_ENV_NAME": "redacted"])
    )

    XCTAssertEqual(response.status, 400)
    guard case let .object(graphql)? = response.body["graphql"] else {
      return XCTFail("expected graphql body")
    }
    XCTAssertNotNil(graphql["errors"])
    XCTAssertNil(graphql["schema"])
    XCTAssertNil(response.body["context"])
  }

  func testGraphQLRouteRejectsNoteDocumentsWhenAuthenticatorIsMissing() async throws {
    let handler = DeterministicServerRouteHandler(graphQLExecutor: try makeNoteGraphQLDocumentExecutor())
    let body = Data(#"""
    {
      "query": "mutation CreateNote($input: CreateNoteInput!) { createNote(input: $input) { result { accepted status } } }",
      "variables": {
        "input": {
          "bodyMarkdown": "# Server Note\n\nUnauthenticated body"
        }
      },
      "operationName": "CreateNote"
    }
    """#.utf8)

    let response = await handler.route(
      .init(method: "POST", path: "/graphql", body: body),
      context: .init()
    )

    XCTAssertEqual(response.status, 503)
    XCTAssertEqual(response.body["error"], .string("note API authentication is not configured"))
  }

  func testGraphQLRouteRejectsMultiOperationNoteMutationByResolvedOperationName() async throws {
    let handler = DeterministicServerRouteHandler(graphQLExecutor: try makeNoteGraphQLDocumentExecutor())
    let body = Data(#"""
    {
      "query": "query Safe { workflowSession } mutation Evil { deleteNote(noteId: \"note-1\") { accepted status } }",
      "operationName": "Evil"
    }
    """#.utf8)

    let response = await handler.route(
      .init(method: "POST", path: "/graphql", body: body),
      context: .init()
    )

    XCTAssertEqual(response.status, 503)
    XCTAssertEqual(response.body["error"], .string("note API authentication is not configured"))
  }

  func testGraphQLRouteRejectsAmbiguousMultiOperationNoteDocumentWithoutOperationName() async throws {
    let handler = DeterministicServerRouteHandler(graphQLExecutor: try makeNoteGraphQLDocumentExecutor())
    let body = Data(#"""
    {
      "query": "query Safe { workflowSession } mutation Evil { deleteNote(noteId: \"note-1\") { accepted status } }"
    }
    """#.utf8)

    let response = await handler.route(
      .init(method: "POST", path: "/graphql", body: body),
      context: .init()
    )

    XCTAssertEqual(response.status, 503)
    XCTAssertEqual(response.body["error"], .string("note API authentication is not configured"))
  }

  func testGraphQLRouteRejectsMissingAndNonObjectBodies() async {
    let handler = DeterministicServerRouteHandler()

    let missing = await handler.route(.init(method: "POST", path: "/graphql"), context: .init())
    let nonObject = await handler.route(.init(method: "POST", path: "/graphql", body: Data(#"[]"#.utf8)), context: .init())
    let nonObjectVariables = await handler.route(
      .init(method: "POST", path: "/graphql", body: Data(#"{"query":"query","variables":[]}"#.utf8)),
      context: .init()
    )
    let whitespaceQuery = await handler.route(
      .init(method: "POST", path: "/graphql", body: Data(#"{"query":"   "}"#.utf8)),
      context: .init()
    )
    let emptyOperationName = await handler.route(
      .init(method: "POST", path: "/graphql", body: Data(#"{"query":"query EmptyOp { ok }","operationName":"   "}"#.utf8)),
      context: .init()
    )
    let nonStringOperationName = await handler.route(
      .init(method: "POST", path: "/graphql", body: Data(#"{"query":"query Op { ok }","operationName":1}"#.utf8)),
      context: .init()
    )
    let missingNamedOperation = await handler.route(
      .init(method: "POST", path: "/graphql", body: Data(#"{"query":"query Present { ok }","operationName":"Missing"}"#.utf8)),
      context: .init()
    )

    XCTAssertEqual(missing.status, 400)
    XCTAssertEqual(nonObject.status, 400)
    XCTAssertEqual(nonObjectVariables.status, 400)
    XCTAssertEqual(whitespaceQuery.status, 400)
    XCTAssertEqual(nonStringOperationName.status, 400)
    XCTAssertEqual(missingNamedOperation.status, 400)
    XCTAssertEqual(nonStringOperationName.body["error"], .string("graphql operationName must be a string when present"))
    guard case let .object(graphqlError)? = missingNamedOperation.body["graphql"] else {
      return XCTFail("expected structured graphql error")
    }
    XCTAssertEqual(
      graphqlError["errors"],
      .array([.object(["message": .string("graphql operationName 'Missing' was not found in query")])])
    )
    XCTAssertEqual(emptyOperationName.status, 200)
    guard case let .object(graphql)? = emptyOperationName.body["graphql"] else {
      return XCTFail("expected graphql body")
    }
    XCTAssertEqual(graphql["operationName"], .null)
  }

  func testGraphQLRouteRejectsOversizedQueryBeforeParsingOperations() async throws {
    let handler = DeterministicServerRouteHandler()
    let oversizedQuery = "query Oversized { " +
      String(repeating: "field ", count: NoteGraphQLDocumentLimits.maximumDocumentUTF8Bytes / 6 + 1) +
      "}"
    let body = try JSONEncoder().encode(JSONValue.object(["query": .string(oversizedQuery)]))

    let response = await handler.route(
      .init(method: "POST", path: "/graphql", body: body),
      context: .init()
    )

    XCTAssertEqual(response.status, 400)
    XCTAssertEqual(response.body["error"], .string("graphql query exceeds the maximum supported size"))
  }

  func testGraphQLRouteHandlesDuplicateMixedCaseHeadersDeterministically() async {
    let body = Data(#"{"query":"query Test { workflowSession }"}"#.utf8)
    let response = await DeterministicServerRouteHandler().route(
      .init(
        method: "POST",
        path: "/graphql",
        headers: [
          "Authorization": "Bearer upper-token",
          "authorization": "Bearer lower-token",
          "X-Riela-Manager-Session-Id": "upper-session",
          "x-riela-manager-session-id": "lower-session"
        ],
        body: body
      ),
      context: .init()
    )

    XCTAssertEqual(response.status, 200)
    guard case let .object(contextObject)? = response.body["context"] else {
      return XCTFail("expected context body")
    }
    XCTAssertEqual(contextObject["bearerTokenPresent"], .bool(true))
    XCTAssertEqual(contextObject["managerSessionId"], .string("lower-session"))
  }

  func testGraphQLRouteRecordsRedactedTelemetryWithoutQueriesVariablesOrHeaders() async throws {
    let telemetry = InMemoryRielaTelemetry()
    let handler = DeterministicServerRouteHandler(telemetry: telemetry)
    let body = Data(##"{"query":"# leading comment\nmutation RunWorkflow($token:String){ run(token:$token) }","variables":{"token":"secret-token"},"operationName":"RunWorkflow"}"##.utf8)

    let response = await handler.route(
      .init(
        method: "POST",
        path: "/graphql",
        headers: ["Authorization": "Bearer secret-token"],
        body: body
      ),
      context: .init()
    )

    XCTAssertEqual(response.status, 200)
    let spans = await telemetry.spans()
    let span = try XCTUnwrap(spans.first { $0.name == "riela.server.request" })
    XCTAssertEqual(span.attributes["http.method"], "POST")
    XCTAssertEqual(span.attributes["http.path"], "/graphql")
    XCTAssertEqual(span.attributes["graphql.operation.type"], "mutation")
    XCTAssertEqual(span.attributes["graphql.operation.name"], "RunWorkflow")
    XCTAssertFalse(span.attributes.values.contains { $0.contains("secret-token") })
    XCTAssertFalse(span.attributes.values.contains { $0.contains("run(token") })
  }

  func testReadOnlyRoutesAndFailuresAreDeterministic() async {
    let handler = DeterministicServerRouteHandler()
    let health = await handler.route(.init(method: "GET", path: "/healthz"), context: .init())
    let unsupportedMethod = await handler.route(.init(method: "POST", path: "/overview"), context: .init())
    let missing = await handler.route(.init(method: "GET", path: "/missing"), context: .init())

    XCTAssertEqual(health.body["status"], .string("ok"))
    XCTAssertEqual(unsupportedMethod.status, 405)
    XCTAssertEqual(missing.status, 404)
  }

  private func makeNoteGraphQLDocumentExecutor(function: String = #function) throws -> NoteGraphQLDocumentExecutor {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      .appendingPathComponent("tmp/RielaServerTests", isDirectory: true)
      .appendingPathComponent(function.replacingOccurrences(of: "()", with: ""), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let service = try NoteService(driver: SQLiteNoteDatabaseDriver(noteRoot: root.path))
    return NoteGraphQLDocumentExecutor(service: GraphQLNoteGraphQLService(service: service))
  }

  private func graphQLPayload(_ body: JSONObject, field: String) throws -> JSONObject {
    let data = try objectValue(body["data"], field: "data")
    return try objectValue(data[field], field: field)
  }

  private func resultObject(_ payload: JSONObject) throws -> JSONObject {
    try objectValue(payload["result"], field: "result")
  }

  private func objectValue(_ value: JSONValue?, field: String) throws -> JSONObject {
    guard case let .object(object)? = value else {
      XCTFail("expected \(field) object")
      return [:]
    }
    return object
  }

  private func arrayValue(_ value: JSONValue?, field: String) throws -> [JSONValue] {
    guard case let .array(array)? = value else {
      XCTFail("expected \(field) array")
      return []
    }
    return array
  }

  private func stringValue(_ value: JSONValue?, field: String) throws -> String {
    guard case let .string(string)? = value else {
      XCTFail("expected \(field) string")
      return ""
    }
    return string
  }
}
