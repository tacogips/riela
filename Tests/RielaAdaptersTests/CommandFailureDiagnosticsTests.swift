import Foundation
import XCTest
@testable import RielaAdapters
@testable import RielaCore

final class CommandFailureDiagnosticsTests: XCTestCase {
  let schema: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
    "required": .array([.string("status"), .string("count")]), "properties": .object([
      "status": .object(["type": .string("string"), "enum": .array([.string("failed")])]),
      "count": .object(["type": .string("integer"), "minimum": .integer(0), "maximum": .integer(100)])
    ])]

  func testRejectsPrivateExtraFieldsInvalidTypesAndBounds() throws {
    let policy = WorkflowFailureDiagnostics(schema: schema)
    XCTAssertNotNil(policy.metadata(from: #"{"status":"failed","count":2}"#))
    for raw in [#"{"status":"failed","count":2,"body":"PRIVATE"}"#,
                #"{"status":"PRIVATE","count":2}"#, #"{"status":"failed","count":101}"#,
                #"{"status":"failed","count":true}"#, #"{"status":"failed"}"#, "PRIVATE"] {
      XCTAssertNil(policy.metadata(from: raw))
    }
    XCTAssertNil(WorkflowFailureDiagnostics(schema: schema, maxBytes: 2).metadata(from: #"{"status":"failed","count":2}"#))
    XCTAssertNil(WorkflowFailureDiagnostics(schema: ["type": .string("object")]).metadata(from: "{}"))
    let decoded = try JSONDecoder().decode(WorkflowCommandExecution.self, from:
      JSONEncoder().encode(WorkflowCommandExecution(executable: "false", failureDiagnostics: policy)))
    XCTAssertEqual(decoded.failureDiagnostics, policy)
  }

  func testSelectedPathNeverRetainsPrivateSiblingsAndBoundsWholeEnvelope() throws {
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

  func testFiniteCollectionsAndDefaultDecoding() throws {
    let child: JSONValue = .object(["type": .string("array"), "maxItems": .integer(2),
      "items": .object(["type": .string("boolean")])])
    let root: JSONObject = ["type": .string("object"), "additionalProperties": .bool(false),
      "required": .array([.string("flags")]), "properties": .object(["flags": child])]
    let policy = WorkflowFailureDiagnostics(schema: root)
    XCTAssertNotNil(policy.metadata(from: #"{"flags":[true,false]}"#))
    XCTAssertNil(policy.metadata(from: #"{"flags":[true,false,true]}"#))
    XCTAssertNil(policy.metadata(from: #"{"flags":["PRIVATE"]}"#))
    let raw = try JSONEncoder().encode(JSONValue.object(["schema": .object(root)]))
    XCTAssertEqual(try JSONDecoder().decode(WorkflowFailureDiagnostics.self, from: raw).maxBytes, 16_384)
  }

  func testOversizedSuccessCannotBecomeAcceptedTruncatedOutput() async throws {
    let executor = LocalWorkflowStdioNodeExecutor(runner: FailureProcess(
      stdout: "{}" + String(repeating: " ", count: 65_536), status: 0))
    let node = AgentNodePayload(id: "node", nodeType: .command, model: "",
      command: WorkflowCommandExecution(executable: "false", failureDiagnostics: WorkflowFailureDiagnostics(schema: schema)))
    do {
      _ = try await executor.execute(WorkflowStdioNodeExecutionInput(workflowId: "fixture", sessionId: "fixture",
        stepId: "step", nodeId: "node", executionIndex: 1, kind: .command, node: node,
        variables: [:], resolvedInputPayload: [:]), context: AdapterExecutionContext())
      XCTFail("Oversized output must fail")
    } catch let error as AdapterExecutionError {
      XCTAssertEqual(error.code, .providerError)
      XCTAssertEqual(error.message, "command stdout exceeded diagnostic capture limit")
    }
  }

  func testFailedCommandRemainsFailureAndOnlyOptInFiniteMetadataIsEmitted() async throws {
    for enabled in [false, true] {
      let events = FailureEventCollector()
      let executor = LocalWorkflowStdioNodeExecutor(runner: FailureProcess())
      let node = AgentNodePayload(id: "node", nodeType: .command, model: "",
        command: WorkflowCommandExecution(executable: "false",
          failureDiagnostics: enabled ? WorkflowFailureDiagnostics(schema: schema) : nil))
      do {
        _ = try await executor.execute(WorkflowStdioNodeExecutionInput(workflowId: "fixture", sessionId: "fixture",
          stepId: "step", nodeId: "node", executionIndex: 1, kind: .command, node: node,
          variables: [:], resolvedInputPayload: [:]), context: AdapterExecutionContext { event in await events.add(event) })
        XCTFail("Failed stdout must never become accepted output")
      } catch let error as AdapterExecutionError {
        XCTAssertEqual(error.code, .providerError)
        XCTAssertFalse(error.message.contains("count"))
      }
      let captured = await events.values
      XCTAssertEqual(captured.count, enabled ? 1 : 0)
      if enabled {
        XCTAssertNil(captured[0].contentSnapshot)
        XCTAssertEqual(captured[0].metadata?["authoritative"], .bool(false))
        XCTAssertEqual(captured[0].metadata?["captureStatus"], .string("validated"))
      }
    }
  }
}

private struct FailureProcess: LocalProcessRunning {
  var stdout = #"{"status":"failed","count":2}"#
  var status: Int32 = 1
  func run(configuration: LocalProcessConfiguration, stdin: String, deadline: Date?) async throws -> LocalProcessResult {
    LocalProcessResult(stdout: stdout, stderr: "", terminationStatus: status)
  }
}
private actor FailureEventCollector {
  var values: [AdapterBackendEvent] = []
  func add(_ event: AdapterBackendEvent) { values.append(event) }
}
