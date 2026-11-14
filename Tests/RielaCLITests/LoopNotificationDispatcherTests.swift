import Foundation
import RielaCore
import XCTest
@testable import RielaCLI

final class LoopNotificationDispatcherTests: XCTestCase {
  // MARK: - Outcome classification

  func testOutcomeMapping() {
    let acceptedGate = Self.gate("review", decision: .accepted)
    let rejectedGate = Self.gate("review", decision: .rejected)

    XCTAssertEqual(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .completed),
        manifest: Self.manifest(gates: [acceptedGate]),
        requiredGateIds: ["review"]
      ),
      .accepted
    )
    XCTAssertEqual(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .completed),
        manifest: Self.manifest(gates: [rejectedGate]),
        requiredGateIds: ["review"]
      ),
      .rejected
    )
    XCTAssertEqual(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .completed),
        manifest: Self.manifest(gates: []),
        requiredGateIds: ["review"]
      ),
      .rejected,
      "missing required gate on a completed session classifies as rejected"
    )
    XCTAssertEqual(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .failed, failureKind: .loopNotConverging),
        manifest: nil,
        requiredGateIds: []
      ),
      .stalled
    )
    XCTAssertEqual(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .failed, failureKind: .budgetExceeded),
        manifest: nil,
        requiredGateIds: []
      ),
      .failed
    )
    XCTAssertNil(
      LoopOutcomeClassifier.outcome(
        session: Self.session(status: .running),
        manifest: nil,
        requiredGateIds: []
      ),
      "non-terminal sessions never classify"
    )
  }

  // MARK: - Payload export safety

  func testPayloadIsExportSafe() throws {
    let manifest = Self.manifest(gates: [
      Self.gate(
        "review",
        decision: .rejected,
        findings: [LoopBlockingFinding(
          id: "f1",
          severity: "high",
          filePath: "/secret/path/leak.swift",
          message: "SECRET_FINDING_MESSAGE"
        )]
      )
    ])
    let payload = LoopOutcomeNotification.make(
      session: Self.session(status: .completed),
      manifest: manifest,
      outcome: .rejected
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encoded = try XCTUnwrap(String(data: encoder.encode(payload), encoding: .utf8))

    XCTAssertTrue(encoded.contains("\"outcome\":\"rejected\""))
    XCTAssertTrue(encoded.contains("\"blockingFindingCount\":1"))
    XCTAssertFalse(encoded.contains("SECRET_FINDING_MESSAGE"), "finding messages must not be exported")
    XCTAssertFalse(encoded.contains("/secret/path"), "file paths must not be exported")
    XCTAssertFalse(encoded.contains("message"), "no message field of any kind")
    XCTAssertFalse(encoded.contains("filePath"), "no path field of any kind")
  }

  // MARK: - Dispatch behavior

  func testWebhookDeliversWithEnvIndirection() async {
    let transport = RecordingTransport(failuresBeforeSuccess: 0)
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/hook", "HOOK_TOKEN": "tok"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["accepted"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL", bearerTokenEnv: "HOOK_TOKEN")
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .accepted)]),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )
    let posts = await transport.posts
    XCTAssertEqual(posts.count, 1)
    XCTAssertEqual(posts.first?.url.absoluteString, "https://example.invalid/hook")
    XCTAssertEqual(posts.first?.bearerToken, "tok")
    XCTAssertTrue(diagnostics.contains { $0.contains("delivered on attempt 1") })
  }

  func testWebhookMissingEnvIsSkippedWithDiagnosticNotError() async {
    let transport = RecordingTransport(failuresBeforeSuccess: 0)
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: [:],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["accepted"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .accepted)]),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )
    let skippedPosts = await transport.posts
    XCTAssertEqual(skippedPosts.count, 0)
    XCTAssertTrue(diagnostics.contains { $0.contains("skipped") && $0.contains("HOOK_URL") })
  }

  func testWebhookRetriesOnceThenSucceeds() async {
    let transport = RecordingTransport(failuresBeforeSuccess: 1)
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/hook"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["accepted"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .accepted)]),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )
    let retriedPosts = await transport.posts
    XCTAssertEqual(retriedPosts.count, 2, "exactly one retry")
    XCTAssertTrue(diagnostics.contains { $0.contains("attempt 1 failed") })
    XCTAssertTrue(diagnostics.contains { $0.contains("delivered on attempt 2") })
  }

  func testDispatchFailureNeverThrowsAndRecordsDiagnostics() async {
    let transport = RecordingTransport(failuresBeforeSuccess: 99)
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/hook"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["accepted"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .accepted)]),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )
    let failedPosts = await transport.posts
    XCTAssertEqual(failedPosts.count, 2)
    XCTAssertTrue(diagnostics.contains { $0.contains("attempt 2 failed") })
  }

  func testCommandChannelReceivesPayloadOnStdinAndTimesOut() async {
    let recorder = CommandRecorder()
    let dispatcher = LoopNotificationDispatcher(
      transport: RecordingTransport(failuresBeforeSuccess: 0),
      environment: [:],
      commandRunner: { argv, stdin, _, timeout in
        await recorder.record(argv: argv, stdin: stdin, timeout: timeout)
        throw CLIUsageError("notification command timed out after \(Int(timeout))s")
      }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["rejected"], channels: [
        LoopNotificationChannelDeclaration(type: "command", argv: ["scripts/notify.sh", "--loop"])
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .rejected)]),
      workflowDirectory: "/tmp/wf-does-not-exist",
      workingDirectory: "/tmp"
    )
    let calls = await recorder.calls
    XCTAssertEqual(calls.count, 2, "timeout retries once")
    XCTAssertEqual(calls.first?.argv.first, "scripts/notify.sh", "falls back to argv when not workflow-relative")
    XCTAssertEqual(calls.first?.timeout, 5)
    XCTAssertTrue((String(data: calls.first?.stdin ?? Data(), encoding: .utf8) ?? "").contains("\"outcome\":\"rejected\""))
    XCTAssertTrue(diagnostics.contains { $0.contains("timed out") })
  }

  func testUndeclaredOutcomeDispatchesNothing() async {
    let transport = RecordingTransport(failuresBeforeSuccess: 0)
    let dispatcher = LoopNotificationDispatcher(
      transport: transport,
      environment: ["HOOK_URL": "https://example.invalid/hook"],
      commandRunner: { _, _, _, _ in 0 }
    )
    let diagnostics = await dispatcher.dispatchIfDeclared(
      workflow: Self.workflow(on: ["failed"], channels: [
        LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
      ]),
      session: Self.session(status: .completed),
      manifest: Self.manifest(gates: [Self.gate("review", decision: .accepted)]),
      workflowDirectory: "/tmp/wf",
      workingDirectory: "/tmp"
    )
    let undeclaredPosts = await transport.posts
    XCTAssertEqual(undeclaredPosts.count, 0)
    XCTAssertTrue(diagnostics.isEmpty)
  }

  func testPackagedCommandChannelWarnsOnPortability() {
    let workflow = Self.workflow(on: ["accepted"], channels: [
      LoopNotificationChannelDeclaration(type: "command", argv: ["scripts/notify.sh"]),
      LoopNotificationChannelDeclaration(type: "webhook", urlEnv: "HOOK_URL")
    ])
    let warnings = packageLoopNotificationWarnings(for: workflow.loop)
    XCTAssertEqual(warnings.count, 1)
    XCTAssertEqual(warnings.first?.code, "LOOP_NOTIFICATION_PORTABILITY")
    XCTAssertEqual(warnings.first?.path, "workflow.loop.notifications.channels[0]")
  }

  // MARK: - Fixtures

  private struct RecordedCommand {
    var argv: [String]
    var stdin: Data
    var timeout: TimeInterval
  }

  private actor CommandRecorder {
    private(set) var calls: [RecordedCommand] = []

    func record(argv: [String], stdin: Data, timeout: TimeInterval) {
      calls.append(RecordedCommand(argv: argv, stdin: stdin, timeout: timeout))
    }
  }

  private struct RecordedPost {
    var url: URL
    var bearerToken: String?
    var body: Data
  }

  private actor RecordingTransport: LoopNotificationTransporting {
    private(set) var posts: [RecordedPost] = []
    private var failuresRemaining: Int

    init(failuresBeforeSuccess: Int) {
      self.failuresRemaining = failuresBeforeSuccess
    }

    func post(url: URL, bearerToken: String?, body: Data, timeoutSeconds: TimeInterval) async throws {
      posts.append(RecordedPost(url: url, bearerToken: bearerToken, body: body))
      if failuresRemaining > 0 {
        failuresRemaining -= 1
        throw CLIUsageError("simulated transport failure")
      }
    }
  }

  private static func workflow(
    on: [String],
    channels: [LoopNotificationChannelDeclaration]
  ) -> WorkflowDefinition {
    WorkflowDefinition(
      workflowId: "notify-demo",
      defaults: WorkflowDefaults(nodeTimeoutMs: 120_000, maxLoopIterations: 3),
      entryStepId: "review",
      nodeRegistry: [WorkflowNodeRegistryRef(id: "review-node", nodeFile: "nodes/review.json")],
      steps: [WorkflowStepRef(id: "review", nodeId: "review-node", role: .worker)],
      nodes: [WorkflowNodeRef(id: "review-node", nodeFile: "nodes/review.json")],
      loop: WorkflowLoopMetadata(
        notifications: LoopNotificationDeclaration(on: on, channels: channels),
        gates: [LoopGateDeclaration(
          id: "review",
          stepId: "review",
          required: true,
          acceptWhen: LoopGateAcceptancePolicy(decision: .accepted)
        )]
      )
    )
  }

  private static func session(
    status: WorkflowSessionStatus,
    failureKind: WorkflowSessionFailureKind? = nil
  ) -> WorkflowSession {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    var session = WorkflowSession(
      workflowId: "notify-demo",
      sessionId: "session-1",
      status: status,
      entryStepId: "review",
      createdAt: date,
      updatedAt: date.addingTimeInterval(60)
    )
    session.failureKind = failureKind
    return session
  }

  private static func gate(
    _ gateId: String,
    decision: LoopGateDecision,
    findings: [LoopBlockingFinding] = []
  ) -> LoopGateResult {
    LoopGateResult(
      gateId: gateId,
      stepId: gateId,
      stepExecutionId: "\(gateId)-exec",
      decision: decision,
      severityCounts: LoopFindingSeverityCounts(),
      blockingFindings: findings
    )
  }

  private static func manifest(gates: [LoopGateResult]) -> LoopEvidenceManifest {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    return LoopEvidenceManifest(
      schemaVersion: 1,
      manifestId: "loop-evidence-session-1",
      workflowId: "notify-demo",
      sessionId: "session-1",
      workflowSource: LoopWorkflowSource(scope: "project", kind: "workflow-directory", mutable: true),
      policy: LoopPolicyEvidence(),
      gates: gates,
      redaction: LoopRedactionSummary(policyName: "summary-only", status: "clean"),
      createdAt: date,
      updatedAt: date
    )
  }
}
