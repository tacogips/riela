import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

private final class RetryAttemptRecorder: @unchecked Sendable {
  private let queue = DispatchQueue(label: "riela.adapter-utilities-test-retry-attempts")
  private var count = 0

  func increment() -> Int {
    queue.sync {
      count += 1
      return count
    }
  }

  func value() -> Int {
    queue.sync {
      count
    }
  }
}

final class AdapterUtilitiesTests: XCTestCase {
  func testRetryPolicyClampsAttemptsAndDelay() {
    let policy = RetryPolicy(maxAttempts: 0, retryDelay: .milliseconds(-50))

    XCTAssertEqual(policy.maxAttempts, 1)
    XCTAssertEqual(policy.retryDelay, .zero)
  }

  func testExecuteWithRetryRetriesProviderFailuresBeforeDeadline() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .zero),
      deadline: Date(timeIntervalSince1970: 200),
      now: { Date(timeIntervalSince1970: 100) },
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.providerError, "temporary")
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetrySkipsProviderRetryWhenDeadlineCannotCoverDelay() async {
    let attempts = RetryAttemptRecorder()

    do {
      let _: String = try await executeWithRetry(
        policy: RetryPolicy(maxAttempts: 3, retryDelay: .milliseconds(100)),
        deadline: Date(timeIntervalSince1970: 100.05),
        now: { Date(timeIntervalSince1970: 100) },
        operation: {
          _ = attempts.increment()
          throw AdapterExecutionError(.providerError, "temporary")
        },
        normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
      )
      XCTFail("Expected provider error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "temporary")
      XCTAssertEqual(attempts.value(), 1)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testExecuteWithRetryDoesNotRetryTimeoutWhenDeadlineIsSet() async {
    let attempts = RetryAttemptRecorder()

    do {
      let _: String = try await executeWithRetry(
        policy: RetryPolicy(maxAttempts: 3, retryDelay: .zero),
        deadline: Date(timeIntervalSince1970: 200),
        now: { Date(timeIntervalSince1970: 100) },
        operation: {
          _ = attempts.increment()
          throw AdapterExecutionError(.timeout, "timed out")
        },
        normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
      )
      XCTFail("Expected timeout")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.message, "timed out")
      XCTAssertEqual(attempts.value(), 1)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testExecuteWithRetryStillRetriesTimeoutWithoutDeadline() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .zero),
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.timeout, "timed out")
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetryHonorsRetryAfterBeforePolicyDelay() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .seconds(30)),
      deadline: Date(timeIntervalSince1970: 100.05),
      now: { Date(timeIntervalSince1970: 100) },
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.providerError, "rate limited", retryAfter: .milliseconds(1))
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetryAppliesBackoffMultiplierToLaterAttempts() async {
    let attempts = RetryAttemptRecorder()

    do {
      let _: String = try await executeWithRetry(
        policy: RetryPolicy(maxAttempts: 3, retryDelay: .milliseconds(1), backoffMultiplier: 10),
        deadline: Date(timeIntervalSince1970: 100.005),
        now: { Date(timeIntervalSince1970: 100) },
        operation: {
          _ = attempts.increment()
          throw AdapterExecutionError(.providerError, "temporary")
        },
        normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
      )
      XCTFail("Expected provider error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(attempts.value(), 2)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testExecuteWithRetryCapsDelayAtMaxDelay() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .seconds(10), maxDelay: .milliseconds(1)),
      deadline: Date(timeIntervalSince1970: 100.005),
      now: { Date(timeIntervalSince1970: 100) },
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.providerError, "temporary")
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetryCapsRetryAfterAtMaxDelay() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .seconds(30), maxDelay: .milliseconds(1)),
      deadline: Date(timeIntervalSince1970: 100.005),
      now: { Date(timeIntervalSince1970: 100) },
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.providerError, "rate limited", retryAfter: .seconds(60))
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetryAppliesFullJitterDelay() async throws {
    let attempts = RetryAttemptRecorder()

    let output: String = try await executeWithRetry(
      policy: RetryPolicy(maxAttempts: 2, retryDelay: .seconds(10), useJitter: true),
      deadline: Date(timeIntervalSince1970: 100.005),
      now: { Date(timeIntervalSince1970: 100) },
      randomUnitInterval: { 0 },
      operation: {
        if attempts.increment() == 1 {
          throw AdapterExecutionError(.providerError, "temporary")
        }
        return "ok"
      },
      normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
    )

    XCTAssertEqual(output, "ok")
    XCTAssertEqual(attempts.value(), 2)
  }

  func testExecuteWithRetrySkipsErrorsMarkedNonRetryable() async {
    let attempts = RetryAttemptRecorder()

    do {
      let _: String = try await executeWithRetry(
        policy: RetryPolicy(maxAttempts: 3, retryDelay: .zero),
        operation: {
          _ = attempts.increment()
          throw AdapterExecutionError(.providerError, "bad request", isRetryable: false)
        },
        normalizeError: { normalizeAdapterFailure($0, fallbackMessage: "adapter failed") }
      )
      XCTFail("Expected provider error")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.isRetryable, false)
      XCTAssertEqual(attempts.value(), 1)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testExecuteWithRetryRethrowsCancellationWithoutNormalizing() async {
    let attempts = RetryAttemptRecorder()

    do {
      let _: String = try await executeWithRetry(
        policy: RetryPolicy(maxAttempts: 3, retryDelay: .zero),
        operation: {
          _ = attempts.increment()
          throw CancellationError()
        },
        normalizeError: { _ in
          XCTFail("Cancellation should bypass adapter failure normalization")
          return AdapterExecutionError(.providerError, "unexpected")
        }
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      XCTAssertEqual(attempts.value(), 1)
    } catch {
      XCTFail("Expected cancellation, got \(error)")
    }
  }

  func testBuildCombinedPromptTextPreservesSystemPromptBoundary() {
    XCTAssertEqual(
      buildCombinedPromptText(promptText: "Do work", systemPromptText: "Be concise"),
      "Be concise\n\nDo work"
    )
    XCTAssertEqual(buildCombinedPromptText(promptText: "Do work", systemPromptText: "  "), "Do work")
  }

  func testResolveBackendRequiresExplicitBackend() throws {
    let node = AgentNodePayload(id: "worker", model: "gpt-5")

    XCTAssertThrowsError(try resolveNodeExecutionBackend(node)) { error in
      let adapterError = error as? AdapterExecutionError
      XCTAssertEqual(adapterError?.code, .providerError)
    }
  }

  func testResolveAdapterImagePathsFindsGatewayDescriptorPathKeys() {
    let input = AdapterExecutionInput(
      node: AgentNodePayload(id: "worker", model: "gpt-5"),
      promptText: "hello",
      mergedVariables: [
        "workflowInput": .object([
          "imagePaths": .array([.string("/tmp/from-image-paths.png")]),
          "attachments": .array([
            .object([
              "kind": .string("image"),
              "mediaType": .string("image/jpeg"),
              "path": .string("/tmp/from-path.jpg")
            ]),
            .object([
              "contentType": .string("image/png"),
              "localPath": .string("/tmp/from-local-path.png")
            ]),
            .object([
              "mediaType": .string("image/webp"),
              "source": .object([
                "downloadPath": .string("/tmp/from-source-download.webp")
              ])
            ]),
            .object([
              "kind": .string("photo"),
              "mimeType": .string("image/png"),
              "downloadPath": .string("/tmp/from-photo-kind.png")
            ])
          ])
        ])
      ]
    )

    XCTAssertEqual(
      resolveAdapterImagePaths(input),
      [
        "/tmp/from-image-paths.png",
        "/tmp/from-path.jpg",
        "/tmp/from-local-path.png",
        "/tmp/from-source-download.webp",
        "/tmp/from-photo-kind.png"
      ]
    )
  }

  func testOutputContractEnvelopeDefaultsAndBusinessPayloadFallback() throws {
    let envelope = try normalizeOutputContractEnvelope(
      ["when": .object(["accepted": .bool(true)]), "payload": .object(["status": .string("ok")])],
      source: "adapterOutput"
    )

    XCTAssertTrue(envelope.usedEnvelope)
    XCTAssertTrue(envelope.completionPassed)
    XCTAssertEqual(envelope.when, ["accepted": true])
    XCTAssertEqual(envelope.payload, ["status": .string("ok")])

    let businessPayload = try normalizeOutputContractEnvelope(
      ["status": .string("ok")],
      source: "adapterOutput",
      defaults: (false, ["retry": true])
    )

    XCTAssertFalse(businessPayload.usedEnvelope)
    XCTAssertFalse(businessPayload.completionPassed)
    XCTAssertEqual(businessPayload.when, ["retry": true])
    XCTAssertEqual(businessPayload.payload, ["status": .string("ok")])
  }

  func testOutputContractEnvelopeDoesNotApplyLoopRoutingByDefault() throws {
    let envelope = try normalizeOutputContractEnvelope(
      [
        "when": .object(["always": .bool(true)]),
        "payload": .object([
          "accepted": .bool(false),
          "goalAchieved": .bool(false),
          "decision": .string("needs_work")
        ])
      ],
      source: "goal-review"
    )

    XCTAssertEqual(envelope.when, ["always": true])
    XCTAssertEqual(envelope.routingDiagnostics, [])
  }

  func testLoopCompletionReviewReconcilerCanBeAppliedExplicitly() throws {
    let envelope = try normalizeOutputContractEnvelope(
      [
        "when": .object(["always": .bool(true)]),
        "payload": .object([
          "accepted": .bool(false),
          "goalAchieved": .bool(false),
          "decision": .string("needs_work")
        ])
      ],
      source: "goal-review",
      routingReconciler: reconcileCompletionReviewRouting
    )

    XCTAssertEqual(envelope.when, ["needs_replan": false, "needs_work": true])
    XCTAssertEqual(envelope.routingDiagnostics.count, 1)
  }

  func testOutputContractEnvelopeRequiresBooleanWhenObjectPayloadAndBooleanCompletionPassed() {
    XCTAssertThrowsError(
      try normalizeOutputContractEnvelope(
        ["when": .object(["accepted": .string("yes")]), "payload": .object([:])],
        source: "adapterOutput"
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }

    XCTAssertThrowsError(
      try normalizeOutputContractEnvelope(
        ["when": .object(["accepted": .bool(true)]), "payload": .array([])],
        source: "adapterOutput"
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }

    XCTAssertThrowsError(
      try normalizeOutputContractEnvelope(
        [
          "completionPassed": .string("false"),
          "when": .object(["accepted": .bool(true)]),
          "payload": .object([:])
        ],
        source: "adapterOutput"
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testOutputContractEnvelopeNormalizesFlattenedWhenWithoutPayload() throws {
    // Observed from a claude-code reviewer: routing flags mirrored into `when`,
    // business fields left beside it instead of under `payload`.
    let envelope = try normalizeOutputContractEnvelope(
      [
        "when": .object(["needs_revision": .bool(false), "plans_remaining": .bool(true)]),
        "needs_revision": .bool(false),
        "plans_remaining": .bool(true),
        "accepted": .bool(true),
        "loopGate": .object(["decision": .string("accepted")])
      ],
      source: "agent-gateway/claude-code"
    )

    XCTAssertTrue(envelope.usedEnvelope)
    XCTAssertTrue(envelope.completionPassed)
    XCTAssertEqual(envelope.when, ["needs_revision": false, "plans_remaining": true])
    XCTAssertEqual(
      envelope.payload,
      [
        "needs_revision": .bool(false),
        "plans_remaining": .bool(true),
        "accepted": .bool(true),
        "loopGate": .object(["decision": .string("accepted")])
      ]
    )
    XCTAssertEqual(envelope.routingDiagnostics.count, 1)

    let flattenedWithCompletion = try normalizeOutputContractEnvelope(
      ["completionPassed": .bool(false), "when": .object(["retry": .bool(true)]), "status": .string("x")],
      source: "adapterOutput"
    )
    XCTAssertFalse(flattenedWithCompletion.completionPassed)
    XCTAssertEqual(flattenedWithCompletion.payload, ["status": .string("x")])

    let renormalized = try normalizeOutputContractEnvelope(
      envelope.payload,
      source: "adapterOutput",
      defaults: (envelope.completionPassed, envelope.when)
    )
    XCTAssertFalse(renormalized.usedEnvelope)
    XCTAssertEqual(renormalized.when, ["needs_revision": false, "plans_remaining": true])
    XCTAssertEqual(renormalized.payload, envelope.payload)

    XCTAssertThrowsError(
      try normalizeOutputContractEnvelope(
        ["when": .object(["accepted": .string("yes")]), "status": .string("ok")],
        source: "adapterOutput"
      )
    ) { error in
      XCTAssertEqual((error as? AdapterExecutionError)?.code, .invalidOutput)
    }
  }

  func testParseJSONCandidatePicksFencedJSONBlockAfterNonJSONFence() throws {
    let text = """
      I will continue thinking and providing output in English. Here is a snippet:
      ```tsx
      const view = { kind: "month" };
      ```
      And the structured result:
      ```json
      {"designAccepted": true, "payload": {"summary": "calendar design"}}
      ```
      """
    let object = try parseJSONObjectCandidate(text, source: "adapterOutput")
    XCTAssertEqual(object["designAccepted"], .bool(true))
    XCTAssertEqual(object["payload"], .object(["summary": .string("calendar design")]))
  }

  func testParseJSONCandidateFallsBackWhenFencedJSONContainsInnerFence() throws {
    let text = """
      Preamble prose before the payload.
      ```json
      {"designMarkdown": "example:\\n```ts\\nconst a = 1;\\n```\\ndone", "accepted": true}
      ```
      """
    let object = try parseJSONObjectCandidate(text, source: "adapterOutput")
    XCTAssertEqual(object["accepted"], .bool(true))
    XCTAssertEqual(
      object["designMarkdown"],
      .string("example:\n```ts\nconst a = 1;\n```\ndone")
    )
  }

  func testParseJSONCandidateStillAcceptsUntaggedFencedObject() throws {
    let text = """
      result below
      ```
      {"ok": true}
      ```
      """
    let object = try parseJSONObjectCandidate(text, source: "adapterOutput")
    XCTAssertEqual(object["ok"], .bool(true))
  }

  func testParseJSONCandidateIgnoresEscapedQuotedBracesBeforeBalancedObject() throws {
    let object = try parseJSONObjectCandidate(
      #"prefix "{ \"ignored\": { not json } }" {"payload":{"text":"brace } and escaped quote \" still string"},"when":{"done":true}} suffix"#,
      source: "adapterOutput"
    )

    XCTAssertEqual(object["payload"], .object(["text": .string(#"brace } and escaped quote " still string"#)]))
    XCTAssertEqual(object["when"], .object(["done": .bool(true)]))
  }

  func testRedactingAdapterKeepsCodeAndRetryMetadataAndRedactsSnapshotAndAgentValues() async throws {
    let snapshotToken = "snapshot-token-canary-\(UUID().uuidString)"
    let agentToken = "agent-token-canary-\(UUID().uuidString)"
    let shortPublic = "true"
    let primary = FailingRecordingAdapter(error: AdapterExecutionError(
      .timeout, "failed with \(snapshotToken) and \(agentToken) flag=\(shortPublic)",
      isRetryable: true, retryAfter: .seconds(3)
    ))
    let adapter = AdapterFailureRedactingNodeAdapter(
      primary: primary, environment: ["SERVICE_TOKEN": snapshotToken, "FEATURE_TOKEN_ENABLED": shortPublic]
    )
    var input = AdapterExecutionInput(node: AgentNodePayload(id: "worker", model: "gpt-5"), promptText: "hello")
    input.agentEnvironment = ["AGENT_API_KEY": agentToken]
    do {
      _ = try await adapter.execute(input, context: AdapterExecutionContext())
      XCTFail("expected failure")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .timeout)
      XCTAssertEqual(error.isRetryable, true)
      XCTAssertEqual(error.retryAfter, .seconds(3))
      XCTAssertFalse(error.message.contains(snapshotToken))
      XCTAssertFalse(error.message.contains(agentToken))
      XCTAssertTrue(error.message.contains("flag=true"), error.message)
    }
    await adapter.workflowRunDidEnd(WorkflowRunLifecycleContext(workflowRunId: "run-1"))
    let ended = await primary.endedRuns()
    XCTAssertEqual(ended, ["run-1"])
  }

  func testRedactingAdapterPassesCancellationThrough() async {
    let adapter = AdapterFailureRedactingNodeAdapter(
      primary: FailingRecordingAdapter(error: CancellationError()), environment: [:]
    )
    do {
      _ = try await adapter.execute(
        AdapterExecutionInput(node: AgentNodePayload(id: "worker", model: "gpt-5"), promptText: "hello"),
        context: AdapterExecutionContext()
      )
      XCTFail("expected cancellation")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }
}

private actor FailingRecordingAdapter: NodeAdapter {
  let error: any Error
  private var ended: [String] = []

  init(error: any Error) {
    self.error = error
  }

  func execute(_ input: AdapterExecutionInput, context: AdapterExecutionContext) async throws -> AdapterExecutionOutput {
    throw error
  }

  func workflowRunDidEnd(_ context: WorkflowRunLifecycleContext) async {
    ended.append(context.workflowRunId)
  }

  func endedRuns() -> [String] { ended }
}
