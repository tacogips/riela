import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class CommandFailureDiagnosticsCaptureTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("status")]), "properties": .object([
      "status": .object(["type": .string("string"), "enum": .array([.string("failed")])])
    ])]

  func testBoundedCaptureReportsRetainedBytesAndInvalidUTF8WithoutSubstitution() async throws {
    let result = try await FoundationLocalProcessRunner().run(configuration: LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "head -c 30000 /dev/zero | LC_ALL=C tr '\\000' '\\377'"], stdoutCaptureByteLimit: 65_537),
      stdin: "", deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(result.terminationStatus, 0)
    XCTAssertEqual(result.stdoutRetainedByteCount, 30_000)
    XCTAssertTrue(result.stdoutInvalidUTF8)
    XCTAssertEqual(result.stdout, "")

    let unbounded = try await FoundationLocalProcessRunner().run(configuration: LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf ok"]),
      stdin: "", deadline: Date().addingTimeInterval(10))
    XCTAssertNil(unbounded.stdoutRetainedByteCount)
    XCTAssertFalse(unbounded.stdoutInvalidUTF8)
    XCTAssertEqual(unbounded.stdout, "ok")
  }

  func testInvalidUTF8UnderTheLimitIsReportedExplicitlyNotAsOverflow() async throws {
    let script = "head -c 30000 /dev/zero | LC_ALL=C tr '\\000' '\\377'; exit "
    for exitCode in [0, 5] {
      let events = EventCollector()
      do {
        _ = try await LocalWorkflowStdioNodeExecutor(runner: FoundationLocalProcessRunner()).execute(
          input(command: WorkflowCommandExecution(executable: "/bin/sh", arguments: ["-c", script + String(exitCode)],
            failureDiagnostics: WorkflowFailureDiagnostics(schema: schema))),
          context: AdapterExecutionContext { event in await events.add(event) })
        XCTFail("invalid UTF-8 stdout must fail")
      } catch let error as AdapterExecutionError {
        if exitCode == 0 {
          XCTAssertEqual(error.code, .invalidOutput)
          XCTAssertEqual(error.message, "command node stdout is not valid UTF-8")
        } else {
          XCTAssertEqual(error.code, .providerError)
          XCTAssertEqual(error.message, "command node 'node' failed with exit code 5: ")
        }
      }
      let captured = await events.values
      XCTAssertEqual(captured.count, exitCode == 0 ? 0 : 1)
      if exitCode != 0 {
        XCTAssertEqual(captured.first?.metadata, WorkflowFailureDiagnostics.eventMetadata(exitCode: 5, diagnostics: nil))
        XCTAssertEqual(captured.first?.eventType, WorkflowFailureDiagnostics.eventType)
      }
    }
  }

  func testOverflowUsesRetainedByteCountInsteadOfDecodedLength() async throws {
    let short = #"{"status":"failed"}"#
    do {
      _ = try await LocalWorkflowStdioNodeExecutor(runner: FixedProcess(result: LocalProcessResult(
        stdout: short, stderr: "", terminationStatus: 0, stdoutRetainedByteCount: 65_537
      ))).execute(input(command: command()), context: AdapterExecutionContext())
      XCTFail("retained bytes above the limit must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.message, "command stdout exceeded diagnostic capture limit")
    }

    let events = EventCollector()
    do {
      _ = try await LocalWorkflowStdioNodeExecutor(runner: FixedProcess(result: LocalProcessResult(
        stdout: short, stderr: "", terminationStatus: 2, stdoutRetainedByteCount: 65_537
      ))).execute(input(command: command()), context: AdapterExecutionContext { event in await events.add(event) })
      XCTFail("failed command must throw")
    } catch is AdapterExecutionError {}
    let captured = await events.values
    XCTAssertEqual(captured.first?.metadata?["captureStatus"], .string("rejected"))
    XCTAssertNil(captured.first?.metadata?["diagnostics"])

    let valid = try await LocalWorkflowStdioNodeExecutor(runner: FixedProcess(result: LocalProcessResult(
      stdout: short, stderr: "", terminationStatus: 0, stdoutRetainedByteCount: 65_536
    ))).execute(input(command: command()), context: AdapterExecutionContext())
    XCTAssertEqual(valid.payload?["status"], .string("failed"))
  }

  func testExecutorReceiptAlwaysPassesTheStoreShapeCheck() {
    let validated = WorkflowFailureDiagnostics.eventMetadata(exitCode: 9, diagnostics: ["status": .string("failed")])
    let rejected = WorkflowFailureDiagnostics.eventMetadata(exitCode: -1, diagnostics: nil)
    for metadata in [validated, rejected] {
      XCTAssertEqual(WorkflowFailureDiagnostics.retainedEventMetadata(
        eventType: WorkflowFailureDiagnostics.eventType, metadata: metadata), metadata)
      XCTAssertNil(WorkflowFailureDiagnostics.retainedEventMetadata(eventType: "other", metadata: metadata))
    }
  }

  private func command() -> WorkflowCommandExecution {
    WorkflowCommandExecution(executable: "false", failureDiagnostics: WorkflowFailureDiagnostics(schema: schema))
  }

  private func input(command: WorkflowCommandExecution) -> WorkflowStdioNodeExecutionInput {
    WorkflowStdioNodeExecutionInput(workflowId: "fixture", sessionId: "fixture", stepId: "step", nodeId: "node",
      executionIndex: 1, kind: .command,
      node: AgentNodePayload(id: "node", nodeType: .command, model: "", command: command),
      variables: [:], resolvedInputPayload: [:])
  }
}

private struct FixedProcess: LocalProcessRunning {
  var result: LocalProcessResult

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    result
  }
}

private actor EventCollector {
  private(set) var values: [AdapterBackendEvent] = []
  func add(_ event: AdapterBackendEvent) { values.append(event) }
}
