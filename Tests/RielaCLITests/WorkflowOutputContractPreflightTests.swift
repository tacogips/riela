import Foundation
import XCTest
@testable import RielaCLI

final class WorkflowOutputContractCLIPreflightTests: XCTestCase {
  func testValidateUsesExactCatalogForwardingEvidence() async throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = repository.appendingPathComponent("tmp/catalog-preflight-\(UUID().uuidString)")
    let bundle = root.appendingPathComponent("catalog-check")
    try FileManager.default.createDirectory(at: bundle.appendingPathComponent("nodes"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"id":"agent","executionBackend":"codex-agent","agentSandbox":"read-only","model":"model","output":{"jsonSchema":{"type":"object","required":["flag"],"properties":{"flag":{"type":"boolean"}}}}}"#
      .write(to: bundle.appendingPathComponent("nodes/agent.json"), atomically: true, encoding: .utf8)
    func validate(_ version: String) async throws -> CLICommandResult {
      try """
      {"workflowId":"catalog-check","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":2},
       "entryStepId":"produce","nodes":[{"id":"agent","nodeFile":"nodes/agent.json"},
       {"id":"reply","addon":{"name":"riela/chat-reply-worker","version":"\(version)"}}],
       "steps":[{"id":"produce","nodeId":"agent","transitions":[{"toStepId":"reply"}]},
       {"id":"reply","nodeId":"reply","transitions":[{"toStepId":"done","label":"flag"}]},
       {"id":"done","nodeId":"reply"}]}
      """.write(to: bundle.appendingPathComponent("workflow.json"), atomically: true, encoding: .utf8)
      return await RielaCLIApplication().run([
        "workflow", "validate", "catalog-check", "--workflow-definition-dir", root.path, "--output", "json"
      ])
    }
    let matching = try await validate("1")
    XCTAssertFalse(matching.stdout.contains("analysis_incomplete: route control 'flag'"), matching.stdout)
    let mismatch = try await validate("2")
    XCTAssertTrue(mismatch.stdout.contains("analysis_incomplete: route control 'flag'"), mismatch.stdout)
  }

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
