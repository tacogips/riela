import Foundation
import RielaAdapters
import RielaCore
import RielaGraphQL
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class OAuthEnvironmentRedactionTests: XCTestCase {
  func testCredentialAliasSelectionDoesNotSelectSimilarPublicNames() {
    let credentials = [
      "ART_LATEST_GMAIL_OAUTH_CLIENT_JSON": "synthetic-oauth-client-json-canary",
      "oauth_client_json": "synthetic-unprefixed-oauth-canary",
      "ART_LATEST_X_CONSUMER_KEY": "synthetic-oauth-consumer-canary",
      "X_GW_CONSUMER_KEY": "synthetic-gateway-consumer-canary",
      "CONSUMER_KEY": "synthetic-unprefixed-consumer-canary"
    ]
    let supplied = credentials.merging([
      "PUBLIC_OAUTH_CLIENT_JSON_FORMAT": "public-json-format",
      "PUBLIC_CONSUMER_KEY_COUNT": "public-count",
      "PUBLIC_DOCUMENT_TITLE": "ordinary-public-document"
    ]) { first, _ in first }
    XCTAssertEqual(Set(sensitiveAdapterEnvironmentValues(supplied)), Set(credentials.values))
  }

  func testErrorAndRecursiveJSONRedactionUseSyntheticEnvironmentAliases() throws {
    try withSyntheticCredentials { client, consumer, clientSecret in
      let raw = "provider failed: \(client) and \(consumer); ordinary diagnostic survives"
      let normalized = normalizeAdapterFailure(
        AdapterExecutionError(.providerError, raw, isRetryable: true), fallbackMessage: "failed"
      )
      XCTAssertEqual(normalized.code, .providerError)
      XCTAssertEqual(normalized.isRetryable, true)
      let preflight = agentPreflightErrorDetail(
        AdapterExecutionError(.providerError, raw), fallback: "preflight failed"
      )
      let value = redactAdapterSensitiveJSONValue(.object([
        "message": .string(raw),
        consumer: .array([.string(client), .object(["nested": .string(consumer)])]),
        "public": .string("ordinary-public-document")
      ]))
      let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
      for text in [normalized.message, preflight, encoded] {
        assertNoCanaries(text, values: [client, consumer, clientSecret])
        XCTAssertTrue(text.contains("<redacted>"))
      }
      XCTAssertTrue(normalized.message.contains("ordinary diagnostic survives"))
      XCTAssertTrue(encoded.contains("ordinary-public-document"))
    }
  }

  func testNormalizedDiagnosticsStayRedactedInRuntimeArtifactAndGraphQLProjection() throws {
    try withSyntheticCredentials { client, consumer, clientSecret in
      let normalized = normalizeAdapterFailure(
        AdapterExecutionError(.providerError, "synthetic failure \(client) \(consumer)"),
        fallbackMessage: "adapter failed"
      )
      let log = agentPreflightErrorDetail(
        AdapterExecutionError(.providerError, "synthetic preflight \(client) \(consumer)"),
        fallback: "preflight failed"
      )
      let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("tmp/oauth-redaction-\(UUID().uuidString)", isDirectory: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let session = WorkflowSession(
        workflowId: "synthetic-redaction", sessionId: "synthetic-redaction-session",
        status: .failed, entryStepId: "inspect", createdAt: date, updatedAt: date,
        failureReason: normalized.message
      )
      let snapshot = WorkflowRuntimePersistenceSnapshot(session: session, diagnostics: [log])
      let store = FileWorkflowRuntimePersistenceStore(rootDirectory: root.path)
      try store.save(snapshot)
      let artifact = root.appendingPathComponent(session.sessionId)
        .appendingPathComponent("runtime-snapshot.json")
      let artifactText = try String(contentsOf: artifact, encoding: .utf8)
      let loaded = try store.load(sessionId: session.sessionId)
      let projected = GraphQLContractProjector.project(
        session: loaded.session, logs: [.init(level: "error", message: loaded.diagnostics[0])]
      )
      let graphqlText = String(decoding: try JSONEncoder().encode(projected), as: UTF8.self)
      for text in [artifactText, graphqlText] {
        assertNoCanaries(text, values: [client, consumer, clientSecret])
        XCTAssertTrue(text.contains("redacted"))
        XCTAssertTrue(text.contains("synthetic"))
      }
    }
  }

  private func withSyntheticCredentials(_ body: (String, String, String) throws -> Void) rethrows {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
    let clientName = "RIELA_SYNTHETIC_\(suffix)_OAUTH_CLIENT_JSON"
    let consumerName = "RIELA_SYNTHETIC_\(suffix)_CONSUMER_KEY"
    let secret = "synthetic-oauth-inner-canary-\(suffix)"
    let client = "{\"installed\":{\"client_secret\":\"\(secret)\"}}"
    let consumer = "synthetic-consumer-canary-\(suffix)"
    setenv(clientName, client, 1)
    setenv(consumerName, consumer, 1)
    defer { unsetenv(clientName); unsetenv(consumerName) }
    // Unique synthetic names: never inspect or replace an existing real credential.
    try body(client, consumer, secret)
  }

  private func assertNoCanaries(_ text: String, values: [String], file: StaticString = #filePath, line: UInt = #line) {
    for value in values { XCTAssertFalse(text.contains(value), "synthetic credential leaked", file: file, line: line) }
  }
}
