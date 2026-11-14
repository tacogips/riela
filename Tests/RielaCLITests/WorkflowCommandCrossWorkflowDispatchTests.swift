import Foundation
import Darwin
import RielaCore
import XCTest
@testable import RielaCLI

/// End-to-end live cross-workflow dispatch through the CLI without any agent
/// backend: the caller and callee are command-node workflows resolved from the
/// same --workflow-definition-dir root (examples/workflow-call-live-echo).
final class WorkflowCommandCrossWorkflowDispatchTests: XCTestCase {
  private struct WorkflowProcessResult {
    let status: Int32
    let terminationReason: Process.TerminationReason
    let stdout: String
    let stderr: String
  }

  func testLiveRunDispatchesCalleeWorkflowAndResumesWithCalleeResult() async throws {
    let root = repositoryRoot()
    let sessionStore = FileManager.default.temporaryDirectory
      .appendingPathComponent("riela-cross-workflow-live-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: sessionStore) }

    let run = await RielaCLIApplication().run([
      "workflow", "run", "workflow-call-live-echo",
      "--workflow-definition-dir", "\(root)/examples",
      "--session-store", sessionStore.path,
      "--output", "json"
    ])

    XCTAssertEqual(run.exitCode, .success, run.stderr + run.stdout)
    let result = try decodeJSON(WorkflowRunResult.self, from: run.stdout)
    XCTAssertEqual(result.workflowId, "workflow-call-live-echo")
    XCTAssertEqual(result.status, .completed)
    XCTAssertEqual(result.session.executions.map(\.stepId), ["produce-request", "apply-result"])
    XCTAssertEqual(result.rootOutput?["status"], .string("applied"))
    XCTAssertEqual(
      result.rootOutput?["receivedCalleeResult"],
      .string("echoed:outbound-request"),
      "resume step must receive the callee root output, not the outbound handoff echo"
    )

    // Reopen the canonical runtime journal after a real WorkflowRunCommand
    // cross-workflow run. The prepared snapshot has an active callee entry,
    // while the terminal snapshot is complete; success proves terminal
    // publication reused the exact persisted reservation rather than trying
    // to reconstruct it from the terminal session.
    let reopened = SQLiteWorkflowRuntimePersistenceStore(
      rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
    )
    let sourceExecutionId = try XCTUnwrap(
      result.session.executions.first(where: { $0.stepId == "produce-request" })?.executionId
    )
    let record = try XCTUnwrap(try reopened.nestedInvocationRecord(
      parentSessionId: result.session.sessionId,
      sourceStepExecutionId: sourceExecutionId,
      branchId: "cross-workflow"
    ))
    XCTAssertNotNil(record.reservation.childSnapshot.session.currentStepId)
    XCTAssertEqual(record.reservation.childSnapshot.session.status, .created)
    XCTAssertEqual(record.childTerminalSnapshot?.session.status, .completed)
    XCTAssertEqual(record.phase, .delivered)
    let parentArrivals = try SQLiteWorkflowMessageLog(
      databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      )
    ).listMessages(workflowExecutionId: result.session.sessionId, toStepId: "apply-result")
    XCTAssertEqual(parentArrivals.count, 1)
  }

  func testValidateReportsNoCapabilityGapForSupportedCrossWorkflowDispatchShape() async throws {
    let root = repositoryRoot()
    let validate = await RielaCLIApplication().run([
      "workflow", "validate", "workflow-call-live-echo",
      "--workflow-definition-dir", "\(root)/examples",
      "--output", "json"
    ])

    XCTAssertEqual(validate.exitCode, .success, validate.stderr + validate.stdout)
    let result = try decodeJSON(WorkflowValidationCommandResult.self, from: validate.stdout)
    XCTAssertTrue(result.valid)
    XCTAssertTrue(
      result.diagnostics.isEmpty,
      "cross-workflow dispatch with resumeStepId is supported live and must not report gaps: \(result.diagnostics)"
    )
  }

  /// Every stop is an uncatchable SIGKILL in a separate ordinary-production
  /// `riela` process. The fixture's child command writes an independent
  /// durable effect marker before emitting its result. At `.prepared`, the
  /// parent stage is intentionally still in memory: no staged parent output,
  /// nested intent, or child snapshot may be durable until the canonical
  /// transaction. The resumed process gets all state exclusively from
  /// canonical SQLite.
  func testSubprocessAbruptTerminationCheckpointsReopenCanonicalSQLiteWithoutDuplicatingDurableEffect() throws {
    let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let executable = try currentWorkflowExecutable(repository: repository)
    let checkpoints: [NestedRecoveryCheckpoint] = [
      .prepared,
      .beforeChildNodeEffect,
      .afterChildEffect,
      .afterChildNodeResult,
      .childTerminalPersisted,
      .parentIntentPersisted,
      .beforeParentPublication,
      .parentPublicationPersisted
    ]

    for checkpoint in checkpoints {
      let sessionStore = repository
        .appendingPathComponent("tmp/specialist-supervisor/process-recovery/\(checkpoint.rawValue)-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: sessionStore, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: sessionStore) }
      let fixtureRoot = try durableEffectFixture(repository: repository, sessionStore: sessionStore)
      let effectMarker = sessionStore.appendingPathComponent("child-effect.marker")

      let interrupted = try runWorkflowProcess(
        executable: executable,
        repository: repository,
        arguments: workflowRunArguments(sessionStore: sessionStore, workflowRoot: fixtureRoot),
        environment: [
          "RIELA_ENABLE_TEST_FAILPOINTS": "1",
          "RIELA_TEST_NESTED_RECOVERY_CHECKPOINT": checkpoint.rawValue,
          "RIELA_TEST_EFFECT_MARKER": effectMarker.path
        ]
      )
      XCTAssertEqual(interrupted.terminationReason, .uncaughtSignal,
                     "\(checkpoint.rawValue) must be an abrupt OS signal termination; stdout: \(interrupted.stdout); stderr: \(interrupted.stderr)")
      XCTAssertEqual(interrupted.status, SIGKILL,
                     "\(checkpoint.rawValue) must terminate the first process with SIGKILL")
      if checkpoint == .prepared || checkpoint == .beforeChildNodeEffect || checkpoint == .parentIntentPersisted {
        XCTAssertFalse(FileManager.default.fileExists(atPath: effectMarker.path))
      } else {
        XCTAssertEqual(try String(contentsOf: effectMarker, encoding: .utf8), "effect",
                       "\(checkpoint.rawValue) must stop only after the child durable effect")
      }

      let persistence = SQLiteWorkflowRuntimePersistenceStore(
        rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
      )
      let parent = try XCTUnwrap(
        try persistence.loadAll().first(where: { $0.session.workflowId == "workflow-call-live-echo" }),
        "\(checkpoint.rawValue) must persist the interrupted parent before process exit: \(interrupted.stderr)"
      )
      let sourceExecutionId = try XCTUnwrap(
        parent.session.executions.first(where: { $0.stepId == "produce-request" })?.executionId
      )
      if checkpoint == .prepared {
        let stagedExecution = try XCTUnwrap(
          parent.session.executions.first(where: { $0.executionId == sourceExecutionId })
        )
        XCTAssertNil(stagedExecution.acceptedOutput,
                     "The parent stage must remain in memory until canonical nested publication")
        XCTAssertNil(stagedExecution.pendingRoutePublication,
                     "The waiting checkpoint must not precede its immutable nested intent")
        XCTAssertNil(try persistence.nestedInvocationRecord(
          parentSessionId: parent.session.sessionId,
          sourceStepExecutionId: sourceExecutionId,
          branchId: "cross-workflow"
        ), "The child reservation must appear only with the parent checkpoint")
      }

      let resumed = try runWorkflowProcess(
        executable: executable,
        repository: repository,
        arguments: workflowRunArguments(sessionStore: sessionStore, workflowRoot: fixtureRoot) + ["--resume-session-id", parent.session.sessionId],
        environment: ["RIELA_TEST_EFFECT_MARKER": effectMarker.path]
      )
      var durableSourceExecutionId = sourceExecutionId
      if checkpoint == .afterChildEffect {
        XCTAssertNotEqual(resumed.status, 0, "the unresolved effect must not be relaunched")
      } else {
        XCTAssertEqual(resumed.status, 0, "\(checkpoint.rawValue) reopen failed; stdout: \(resumed.stdout); stderr: \(resumed.stderr)")
        let result = try decodeJSON(WorkflowRunResult.self, from: resumed.stdout)
        XCTAssertEqual(result.status, .completed)
        if checkpoint == .prepared {
          durableSourceExecutionId = try XCTUnwrap(
            result.session.executions.last(where: {
              $0.stepId == "produce-request" && $0.status == .completed
            })?.executionId,
            "A pre-transaction process death must rerun the non-durable parent stage before reserving its child"
          )
        }
      }

      let record = try XCTUnwrap(try persistence.nestedInvocationRecord(
        parentSessionId: parent.session.sessionId,
        sourceStepExecutionId: durableSourceExecutionId,
        branchId: "cross-workflow"
      ))
      if checkpoint == .afterChildEffect {
        XCTAssertEqual(record.phase, .recoveryRequired)
        XCTAssertNil(record.childTerminalSnapshot)
      } else {
        XCTAssertEqual(record.phase, .delivered)
        let terminalChild = try XCTUnwrap(record.childTerminalSnapshot)
        XCTAssertEqual(terminalChild.session.status, .completed)
        XCTAssertEqual(terminalChild.session.executions.count, 1)
      }
      XCTAssertEqual(try String(contentsOf: effectMarker, encoding: .utf8), "effect",
                     "\(checkpoint.rawValue) must not relaunch the independently observable child effect")
      let arrivals = try SQLiteWorkflowMessageLog(
        databasePath: SQLiteWorkflowRuntimePersistenceStore.defaultDatabasePath(
          rootDirectory: canonicalRuntimeStoreRoot(sessionStoreRoot: sessionStore.path)
        )
      ).listMessages(workflowExecutionId: parent.session.sessionId, toStepId: "apply-result")
      XCTAssertEqual(arrivals.count, checkpoint == .afterChildEffect ? 0 : 1,
                     "\(checkpoint.rawValue) must not publish a parent arrival from an uncertain effect")
    }
  }

  private func repositoryRoot() -> String {
    FileManager.default.currentDirectoryPath
  }

  private func decodeJSON<T: Decodable>(_ type: T.Type, from stdout: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(type, from: Data(stdout.utf8))
  }

  private func workflowRunArguments(sessionStore: URL, workflowRoot: URL) -> [String] {
    [
      "workflow", "run", "workflow-call-live-echo",
      "--workflow-definition-dir", workflowRoot.path,
      "--session-store", sessionStore.path,
      "--output", "json"
    ]
  }

  private func runWorkflowProcess(
    executable: URL,
    repository: URL,
    arguments: [String],
    environment overrides: [String: String] = [:]
  ) throws -> WorkflowProcessResult {
    let process = try WorkflowSubprocessTestSupport.capture(
      executable: executable, arguments: arguments,
      logRoot: repository.appendingPathComponent("tmp/specialist-supervisor/process-recovery-logs"),
      workingDirectory: repository,
      environment: ProcessInfo.processInfo.environment.merging(overrides) { _, replacement in replacement }
    )
    return WorkflowProcessResult(
      status: process.status,
      terminationReason: process.terminationReason,
      stdout: process.stdout,
      stderr: process.stderr
    )
  }

  private func durableEffectFixture(repository: URL, sessionStore: URL) throws -> URL {
    let examples = repository.appendingPathComponent("examples", isDirectory: true)
    let fixtureRoot = sessionStore.appendingPathComponent("workflow-fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    for workflow in ["workflow-call-live-echo", "workflow-call-live-echo-callee"] {
      try FileManager.default.copyItem(
        at: examples.appendingPathComponent(workflow, isDirectory: true),
        to: fixtureRoot.appendingPathComponent(workflow, isDirectory: true)
      )
    }
    let node: [String: Any] = [
      "id": "echo-worker",
      "nodeType": "command",
      "command": [
        "executable": "/bin/sh",
        "arguments": [
          "-c",
          "printf effect >> \"$RIELA_TEST_EFFECT_MARKER\"; printf '%s\\n' '{\"calleeResult\":\"echoed:{{handoff}}\"}'"
        ]
      ]
    ]
    let nodeData = try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
    try nodeData.write(to: fixtureRoot.appendingPathComponent(
      "workflow-call-live-echo-callee/nodes/node-echo-worker.json"
    ))
    return fixtureRoot
  }

  private func currentWorkflowExecutable(repository: URL) throws -> URL {
    let scratch = repository.appendingPathComponent("tmp/specialist-supervisor/process-recovery-build")
    let swift = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    let build = try WorkflowSubprocessTestSupport.capture(
      executable: URL(fileURLWithPath: swift), arguments: ["build", "--product", "riela", "--scratch-path", scratch.path],
      logRoot: scratch.appendingPathComponent("logs"), workingDirectory: repository, timeout: 180
    )
    guard build.status == 0 else {
      throw NSError(domain: "WorkflowCommandCrossWorkflowDispatchTests", code: Int(build.status), userInfo: [
        NSLocalizedDescriptionKey: build.stderr
      ])
    }
    let locate = try WorkflowSubprocessTestSupport.capture(
      executable: URL(fileURLWithPath: swift), arguments: ["build", "--show-bin-path", "--scratch-path", scratch.path],
      logRoot: scratch.appendingPathComponent("logs"), workingDirectory: repository
    )
    let binPath = locate.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let executable = URL(fileURLWithPath: binPath).appendingPathComponent("riela")
    guard locate.status == 0, FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw NSError(domain: "WorkflowCommandCrossWorkflowDispatchTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "current product build did not produce riela"
      ])
    }
    return executable
  }
}
