import Foundation
import XCTest
@testable import RielaCLI

final class WorkflowOutputContractCLIPreflightTests: XCTestCase {
  func testValidateRejectsNestedUnsupportedSchemaKeyword() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/schema-preflight-\(UUID().uuidString)")
    let bundle = root.appendingPathComponent("schema-check")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try """
    {"workflowId":"schema-check","description":"schema test","defaults":{"nodeTimeoutMs":120000,"maxLoopIterations":3},
     "entryStepId":"worker","nodes":[{"id":"worker","nodeFile":"nodes/worker.json"}],
     "steps":[{"id":"worker","nodeId":"worker"}]}
    """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
    try """
    {"id":"worker","executionBackend":"codex-agent","agentSandbox":"read-only","model":"model","variables":{},
     "output":{"jsonSchema":{"type":"object","properties":{"nested":{"if":{"type":"object"}}}}}}
    """.write(to: bundle.appendingPathComponent("nodes/worker.json"), atomically: true, encoding: .utf8)
    let result = await RielaCLIApplication().run([
      "workflow", "validate", "schema-check", "--workflow-definition-dir", root.path, "--output", "json"
    ])
    XCTAssertNotEqual(result.exitCode, .success)
    XCTAssertTrue((result.stdout + result.stderr).contains("$schema.properties.nested.if"), result.stdout + result.stderr)
    XCTAssertTrue((result.stdout + result.stderr).contains("unsupported JSON Schema keyword"))
  }
}
