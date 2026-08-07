import Foundation
import RielaGraphQL
import RielaObservability
import XCTest
@testable import RielaCore
@testable import RielaServer

final class ServerContractsTests: XCTestCase {
  func testServerConfigurationDefaultsBindLocalhost() {
    let configuration = RielaServerConfiguration()

    XCTAssertEqual(configuration.host, "127.0.0.1")
    XCTAssertEqual(configuration.port, 8787)
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
    // The schema wraps long argument lists across lines, so compare with
    // whitespace stripped rather than pinning a formatting style.
    let compactSchema = schema.filter { !$0.isWhitespace }
    guard case let .object(contextObject)? = response.body["context"] else {
      return XCTFail("expected context body")
    }
    XCTAssertEqual(contextObject["bearerTokenPresent"], .bool(true))
    XCTAssertEqual(contextObject["managerSessionId"], .string("manager-session"))
    XCTAssertEqual(contextObject["sanitizedEnvironmentKeys"], .array([.string("KEEP")]))
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
