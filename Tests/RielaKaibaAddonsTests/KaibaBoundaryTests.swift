import AppCore
import Foundation
import KaibaClient
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
      _ = try await KaibaAddonCatalog.executeForTesting(
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

  func testKnownKaibaAddonRequiresAnExplicitExecutionSnapshot() async {
    do {
      _ = try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-boundary-test",
          stepId: "missing-snapshot",
          nodeId: "missing-snapshot",
          addon: WorkflowNodeAddonRef(name: "kaiba/note-search", version: "1"),
          variables: [:]
        ),
        environment: [:]
      )
      XCTFail("expected missing snapshot to fail closed")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
      XCTAssertEqual(error.message, "kaiba execution requires validated instance preflight")
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

  // MARK: - The resolved GraphQL client's HTTP contract

  func testRemoteNodeSendsTheDocumentWithTheResolvedClientBearerKey() async throws {
    let transport = BoundaryKaibaTransport(response: .init(
      statusCode: 200,
      body: Data(#"{"data":{"notebooks":{"result":{"accepted":true}}}}"#.utf8)
    ))
    let client = try boundaryClient(
      authentication: .bearer(try KaibaBearerToken("issued-key")),
      transport: transport
    )

    let output = try await KaibaAddonExecutionContext.withMockExecutionForTesting(client: client) {
      try await KaibaAddonCatalog.execute(
        WorkflowAddonExecutionInput(
          workflowId: "kaiba-boundary-test",
          stepId: "remote",
          nodeId: "remote",
          addon: .init(name: "kaiba/note-graphql-remote", version: "1", config: [
            "query": .string("query Notebooks($limit: Int) { notebooks(limit: $limit) { result { accepted } } }"),
            "operationName": .string("Notebooks"),
            "variables": .object(["limit": .integer(2)])
          ]),
          variables: [:]
        ),
        environment: [:]
      )
    }

    let request = try XCTUnwrap(transport.requests.first)
    XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8787/graphql")
    XCTAssertEqual(request.headers["authorization"], "Bearer issued-key")
    let decoded = try JSONDecoder().decode(RielaCore.JSONValue.self, from: request.body)
    guard case let .object(body) = decoded else {
      return XCTFail("expected a JSON object request body")
    }
    XCTAssertEqual(body["query"], .string("query Notebooks($limit: Int) { notebooks(limit: $limit) { result { accepted } } }"))
    XCTAssertEqual(body["operationName"], .string("Notebooks"))
    XCTAssertEqual(body["variables"], .object(["limit": .integer(2)]))
    XCTAssertEqual(output.payload["status"], .string("ok"))
    XCTAssertEqual(output.payload["fieldName"], .string("notebooks"))
  }
}

private func boundaryClient(
  authentication: KaibaAuthentication,
  transport: any KaibaHTTPTransporting
) throws -> KaibaClient {
  try KaibaClient(
    endpoint: URL(string: "http://127.0.0.1:8787")!,
    authentication: authentication,
    transport: transport
  )
}

private final class BoundaryKaibaTransport: KaibaHTTPTransporting, @unchecked Sendable {
  private let lock = NSLock()
  private let response: KaibaHTTPResponse
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
