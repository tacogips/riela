import RielaCore
import XCTest
@testable import RielaCLI

extension WorkflowCommandTests {
  func testSessionCommandJSONLHandlerForwardsBackendAndSilenceEvents() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-jsonl-events-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }
    let resolution = WorkflowResolutionOptions(
      workflowName: "worker-only-single-step",
      scope: .direct,
      workflowDefinitionDir: "\(root)/examples",
      workingDirectory: root
    )
    let bundle = try CLIRuntimeEnvironment.$overrides.withValue(["HOME": sessionStore.path]) {
      try FileSystemWorkflowBundleResolver().resolve(resolution)
    }
    let recorder = WorkflowRunJSONLRecorder(writer: nil)
    let handler = await makeSessionCommandLivePersistenceHandler(
      configuration: SessionLivePersistenceConfig(
        workflowName: "worker-only-single-step",
        requestedScope: .auto,
        resolution: resolution,
        storeRoot: sessionStore.path,
        bundle: bundle,
        variables: [:],
        runtimeStore: InMemoryWorkflowRuntimeStore(),
        mockScenarioPath: nil,
        workingDirectory: root
      ),
      recorder: recorder
    )

    await handler(WorkflowRunEvent(
      type: .backendEvent,
      workflowId: "worker-only-single-step",
      sessionId: "session-live-events",
      stepId: "main-worker",
      backendEventType: "assistant_message",
      backendEventContent: "still working"
    ))
    await handler(WorkflowRunEvent(
      type: .silenceWarning,
      workflowId: "worker-only-single-step",
      sessionId: "session-live-events",
      stepId: "main-worker",
      silentForMs: 30_000,
      silenceThresholdMs: 30_000
    ))

    let lines = await recorder.bufferedOutput().split(separator: "\n").map(String.init)
    XCTAssertTrue(lines.contains { $0.contains(#""type":"backend_event""#) })
    XCTAssertTrue(lines.contains { $0.contains(#""type":"silence_warning""#) })
  }

  func testSessionRerunAndResumeJSONLWritersReceiveLiveEventsAndFinalResults() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-session-jsonl-live-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let initialRun = await RielaCLIApplication().run([
      "workflow", "run", "worker-only-single-step",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ], environment: ["HOME": sessionStore.path])
    XCTAssertEqual(initialRun.exitCode, .success, initialRun.stderr)
    let initialResult = try decodeJSON(WorkflowRunResult.self, from: initialRun.stdout)

    let rerunProbe = JSONLWriterProbe(sessionStore: sessionStore)
    let rerunApp = RielaCLIApplication(
      sessionRerunCommand: SessionRerunCommand(jsonlRecordWriter: rerunProbe.record)
    )
    let rerun = await rerunApp.run([
      "session", "rerun", initialResult.session.sessionId, "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--output", "jsonl"
    ], environment: ["HOME": sessionStore.path])

    XCTAssertEqual(rerun.exitCode, .success, rerun.stderr)
    XCTAssertTrue(rerun.stdout.isEmpty)
    XCTAssertTrue(rerunProbe.persistedAtSessionStart())
    let rerunLines = rerunProbe.lines()
    try assertLiveSessionRecords(
      rerunLines,
      workflowName: "worker-only-single-step",
      sessionStore: sessionStore.path
    )
    let rerunResult = try decodeJSON(SessionRerunCommandResult.self, from: try XCTUnwrap(rerunLines.last))
    XCTAssertEqual(rerunResult.type, "rerun_result")
    XCTAssertEqual(rerunResult.sourceSessionId, initialResult.session.sessionId)
    XCTAssertEqual(rerunResult.status, .completed)
    XCTAssertEqual(rerunLines.filter { $0.contains(#""type":"rerun_result""#) }.count, 1)

    let recoverProbe = JSONLWriterProbe(sessionStore: sessionStore)
    let recoverApp = RielaCLIApplication(
      loopCommandRunner: LoopCommandRunner(
        sessionRerunCommand: SessionRerunCommand(jsonlRecordWriter: recoverProbe.record)
      )
    )
    let recover = await recoverApp.run([
      "loop", "recover", initialResult.session.sessionId,
      "--from-step", "main-worker",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/worker-only-single-step/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--output", "jsonl"
    ], environment: ["HOME": sessionStore.path])

    XCTAssertEqual(recover.exitCode, .success, recover.stderr)
    XCTAssertTrue(recover.stdout.isEmpty)
    XCTAssertTrue(recoverProbe.persistedAtSessionStart())
    let recoverLines = recoverProbe.lines()
    try assertLiveSessionRecords(
      recoverLines,
      workflowName: "worker-only-single-step",
      sessionStore: sessionStore.path
    )
    XCTAssertEqual(recoverLines.filter { $0.contains(#""type":"rerun_result""#) }.count, 1)

    let interruptedRun = await RielaCLIApplication().run([
      "workflow", "run", "recent-change-quality-loop",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "json"
    ], environment: ["HOME": sessionStore.path])
    XCTAssertEqual(interruptedRun.exitCode, .failure, interruptedRun.stderr)
    let interruptedResult = try decodeJSON(WorkflowRunFailureResult.self, from: interruptedRun.stdout)
    XCTAssertEqual(interruptedResult.failureKind, .maxStepsExceeded)
    let interruptedSessionId = try XCTUnwrap(interruptedResult.sessionId)

    let continueProbe = JSONLWriterProbe(sessionStore: sessionStore)
    let continueApp = RielaCLIApplication(
      sessionContinueCommand: SessionContinueCommand(
        sessionResumeCommand: SessionResumeCommand(jsonlRecordWriter: continueProbe.record)
      )
    )
    let continued = await continueApp.run([
      "session", "continue", interruptedSessionId,
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--max-steps", "10",
      "--output", "jsonl"
    ], environment: ["HOME": sessionStore.path])

    XCTAssertEqual(continued.exitCode, .success, continued.stderr)
    XCTAssertTrue(continued.stdout.isEmpty)
    XCTAssertTrue(continueProbe.persistedAtSessionStart())
    let continueLines = continueProbe.lines()
    try assertLiveSessionRecords(
      continueLines,
      workflowName: "recent-change-quality-loop",
      sessionStore: sessionStore.path
    )
    XCTAssertEqual(continueLines.filter { $0.contains(#""type":"resume_result""#) }.count, 1)

    let secondInterruptedRun = await RielaCLIApplication().run([
      "workflow", "run", "recent-change-quality-loop",
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--max-steps", "1",
      "--output", "json"
    ], environment: ["HOME": sessionStore.path])
    XCTAssertEqual(secondInterruptedRun.exitCode, .failure, secondInterruptedRun.stderr)
    let secondInterruptedResult = try decodeJSON(WorkflowRunFailureResult.self, from: secondInterruptedRun.stdout)
    let secondInterruptedSessionId = try XCTUnwrap(secondInterruptedResult.sessionId)

    let resumeProbe = JSONLWriterProbe(sessionStore: sessionStore)
    let resumeApp = RielaCLIApplication(
      sessionResumeCommand: SessionResumeCommand(jsonlRecordWriter: resumeProbe.record)
    )
    let resume = await resumeApp.run([
      "session", "resume", secondInterruptedSessionId,
      "--workflow-definition-dir", "\(root)/examples",
      "--mock-scenario", "\(root)/examples/recent-change-quality-loop/mock-scenario.json",
      "--working-directory", sessionStore.path,
      "--session-store", sessionStore.path,
      "--max-steps", "10",
      "--output", "jsonl"
    ], environment: ["HOME": sessionStore.path])

    XCTAssertEqual(resume.exitCode, .success, resume.stderr)
    XCTAssertTrue(resume.stdout.isEmpty)
    XCTAssertTrue(resumeProbe.persistedAtSessionStart())
    let resumeLines = resumeProbe.lines()
    try assertLiveSessionRecords(
      resumeLines,
      workflowName: "recent-change-quality-loop",
      sessionStore: sessionStore.path
    )
    let resumeResult = try decodeJSON(SessionResumeCommandResult.self, from: try XCTUnwrap(resumeLines.last))
    XCTAssertEqual(resumeResult.type, "resume_result")
    XCTAssertEqual(resumeResult.sourceSessionId, secondInterruptedSessionId)
    XCTAssertEqual(resumeResult.status, .completed)
    XCTAssertEqual(resumeLines.filter { $0.contains(#""type":"resume_result""#) }.count, 1)
  }

  private func assertLiveSessionRecords(
    _ lines: [String],
    workflowName: String,
    sessionStore: String
  ) throws {
    XCTAssertGreaterThanOrEqual(lines.count, 4)
    let first = try decodeJSON(WorkflowRunEvent.self, from: try XCTUnwrap(lines.first))
    XCTAssertEqual(first.type, .sessionStarted)

    let contextLine = try XCTUnwrap(lines.first { $0.contains(#""type":"run_context""#) })
    let context = try decodeJSON(WorkflowRunContextRecord.self, from: contextLine)
    XCTAssertEqual(context.sessionId, first.sessionId)
    XCTAssertEqual(context.workflowName, workflowName)
    XCTAssertEqual(context.sessionStore, sessionStore)
    XCTAssertEqual(context.scope, .auto)

    XCTAssertTrue(lines.contains { $0.contains(#""type":"step_started""#) })
    XCTAssertTrue(lines.contains { $0.contains(#""type":"session_completed""#) })
  }

  func testSessionCommandJSONLRenderingUsesValidFallbackWhenEncodingFails() async throws {
    let result = await renderSessionCommandStructuredPayload(
      ThrowingSessionPayload(),
      output: .jsonl,
      exitCode: .failure,
      jsonlRecorder: WorkflowRunJSONLRecorder(writer: nil)
    )

    let lines = result.stdout.split(separator: "\n")
    XCTAssertEqual(lines.count, 1)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    )
    XCTAssertEqual(object["type"] as? String, "session_encode_failed")

    let failure = SessionCommandFailureResult(sessionId: "session-1", error: "failed", exitCode: 1)
    let failureObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(try jsonString(failure).utf8)) as? [String: Any]
    )
    XCTAssertEqual(failureObject["type"] as? String, "session_failure")
  }
}

private struct ThrowingSessionPayload: Encodable {
  func encode(to encoder: any Encoder) throws {
    throw EncodingError.invalidValue(
      "unencodable",
      EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "test failure")
    )
  }
}
