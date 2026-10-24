import Foundation
import RielaCore
import XCTest
@testable import RielaAppSupport
@testable import RielaCLI

/// The managed-name set RielaApp sends over the private channel must be the
/// set the `riela events serve` child enforces, so both sides derive it from
/// `WorkflowEnvironmentRequirements.names` (RielaCore).
final class RuntimeEnvironmentSurfaceNamesTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    root = repository.appendingPathComponent("tmp/runtime-environment-surface-names/\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  func testAppRequiredNamesMatchTheCLIChildCollectorForATopLevelWorkflow() async throws {
    let workflow = root.appendingPathComponent("workflows/env-parity", isDirectory: true)
    try FileManager.default.createDirectory(at: workflow, withIntermediateDirectories: true)
    try write(#"""
      {"workflowId":"env-parity","defaults":{"nodeTimeoutMs":1000,"maxLoopIterations":3},
       "requiredEnvironment":["ROOT_KEY","SHARED_KEY"],
       "entryStepId":"work",
       "nodes":[
         {"id":"work","nodeFile":"work.json"},
         {"id":"agent","nodeFile":"agent.json"}
       ],
       "steps":[
         {"id":"work","nodeId":"work","transitions":[{"toStepId":"agent"}]},
         {"id":"agent","nodeId":"agent"}
       ]}
      """#, to: workflow.appendingPathComponent("workflow.json"))
    try write(#"""
      {"id":"work","nodeType":"command","modelFreeze":false,
       "requiredEnvironment":["COMMAND_KEY","SHARED_KEY","INLINE_KEY"],
       "command":{"executable":"/bin/echo","arguments":["{}"]}}
      """#, to: workflow.appendingPathComponent("work.json"))
    try write(#"""
      {"id":"agent","executionBackend":"codex-agent","model":"gpt-5.5",
       "agentEnvironment":{
         "REQUIRED_TARGET":{"fromEnv":"AGENT_KEY","required":true},
         "OPTIONAL_TARGET":{"fromEnv":"OPTIONAL_AGENT_KEY"}
       }}
      """#, to: workflow.appendingPathComponent("agent.json"))

    let resolution = WorkflowResolutionOptions(
      workflowName: "env-parity", workflowDefinitionDir: workflow.path, workingDirectory: root.path
    )
    let resolver = FileSystemWorkflowBundleResolver()
    let bundle = try resolver.resolve(resolution)
    let cli = try await CLIRuntimeEnvironmentPreparation.required(bundle: bundle, resolution: resolution, resolver: resolver)
    let app = RielaAppWorkflowEnvironmentRequirements.requiredEnvironment(workflowDirectory: workflow).map(\.name)

    XCTAssertEqual(Set(app), Set(cli))
    XCTAssertEqual(Set(cli), ["ROOT_KEY", "SHARED_KEY", "INLINE_KEY", "COMMAND_KEY", "AGENT_KEY"])
    XCTAssertEqual(app.count, Set(app).count)
  }

  private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
  }
}
