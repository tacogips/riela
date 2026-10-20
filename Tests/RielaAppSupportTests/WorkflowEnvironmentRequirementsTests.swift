import Foundation
import XCTest
@testable import RielaAppSupport

final class WorkflowEnvironmentRequirementsTests: XCTestCase {
  func testAppCollectsExplicitAndBoundRequirementsWithoutOptionalBindings() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/environment-requirements-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workflow = #"{"requiredEnvironment":["ROOT_KEY","SHARED_KEY"],"nodes":[{"requiredEnvironment":["INLINE_KEY"],"nodeFile":"worker.json"}]}"#
    let payload = #"""
    {
      "requiredEnvironment": ["COMMAND_KEY", "SHARED_KEY"],
      "apiKeyEnvironment": "SDK_KEY",
      "addon": {"env": {
        "TOKEN": {"fromEnv": "ADDON_KEY"},
        "OPTIONAL": {"fromEnv": "OPTIONAL_KEY", "required": false}
      }},
      "agentEnvironment": {
        "REQUIRED": {"fromEnv": "AGENT_KEY", "required": true},
        "OPTIONAL": {"fromEnv": "OPTIONAL_AGENT_KEY"}
      }
    }
    """#
    try Data(workflow.utf8).write(to: root.appendingPathComponent("workflow.json"))
    try Data(payload.utf8).write(to: root.appendingPathComponent("worker.json"))
    let names = RielaAppWorkflowEnvironmentRequirements.requiredEnvironment(workflowDirectory: root).map(\.name)
    XCTAssertEqual(Set(names), ["ROOT_KEY", "SHARED_KEY", "INLINE_KEY", "COMMAND_KEY", "SDK_KEY", "ADDON_KEY", "AGENT_KEY"])
    XCTAssertEqual(names.count, Set(names).count)
  }
}
