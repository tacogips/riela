import Foundation
import RielaObservability
import XCTest
@testable import RielaCore
@testable import RielaServer

final class ServerContractsTests: XCTestCase {
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

    XCTAssertEqual(missing.status, 400)
    XCTAssertEqual(nonObject.status, 400)
    XCTAssertEqual(nonObjectVariables.status, 400)
    XCTAssertEqual(whitespaceQuery.status, 400)
    XCTAssertEqual(emptyOperationName.status, 200)
    guard case let .object(graphql)? = emptyOperationName.body["graphql"] else {
      return XCTFail("expected graphql body")
    }
    XCTAssertEqual(graphql["operationName"], .null)
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
    let body = Data(#"{"query":"mutation RunWorkflow($token:String){ run(token:$token) }","variables":{"token":"secret-token"},"operationName":"RunWorkflow"}"#.utf8)

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
}
