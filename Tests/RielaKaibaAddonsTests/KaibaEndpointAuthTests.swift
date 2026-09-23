import Foundation
import KaibaClient
import RielaCore
import RielaKaibaSupport
import XCTest
@testable import RielaKaibaAddons

/// GraphQL add-ons inherit endpoint and authentication solely from the
/// validated execution snapshot. Authored node configuration cannot redirect a
/// request or select a credential.
final class KaibaEndpointAuthTests: XCTestCase {
  func testRemoteNodeRejectsMissingDocumentBeforeTransport() async throws {
    do {
      _ = try await executeGraphQL(config: [:])
      XCTFail("expected the missing document to be rejected")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .invalidInput)
      XCTAssertTrue(error.message.contains("query is required"), error.message)
    }
  }

  func testGraphQLNodeReportsLegacyLocalInputsWithoutUsingThem() async throws {
    let ignoredLocalStoreValues = [
      "/tmp/ignored-kaiba-note-root",
      "/tmp/ignored-kaiba-config.json",
      "/tmp/ignored-kaiba.sqlite"
    ]
    let transport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try testClient(authentication: .unauthenticated, transport: transport)

    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "endpoint",
          nodeId: "endpoint",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
            "noteRoot": .string(ignoredLocalStoreValues[0]),
            "configPath": .string(ignoredLocalStoreValues[1]),
            "databasePath": .string(ignoredLocalStoreValues[2]),
            "query": .string("query { ok }")
          ]),
          resolvedInputPayload: [:]
        ),
        environment: [
          "KAIBA_NOTE_ROOT": "/tmp/ignored-kaiba-environment-root",
          "RIELA_NOTE_ROOT": "/tmp/ignored-riela-environment-root"
        ]
      )
    }

    XCTAssertEqual(try XCTUnwrap(transport.requests.first).url.absoluteString, "http://127.0.0.1:8787/graphql")
    XCTAssertNil(try XCTUnwrap(transport.requests.first).headers["authorization"])
    XCTAssertEqual(output.payload["fieldName"], .string("ok"))
    XCTAssertEqual(
      output.payload["kaibaCompatibilityDiagnosticCodes"],
      .array([.string("legacy_kaiba_local_config_ignored")])
    )
    XCTAssertNil(output.payload["endpoint"])
    XCTAssertNil(output.payload["authenticated"])
    for ignoredValue in ignoredLocalStoreValues {
      XCTAssertFalse(String(reflecting: output).contains(ignoredValue))
      XCTAssertFalse(String(reflecting: transport.requests).contains(ignoredValue))
    }
  }

  func testGraphQLNodeBlocksMismatchedLegacyConnectionBeforeTransport() async throws {
    let transport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try testClient(authentication: .unauthenticated, transport: transport)

    do {
      _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
        try await KaibaAddonCatalog.execute(
          WorkflowAddonExecutionInput(
            workflowId: "kaiba-endpoint-auth-test",
            stepId: "endpoint",
            nodeId: "endpoint",
            addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
              "endpoint": .string("https://untrusted.example/graphql"),
              "apiKeyEnv": .string("UNTRUSTED_KEY"),
              "query": .string("query { ok }")
            ]),
            resolvedInputPayload: [:]
          ),
          environment: ["UNTRUSTED_KEY": "must-not-be-used"]
        )
      }
      XCTFail("expected mismatched legacy connection fields to fail closed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(
        error.message,
        "legacy_kaiba_connection_mismatch. Bind the intended named instance and remove legacy fields."
      )
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }

  func testGraphQLNodeRejectsEveryLegacyConnectionAssertionMismatchBeforeTransport() async throws {
    let unauthenticatedMismatches: [(String, JSONValue)] = [
      ("endpoint", .string("https://untrusted.example.test/graphql")),
      ("allowUnauthenticated", .bool(false)),
      ("allowInsecureHTTP", .bool(true)),
      ("allowRemoteUnauthenticated", .bool(true))
    ]

    for (key, value) in unauthenticatedMismatches {
      try await assertLegacyConnectionMismatch(config: [key: value])
    }

    let bearerInstance = KaibaInstance(
      id: "test-kaiba-instance",
      name: "Test Kaiba",
      endpoint: "http://127.0.0.1:8787/graphql",
      authentication: .bearer(environmentVariable: "KAIBA_TEST_TOKEN")
    )
    try await assertLegacyConnectionMismatch(
      config: ["apiKeyEnv": .string("OTHER_KAIBA_TEST_TOKEN")],
      authentication: .bearer(try KaibaBearerToken("test-bearer-token")),
      instance: bearerInstance,
      environment: ["KAIBA_TEST_TOKEN": "test-bearer-token"]
    )
  }

  func testGraphQLNodeRejectsMalformedLegacyConnectionAssertionsBeforeTransport() async throws {
    let malformedAssertions: [(String, JSONValue)] = [
      ("endpoint", .number(1)),
      ("apiKeyEnv", .bool(true)),
      ("allowUnauthenticated", .string("true")),
      ("allowInsecureHTTP", .string("false")),
      ("allowRemoteUnauthenticated", .number(0))
    ]

    for (key, value) in malformedAssertions {
      try await assertLegacyConnectionMismatch(config: [key: value])
    }
  }

  func testGraphQLNodeAcceptsExactLegacyConnectionAssertions() async throws {
    let transport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try testClient(authentication: .unauthenticated, transport: transport)

    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "endpoint",
          nodeId: "endpoint",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
            "endpoint": .string("http://127.0.0.1:8787/graphql"),
            "allowUnauthenticated": .bool(true),
            "allowInsecureHTTP": .bool(false),
            "allowRemoteUnauthenticated": .bool(false),
            "query": .string("query { ok }")
          ]),
          resolvedInputPayload: [:]
        ),
        environment: [:]
      )
    }

    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(
      output.payload["kaibaCompatibilityDiagnosticCodes"],
      .array([.string("legacy_kaiba_connection_config_matched")])
    )
  }

  func testGraphQLNodeMatchesBearerLegacyAssertionsAndRejectsContradictoryAuth() async throws {
    let matchingTransport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let matchingClient = try testClient(
      authentication: .bearer(try KaibaBearerToken("test-bearer-token")),
      transport: matchingTransport
    )
    let exactConfig: JSONObject = [
      "endpoint": .string("http://127.0.0.1:8787/graphql"),
      "apiKeyEnv": .string("KAIBA_TEST_TOKEN"),
      "allowUnauthenticated": .bool(false),
      "allowInsecureHTTP": .bool(false),
      "allowRemoteUnauthenticated": .bool(false),
      "query": .string("query { ok }")
    ]

    _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(
      client: matchingClient,
      instance: KaibaInstance(
        id: "test-kaiba-instance",
        name: "Test Kaiba",
        endpoint: "http://127.0.0.1:8787/graphql",
        authentication: .bearer(environmentVariable: "KAIBA_TEST_TOKEN")
      )
    ) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "endpoint",
          nodeId: "endpoint",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: exactConfig),
          resolvedInputPayload: [:]
        ),
        environment: ["KAIBA_TEST_TOKEN": "test-bearer-token"]
      )
    }
    XCTAssertEqual(matchingTransport.requests.count, 1)

    let mismatchTransport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let mismatchClient = try testClient(authentication: .unauthenticated, transport: mismatchTransport)
    do {
      _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: mismatchClient) {
        try await KaibaAddonCatalog.execute(
          WorkflowAddonExecutionInput(
            workflowId: "kaiba-endpoint-auth-test",
            stepId: "endpoint",
            nodeId: "endpoint",
            addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
              "apiKeyEnv": .string("KAIBA_TEST_TOKEN"),
              "allowUnauthenticated": .bool(true),
              "query": .string("query { ok }")
            ]),
            resolvedInputPayload: [:]
          ),
          environment: ["KAIBA_TEST_TOKEN": "test-bearer-token"]
        )
      }
      XCTFail("expected contradictory legacy authentication assertions to fail closed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(
        error.message,
        "legacy_kaiba_connection_mismatch. Bind the intended named instance and remove legacy fields."
      )
    }
    XCTAssertTrue(mismatchTransport.requests.isEmpty)
  }

  func testDocumentAliasUsesTheSameResolvedClientTransport() async throws {
    let transport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"notebooks":{"result":{"accepted":true}}}}"#.utf8)
    ))
    let client = try testClient(authentication: .unauthenticated, transport: transport)

    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "document",
          nodeId: "document",
          addon: .init(name: "kaiba/note-graphql-document", version: "1", config: [
            "query": .string("query { notebooks { result { accepted } } }")
          ]),
          resolvedInputPayload: [:]
        ),
        environment: [:]
      )
    }

    XCTAssertEqual(transport.requests.count, 1)
    XCTAssertEqual(output.payload["statusCode"], .number(200))
    XCTAssertEqual(output.payload["fieldName"], .string("notebooks"))
  }

  private func executeGraphQL(config: JSONObject) async throws -> AdapterExecutionOutput {
    try await KaibaAddonExecutionContext.withMockExecutionForTesting(
      client: try testClient(
        authentication: .unauthenticated,
        transport: RecordingKaibaTransport(response: .init(statusCode: 200, body: Data(#"{"data":{}}"#.utf8)))
      )
    ) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-endpoint-auth-test",
          stepId: "endpoint",
          nodeId: "endpoint",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: config),
          resolvedInputPayload: [:]
        ),
        environment: [:]
      )
    }
  }

  private func assertLegacyConnectionMismatch(
    config assertions: JSONObject,
    authentication: KaibaAuthentication = .unauthenticated,
    instance: KaibaInstance? = nil,
    environment: [String: String] = [:]
  ) async throws {
    var config = assertions
    config["query"] = .string("query { ok }")
    let transport = RecordingKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try testClient(authentication: authentication, transport: transport)

    do {
      _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(
        client: client,
        instance: instance
      ) {
        try await KaibaAddonCatalog.execute(
          WorkflowAddonExecutionInput(
            workflowId: "kaiba-endpoint-auth-test",
            stepId: "endpoint",
            nodeId: "endpoint",
            addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: config),
            resolvedInputPayload: [:]
          ),
          environment: environment
        )
      }
      XCTFail("expected mismatched legacy connection assertion to fail closed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(
        error.message,
        "legacy_kaiba_connection_mismatch. Bind the intended named instance and remove legacy fields."
      )
    }
    XCTAssertTrue(transport.requests.isEmpty)
  }
}

private func testClient(
  authentication: KaibaAuthentication,
  transport: any KaibaHTTPTransporting
) throws -> KaibaClient {
  try KaibaClient(
    endpoint: URL(string: "http://127.0.0.1:8787")!,
    authentication: authentication,
    transport: transport
  )
}

private final class RecordingKaibaTransport: KaibaHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let response: KaibaHTTPResponse
  private var recorded: [KaibaHTTPRequest] = []

  init(response: KaibaHTTPResponse) {
    self.response = response
  }

  var requests: [KaibaHTTPRequest] { lock.withLock { recorded } }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    lock.withLock { recorded.append(request) }
    return response
  }
}
