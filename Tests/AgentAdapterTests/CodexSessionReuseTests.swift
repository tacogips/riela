import XCTest
@testable import CodexAgent
@testable import RielaAdapters
@testable import RielaCore

final class CodexSessionReuseTests: XCTestCase {
  func testSessionIdExtractorAcceptsSupportedVariantsAndRejectsAmbiguity() {
    XCTAssertEqual(
      CodexSessionIdExtractor.observation(from: #"{"type":"thread.started","thread_id":"thread-1"}"#),
      .identified("thread-1")
    )
    XCTAssertEqual(
      CodexSessionIdExtractor.observation(
        from: #"{"type":"session_meta","meta":{"id":"thread-2"}}"#
      ),
      .identified("thread-2")
    )
    XCTAssertEqual(
      CodexSessionIdExtractor.observation(
        from: #"{"type":"session_meta","payload":{"sessionId":"thread-3"}}"#
      ),
      .identified("thread-3")
    )
    XCTAssertEqual(
      CodexSessionIdExtractor.observation(
        from: #"{"type":"thread.started","thread_id":"one"}"# + "\n"
          + #"{"type":"session_meta","session_id":"two"}"#
      ),
      .ambiguous
    )
    XCTAssertEqual(
      CodexSessionIdExtractor.observation(from: #"{"type":"session_meta","session_id":" "}"#),
      .none
    )
  }

  func testCapturedSessionIsResumedAndExplicitNewRemainsFresh() async throws {
    let runner = SequencedRunner([
      result(threadId: "thread-a", content: "one"),
      result(content: "two"),
      result(threadId: "thread-new", content: "three")
    ])
    let adapter = CodexAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(
      input(stepId: "first", mode: .new, workflowSessionId: "session"),
      context: AdapterExecutionContext()
    )
    _ = try await adapter.execute(
      input(stepId: "second", mode: .reuse, workflowSessionId: "session"),
      context: AdapterExecutionContext()
    )
    _ = try await adapter.execute(
      input(stepId: "third", mode: .new, workflowSessionId: "session"),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertTrue(runs[0].configuration.arguments.containsSubsequence(["exec", "--json"]))
    XCTAssertTrue(runs[1].configuration.arguments.containsSubsequence(["exec", "resume", "--json"]))
    XCTAssertTrue(runs[1].configuration.arguments.contains("thread-a"))
    XCTAssertEqual(runs[1].stdin, "resumed second")
    XCTAssertTrue(runs[2].configuration.arguments.containsSubsequence(["exec", "--json"]))
    XCTAssertFalse(runs[2].configuration.arguments.contains("resume"))
  }

  func testNamedInheritanceTargetsExactStepAndMissingTargetFallsBackFresh() async throws {
    let runner = SequencedRunner([
      result(threadId: "thread-a", content: "one"),
      result(threadId: "thread-b", content: "two"),
      result(content: "three"),
      result(threadId: "thread-fallback", content: "four")
    ])
    let adapter = CodexAgentAdapter(runner: runner, authPreflight: false)

    _ = try await adapter.execute(input(stepId: "a", mode: .new), context: AdapterExecutionContext())
    _ = try await adapter.execute(input(stepId: "b", mode: .new), context: AdapterExecutionContext())
    _ = try await adapter.execute(
      input(stepId: "inherit-a", mode: .reuse, inheritFromStepId: "a"),
      context: AdapterExecutionContext()
    )
    _ = try await adapter.execute(
      input(stepId: "missing", mode: .reuse, inheritFromStepId: "does-not-exist"),
      context: AdapterExecutionContext()
    )

    let runs = await runner.runs()
    XCTAssertTrue(runs[2].configuration.arguments.contains("thread-a"))
    XCTAssertFalse(runs[2].configuration.arguments.contains("thread-b"))
    XCTAssertFalse(runs[3].configuration.arguments.contains("resume"))
    XCTAssertEqual(runs[3].stdin, "fresh missing")
  }

  func testConcurrentBranchSessionsNeverShareThreads() async throws {
    let runner = BranchAwareRunner()
    let adapter = CodexAgentAdapter(runner: runner, authPreflight: false)
    let branchAFreshInput = input(stepId: "branch-a-first", mode: .reuse, workflowSessionId: "branch-a")
    let branchBFreshInput = input(stepId: "branch-b-first", mode: .reuse, workflowSessionId: "branch-b")

    async let firstFresh = adapter.execute(
      branchAFreshInput,
      context: AdapterExecutionContext()
    )
    async let secondFresh = adapter.execute(
      branchBFreshInput,
      context: AdapterExecutionContext()
    )
    _ = try await (firstFresh, secondFresh)
    let branchAResumeInput = input(stepId: "branch-a-second", mode: .reuse, workflowSessionId: "branch-a")
    let branchBResumeInput = input(stepId: "branch-b-second", mode: .reuse, workflowSessionId: "branch-b")

    async let firstResume = adapter.execute(
      branchAResumeInput,
      context: AdapterExecutionContext()
    )
    async let secondResume = adapter.execute(
      branchBResumeInput,
      context: AdapterExecutionContext()
    )
    _ = try await (firstResume, secondResume)

    let resumeRuns = await runner.runs().filter { $0.configuration.arguments.contains("resume") }
    XCTAssertEqual(resumeRuns.count, 2)
    XCTAssertEqual(Set(resumeRuns.compactMap(resumedSessionId)), ["thread-a", "thread-b"])
  }

  func testAuthSuccessIsCachedPerRunFailureRetriesAndCleanupEvicts() async throws {
    let successCounter = AuthCheckCounter()
    let runner = RecordingRunner(output: "done")
    let adapter = CodexAgentAdapter(
      runner: runner,
      checkAuthPreflight: { _ in try await successCounter.succeed() }
    )

    _ = try await adapter.execute(input(stepId: "one", mode: .new), context: AdapterExecutionContext())
    _ = try await adapter.execute(input(stepId: "two", mode: .new), context: AdapterExecutionContext())
    let initialSuccessCount = await successCounter.value()
    XCTAssertEqual(initialSuccessCount, 1)

    await adapter.workflowRunDidEnd(WorkflowRunLifecycleContext(workflowRunId: "run"))
    _ = try await adapter.execute(input(stepId: "three", mode: .new), context: AdapterExecutionContext())
    let postCleanupSuccessCount = await successCounter.value()
    XCTAssertEqual(postCleanupSuccessCount, 2)

    let retryCounter = AuthCheckCounter(failuresRemaining: 1)
    let retryAdapter = CodexAgentAdapter(
      runner: RecordingRunner(output: "done"),
      checkAuthPreflight: { _ in try await retryCounter.succeed() }
    )
    do {
      _ = try await retryAdapter.execute(input(stepId: "one", mode: .new), context: AdapterExecutionContext())
      XCTFail("Expected the first authentication check to fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .policyBlocked)
    }
    _ = try await retryAdapter.execute(input(stepId: "two", mode: .new), context: AdapterExecutionContext())
    let retryCount = await retryCounter.value()
    XCTAssertEqual(retryCount, 2)
  }

  func testAuthCancellationSurfacesAndIsNotCached() async throws {
    let counter = AuthCancellationCounter()
    let adapter = CodexAgentAdapter(
      runner: RecordingRunner(output: "done"),
      checkAuthPreflight: { _ in try await counter.check() }
    )
    do {
      _ = try await adapter.execute(input(stepId: "one", mode: .new), context: AdapterExecutionContext())
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
    _ = try await adapter.execute(input(stepId: "two", mode: .new), context: AdapterExecutionContext())
    let cancellationCount = await counter.value()
    XCTAssertEqual(cancellationCount, 2)
  }

  private func input(
    stepId: String,
    mode: NodeSessionMode,
    inheritFromStepId: String? = nil,
    workflowSessionId: String = "session"
  ) -> AdapterExecutionInput {
    AdapterExecutionInput(
      node: AgentNodePayload(
        id: stepId,
        executionBackend: .codexAgent,
        model: "model"
      ),
      promptText: "fresh \(stepId)",
      freshPromptText: "fresh \(stepId)",
      resumedPromptText: "resumed \(stepId)",
      sessionPolicy: WorkflowStepSessionPolicy(mode: mode, inheritFromStepId: inheritFromStepId),
      executionIdentity: AdapterExecutionIdentity(
        workflowRunId: "run",
        workflowSessionId: workflowSessionId,
        stepId: stepId
      )
    )
  }

  private func result(threadId: String? = nil, content: String) -> LocalAgentProcessResult {
    var lines: [String] = []
    if let threadId {
      lines.append(#"{"type":"thread.started","thread_id":"\#(threadId)"}"#)
    }
    lines.append(#"{"type":"assistant.snapshot","content":"\#(content)"}"#)
    return LocalAgentProcessResult(stdout: lines.joined(separator: "\n"), stderr: "", terminationStatus: 0)
  }

  private func resumedSessionId(_ run: RecordedRun) -> String? {
    guard let separatorIndex = run.configuration.arguments.lastIndex(of: "--") else {
      return nil
    }
    let sessionIndex = run.configuration.arguments.index(after: separatorIndex)
    guard sessionIndex < run.configuration.arguments.endIndex else {
      return nil
    }
    return run.configuration.arguments[sessionIndex]
  }
}

private actor BranchAwareRunner: LocalAgentProcessRunning {
  private var recordedRuns: [RecordedRun] = []

  func run(
    configuration: LocalAgentProcessConfiguration,
    stdin: String,
    deadline: Date?
  ) async throws -> LocalAgentProcessResult {
    recordedRuns.append(RecordedRun(configuration: configuration, stdin: stdin, deadline: deadline))
    let threadId = stdin.contains("branch-a") ? "thread-a" : "thread-b"
    let threadLine = configuration.arguments.contains("resume")
      ? ""
      : #"{"type":"thread.started","thread_id":"\#(threadId)"}"# + "\n"
    return LocalAgentProcessResult(
      stdout: threadLine + #"{"type":"assistant.snapshot","content":"done"}"#,
      stderr: "",
      terminationStatus: 0
    )
  }

  func runs() -> [RecordedRun] {
    recordedRuns
  }
}

private actor AuthCheckCounter {
  private var count = 0
  private var failuresRemaining: Int

  init(failuresRemaining: Int = 0) {
    self.failuresRemaining = failuresRemaining
  }

  func succeed() throws {
    count += 1
    if failuresRemaining > 0 {
      failuresRemaining -= 1
      throw AdapterExecutionError(.policyBlocked, "authentication failed")
    }
  }

  func value() -> Int {
    count
  }
}

private actor AuthCancellationCounter {
  private var count = 0

  func check() throws {
    count += 1
    if count == 1 {
      throw CancellationError()
    }
  }

  func value() -> Int {
    count
  }
}
