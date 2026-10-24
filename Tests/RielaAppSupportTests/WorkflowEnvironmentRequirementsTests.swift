import Foundation
import RielaCore
import XCTest
@testable import RielaAppSupport

final class WorkflowEnvironmentRequirementsTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("tmp/environment-requirements-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// Names come from the RielaCore collector the CLI child uses; package
  /// requirements keep their descriptions and secret flags.
  func testAppCollectsExplicitAndBoundRequirementsWithoutOptionalBindings() throws {
    let workflow = #"""
      {"workflowId":"requirements","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},
       "requiredEnvironment":["ROOT_KEY","SHARED_KEY"],"entryStepId":"worker",
       "nodes":[{"id":"worker","nodeFile":"worker.json"}],
       "steps":[{"id":"worker","nodeId":"worker"}]}
      """#
    let payload = #"""
      {"id":"worker","executionBackend":"codex-agent","model":"gpt-5.5",
       "requiredEnvironment":["COMMAND_KEY","SHARED_KEY","INLINE_KEY"],
       "agentEnvironment":{
         "REQUIRED":{"fromEnv":"AGENT_KEY","required":true},
         "OPTIONAL":{"fromEnv":"OPTIONAL_AGENT_KEY"}
       }}
      """#
    try Data(workflow.utf8).write(to: root.appendingPathComponent("workflow.json"))
    try Data(payload.utf8).write(to: root.appendingPathComponent("worker.json"))
    let package = RielaAppEnvRequirement(name: "SHARED_KEY", description: "Shared credential", secret: true)
    let requirements = RielaAppWorkflowEnvironmentRequirements.requiredEnvironment(
      workflowDirectory: root, packageRequirements: [package]
    )
    let names = requirements.map(\.name)
    XCTAssertEqual(Set(names), ["ROOT_KEY", "SHARED_KEY", "INLINE_KEY", "COMMAND_KEY", "AGENT_KEY"])
    XCTAssertEqual(names.count, Set(names).count)
    XCTAssertEqual(requirements.first { $0.name == "SHARED_KEY" }, package)
  }

  /// An invalid or unreadable workflow (which the CLI refuses to run) adds no
  /// names, and a node file outside the workflow directory is never read.
  func testInvalidWorkflowAndEscapingNodeFileContributeNoNames() throws {
    try Data(#"{"requiredEnvironment":["ROOT_KEY"],"nodes":[]}"#.utf8)
      .write(to: root.appendingPathComponent("workflow.json"))
    let package = RielaAppEnvRequirement(name: "PACKAGE_KEY")
    XCTAssertEqual(
      RielaAppWorkflowEnvironmentRequirements.requiredEnvironment(workflowDirectory: root, packageRequirements: [package]),
      [package]
    )

    let nested = root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data(#"{"id":"worker","requiredEnvironment":["OUTSIDE_KEY"]}"#.utf8)
      .write(to: root.appendingPathComponent("outside.json"))
    try Data(#"""
      {"workflowId":"escape","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},"entryStepId":"worker",
       "nodes":[{"id":"worker","nodeFile":"../outside.json"}],"steps":[{"id":"worker","nodeId":"worker"}]}
      """#.utf8).write(to: nested.appendingPathComponent("workflow.json"))
    XCTAssertFalse(RielaAppWorkflowEnvironmentRequirements.workflowNames(workflowDirectory: nested).contains("OUTSIDE_KEY"))
  }

  /// Loader-managed names are not "missing" just because the pre-loader
  /// environment lacks them; the published snapshot decides after a load.
  func testPresenceRuleConsidersLoaderManagedNames() {
    let resolution = RuntimeEnvironmentConfiguration(sources: [
      RuntimeEnvironmentCommandSource(id: "loader", names: ["LOADER_KEY"], command: ["/bin/echo"])
    ])
    let names = ["FILE_KEY", "LOADER_KEY", "OTHER_KEY"]
    let environment = ["FILE_KEY": "value", "OTHER_KEY": "  "]
    XCTAssertEqual(
      RielaAppEnvironmentPresence.missingNames(names, environment: environment, resolution: resolution, status: .init()),
      ["OTHER_KEY"]
    )
    XCTAssertEqual(
      RielaAppEnvironmentPresence.missingNames(names, environment: environment, resolution: nil, status: .init()),
      ["LOADER_KEY", "OTHER_KEY"]
    )
    let loaded = RuntimeEnvironmentStatus(names: ["LOADER_KEY"], configuredNames: ["LOADER_KEY"], generation: 1, readiness: .ready)
    XCTAssertEqual(
      RielaAppEnvironmentPresence.missingNames(names, environment: environment, resolution: resolution, status: loaded),
      ["OTHER_KEY"]
    )
    let loadedWithoutValue = RuntimeEnvironmentStatus(names: ["LOADER_KEY"], generation: 1, readiness: .ready)
    XCTAssertEqual(
      RielaAppEnvironmentPresence.missingNames(names, environment: environment, resolution: resolution, status: loadedWithoutValue),
      ["LOADER_KEY", "OTHER_KEY"]
    )
    let failed = RuntimeEnvironmentStatus(names: ["LOADER_KEY"], readiness: .failed, lastError: .sourceFailed)
    XCTAssertEqual(
      RielaAppEnvironmentPresence.missingNames(names, environment: environment, resolution: resolution, status: failed),
      ["LOADER_KEY", "OTHER_KEY"]
    )
  }
}
