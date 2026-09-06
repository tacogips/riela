import Foundation
import KaibaClient
import RielaCore
import XCTest
@testable import RielaKaibaAddons

final class KaibaCompatibilityAndRedactionTests: XCTestCase {
  func testGraphQLOutputDoesNotReflectLegacyLocalValues() async throws {
    let endpointSentinel = "https://untrusted.kaiba-redaction.test/graphql"
    let credentialSentinel = "kaiba-redaction-sentinel-token"
    let transport = KaibaRedactionTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"ok":true}}"#.utf8)
    ))
    let client = try KaibaClient(
      endpoint: URL(string: "http://127.0.0.1:8787")!,
      authentication: .unauthenticated,
      transport: transport
    )

    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await KaibaAddonCatalog.execute(
        .init(
          workflowId: "kaiba-redaction",
          stepId: "graphql",
          nodeId: "graphql",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
            "noteRoot": .string(endpointSentinel),
            "query": .string("query { ok }")
          ])
        ),
        environment: ["KAIBA_NOTE_ROOT": credentialSentinel]
      )
    }

    XCTAssertFalse(String(reflecting: output).contains(endpointSentinel))
    XCTAssertFalse(String(reflecting: output).contains(credentialSentinel))
    XCTAssertFalse(String(reflecting: transport.requests).contains(endpointSentinel))
    XCTAssertFalse(String(reflecting: transport.requests).contains(credentialSentinel))
  }

  func testGraphQLTransportFailureDoesNotExposeEndpointOrCredentialSentinels() async throws {
    let endpointSentinel = "https://untrusted.kaiba-redaction.test/graphql"
    let credentialSentinel = "kaiba-redaction-sentinel-token"
    let transport = KaibaFailingRedactionTransport(
      message: "transport failed for \(endpointSentinel) with bearer \(credentialSentinel)"
    )
    let client = try KaibaClient(
      endpoint: URL(string: "http://127.0.0.1:8787")!,
      authentication: .unauthenticated,
      transport: transport
    )

    do {
      _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
        try await KaibaAddonCatalog.execute(
          .init(
            workflowId: "kaiba-redaction",
            stepId: "graphql-failure",
            nodeId: "graphql-failure",
            addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
              "endpoint": .string("http://127.0.0.1:8787/graphql"),
              "allowUnauthenticated": .bool(true),
              "allowInsecureHTTP": .bool(false),
              "allowRemoteUnauthenticated": .bool(false),
              "query": .string("query { ok }")
            ])
          ),
          environment: ["UNTRUSTED_KAIBA_TOKEN": credentialSentinel]
        )
      }
      XCTFail("expected the transport failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "kaiba GraphQL request failed")
      XCTAssertFalse(String(reflecting: error).contains(endpointSentinel))
      XCTAssertFalse(String(reflecting: error).contains(credentialSentinel))
    }
  }

  func testGraphQLServerErrorAndSDKEndpointRejectionDoNotExposeSentinels() async throws {
    let endpointSentinel = "https://untrusted.kaiba-redaction.test/graphql"
    let credentialSentinel = "kaiba-redaction-sentinel-token"
    let transport = KaibaRedactionTransport(response: .init(
      statusCode: 200,
      body: Data("""
      {"errors":[{"message":"rejected at \(endpointSentinel) with bearer \(credentialSentinel)"}]}
      """.utf8)
    ))
    let client = try KaibaClient(
      endpoint: URL(string: "http://127.0.0.1:8787")!,
      authentication: .unauthenticated,
      transport: transport
    )

    do {
      _ = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
        try await KaibaAddonCatalog.execute(
          .init(
            workflowId: "kaiba-redaction",
            stepId: "graphql-server-error",
            nodeId: "graphql-server-error",
            addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
              "query": .string("query { ok }")
            ])
          ),
          environment: [:]
        )
      }
      XCTFail("expected the GraphQL server error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "kaiba GraphQL request failed")
      XCTAssertFalse(String(reflecting: error).contains(endpointSentinel))
      XCTAssertFalse(String(reflecting: error).contains(credentialSentinel))
    }

    XCTAssertThrowsError(
      try KaibaClient(
        endpoint: URL(string: "https://kaiba.example.test/graphql?token=\(credentialSentinel)")!,
        authentication: .unauthenticated
      )
    ) { error in
      XCTAssertFalse(String(reflecting: error).contains(credentialSentinel))
    }
  }
}

private final class KaibaRedactionTransport: KaibaHTTPTransporting, @unchecked Sendable {
  private let response: KaibaHTTPResponse
  private let lock = NSLock()
  private var recorded: [KaibaHTTPRequest] = []

  init(response: KaibaHTTPResponse) {
    self.response = response
  }

  var requests: [KaibaHTTPRequest] {
    lock.withLock { recorded }
  }

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    lock.withLock { recorded.append(request) }
    return response
  }
}

private struct KaibaRedactionTransportFailure: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

private struct KaibaFailingRedactionTransport: KaibaHTTPTransporting {
  let message: String

  func send(_ request: KaibaHTTPRequest, maximumResponseBytes: Int) async throws -> KaibaHTTPResponse {
    throw KaibaRedactionTransportFailure(message: message)
  }
}
