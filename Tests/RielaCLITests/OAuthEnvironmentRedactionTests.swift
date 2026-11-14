import Foundation
import RielaAdapters
import RielaCore
import RielaGraphQL
import XCTest
@testable import RielaCLI

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

  /// Real path: an agent adapter failure travels through the redaction seam
  /// (`AdapterFailureRedactingNodeAdapter`, the outermost production adapter)
  /// into the real runner, which
  /// persists it as the step/session `failureReason`.
  /// The credentials exist ONLY in the execution snapshot (as loader-provided
  /// values do), never in `ProcessInfo`, so a ProcessInfo-only redactor would leak.
  func testAgentFailureReasonIsRedactedFromTheExecutionSnapshot() async throws {
    let fixture = SyntheticCredentials()
    for value in fixture.values {
      XCTAssertFalse(ProcessInfo.processInfo.environment.values.contains(value), "credential must be snapshot-only")
    }
    let store = InMemoryWorkflowRuntimeStore()
    let adapter = AdapterFailureRedactingNodeAdapter(
      primary: EchoingFailureAdapter(echoed: fixture.values), environment: fixture.snapshot
    )
    let runner = DeterministicWorkflowRunner(store: store, adapter: adapter, runtimeEnvironment: fixture.snapshot)
    do {
      _ = try await runner.run(request())
      XCTFail("expected adapter failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.isRetryable, false)
      assertNoCanaries(error.message, values: fixture.canaries)
    }
    let latest = await store.latestSession(workflowId: "synthetic-redaction")
    let session = try XCTUnwrap(latest)
    let reason = try XCTUnwrap(session.failureReason)
    assertNoCanaries(reason, values: fixture.canaries)
    XCTAssertTrue(reason.hasPrefix("provider_error: "), reason)
    XCTAssertTrue(reason.contains("<redacted>"), reason)
    XCTAssertTrue(reason.contains("ordinary diagnostic survives"), reason)

    // The persisted artifact and the GraphQL projection carry the same redacted reason.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/oauth-redaction-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = FileWorkflowRuntimePersistenceStore(rootDirectory: root.path)
    try persistence.save(WorkflowRuntimePersistenceSnapshot(session: session, diagnostics: [reason]))
    let artifact = try String(
      contentsOf: root.appendingPathComponent(session.sessionId).appendingPathComponent("runtime-snapshot.json"),
      encoding: .utf8
    )
    let loaded = try persistence.load(sessionId: session.sessionId)
    let projected = GraphQLContractProjector.project(
      session: loaded.session, logs: [.init(level: "error", message: loaded.diagnostics[0])]
    )
    let graphqlText = try XCTUnwrap(String(bytes: try JSONEncoder().encode(projected), encoding: .utf8))
    for text in [artifact, graphqlText] {
      assertNoCanaries(text, values: fixture.canaries)
      XCTAssertTrue(text.contains("redacted"))
    }
  }

  /// Only `AdapterExecutionError` is redacted. Every other error passes through
  /// the seam unchanged (same type and value), including
  /// `WorkflowPublicationError.validationRejected`, which the runner's retry
  /// loop matches on, and cancellation.
  func testNonAdapterErrorsPassThroughTheSeamUnchanged() async throws {
    let fixture = SyntheticCredentials()
    let values = sensitiveAdapterEnvironmentValues(fixture.snapshot)
    let rejected = WorkflowPublicationError.validationRejected("schema mismatch")
    XCTAssertEqual(redactedAdapterFailure(rejected, sensitiveValues: values) as? WorkflowPublicationError, rejected)
    XCTAssertTrue(redactedAdapterFailure(CancellationError(), sensitiveValues: values) is CancellationError)
    let other = redactedAdapterFailure(SyntheticError(text: "plain"), sensitiveValues: values)
    XCTAssertEqual((other as? SyntheticError)?.text, "plain")

    let adapter = AdapterFailureRedactingNodeAdapter(primary: ThrowingAdapter(error: rejected), environment: fixture.snapshot)
    do {
      _ = try await adapter.execute(
        AdapterExecutionInput(node: AgentNodePayload(id: "node", model: "gpt-5.5"), promptText: "hello"),
        context: AdapterExecutionContext()
      )
      XCTFail("expected validationRejected")
    } catch let error as WorkflowPublicationError {
      XCTAssertEqual(error, rejected)
    }
  }

  /// Successful outputs are returned untouched.
  func testSuccessfulOutputPassesThroughTheSeamUnchanged() async throws {
    let fixture = SyntheticCredentials()
    let output = AdapterExecutionOutput(
      provider: "codex", model: "gpt-5.5", promptText: "echo \(fixture.consumer)", completionPassed: true,
      when: ["done": true], payload: ["text": .string(fixture.consumer)]
    )
    let adapter = AdapterFailureRedactingNodeAdapter(primary: SucceedingAdapter(output: output), environment: fixture.snapshot)
    let result = try await adapter.execute(
      AdapterExecutionInput(node: AgentNodePayload(id: "node", model: "gpt-5.5"), promptText: "hello"),
      context: AdapterExecutionContext()
    )
    XCTAssertEqual(result, output)
  }

  /// The production chain (agent backends, sandboxed or not) ends in the seam,
  /// fed from the execution snapshot the adapter is built with.
  func testProductionAdapterChainIsWrappedByTheRedactionSeam() {
    XCTAssertTrue(makeProductionNodeAdapter(environment: [:]) is AdapterFailureRedactingNodeAdapter)
  }

  private func request() -> DeterministicWorkflowRunRequest {
    DeterministicWorkflowRunRequest(
      workflow: WorkflowDefinition(
        workflowId: "synthetic-redaction",
        defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
        entryStepId: "inspect",
        nodeRegistry: [WorkflowNodeRegistryRef(id: "node", nodeFile: "nodes/node.json")],
        steps: [WorkflowStepRef(id: "inspect", nodeId: "node")],
        nodes: [WorkflowNodeRef(id: "node", nodeFile: "nodes/node.json")]
      ),
      nodePayloads: [
        "node": AgentNodePayload(id: "node", executionBackend: .codexAgent, model: "gpt-5.5", agentSandbox: .readOnly)
      ]
    )
  }

  private func assertNoCanaries(_ text: String, values: [String], file: StaticString = #filePath, line: UInt = #line) {
    for value in values { XCTAssertFalse(text.contains(value), "synthetic credential leaked", file: file, line: line) }
  }
}

/// Synthetic snapshot-only credentials with unique names. Nothing is exported
/// to the process environment (no `setenv`), so parallel tests are unaffected.
private struct SyntheticCredentials {
  let client: String
  let consumer: String
  let secret: String
  let snapshot: [String: String]

  init() {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "_")
    secret = "synthetic-oauth-inner-canary-\(suffix)"
    client = "{\"installed\":{\"client_secret\":\"\(secret)\"}}"
    consumer = "synthetic-consumer-canary-\(suffix)"
    snapshot = [
      "RIELA_SYNTHETIC_\(suffix)_OAUTH_CLIENT_JSON": client,
      "RIELA_SYNTHETIC_\(suffix)_CONSUMER_KEY": consumer,
      "PUBLIC_DOCUMENT_TITLE": "ordinary-public-document"
    ]
  }

  var values: [String] { [client, consumer] }
  var canaries: [String] { [client, consumer, secret] }
}

/// Simulates a provider that echoes credentials into its failure text.
private struct EchoingFailureAdapter: NodeAdapter {
  let echoed: [String]

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw AdapterExecutionError(
      .providerError,
      "provider rejected credentials \(echoed.joined(separator: " ")); ordinary diagnostic survives",
      isRetryable: false
    )
  }

  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {}
}

private struct SyntheticError: Error, CustomStringConvertible {
  let text: String
  var description: String { text }
}

private struct ThrowingAdapter: NodeAdapter {
  let error: any Error
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw error
  }
  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {}
}

private struct SucceedingAdapter: NodeAdapter {
  let output: AdapterExecutionOutput
  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    output
  }
  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {}
}
