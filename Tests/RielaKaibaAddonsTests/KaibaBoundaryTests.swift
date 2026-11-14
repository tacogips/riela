import AppCore
import AppGraphQL
import Foundation
import RielaAddons
import RielaCore
import XCTest
@testable import RielaKaibaAddons

/// The riela ↔ kaiba boundary itself, as a contract.
///
/// `RielaKaibaAddons` is the only target that links kaiba; everything else
/// knows kaiba as a set of add-on names and RielaCore payloads. These tests pin
/// the pieces that keep that true: the name registry that validation reads, the
/// fail-closed dispatch for names nobody owns, the JSON re-encoding every
/// payload crosses the boundary through, and the remote node's HTTP contract.
final class KaibaBoundaryTests: XCTestCase {
  /// `RielaBuiltinAddonCatalog.noteAddons` (RielaAddons) is hand-maintained so
  /// that workflow validation never has to link kaiba. This is the one place
  /// the two lists are held together; without it they drift silently and a
  /// registered add-on stops resolving (or an unregistered one resolves).
  func testRegistryAndCatalogAgreeOnTheKaibaAddonNames() {
    XCTAssertEqual(
      Set(RielaBuiltinAddonCatalog.noteAddons.map(\.name)),
      Set(KaibaAddonCatalog.addonNames)
    )
  }

  func testCatalogHandlesExactlyItsOwnNames() {
    for name in KaibaAddonCatalog.addonNames {
      XCTAssertTrue(KaibaAddonCatalog.handles(name), name)
    }
    XCTAssertFalse(KaibaAddonCatalog.handles("riela/git-commit"))
    XCTAssertFalse(KaibaAddonCatalog.handles("kaiba/note-memory-save"))
  }

  /// A `kaiba/` name nobody owns must fail closed at the boundary, not fall
  /// through into some other resolver.
  func testAnUnownedKaibaNameFailsClosed() async {
    do {
      _ = try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-boundary-test",
          stepId: "unowned",
          nodeId: "unowned",
          addon: WorkflowNodeAddonRef(name: "kaiba/does-not-exist", version: "1", config: [:]),
          variables: [:]
        ),
        environment: [:]
      )
      XCTFail("expected the unowned kaiba add-on name to be refused")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertTrue(error.message.contains("missing kaiba add-on resolver"), error.message)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  /// Every payload crossing the boundary is re-encoded between riela's and
  /// kaiba's structurally identical JSON models. The trip must be lossless for
  /// every value shape a workflow can produce — a value that changes here
  /// changes silently in every note body and every add-on result.
  func testJSONBridgeRoundTripsEveryValueShape() throws {
    let original: RielaCore.JSONValue = .object([
      "null": .null,
      "bool": .bool(true),
      "integer": .integer(9_007_199_254_740_991),
      "negative": .integer(-42),
      "fraction": .number(1.5),
      "unicode": .string("日本語 / emoji 🎌 / \"quotes\""),
      "nested": .array([
        .object(["deep": .array([.integer(1), .string("two"), .null])]),
        .bool(false)
      ])
    ])

    let kaibaSide = try kaibaJSONValue(original)
    let roundTripped = try rielaJSONValue(kaibaSide)

    XCTAssertEqual(roundTripped, original)
    // And the reverse direction, starting from kaiba's model.
    XCTAssertEqual(try kaibaJSONValue(try rielaJSONValue(kaibaSide)), kaibaSide)
  }

  // MARK: - The remote node's HTTP contract

  /// What `kaiba/note-graphql-remote` actually puts on the wire: the document
  /// and variables in a kaiba GraphQL envelope, the bearer key in the header,
  /// and the bare endpoint routed to /graphql. Everything a live `kaiba serve`
  /// would key its authentication and library access decisions on.
  func testRemoteNodeSendsTheDocumentWithItsBearerKey() async throws {
    let transport = RecordingGraphQLTransport(response: GraphQLHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"notebooks":{"result":{"accepted":true}}}}"#.utf8)
    ))

    let output = try await KaibaRemoteGraphQLAddon.$transportOverride.withValue(transport) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-boundary-test",
          stepId: "remote",
          nodeId: "remote",
          addon: WorkflowNodeAddonRef(name: "kaiba/note-graphql-remote", version: "1", config: [
            "endpoint": .string("http://kaiba.example:8787"),
            "query": .string("query Notebooks($limit: Int) { notebooks(limit: $limit) { result { accepted } } }"),
            "operationName": .string("Notebooks"),
            "variables": .object(["limit": .integer(2)])
          ]),
          variables: [:]
        ),
        environment: ["KAIBA_API_KEY": "issued-key"]
      )
    }

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url.absoluteString, "http://kaiba.example:8787/graphql")
    XCTAssertEqual(request.headers["authorization"], "Bearer issued-key")
    let decoded = try JSONDecoder().decode(RielaCore.JSONValue.self, from: request.body)
    guard case let .object(body) = decoded else {
      return XCTFail("expected a JSON object request body")
    }
    XCTAssertEqual(
      body["query"],
      .string("query Notebooks($limit: Int) { notebooks(limit: $limit) { result { accepted } } }")
    )
    XCTAssertEqual(body["operationName"], .string("Notebooks"))
    XCTAssertEqual(body["variables"], .object(["limit": .integer(2)]))

    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["authenticated"], .bool(true))
    XCTAssertEqual(output.payload["endpoint"], .string("http://kaiba.example:8787"))
    // The response body crossed the bridge back into riela's model intact.
    XCTAssertEqual(output.payload["fieldName"], .string("notebooks"))
    XCTAssertEqual(
      output.payload["fieldPayload"],
      .object(["result": .object(["accepted": .bool(true)])])
    )
  }

  /// The keyless opt-in sends no Authorization header at all — an empty bearer
  /// would read as a malformed credential to `kaiba serve`, not as anonymity.
  func testKeylessOptInSendsNoAuthorizationHeader() async throws {
    let transport = RecordingGraphQLTransport(response: GraphQLHTTPResponse(
      statusCode: 200,
      body: Data(#"{"data":{"notebooks":{"result":{"accepted":true}}}}"#.utf8)
    ))

    let output = try await KaibaRemoteGraphQLAddon.$transportOverride.withValue(transport) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-boundary-test",
          stepId: "remote",
          nodeId: "remote",
          addon: WorkflowNodeAddonRef(name: "kaiba/note-graphql-remote", version: "1", config: [
            "endpoint": .string("http://kaiba.example:8787"),
            "allowUnauthenticated": .bool(true),
            "query": .string("{ notebooks(limit: 1) { result { accepted } } }")
          ]),
          variables: [:]
        ),
        environment: [:]
      )
    }

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertNil(request.headers["authorization"])
    XCTAssertEqual(output.payload["authenticated"], .bool(false))
  }
}

/// Records what the node sends and answers with a canned response, so the
/// wire contract is testable without a live `kaiba serve`.
private final class RecordingGraphQLTransport: GraphQLHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let response: GraphQLHTTPResponse
  private var recorded: [GraphQLHTTPRequest] = []

  init(response: GraphQLHTTPResponse) {
    self.response = response
  }

  var requests: [GraphQLHTTPRequest] {
    lock.withLock { recorded }
  }

  func send(_ request: GraphQLHTTPRequest) async throws -> GraphQLHTTPResponse {
    lock.withLock { recorded.append(request) }
    return response
  }
}
