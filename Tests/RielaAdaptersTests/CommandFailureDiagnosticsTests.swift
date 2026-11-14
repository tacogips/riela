import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class CommandFailureDiagnosticsTests: XCTestCase {
  private let schema: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("status"), .string("count")]), "properties": .object([
      "status": .object(["type": .string("string"), "enum": .array([.string("failed")])]),
      "count": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(100)])
    ])]

  func testRejectsInvalidValuesSchemasAndBounds() throws {
    let policy = WorkflowFailureDiagnostics(schema: schema)
    XCTAssertNotNil(policy.metadata(from: #"{"status":"failed","count":2}"#))
    for raw in [#"{"status":"failed","count":2,"body":"PRIVATE"}"#,
                #"{"status":"PRIVATE","count":2}"#, #"{"status":"failed","count":101}"#,
                #"{"status":"failed","count":true}"#, #"{"status":"failed"}"#, "PRIVATE"] {
      XCTAssertNil(policy.metadata(from: raw))
    }
    XCTAssertNil(WorkflowFailureDiagnostics(schema: schema, maxBytes: 0).metadata(from: #"{"status":"failed","count":2}"#))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: schema, maxBytes: 65_537).metadata(from: #"{"status":"failed","count":2}"#))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: ["type": .string("object")]).metadata(from: "{}"))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: ["type": .string("string")]).metadata(from: #""free""#))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: ["type": .string("integer"), "minimum": .integer(0),
      "maximum": .integer(1_000_000_001)]).metadata(from: "1"))
    let tooMany: JSONObject = ["type": .string("array"), "items": .object(["type": .string("boolean")]),
      "maxItems": .integer(257)]
    XCTAssertNil(WorkflowFailureDiagnostics(schema: tooMany).metadata(from: "[]"))
    let decoded = try JSONDecoder().decode(WorkflowCommandExecution.self,
      from: JSONEncoder().encode(WorkflowCommandExecution(executable: "false", failureDiagnostics: policy)))
    XCTAssertEqual(decoded.failureDiagnostics, policy)
  }

  func testSelectedPathNeverRetainsPrivateSiblings() throws {
    let policy = WorkflowFailureDiagnostics(schema: schema, path: ["diagnostics"])
    let raw = #"{"private":"DO_NOT_RETAIN","diagnostics":{"status":"failed","count":2}}"#
    XCTAssertEqual(policy.metadata(from: raw), ["status": .string("failed"), "count": .integer(2)])
    XCTAssertNil(policy.metadata(from: #"{"other":{"status":"failed","count":2}}"#))
    XCTAssertNil(policy.metadata(from: #"{"diagnostics":[{"status":"failed","count":2}]}"#))
    XCTAssertNil(policy.metadata(from: raw + String(repeating: " ", count: 65_536)))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: schema, maxBytes: 2, path: ["diagnostics"]).metadata(from: raw))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowFailureDiagnostics.self,
      from: JSONEncoder().encode(policy)), policy)
  }

  func testRealProcessDrainsOversizeOutputButRetainsOnlyBoundedPrefix() async throws {
    let result = try await FoundationLocalProcessRunner().run(configuration: LocalProcessConfiguration(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "head -c 1048576 /dev/zero; exit 1"], stdoutCaptureByteLimit: 65_537),
      stdin: "", deadline: Date().addingTimeInterval(10))
    XCTAssertEqual(result.terminationStatus, 1)
    XCTAssertEqual(result.stdout.utf8.count, 65_537)
    XCTAssertNil(WorkflowFailureDiagnostics(schema: schema).metadata(from: result.stdout))
  }

  func testRealProcessRejectsMultibyteOverflowForSuccessAndFailure() async throws {
    let script = "printf '{\"text\":\"'; yes 'あ' | tr -d '\\n' | head -c 90000; printf '\"}\\n'; exit "
    for exitCode in [0, 7] {
      let events = DiagnosticEventCollector()
      let executor = makeExecutor(runner: FoundationLocalProcessRunner())
      do {
        _ = try await executor.execute(
          makeInput(command: WorkflowCommandExecution(
            executable: "/bin/sh",
            arguments: ["-c", script + String(exitCode)],
            failureDiagnostics: WorkflowFailureDiagnostics(schema: schema)
          )),
          context: AdapterExecutionContext { event in await events.add(event) }
        )
        XCTFail("multibyte stdout above the capture limit must fail")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        if exitCode == 0 {
          XCTAssertEqual(error.message, "command stdout exceeded diagnostic capture limit")
        }
      }

      let captured = await events.values
      if exitCode == 0 {
        XCTAssertTrue(captured.isEmpty)
      } else {
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.metadata?["captureStatus"], .string("rejected"))
        XCTAssertNil(captured.first?.metadata?["diagnostics"])
      }
    }
  }

  func testProcessConfigurationIsOptInAndKeepsEnvironmentIsolated() async throws {
    for enabled in [false, true] {
      let recorder = DiagnosticConfigurationRecorder()
      let runner = DiagnosticProcess(stdout: #"{"status":"failed","count":2}"#, status: 0, recorder: recorder)
      let command = WorkflowCommandExecution(executable: "true",
        failureDiagnostics: enabled ? WorkflowFailureDiagnostics(schema: schema) : nil)
      _ = try await makeExecutor(runner: runner).execute(makeInput(command: command), context: AdapterExecutionContext())
      let recordedConfigurations = await recorder.values
      let configuration = try XCTUnwrap(recordedConfigurations.last)
      XCTAssertFalse(configuration.inheritEnvironment)
      XCTAssertEqual(configuration.stdoutCaptureByteLimit, enabled ? 65_537 : nil)
    }
  }

  func testExactlyLimitSuccessIsAcceptedAndOverflowSuccessFails() async throws {
    let exactOutput = #"{"status":"failed","count":2}"# + String(repeating: " ", count: 65_536 - 29)
    XCTAssertEqual(exactOutput.utf8.count, 65_536)
    let valid = try await makeExecutor(runner: DiagnosticProcess(stdout: exactOutput, status: 0)).execute(
      makeInput(command: command()), context: AdapterExecutionContext())
    XCTAssertEqual(valid.payload?["count"], .integer(2))

    do {
      _ = try await makeExecutor(runner: DiagnosticProcess(
        stdout: #"{"status":"failed","count":2}"# + String(repeating: " ", count: 65_536), status: 0
      )).execute(makeInput(command: command()), context: AdapterExecutionContext())
      XCTFail("oversized output must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "command stdout exceeded diagnostic capture limit")
    }
  }

  func testFailedCommandEmitsOnlyOptInBoundedMetadataAndStillFails() async throws {
    for enabled in [false, true] {
      let events = DiagnosticEventCollector()
      let executor = makeExecutor(runner: DiagnosticProcess(stdout: #"{"status":"failed","count":2}"#, status: 7))
      do {
        _ = try await executor.execute(makeInput(command: command(enabled: enabled)),
          context: AdapterExecutionContext { event in await events.add(event) })
        XCTFail("failed stdout must never become accepted output")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        XCTAssertEqual(error.message, "command node 'node' failed with exit code 7: ")
      }
      let captured = await events.values
      XCTAssertEqual(captured.count, enabled ? 1 : 0)
      if enabled, let event = captured.first {
        XCTAssertEqual(event.provider, "command")
        XCTAssertEqual(event.eventType, "command_failure_diagnostics")
        XCTAssertEqual(event.channel, .lifecycle)
        XCTAssertEqual(event.metadata?["authoritative"], .bool(false))
        XCTAssertEqual(event.metadata?["exitCode"], .integer(7))
        XCTAssertEqual(event.metadata?["captureStatus"], .string("validated"))
        XCTAssertEqual(event.metadata?["diagnostics"], .object(["status": .string("failed"), "count": .integer(2)]))
        XCTAssertNil(event.contentSnapshot)
      }
    }
  }

  func testRejectedFailureReceiptContainsNoRawStdoutFragmentsOrSiblings() async throws {
    let raw = #"{"private":"DO_NOT_RETAIN","diagnostics":{"status":"failed","count":2,"extra":"SECRET"}}"#
    let events = DiagnosticEventCollector()
    do {
      _ = try await makeExecutor(runner: DiagnosticProcess(stdout: raw, status: 1)).execute(
        makeInput(command: command(path: ["diagnostics"])),
        context: AdapterExecutionContext { event in await events.add(event) })
      XCTFail("failed command must throw")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
    let capturedEvents = await events.values
    let event = try XCTUnwrap(capturedEvents.first)
    XCTAssertEqual(event.metadata?["captureStatus"], .string("rejected"))
    XCTAssertNil(event.metadata?["diagnostics"])
    let encodedEvent = try JSONEncoder().encode(event)
    let serialized = try XCTUnwrap(String(data: encodedEvent, encoding: .utf8))
    XCTAssertFalse(serialized.contains("DO_NOT_RETAIN"))
    XCTAssertFalse(serialized.contains("SECRET"))
    XCTAssertFalse(serialized.contains("extra"))

    let oversizedEvents = DiagnosticEventCollector()
    let oversizedStdout = #"{"status":"failed","count":2}"# + String(repeating: " ", count: 65_508)
    XCTAssertEqual(oversizedStdout.utf8.count, 65_537)
    do {
      _ = try await makeExecutor(runner: DiagnosticProcess(stdout: oversizedStdout, status: 1)).execute(
        makeInput(command: command()), context: AdapterExecutionContext { event in await oversizedEvents.add(event) })
      XCTFail("failed command must throw")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
    }
    let oversizedReceipts = await oversizedEvents.values
    let oversizedReceipt = try XCTUnwrap(oversizedReceipts.first)
    XCTAssertEqual(oversizedReceipts.count, 1)
    XCTAssertEqual(oversizedReceipt.metadata?["captureStatus"], .string("rejected"))
    XCTAssertNil(oversizedReceipt.metadata?["diagnostics"])
  }

  private func command(enabled: Bool = true, path: [String] = []) -> WorkflowCommandExecution {
    WorkflowCommandExecution(executable: "false",
      failureDiagnostics: enabled ? WorkflowFailureDiagnostics(schema: schema, path: path) : nil)
  }

  private func makeInput(command: WorkflowCommandExecution) -> WorkflowStdioNodeExecutionInput {
    WorkflowStdioNodeExecutionInput(workflowId: "fixture", sessionId: "fixture", stepId: "step", nodeId: "node",
      executionIndex: 1, kind: .command,
      node: AgentNodePayload(id: "node", nodeType: .command, model: "", command: command),
      variables: [:], resolvedInputPayload: [:])
  }

  private func makeExecutor(runner: any LocalProcessRunning) -> LocalWorkflowStdioNodeExecutor {
    LocalWorkflowStdioNodeExecutor(runner: runner)
  }
}

private struct DiagnosticProcess: LocalProcessRunning {
  var stdout: String
  var status: Int32
  var recorder: DiagnosticConfigurationRecorder?

  init(stdout: String, status: Int32, recorder: DiagnosticConfigurationRecorder? = nil) {
    self.stdout = stdout
    self.status = status
    self.recorder = recorder
  }

  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    await recorder?.add(configuration)
    return LocalProcessResult(stdout: stdout, stderr: "", terminationStatus: status)
  }
}

private actor DiagnosticConfigurationRecorder {
  private(set) var values: [LocalProcessConfiguration] = []
  func add(_ value: LocalProcessConfiguration) { values.append(value) }
}

private actor DiagnosticEventCollector {
  private(set) var values: [AdapterBackendEvent] = []
  func add(_ event: AdapterBackendEvent) { values.append(event) }
}
